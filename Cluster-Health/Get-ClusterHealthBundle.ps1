<#
.SYNOPSIS
    Runs a comprehensive health check bundle for a vSphere cluster and reports all findings.

.DESCRIPTION
    Accepts a cluster name and executes a standard set of health checks in a single run:

    1. Cluster configuration  — HA, DRS, EVC mode, admission control
    2. Host availability      — connection state, maintenance mode, lockdown mode
    3. Resource pressure      — CPU/memory usage per host, vCPU/vRAM overcommit, ballooning/swapping
    4. Datastore health       — capacity thresholds, accessibility
    5. VM health              — snapshots past threshold, Tools issues, consolidation needed
    6. Recent critical events — HA restarts, host isolation, VM resets in the past N hours
    7. Active alarms          — triggered alarms on the cluster and its hosts

    All findings are written to the console grouped by section and optionally exported to a
    single CSV with columns for Section, Severity, Object, Check, Value, and Recommendation.
    Designed as a daily morning health check or pre/post change validation.

.PARAMETER ClusterName
    Required. Name of the vSphere cluster to analyze.

.PARAMETER EventHoursBack
    Optional. How many hours of event history to query for critical events. Default: 24.

.PARAMETER SnapshotAgeDays
    Optional. Flag VM snapshots older than this many days as warnings. Default: 7.

.PARAMETER DatastoreWarnPct
    Optional. Datastore used-space percentage that triggers a WARNING. Default: 80.

.PARAMETER DatastoreCritPct
    Optional. Datastore used-space percentage that triggers a CRITICAL alert. Default: 90.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. Default: c1r1r12-vcsa-01.texnet1.net.

.PARAMETER OutputFile
    Optional. Path to export the full findings report as CSV.

.EXAMPLE
    .\Get-ClusterHealthBundle.ps1 -ClusterName "Cluster01"
    Run full health check on Cluster01, output to console only.

.EXAMPLE
    .\Get-ClusterHealthBundle.ps1 -ClusterName "Cluster01" -OutputFile "health-$(Get-Date -Format 'yyyyMMdd').csv"
    Run full health check and export findings to a dated CSV file.

.EXAMPLE
    .\Get-ClusterHealthBundle.ps1 -ClusterName "Cluster01" -EventHoursBack 48 -SnapshotAgeDays 3 -DatastoreWarnPct 75
    Run with tighter thresholds and a larger event lookback window.

.OUTPUTS
    CSV with columns: Section, Severity, ObjectType, Object, Check, Value, Recommendation, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter cluster, host, VM, and event data

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [int]$EventHoursBack = 24,

    [Parameter(Mandatory=$false)]
    [int]$SnapshotAgeDays = 7,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 99)]
    [int]$DatastoreWarnPct = 80,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$DatastoreCritPct = 90,

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

$cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param(
        [string]$Section,
        [string]$Severity,        # OK | WARNING | CRITICAL | INFO
        [string]$ObjectType,
        [string]$Object,
        [string]$Check,
        [string]$Value,
        [string]$Recommendation = ''
    )
    $entry = [PSCustomObject]@{
        Section        = $Section
        Severity       = $Severity
        ObjectType     = $ObjectType
        Object         = $Object
        Check          = $Check
        Value          = $Value
        Recommendation = $Recommendation
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $findings.Add($entry)
    $color  = switch ($Severity) { 'CRITICAL' { 'Red' } 'WARNING' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    $marker = switch ($Severity) { 'CRITICAL' { '[CRIT]' } 'WARNING' { '[WARN]' } 'OK' { '[OK]  ' } default { '[INFO]' } }
    Write-Host ("  $marker {0,-10} {1,-30} {2} = {3}" -f $ObjectType, $Object, $Check, $Value) -ForegroundColor $color
    if ($Recommendation) { Write-Host "          -> $Recommendation" -ForegroundColor Yellow }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Cluster Health Bundle: $ClusterName" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Cyan

# ============================================================
# SECTION 1: Cluster Configuration
# ============================================================
Write-Host "--- Section 1: Cluster Configuration ---`n" -ForegroundColor White

$clusterExt    = $cluster.ExtensionData
$dasConfig     = $clusterExt.Configuration.DasConfig
$drsConfig     = $clusterExt.Configuration.DrsConfig
$clusterSummary = $clusterExt.Summary

# HA
$haEnabled = $dasConfig.Enabled
Add-Finding 'Cluster Config' $(if ($haEnabled) { 'OK' } else { 'CRITICAL' }) `
    'Cluster' $ClusterName 'HA Enabled' $haEnabled `
    $(if (-not $haEnabled) { 'Enable vSphere HA to restart VMs automatically on host failure' } else { '' })

if ($haEnabled) {
    $isolationResponse = if ($dasConfig.DefaultVmSettings) { $dasConfig.DefaultVmSettings.IsolationResponse } else { '(not configured)' }
    $acEnabled         = $dasConfig.AdmissionControlEnabled
    $hbCount           = if ($dasConfig.HeartbeatDatastore) { $dasConfig.HeartbeatDatastore.Count } else { 0 }

    Add-Finding 'Cluster Config' 'INFO'    'Cluster' $ClusterName 'HA Isolation Response' $isolationResponse
    Add-Finding 'Cluster Config' $(if ($acEnabled) { 'OK' } else { 'WARNING' }) `
        'Cluster' $ClusterName 'HA Admission Control' $acEnabled `
        $(if (-not $acEnabled) { 'Admission control disabled — HA cannot guarantee failover capacity' } else { '' })
    Add-Finding 'Cluster Config' $(if ($hbCount -ge 2) { 'OK' } else { 'WARNING' }) `
        'Cluster' $ClusterName 'HA Heartbeat Datastores' $hbCount `
        $(if ($hbCount -lt 2) { 'Less than 2 heartbeat datastores — add a second for redundancy' } else { '' })
}

# DRS
$drsEnabled  = $drsConfig.Enabled
$drsBehavior = $drsConfig.DefaultVmBehavior
$drsRate     = $drsConfig.VmotionRate

Add-Finding 'Cluster Config' $(if ($drsEnabled) { 'OK' } else { 'WARNING' }) `
    'Cluster' $ClusterName 'DRS Enabled' $drsEnabled `
    $(if (-not $drsEnabled) { 'DRS disabled — no automatic load balancing; manual vMotion required' } else { '' })
if ($drsEnabled) {
    Add-Finding 'Cluster Config' 'INFO' 'Cluster' $ClusterName 'DRS Automation Level' $drsBehavior
    Add-Finding 'Cluster Config' 'INFO' 'Cluster' $ClusterName 'DRS Migration Threshold' "Level $drsRate (1=conservative, 5=aggressive)"
}

# EVC Mode
$evcMode = if ($clusterSummary.CurrentEVCModeKey) { $clusterSummary.CurrentEVCModeKey } else { '(none)' }
Add-Finding 'Cluster Config' 'INFO' 'Cluster' $ClusterName 'EVC Mode' $evcMode

# Host count
$numHosts     = $clusterSummary.NumHosts
$numEffective = $clusterSummary.NumEffectiveHosts
Add-Finding 'Cluster Config' $(if ($numEffective -eq $numHosts) { 'OK' } else { 'WARNING' }) `
    'Cluster' $ClusterName 'Effective Hosts' "$numEffective / $numHosts" `
    $(if ($numEffective -lt $numHosts) { "$($numHosts - $numEffective) host(s) are not effective (disconnected or in maintenance)" } else { '' })

# ============================================================
# SECTION 2: Host Availability
# ============================================================
Write-Host "`n--- Section 2: Host Availability ---`n" -ForegroundColor White

$hosts = Get-VMHost -Location $cluster -ErrorAction SilentlyContinue

foreach ($vmhost in $hosts | Sort-Object Name) {
    $connState = $vmhost.ConnectionState
    $inMaint   = $vmhost.ExtensionData.Runtime.InMaintenanceMode
    $lockdown  = $vmhost.ExtensionData.Config.LockdownMode

    $connSev = switch ($connState) {
        'Connected'     { 'OK'       }
        'Disconnected'  { 'CRITICAL' }
        'NotResponding' { 'CRITICAL' }
        default         { 'WARNING'  }
    }
    Add-Finding 'Host Availability' $connSev 'Host' $vmhost.Name 'Connection State' $connState `
        $(if ($connState -ne 'Connected') { 'Host not connected to vCenter — check management network and hostd/vpxa services' } else { '' })

    Add-Finding 'Host Availability' $(if ($inMaint) { 'WARNING' } else { 'OK' }) `
        'Host' $vmhost.Name 'Maintenance Mode' $inMaint `
        $(if ($inMaint) { 'Host is in maintenance mode — VMs cannot run here; exit maintenance when work is complete' } else { '' })

    $lockdownSev = switch ($lockdown) {
        'lockdownDisabled' { 'OK'      }
        'lockdownNormal'   { 'INFO'    }
        'lockdownStrict'   { 'WARNING' }
        default            { 'INFO'    }
    }
    Add-Finding 'Host Availability' $lockdownSev 'Host' $vmhost.Name 'Lockdown Mode' $lockdown
}

# ============================================================
# SECTION 3: Resource Pressure
# ============================================================
Write-Host "`n--- Section 3: Resource Pressure ---`n" -ForegroundColor White

$totalProvCPU    = 0
$totalProvMemGB  = 0
$totalHostCPUMhz = 0
$totalHostMemGB  = 0

foreach ($vmhost in $hosts | Sort-Object Name) {
    $cpuUsedMhz  = $vmhost.CpuUsageMhz
    $cpuTotalMhz = $vmhost.CpuTotalMhz
    $memUsedGB   = [math]::Round($vmhost.MemoryUsageGB, 1)
    $memTotalGB  = [math]::Round($vmhost.MemoryTotalGB, 1)
    $cpuPct      = if ($cpuTotalMhz -gt 0) { [math]::Round($cpuUsedMhz / $cpuTotalMhz * 100, 1) } else { 0 }
    $memPct      = if ($memTotalGB  -gt 0) { [math]::Round($memUsedGB  / $memTotalGB  * 100, 1) } else { 0 }

    $cpuSev = if ($cpuPct -ge 90) { 'CRITICAL' } elseif ($cpuPct -ge 75) { 'WARNING' } else { 'OK' }
    $memSev = if ($memPct -ge 90) { 'CRITICAL' } elseif ($memPct -ge 85) { 'WARNING' } else { 'OK' }

    Add-Finding 'Resource Pressure' $cpuSev 'Host' $vmhost.Name 'CPU Usage' `
        "$cpuPct% ($cpuUsedMhz / $cpuTotalMhz MHz)" `
        $(if ($cpuPct -ge 75) { 'High CPU utilization — check for CPU-ready time on running VMs' } else { '' })

    Add-Finding 'Resource Pressure' $memSev 'Host' $vmhost.Name 'Memory Usage' `
        "$memPct% ($memUsedGB / $memTotalGB GB)" `
        $(if ($memPct -ge 85) { 'High memory pressure — check for ballooning/swapping on hosted VMs' } else { '' })

    $totalHostCPUMhz += $cpuTotalMhz
    $totalHostMemGB  += $memTotalGB
}

# Overcommit ratios
$clusterVMs = Get-VM -Location $cluster -ErrorAction SilentlyContinue
foreach ($vm in $clusterVMs) {
    $totalProvCPU   += $vm.NumCpu
    $totalProvMemGB += $vm.MemoryGB
}

$hostThreadCount = ($hosts | Measure-Object -Property NumCpu -Sum).Sum
$vcpuRatio = if ($hostThreadCount -gt 0) { [math]::Round($totalProvCPU   / $hostThreadCount, 1) } else { 0 }
$vramRatio = if ($totalHostMemGB  -gt 0) { [math]::Round($totalProvMemGB / $totalHostMemGB,  1) } else { 0 }

Add-Finding 'Resource Pressure' $(if ($vcpuRatio -ge 8) { 'WARNING' } elseif ($vcpuRatio -ge 4) { 'INFO' } else { 'OK' }) `
    'Cluster' $ClusterName 'vCPU Overcommit' "${vcpuRatio}:1 ($totalProvCPU vCPU / $hostThreadCount pCPU threads)" `
    $(if ($vcpuRatio -ge 8) { 'High vCPU overcommit — monitor CPU ready time closely' } else { '' })

Add-Finding 'Resource Pressure' $(if ($vramRatio -ge 1.5) { 'WARNING' } elseif ($vramRatio -ge 1.2) { 'INFO' } else { 'OK' }) `
    'Cluster' $ClusterName 'vRAM Overcommit' "${vramRatio}:1 ($([math]::Round($totalProvMemGB,0)) GB provisioned / $([math]::Round($totalHostMemGB,0)) GB physical)" `
    $(if ($vramRatio -ge 1.5) { 'Memory overcommitted — risk of guest ballooning and host swapping under load' } else { '' })

# Ballooning/swapping VMs
$balloonVMs = @($clusterVMs | Where-Object { $_.ExtensionData.Summary.QuickStats.BalloonedMemory -gt 100 })
$swapVMs    = @($clusterVMs | Where-Object { $_.ExtensionData.Summary.QuickStats.SwappedMemory   -gt 100 })

if ($balloonVMs.Count -gt 0) {
    Add-Finding 'Resource Pressure' 'WARNING' 'Cluster' $ClusterName 'VMs Ballooning' "$($balloonVMs.Count) VM(s)" `
        "Ballooning VMs: $($balloonVMs.Name -join ', ') — host is reclaiming guest memory; performance impacted"
}
if ($swapVMs.Count -gt 0) {
    Add-Finding 'Resource Pressure' 'CRITICAL' 'Cluster' $ClusterName 'VMs Swapping' "$($swapVMs.Count) VM(s)" `
        "Swapping VMs: $($swapVMs.Name -join ', ') — SEVERE performance impact; add memory or migrate VMs"
}

# ============================================================
# SECTION 4: Datastore Health
# ============================================================
Write-Host "`n--- Section 4: Datastore Health ---`n" -ForegroundColor White

$datastores = Get-Datastore -Location $cluster -ErrorAction SilentlyContinue | Sort-Object Name

foreach ($ds in $datastores) {
    $capacityGB = [math]::Round($ds.CapacityGB, 1)
    $freeGB     = [math]::Round($ds.FreeSpaceGB, 1)
    $usedPct    = if ($capacityGB -gt 0) { [math]::Round(($capacityGB - $freeGB) / $capacityGB * 100, 1) } else { 0 }

    $capSev = if ($usedPct -ge $DatastoreCritPct) { 'CRITICAL' } `
              elseif ($usedPct -ge $DatastoreWarnPct) { 'WARNING' } `
              else { 'OK' }

    Add-Finding 'Datastore Health' $capSev 'Datastore' $ds.Name 'Space Used' `
        "$usedPct% ($freeGB GB free of $capacityGB GB)" `
        $(if ($usedPct -ge $DatastoreWarnPct) { 'Datastore nearing capacity — delete snapshots, thin-provision, or expand' } else { '' })

    Add-Finding 'Datastore Health' $(if ($ds.Accessible) { 'OK' } else { 'CRITICAL' }) `
        'Datastore' $ds.Name 'Accessible' $ds.Accessible `
        $(if (-not $ds.Accessible) { 'Datastore is inaccessible — check storage fabric and LUN connectivity immediately' } else { '' })
}

# ============================================================
# SECTION 5: VM Health
# ============================================================
Write-Host "`n--- Section 5: VM Health ---`n" -ForegroundColor White

$snapshotThreshold = (Get-Date).AddDays(-$SnapshotAgeDays)

foreach ($vm in $clusterVMs | Sort-Object Name) {
    # Snapshots — only call Get-Snapshot if the VM actually has snapshot tree data
    if ($vm.ExtensionData.Snapshot) {
        $snaps = Get-Snapshot -VM $vm -ErrorAction SilentlyContinue
        if ($snaps) {
            $oldest      = $snaps | Sort-Object Created | Select-Object -First 1
            $snapAgeDays = [math]::Round(((Get-Date) - $oldest.Created).TotalDays, 0)
            $snapSev     = if ($oldest.Created -lt $snapshotThreshold) { 'WARNING' } else { 'INFO' }
            Add-Finding 'VM Health' $snapSev 'VM' $vm.Name 'Snapshots' `
                "$($snaps.Count) snapshot(s); oldest $snapAgeDays day(s) ($(($oldest.Created).ToString('yyyy-MM-dd')))" `
                $(if ($snapSev -eq 'WARNING') { "Snapshots older than $SnapshotAgeDays days slow I/O and consume datastore space. Remove or consolidate." } else { '' })
        }
    }

    # Consolidation needed
    if ($vm.ExtensionData.Runtime.ConsolidationNeeded) {
        Add-Finding 'VM Health' 'WARNING' 'VM' $vm.Name 'Disk Consolidation' 'Needed' `
            'Orphaned delta disks present — right-click VM in vSphere Client and choose Consolidate'
    }

    # VMware Tools
    $toolsStatus  = $vm.ExtensionData.Guest.ToolsStatus
    $toolsRunning = $vm.ExtensionData.Guest.ToolsRunningStatus
    if ($toolsStatus -eq 'toolsNotInstalled') {
        Add-Finding 'VM Health' 'WARNING' 'VM' $vm.Name 'VMware Tools' 'Not Installed' `
            'Install VMware Tools for clean shutdown, quiesced snapshots, and IP reporting'
    }
    elseif ($vm.PowerState -eq 'PoweredOn' -and $toolsRunning -ne 'guestToolsRunning') {
        Add-Finding 'VM Health' 'WARNING' 'VM' $vm.Name 'VMware Tools' "Not Running ($toolsStatus)" `
            'VMware Tools installed but not running — restart Tools service or reboot the VM'
    }
}

# ============================================================
# SECTION 6: Recent Critical Events
# ============================================================
Write-Host "`n--- Section 6: Recent Critical Events (last $EventHoursBack hrs) ---`n" -ForegroundColor White

try {
    $eventMgr           = Get-View EventManager -ErrorAction Stop
    $eventFilter        = New-Object VMware.Vim.EventFilterSpec
    $eventFilter.Entity = New-Object VMware.Vim.EventFilterSpecByEntity
    $eventFilter.Entity.Entity    = $cluster.ExtensionData.MoRef
    $eventFilter.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::all
    $eventFilter.Time             = New-Object VMware.Vim.EventFilterSpecByTime
    $eventFilter.Time.BeginTime   = (Get-Date).AddHours(-$EventHoursBack).ToUniversalTime()
    $eventFilter.Type = @(
        'VmRestartedByHAEvent',
        'HostIsolatedEvent',
        'HostDisconnectedEvent',
        'HostConnectionLostEvent',
        'VmResetEvent',
        'DasHostFailedEvent',
        'VmPoweredOffEvent'
    )

    $events = $eventMgr.QueryEvents($eventFilter)
    if ($events -and $events.Count -gt 0) {
        foreach ($evt in $events | Sort-Object CreatedTime -Descending | Select-Object -First 25) {
            $entityName = if ($evt.Vm) { $evt.Vm.Name } elseif ($evt.Host) { $evt.Host.Name } else { '(cluster)' }
            Add-Finding 'Recent Events' 'CRITICAL' 'Event' $entityName $evt.GetType().Name `
                $evt.CreatedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm') `
                'Review this event — it indicates a cluster-level failure or unplanned VM action'
        }
    }
    else {
        Add-Finding 'Recent Events' 'OK' 'Cluster' $ClusterName "Critical events (last $EventHoursBack hrs)" 'None found'
    }
}
catch {
    Write-Warning "  Event query failed: $_"
}

# ============================================================
# SECTION 7: Active Alarms
# ============================================================
Write-Host "`n--- Section 7: Active Alarms ---`n" -ForegroundColor White

$alarmSources = @($cluster) + @($hosts)
$alarmCount   = 0

foreach ($src in $alarmSources) {
    $alarmStates = $src.ExtensionData.TriggeredAlarmState
    if (-not $alarmStates) { continue }

    foreach ($alarm in $alarmStates) {
        try {
            $alarmDef   = Get-View -Id $alarm.Alarm  -ErrorAction SilentlyContinue
            $alarmName  = if ($alarmDef) { $alarmDef.Info.Name } else { '(unknown alarm)' }
            $objName    = $src.Name
            $sev        = switch ($alarm.OverallStatus) { 'red' { 'CRITICAL' } 'yellow' { 'WARNING' } default { 'INFO' } }
            Add-Finding 'Active Alarms' $sev 'Alarm' $objName $alarmName $alarm.OverallStatus `
                'Investigate and acknowledge or resolve this alarm in vSphere Client'
            $alarmCount++
        }
        catch { continue }
    }
}

if ($alarmCount -eq 0) {
    Add-Finding 'Active Alarms' 'OK' 'Cluster' $ClusterName 'Active Alarms' 'None on cluster or hosts'
}

# ============================================================
# FINAL SUMMARY
# ============================================================
$critical = ($findings | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$warnings = ($findings | Where-Object { $_.Severity -eq 'WARNING'  }).Count
$ok       = ($findings | Where-Object { $_.Severity -eq 'OK'       }).Count
$info     = ($findings | Where-Object { $_.Severity -eq 'INFO'     }).Count

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Bundle Summary: $ClusterName" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total findings : $($findings.Count)" -ForegroundColor White
Write-Host "  CRITICAL       : $critical" -ForegroundColor $(if ($critical -gt 0) { 'Red'    } else { 'White' })
Write-Host "  WARNING        : $warnings" -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  OK             : $ok"       -ForegroundColor Green
Write-Host "  INFO           : $info"     -ForegroundColor Cyan

$issues = $findings | Where-Object { $_.Severity -in @('CRITICAL', 'WARNING') } | Sort-Object Severity
if ($issues) {
    Write-Host "`n  Items requiring attention:" -ForegroundColor Yellow
    foreach ($issue in $issues | Select-Object -First 15) {
        $color = if ($issue.Severity -eq 'CRITICAL') { 'Red' } else { 'Yellow' }
        Write-Host "    [$($issue.Severity)] $($issue.Section) | $($issue.ObjectType): $($issue.Object) — $($issue.Check): $($issue.Value)" -ForegroundColor $color
    }
    if ($issues.Count -gt 15) {
        Write-Host "    ... and $($issues.Count - 15) more. See CSV for full list." -ForegroundColor Gray
    }
}

if ($OutputFile) {
    $findings | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nFull report exported to: $OutputFile" -ForegroundColor Green
}
