<#
.SYNOPSIS
    Reports host availability issues across a cluster: connection state, maintenance mode,
    lockdown mode, and key management service health.

.DESCRIPTION
    Enumerates all ESXi hosts in the specified cluster (or all hosts in the vCenter if no
    cluster is given) and checks:

    - Connection state: Connected, Disconnected, or NotResponding
    - Maintenance mode: flags hosts currently in maintenance
    - Lockdown mode: detects hosts unexpectedly in Normal or Strict lockdown
    - Management services: verifies vpxa, hostd, and ntpd are running as expected

    Hosts that are disconnected, not responding, or have degraded service state are flagged
    immediately. Useful as a first-pass check before applying changes or as part of a
    daily morning review.

.PARAMETER ClusterName
    Optional. Scope the report to a specific cluster. If omitted, all hosts in vCenter
    are checked.

.PARAMETER ExpectLockdownDisabled
    Optional switch. Flag any host that has lockdown mode enabled (Normal or Strict) as a
    warning. Use when your environment policy requires lockdown to be off.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. Default: c1r1r12-vcsa-01.texnet1.net.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Get-HostAvailabilityReport.ps1 -ClusterName "Cluster01"
    Check all hosts in Cluster01.

.EXAMPLE
    .\Get-HostAvailabilityReport.ps1 -ClusterName "Cluster01" -ExpectLockdownDisabled -OutputFile "host-availability.csv"
    Check hosts and flag any in lockdown mode, export to CSV.

.EXAMPLE
    .\Get-HostAvailabilityReport.ps1
    Run against all hosts in the connected vCenter.

.OUTPUTS
    CSV with columns: HostName, Cluster, ConnectionState, PowerState, MaintenanceMode,
                      LockdownMode, Service, ServiceRunning, Severity, Detail, Recommendation, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to host configuration and service data in vCenter

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [switch]$ExpectLockdownDisabled,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

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
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter."
        exit 1
    }
}

# --- Resolve hosts ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $hosts = Get-VMHost -Location $cluster -ErrorAction SilentlyContinue
}
else {
    $hosts = Get-VMHost -ErrorAction SilentlyContinue
}

if (-not $hosts) { Write-Warning "No hosts found."; exit 0 }

Write-Host "`n=== Host Availability Report ===" -ForegroundColor Cyan
Write-Host "  Scope   : $(if ($ClusterName) { $ClusterName } else { 'All hosts in vCenter' })" -ForegroundColor White
Write-Host "  Hosts   : $($hosts.Count)" -ForegroundColor White
Write-Host "  Lockdown policy: $(if ($ExpectLockdownDisabled) { 'Must be DISABLED' } else { 'Not enforced' })`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Services to verify on each host
$keyServices = @(
    @{ Key = 'vpxa';   Label = 'vCenter Agent (vpxa)';   ExpectRunning = $true  },
    @{ Key = 'hostd';  Label = 'Host Management (hostd)'; ExpectRunning = $true  },
    @{ Key = 'ntpd';   Label = 'NTP Daemon (ntpd)';       ExpectRunning = $true  },
    @{ Key = 'SSH';    Label = 'SSH';                      ExpectRunning = $false }  # SSH running may be a policy concern
)

function Add-Result {
    param([string]$HostName, [string]$Cluster, [string]$Check,
          [string]$Severity, [string]$Value, [string]$Detail, [string]$Recommendation = '')
    $entry = [PSCustomObject]@{
        HostName       = $HostName
        Cluster        = $Cluster
        Check          = $Check
        Severity       = $Severity
        Value          = $Value
        Detail         = $Detail
        Recommendation = $Recommendation
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color  = switch ($Severity) { 'CRITICAL' { 'Red' } 'WARNING' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    $marker = switch ($Severity) { 'CRITICAL' { '[CRIT]' } 'WARNING' { '[WARN]' } 'OK' { '[OK]  ' } default { '[INFO]' } }
    Write-Host ("  $marker {0,-35} {1,-28} {2}" -f $HostName, $Check, $Value) -ForegroundColor $color
    if ($Recommendation) { Write-Host "          -> $Recommendation" -ForegroundColor Yellow }
}

foreach ($vmhost in $hosts | Sort-Object Name) {
    # Use a distinct variable name — $clusterName would shadow the $ClusterName parameter
    # (PowerShell variable names are case-insensitive).
    $hostClusterName = if ($cluster) {
        $cluster.Name
    } else {
        $n = (Get-Cluster -VMHost $vmhost -ErrorAction SilentlyContinue).Name
        if ($n) { $n } else { '(standalone)' }
    }

    Write-Host "`n  $($vmhost.Name) [$hostClusterName]" -ForegroundColor White

    # --- Connection State ---
    $connState = $vmhost.ConnectionState
    $connSev   = switch ($connState) {
        'Connected'     { 'OK'       }
        'Disconnected'  { 'CRITICAL' }
        'NotResponding' { 'CRITICAL' }
        default         { 'WARNING'  }
    }
    Add-Result $vmhost.Name $hostClusterName 'Connection State' $connSev $connState `
        "Host is $connState" `
        $(if ($connState -eq 'Disconnected')  { 'Check management network, physical switch, and VMkernel adapter for this host' } `
          elseif ($connState -eq 'NotResponding') { 'Host not responding — check hostd/vpxa services and management network' } `
          else { '' })

    # --- Power State ---
    $powerState = $vmhost.PowerState
    if ($powerState -ne 'PoweredOn') {
        Add-Result $vmhost.Name $hostClusterName 'Power State' 'WARNING' $powerState `
            "Host power state is $powerState" 'Confirm this is intentional'
    }

    # --- Maintenance Mode ---
    $inMaint = $vmhost.ExtensionData.Runtime.InMaintenanceMode
    Add-Result $vmhost.Name $hostClusterName 'Maintenance Mode' `
        $(if ($inMaint) { 'WARNING' } else { 'OK' }) `
        $inMaint `
        $(if ($inMaint) { 'Host is in maintenance mode — VMs cannot run here' } else { 'Not in maintenance' }) `
        $(if ($inMaint) { 'Verify maintenance is intentional; exit when work is complete' } else { '' })

    # --- Lockdown Mode ---
    $lockdown = $vmhost.ExtensionData.Config.LockdownMode
    $lockdownSev = if ($ExpectLockdownDisabled -and $lockdown -ne 'lockdownDisabled') {
        'WARNING'
    }
    elseif ($lockdown -eq 'lockdownStrict') {
        'INFO'
    }
    else { 'OK' }

    $lockdownDetail = switch ($lockdown) {
        'lockdownDisabled' { 'Lockdown disabled (direct host login allowed)' }
        'lockdownNormal'   { 'Normal lockdown (remote access via vCenter only; DCUI still accessible)' }
        'lockdownStrict'   { 'Strict lockdown (vCenter-only access; DCUI disabled)' }
        default            { "Lockdown state: $lockdown" }
    }
    Add-Result $vmhost.Name $hostClusterName 'Lockdown Mode' $lockdownSev $lockdown $lockdownDetail `
        $(if ($ExpectLockdownDisabled -and $lockdown -ne 'lockdownDisabled') {
            'Policy requires lockdown disabled on this environment; disable in host Advanced Settings'
        } else { '' })

    # --- Key Services ---
    if ($connState -eq 'Connected') {
        try {
            $services = Get-VMHostService -VMHost $vmhost -ErrorAction Stop
        }
        catch {
            Write-Warning "    Could not retrieve services for $($vmhost.Name): $_"
            continue
        }

        foreach ($svcDef in $keyServices) {
            $svc = $services | Where-Object { $_.Key -eq $svcDef.Key } | Select-Object -First 1
            if (-not $svc) { continue }

            $isRunning    = $svc.Running
            $expectedRun  = $svcDef.ExpectRunning

            if ($expectedRun -and -not $isRunning) {
                Add-Result $vmhost.Name $hostClusterName "Service: $($svcDef.Label)" 'CRITICAL' `
                    "Not Running (policy: $($svc.Policy))" `
                    "$($svcDef.Label) is installed but not running" `
                    "Start service: Get-VMHost '$($vmhost.Name)' | Get-VMHostService | Where-Object { `$_.Key -eq '$($svcDef.Key)' } | Start-VMHostService"
            }
            elseif (-not $expectedRun -and $isRunning) {
                Add-Result $vmhost.Name $hostClusterName "Service: $($svcDef.Label)" 'WARNING' `
                    "Running (policy: $($svc.Policy))" `
                    "$($svcDef.Label) is running — verify this is intentional per your security policy" `
                    'If SSH should not be running, stop the service and set policy to off'
            }
            else {
                Add-Result $vmhost.Name $hostClusterName "Service: $($svcDef.Label)" 'OK' `
                    "$(if ($isRunning) { 'Running' } else { 'Stopped' }) (policy: $($svc.Policy))" `
                    "Service state matches expected"
            }
        }
    }
}

# --- Summary ---
$critical = ($results | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$warnings = ($results | Where-Object { $_.Severity -eq 'WARNING'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Hosts checked : $($hosts.Count)"  -ForegroundColor White
Write-Host "  Total checks  : $($results.Count)" -ForegroundColor White
Write-Host "  CRITICAL      : $critical" -ForegroundColor $(if ($critical -gt 0) { 'Red'    } else { 'White' })
Write-Host "  WARNING       : $warnings" -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'White' })

$disconnected  = ($results | Where-Object { $_.Check -eq 'Connection State' -and $_.Value -ne 'Connected' }).Count
$inMaintCount  = ($results | Where-Object { $_.Check -eq 'Maintenance Mode' -and $_.Value -eq 'True'      }).Count
$svcFails      = ($results | Where-Object { $_.Check -like 'Service:*'       -and $_.Severity -eq 'CRITICAL' }).Count

if ($disconnected -gt 0)  { Write-Host "  Disconnected/NotResponding : $disconnected host(s)" -ForegroundColor Red    }
if ($inMaintCount -gt 0)  { Write-Host "  In Maintenance Mode        : $inMaintCount host(s)" -ForegroundColor Yellow }
if ($svcFails -gt 0)      { Write-Host "  Service failures           : $svcFails"              -ForegroundColor Red    }

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Where-Object { $_.Severity -in @('CRITICAL', 'WARNING') } |
        Select-Object HostName, Cluster, Check, Severity, Value, Recommendation |
        Format-Table -AutoSize
}
