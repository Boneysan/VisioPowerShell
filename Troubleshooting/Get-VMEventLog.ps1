<#
.SYNOPSIS
    Retrieves recent vCenter events for a VM or all VMs in a folder.

.DESCRIPTION
    Queries vCenter event history for the specified VM or all VMs in a folder.
    Filters by event type (errors, warnings, all), time range, and optional keyword.
    Useful for diagnosing power failures, snapshot issues, guest crashes, and
    network or storage faults in a cyber range environment.

.PARAMETER VMName
    Optional. Name of a specific VM to retrieve events for.
    Mutually exclusive with -Folder.

.PARAMETER Folder
    Optional. vSphere folder path. Retrieves events for all VMs in the folder.
    Mutually exclusive with -VMName.

.PARAMETER HoursBack
    Optional. How many hours of event history to retrieve. Default: 24.

.PARAMETER Severity
    Optional. Filter events by severity level. Default: All.
    Valid values: All, Error, Warning.

.PARAMETER Keyword
    Optional. Case-insensitive keyword to filter event messages (e.g. "snapshot", "network").

.PARAMETER IncludeSubfolders
    Optional switch. Include VMs in subfolders when -Folder is specified.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Get-VMEventLog.ps1 -VMName "DC01" -HoursBack 48 -Severity Error
    Retrieve all error events for DC01 over the last 48 hours.

.EXAMPLE
    .\Get-VMEventLog.ps1 -Folder "CyberRange\Exercise01" -Severity Warning -Keyword "snapshot" -OutputFile "events.csv"
    Retrieve snapshot-related warnings for all VMs in Exercise01.

.OUTPUTS
    CSV with columns: VMName, EventType, Severity, Message, CreatedTime, UserName, Host, Datacenter

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter event history

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false, ParameterSetName='ByVM')]
    [string]$VMName,

    [Parameter(Mandatory=$false, ParameterSetName='ByFolder')]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [int]$HoursBack = 24,

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'Error', 'Warning')]
    [string]$Severity = 'All',

    [Parameter(Mandatory=$false)]
    [string]$Keyword,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

if (-not $VMName -and -not $Folder) {
    Write-Error "Specify either -VMName or -Folder."
    exit 1
}

# --- Connection ---
if ($vCenter) {
    try {
        Write-Host "Connecting to vCenter: $vCenter..." -ForegroundColor Cyan
        Connect-VIServer -Server $vCenter -ErrorAction Stop | Out-Null
        Write-Host "Connected successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter: $_"
        exit 1
    }
}
else {
    Write-Host "Using existing vCenter connection..." -ForegroundColor Yellow
    if (-not (Get-VIServer -ErrorAction SilentlyContinue)) {
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# --- Resolve target VMs ---
$vms = @()
if ($VMName) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Error "VM '$VMName' not found."; exit 1 }
    $vms = @($vm)
}
else {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }

    $vms = if ($IncludeSubfolders) {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
    } else {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
            Where-Object { $_.FolderId -eq $targetFolder.Id }
    }
}

if (-not $vms) { Write-Warning "No VMs found."; exit 0 }

$start = (Get-Date).AddHours(-$HoursBack)
$target = if ($VMName) { $VMName } else { $Folder }

Write-Host "`n=== VM Event Log ===" -ForegroundColor Cyan
Write-Host "  Target     : $target ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Time Range : Last $HoursBack hours (since $($start.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor White
Write-Host "  Severity   : $Severity" -ForegroundColor White
Write-Host "  Keyword    : $(if ($Keyword) { $Keyword } else { '(none)' })`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$eventMgr = Get-View EventManager -ErrorAction Stop

foreach ($vm in $vms | Sort-Object Name) {
    Write-Host "  Querying events for $($vm.Name)..." -ForegroundColor Gray

    try {
        $eventFilter = New-Object VMware.Vim.EventFilterSpec
        $eventFilter.Entity = New-Object VMware.Vim.EventFilterSpecByEntity
        $eventFilter.Entity.Entity = $vm.ExtensionData.MoRef
        $eventFilter.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::self
        $eventFilter.Time = New-Object VMware.Vim.EventFilterSpecByTime
        $eventFilter.Time.BeginTime = $start.ToUniversalTime()

        $events   = $eventMgr.QueryEvents($eventFilter)
    }
    catch {
        Write-Warning "  Failed to query events for $($vm.Name): $_"
        continue
    }

    foreach ($evt in $events) {
        # Severity classification
        $evtSeverity = switch -Wildcard ($evt.GetType().Name) {
            '*Error*'   { 'Error'   }
            '*Warning*' { 'Warning' }
            '*Fault*'   { 'Error'   }
            default     { 'Info'    }
        }

        if ($Severity -eq 'Error'   -and $evtSeverity -ne 'Error')   { continue }
        if ($Severity -eq 'Warning' -and $evtSeverity -notin @('Error','Warning')) { continue }

        $message = $evt.FullFormattedMessage
        if ($Keyword -and $message -notmatch [regex]::Escape($Keyword)) { continue }

        $entry = [PSCustomObject]@{
            VMName      = $vm.Name
            EventType   = $evt.GetType().Name
            Severity    = $evtSeverity
            Message     = $message
            CreatedTime = $evt.CreatedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            UserName    = $evt.UserName
            Host        = if ($evt.Host) { $evt.Host.Name } else { '' }
            Datacenter  = if ($evt.Datacenter) { $evt.Datacenter.Name } else { '' }
        }
        $results.Add($entry)

        $color = switch ($evtSeverity) { 'Error' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
        Write-Host "    [$evtSeverity] $($evt.CreatedTime.ToLocalTime().ToString('HH:mm:ss')) $message" -ForegroundColor $color
    }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  VMs queried : $($vms.Count)" -ForegroundColor White
Write-Host "  Events found: $($results.Count)" -ForegroundColor White

$errCount  = ($results | Where-Object { $_.Severity -eq 'Error'   }).Count
$warnCount = ($results | Where-Object { $_.Severity -eq 'Warning' }).Count
if ($errCount  -gt 0) { Write-Host "  Errors      : $errCount"   -ForegroundColor Red    }
if ($warnCount -gt 0) { Write-Host "  Warnings    : $warnCount"  -ForegroundColor Yellow }

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}
