#Requires -Version 5.1
<#
.SYNOPSIS
    Collects vSphere deployment diagnostic logs to investigate failed VM provisioning.
.DESCRIPTION
    Pulls customization events, VMware Tools status, task history, and optionally
    guest-side logs (sysprep / cloud-init / vmware-imc) for one or more VMs.
    Useful for diagnosing Terraform/Caster deployment failures such as:
      - Customization timeouts
      - Sysprep failures
      - Cloud-init failures
      - Cloning errors
.PARAMETER VMName
    One or more VM names to investigate. Accepts wildcards.
.PARAMETER VIServer
    vCenter hostname or IP. If omitted, uses any existing VIServer connection.
.PARAMETER Credential
    Credentials for vCenter. Prompts if not supplied and not already connected.
.PARAMETER GuestCredential
    Credentials for the guest OS (required for pulling in-guest logs).
    If omitted, in-guest log collection is skipped.
.PARAMETER HoursBack
    How far back to search for events and tasks (default: 24 hours).
.PARAMETER OutputPath
    Folder to write the HTML report to. Defaults to the script directory.
.PARAMETER SkipGuestLogs
    Skip attempting to pull logs from inside the guest OS.
.EXAMPLE
    .\Get-DeploymentDiagnostics.ps1 -VMName "OFFICE-WKS1-CLDT"
.EXAMPLE
    .\Get-DeploymentDiagnostics.ps1 -VMName "OFFICE-WKS1-*" -HoursBack 48 -VIServer vcenter.lab.local
.EXAMPLE
    .\Get-DeploymentDiagnostics.ps1 -VMName "OFFICE-WKS1-CLDT" -GuestCredential (Get-Credential)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$VMName,

    [string]$VIServer,

    [System.Management.Automation.PSCredential]$Credential,

    [System.Management.Automation.PSCredential]$GuestCredential,

    [int]$HoursBack = 24,

    [string]$OutputPath,

    [switch]$SkipGuestLogs
)

# Default OutputPath: script directory if available, otherwise current working directory
if (-not $OutputPath) {
    $OutputPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region Helpers

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "  [*] $Message" -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Yellow
}

#endregion

#region vCenter Connection

Write-Section "vCenter Connection"

if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    if (-not $VIServer) {
        $VIServer = Read-Host "Enter vCenter hostname or IP"
    }
    $connectParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
    if ($Credential) { $connectParams.Credential = $Credential }
    Write-Status "Connecting to $VIServer..."
    Connect-VIServer @connectParams | Out-Null
} else {
    Write-Status "Using existing connection: $($global:DefaultVIServers.Name -join ', ')" -Color Green
}

#endregion

#region Collect Data Per VM

$report = [System.Collections.Generic.List[hashtable]]::new()
$startTime = (Get-Date).AddHours(-$HoursBack)

foreach ($name in $VMName) {
    Write-Section "Investigating VM: $name"

    $vms = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vms) {
        Write-Host "  [!] VM '$name' not found — skipping." -ForegroundColor Red
        continue
    }

    foreach ($vm in $vms) {
        Write-Status "Found VM: $($vm.Name) | Power: $($vm.PowerState) | Host: $($vm.VMHost)"

        $entry = @{
            VMName            = $vm.Name
            PowerState        = $vm.PowerState.ToString()
            VMHost            = $vm.VMHost.Name
            Datastore         = ($vm | Get-Datastore | Select-Object -First 1).Name
            NumCPU            = $vm.NumCpu
            MemoryGB          = $vm.MemoryGB
            GuestOS           = $vm.Guest.OSFullName
            ToolsStatus       = $vm.Guest.State.ToString()
            ToolsRunning      = ''
            ToolsVersion      = ''
            IPAddresses       = ''
            Hostname          = ''
            CustomizationInfo = ''
            CustomEvents      = @()
            FailedTasks       = @()
            GuestLogs         = @{}
        }

        #region VMware Tools & Guest Info
        Write-Status "Checking VMware Tools and guest info..."
        try {
            $view = $vm | Get-View -ErrorAction Stop
            $guest = $view.Guest
            $entry.ToolsRunning  = $guest.ToolsRunningStatus
            $entry.ToolsVersion  = $guest.ToolsVersion
            $entry.IPAddresses   = ($guest.Net | ForEach-Object { $_.IpAddress } | Where-Object { $_ }) -join ', '
            $entry.Hostname      = $guest.HostName

            $custInfo = $guest.CustomizationInfo
            if ($custInfo) {
                $entry.CustomizationInfo = "State: $($custInfo.CustomizationStatus) | Start: $($custInfo.StartTime) | End: $($custInfo.EndTime)"
            } else {
                $entry.CustomizationInfo = "No customization info available"
            }
        } catch {
            Write-Host "  [!] Could not retrieve guest view: $_" -ForegroundColor DarkYellow
        }
        #endregion

        #region Customization Events
        Write-Status "Pulling customization events (last $HoursBack hours)..."
        try {
            $events = Get-VIEvent -Entity $vm -Start $startTime -MaxSamples 200 -ErrorAction Stop |
                Where-Object { $_.FullFormattedMessage -match 'customiz|clone|deploy|template|sysprep|vmtools' -or
                               $_.GetType().Name -match 'Customization|Clone|Error' } |
                Sort-Object CreatedTime

            $entry.CustomEvents = $events | ForEach-Object {
                [PSCustomObject]@{
                    Time    = $_.CreatedTime.ToString('yyyy-MM-dd HH:mm:ss')
                    Type    = $_.GetType().Name
                    Message = $_.FullFormattedMessage
                }
            }

            if ($entry.CustomEvents.Count -eq 0) {
                Write-Host "  [~] No customization/deployment events found in the last $HoursBack hours." -ForegroundColor DarkGray
            } else {
                Write-Status "Found $($entry.CustomEvents.Count) relevant event(s)." -Color Green
                $entry.CustomEvents | ForEach-Object {
                    $color = if ($_.Message -match 'fail|error|timeout') { 'Red' } else { 'Gray' }
                    Write-Host "    $($_.Time)  [$($_.Type)]  $($_.Message)" -ForegroundColor $color
                }
            }
        } catch {
            Write-Host "  [!] Could not retrieve events: $_" -ForegroundColor DarkYellow
        }
        #endregion

        #region Task History
        Write-Status "Pulling recent task history..."
        try {
            $allTasks = Get-Task -Entity $vm -ErrorAction Stop |
                Where-Object { $_.StartTime -ge $startTime } |
                Sort-Object StartTime -Descending

            $entry.FailedTasks = $allTasks | ForEach-Object {
                [PSCustomObject]@{
                    Task        = $_.Name
                    State       = $_.State.ToString()
                    Start       = $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
                    Finish      = if ($_.FinishTime) { $_.FinishTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'In Progress' }
                    Description = $_.Description
                    Error       = if ($_.State -eq 'Error') { $_.ExtensionData.Info.Error.LocalizedMessage } else { '' }
                }
            }

            if ($entry.FailedTasks.Count -eq 0) {
                Write-Host "  [~] No tasks found in the last $HoursBack hours." -ForegroundColor DarkGray
            } else {
                $entry.FailedTasks | ForEach-Object {
                    $color = if ($_.State -eq 'Error') { 'Red' } elseif ($_.State -eq 'Running') { 'Yellow' } else { 'Gray' }
                    Write-Host "    $($_.Start) - $($_.Task) [$($_.State)]$(if($_.Error){" ERROR: $($_.Error)"})" -ForegroundColor $color
                }
            }
        } catch {
            Write-Host "  [!] Could not retrieve tasks: $_" -ForegroundColor DarkYellow
        }
        #endregion

        #region Guest Logs via VMware Tools
        if (-not $SkipGuestLogs -and $GuestCredential) {
            Write-Status "Attempting to pull in-guest logs via VMware Tools..."

            if ($vm.Guest.State -ne 'Running') {
                Write-Host "  [!] VMware Tools not running — cannot pull guest logs." -ForegroundColor DarkYellow
            } else {
                $logPaths = @{
                    # Windows logs
                    'Customization_guestcust.log'   = 'if (Test-Path "C:\Windows\Temp\vmware-imc\guestcust.log") { Get-Content "C:\Windows\Temp\vmware-imc\guestcust.log" -Raw } else { "FILE_NOT_FOUND" }'
                    'Customization_toolsDeploy.log' = 'if (Test-Path "C:\Windows\Temp\vmware-imc\toolsDeployPkg.log") { Get-Content "C:\Windows\Temp\vmware-imc\toolsDeployPkg.log" -Raw } else { "FILE_NOT_FOUND" }'
                    'Sysprep_setupact.log'          = 'if (Test-Path "C:\Windows\Panther\setupact.log") { Get-Content "C:\Windows\Panther\setupact.log" -Tail 100 -Raw } else { "FILE_NOT_FOUND" }'
                    'Sysprep_setuperr.log'          = 'if (Test-Path "C:\Windows\Panther\setuperr.log") { Get-Content "C:\Windows\Panther\setuperr.log" -Raw } else { "FILE_NOT_FOUND" }'

                    # Linux logs (bash)
                    'Linux_guestcust.log'           = 'cat /var/log/vmware-imc/toolsDeployPkg.log 2>/dev/null || echo FILE_NOT_FOUND'
                    'Linux_cloud-init.log'          = 'tail -100 /var/log/cloud-init.log 2>/dev/null || echo FILE_NOT_FOUND'
                    'Linux_cloud-init-output.log'   = 'tail -100 /var/log/cloud-init-output.log 2>/dev/null || echo FILE_NOT_FOUND'
                }

                foreach ($logName in $logPaths.Keys) {
                    $isLinux = $logName.StartsWith('Linux_')
                    $scriptType = if ($isLinux) { 'Bash' } else { 'PowerShell' }
                    try {
                        Write-Status "  Fetching $logName..." -Color DarkGray
                        $result = Invoke-VMScript -VM $vm -ScriptText $logPaths[$logName] `
                            -GuestCredential $GuestCredential -ScriptType $scriptType `
                            -ErrorAction Stop
                        $content = $result.ScriptOutput.Trim()
                        if ($content -ne 'FILE_NOT_FOUND') {
                            $entry.GuestLogs[$logName] = $content
                            Write-Host "  [+] $logName retrieved ($($content.Length) chars)." -ForegroundColor Green
                        }
                    } catch {
                        # Silently skip — wrong OS type for the script, tools not running, etc.
                        Write-Verbose "Skipped $logName`: $_"
                    }
                }
            }
        } elseif (-not $SkipGuestLogs -and -not $GuestCredential) {
            Write-Host "  [~] Skipping guest logs — use -GuestCredential to enable." -ForegroundColor DarkGray
        }
        #endregion

        $report.Add($entry)
    }
}

#endregion

#region Console Summary

Write-Section "Summary"
foreach ($entry in $report) {
    Write-Host "`nVM: $($entry.VMName)" -ForegroundColor White
    Write-Host "  Power State   : $($entry.PowerState)"
    Write-Host "  VMware Tools  : $($entry.ToolsRunning) (v$($entry.ToolsVersion))"
    Write-Host "  Guest IP(s)   : $($entry.IPAddresses)"
    Write-Host "  Hostname      : $($entry.Hostname)"
    Write-Host "  Customization : $($entry.CustomizationInfo)"

    $errEvents = $entry.CustomEvents | Where-Object { $_.Message -match 'fail|error|timeout' }
    if ($errEvents) {
        Write-Host "  Errors Found  : $($errEvents.Count) event error(s)" -ForegroundColor Red
        $errEvents | ForEach-Object { Write-Host "    - $($_.Time): $($_.Message)" -ForegroundColor Red }
    }

    $errTasks = $entry.FailedTasks | Where-Object { $_.State -eq 'Error' }
    if ($errTasks) {
        Write-Host "  Failed Tasks  : $($errTasks.Count)" -ForegroundColor Red
        $errTasks | ForEach-Object { Write-Host "    - $($_.Task): $($_.Error)" -ForegroundColor Red }
    }

    if ($entry.GuestLogs.Count -gt 0) {
        Write-Host "  Guest Logs    : $($entry.GuestLogs.Keys -join ', ')" -ForegroundColor Green
    }
}

#endregion

#region HTML Report

Write-Section "Generating HTML Report"

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportFile = Join-Path $OutputPath "DeployDiag_${timestamp}.html"

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine(@"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Deployment Diagnostics - $timestamp</title>
<style>
  body { font-family: Consolas, monospace; background: #1e1e1e; color: #d4d4d4; margin: 20px; }
  h1   { color: #569cd6; }
  h2   { color: #4ec9b0; border-bottom: 1px solid #333; padding-bottom: 4px; }
  h3   { color: #dcdcaa; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 16px; }
  th   { background: #2d2d2d; color: #9cdcfe; text-align: left; padding: 6px 10px; }
  td   { padding: 5px 10px; border-bottom: 1px solid #2d2d2d; vertical-align: top; }
  tr:hover td { background: #252526; }
  .error { color: #f44747; }
  .warn  { color: #ce9178; }
  .ok    { color: #6a9955; }
  .info  { color: #9cdcfe; }
  pre  { background: #252526; padding: 10px; overflow-x: auto; font-size: 12px;
          white-space: pre-wrap; word-break: break-all; max-height: 400px; overflow-y: auto; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 11px; font-weight: bold; }
  .badge-error { background: #5a1d1d; color: #f44747; }
  .badge-ok    { background: #1e3b1e; color: #6a9955; }
  .badge-warn  { background: #3b2b1e; color: #ce9178; }
</style>
</head>
<body>
<h1>Deployment Diagnostics Report</h1>
<p>Generated: $(Get-Date -Format 'dddd, MMMM dd yyyy HH:mm:ss')<br>
Period: Last $HoursBack hours</p>
"@)

foreach ($entry in $report) {
    [void]$sb.AppendLine("<h2>VM: $($entry.VMName)</h2>")

    # VM Info table
    [void]$sb.AppendLine("<h3>VM Information</h3><table><tr><th>Property</th><th>Value</th></tr>")
    foreach ($kv in @(
        @('Power State',     $entry.PowerState),
        @('VMhost',          $entry.VMHost),
        @('Datastore',       $entry.Datastore),
        @('vCPU',            $entry.NumCPU),
        @('Memory (GB)',     $entry.MemoryGB),
        @('Guest OS',        $entry.GuestOS),
        @('Guest Hostname',  $entry.Hostname),
        @('IP Addresses',    $entry.IPAddresses),
        @('Tools Status',    $entry.ToolsRunning),
        @('Tools Version',   $entry.ToolsVersion),
        @('Customization',   $entry.CustomizationInfo)
    )) {
        $valClass = if ($kv[1] -match 'fail|error|timeout') { 'error' } else { '' }
        [void]$sb.AppendLine("<tr><td>$($kv[0])</td><td class='$valClass'>$($kv[1])</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # Customization Events
    [void]$sb.AppendLine("<h3>Customization &amp; Deployment Events</h3>")
    if ($entry.CustomEvents.Count -eq 0) {
        [void]$sb.AppendLine("<p class='warn'>No relevant events found in the last $HoursBack hours.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Time</th><th>Type</th><th>Message</th></tr>")
        foreach ($evt in $entry.CustomEvents) {
            $cls = if ($evt.Message -match 'fail|error|timeout') { 'error' } elseif ($evt.Message -match 'succeed|complet') { 'ok' } else { '' }
            [void]$sb.AppendLine("<tr><td>$($evt.Time)</td><td>$($evt.Type)</td><td class='$cls'>$($evt.Message)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Task History
    [void]$sb.AppendLine("<h3>Task History</h3>")
    if ($entry.FailedTasks.Count -eq 0) {
        [void]$sb.AppendLine("<p class='warn'>No tasks found in the last $HoursBack hours.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Task</th><th>State</th><th>Start</th><th>Finish</th><th>Error</th></tr>")
        foreach ($t in $entry.FailedTasks) {
            $badge = switch ($t.State) {
                'Error'   { "<span class='badge badge-error'>ERROR</span>" }
                'Running' { "<span class='badge badge-warn'>RUNNING</span>" }
                'Success' { "<span class='badge badge-ok'>SUCCESS</span>" }
                default   { $t.State }
            }
            [void]$sb.AppendLine("<tr><td>$($t.Task)</td><td>$badge</td><td>$($t.Start)</td><td>$($t.Finish)</td><td class='error'>$($t.Error)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Guest Logs
    if ($entry.GuestLogs.Count -gt 0) {
        [void]$sb.AppendLine("<h3>Guest Logs</h3>")
        foreach ($logName in $entry.GuestLogs.Keys) {
            [void]$sb.AppendLine("<h4>$logName</h4><pre>$([System.Web.HttpUtility]::HtmlEncode($entry.GuestLogs[$logName]))</pre>")
        }
    }
}

[void]$sb.AppendLine("</body></html>")

$sb.ToString() | Out-File -FilePath $reportFile -Encoding utf8 -Force
Write-Status "Report saved: $reportFile" -Color Green

# Open in default browser
Write-Host "`nOpening report in browser..." -ForegroundColor Cyan
Start-Process $reportFile
