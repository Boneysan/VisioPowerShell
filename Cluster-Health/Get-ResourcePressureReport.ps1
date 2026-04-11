<#
.SYNOPSIS
    Reports CPU and memory pressure across a cluster: host utilization, vCPU/vRAM overcommit
    ratios, guest ballooning/swapping, and top VMs by resource consumption.

.DESCRIPTION
    Uses real-time cached QuickStats from vCenter (no performance database queries required)
    to give an instant snapshot of resource pressure across all hosts and VMs in the cluster.

    Checks performed:
    - Per-host CPU and memory utilization with configurable warning/critical thresholds
    - Cluster-wide vCPU overcommit ratio (provisioned vCPUs vs physical CPU threads)
    - Cluster-wide vRAM overcommit ratio (provisioned vRAM vs physical RAM)
    - VMs currently ballooning memory (host reclaiming guest memory — moderate impact)
    - VMs currently swapping memory to disk (severe performance impact)
    - Top N VMs ranked by current CPU usage (MHz)
    - Top N VMs ranked by current memory consumption (MB)

    All values are point-in-time snapshots from vCenter's cached guest statistics.
    For sustained trend analysis, use Get-Stat or a monitoring platform.

.PARAMETER ClusterName
    Optional. Scope to a specific cluster. If omitted, all hosts in the vCenter are analyzed.

.PARAMETER CPUWarnPct
    Optional. Host CPU usage percentage that triggers a WARNING. Default: 75.

.PARAMETER CPUCritPct
    Optional. Host CPU usage percentage that triggers a CRITICAL alert. Default: 90.

.PARAMETER MemWarnPct
    Optional. Host memory usage percentage that triggers a WARNING. Default: 85.

.PARAMETER MemCritPct
    Optional. Host memory usage percentage that triggers a CRITICAL alert. Default: 92.

.PARAMETER TopVMCount
    Optional. Number of top VMs to report in the CPU and memory hotspot sections. Default: 10.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. Default: c1r1r12-vcsa-01.texnet1.net.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Get-ResourcePressureReport.ps1 -ClusterName "Cluster01"
    Report resource pressure for Cluster01 with default thresholds.

.EXAMPLE
    .\Get-ResourcePressureReport.ps1 -ClusterName "Cluster01" -CPUWarnPct 70 -MemWarnPct 80 -TopVMCount 15 -OutputFile "pressure.csv"
    Use tighter thresholds and report top 15 VMs, export to CSV.

.OUTPUTS
    CSV with columns: Section, Severity, ObjectType, Object, Metric, Value, Threshold,
                      Recommendation, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to host and VM statistics in vCenter
    - VMware Tools running on VMs for accurate guest memory statistics

    QuickStats values are refreshed by vCenter typically every 20 seconds.
    Balloon/swap values of 0 are normal; any value above the 100 MB threshold
    flagged here indicates active memory pressure on that VM.

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 99)]
    [int]$CPUWarnPct = 75,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$CPUCritPct = 90,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 99)]
    [int]$MemWarnPct = 85,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$MemCritPct = 92,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$TopVMCount = 10,

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

# --- Resolve scope ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $hosts = Get-VMHost -Location $cluster -ErrorAction SilentlyContinue
    $vms   = Get-VM     -Location $cluster -ErrorAction SilentlyContinue
}
else {
    $hosts = Get-VMHost -ErrorAction SilentlyContinue
    $vms   = Get-VM     -ErrorAction SilentlyContinue
}

if (-not $hosts) { Write-Warning "No hosts found."; exit 0 }

Write-Host "`n=== Resource Pressure Report ===" -ForegroundColor Cyan
Write-Host "  Scope         : $(if ($ClusterName) { $ClusterName } else { 'All hosts in vCenter' })" -ForegroundColor White
Write-Host "  Hosts         : $($hosts.Count)" -ForegroundColor White
Write-Host "  VMs           : $($vms.Count)" -ForegroundColor White
Write-Host "  CPU warn/crit : $CPUWarnPct% / $CPUCritPct%" -ForegroundColor White
Write-Host "  Mem warn/crit : $MemWarnPct% / $MemCritPct%`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Section, [string]$Severity, [string]$ObjectType, [string]$Object,
          [string]$Metric, [string]$Value, [string]$Threshold = '', [string]$Recommendation = '')
    $entry = [PSCustomObject]@{
        Section        = $Section
        Severity       = $Severity
        ObjectType     = $ObjectType
        Object         = $Object
        Metric         = $Metric
        Value          = $Value
        Threshold      = $Threshold
        Recommendation = $Recommendation
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color  = switch ($Severity) { 'CRITICAL' { 'Red' } 'WARNING' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    $marker = switch ($Severity) { 'CRITICAL' { '[CRIT]' } 'WARNING' { '[WARN]' } 'OK' { '[OK]  ' } default { '[INFO]' } }
    Write-Host ("  $marker {0,-10} {1,-30} {2} = {3}" -f $ObjectType, $Object, $Metric, $Value) -ForegroundColor $color
    if ($Recommendation) { Write-Host "          -> $Recommendation" -ForegroundColor Yellow }
}

# ============================================================
# SECTION 1: Per-Host CPU and Memory Utilization
# ============================================================
Write-Host "--- Section 1: Host Utilization ---`n" -ForegroundColor White

$totalHostCPUMhz = 0
$totalHostMemGB  = 0
$totalCPUUsedMhz = 0
$totalMemUsedGB  = 0

foreach ($vmhost in $hosts | Sort-Object Name) {
    $cpuUsedMhz  = $vmhost.CpuUsageMhz
    $cpuTotalMhz = $vmhost.CpuTotalMhz
    $memUsedGB   = [math]::Round($vmhost.MemoryUsageGB, 1)
    $memTotalGB  = [math]::Round($vmhost.MemoryTotalGB, 1)
    $cpuPct      = if ($cpuTotalMhz -gt 0) { [math]::Round($cpuUsedMhz / $cpuTotalMhz * 100, 1) } else { 0 }
    $memPct      = if ($memTotalGB  -gt 0) { [math]::Round($memUsedGB  / $memTotalGB  * 100, 1) } else { 0 }

    $cpuSev = if ($cpuPct -ge $CPUCritPct) { 'CRITICAL' } elseif ($cpuPct -ge $CPUWarnPct) { 'WARNING' } else { 'OK' }
    $memSev = if ($memPct -ge $MemCritPct) { 'CRITICAL' } elseif ($memPct -ge $MemWarnPct) { 'WARNING' } else { 'OK' }

    Add-Result 'Host Utilization' $cpuSev 'Host' $vmhost.Name 'CPU' `
        "$cpuPct% ($cpuUsedMhz / $cpuTotalMhz MHz)" "Warn: $CPUWarnPct% Crit: $CPUCritPct%" `
        $(if ($cpuPct -ge $CPUWarnPct) { 'DRS may help; check for CPU-ready time on VMs; consider adding capacity' } else { '' })

    Add-Result 'Host Utilization' $memSev 'Host' $vmhost.Name 'Memory' `
        "$memPct% ($memUsedGB / $memTotalGB GB)" "Warn: $MemWarnPct% Crit: $MemCritPct%" `
        $(if ($memPct -ge $MemWarnPct) { 'Check VMs for ballooning/swapping; consider vMotion VMs to less-loaded hosts' } else { '' })

    $totalHostCPUMhz += $cpuTotalMhz
    $totalHostMemGB  += $memTotalGB
    $totalCPUUsedMhz += $cpuUsedMhz
    $totalMemUsedGB  += $memUsedGB
}

# Cluster-level aggregate
$clusterCPUPct = if ($totalHostCPUMhz -gt 0) { [math]::Round($totalCPUUsedMhz / $totalHostCPUMhz * 100, 1) } else { 0 }
$clusterMemPct = if ($totalHostMemGB  -gt 0) { [math]::Round($totalMemUsedGB  / $totalHostMemGB  * 100, 1) } else { 0 }
$scopeName = if ($ClusterName) { $ClusterName } else { 'vCenter' }

Add-Result 'Host Utilization' 'INFO' 'Cluster' $scopeName 'Aggregate CPU' `
    "$clusterCPUPct% ($([math]::Round($totalCPUUsedMhz/1000,1)) / $([math]::Round($totalHostCPUMhz/1000,1)) GHz)"
Add-Result 'Host Utilization' 'INFO' 'Cluster' $scopeName 'Aggregate Memory' `
    "$clusterMemPct% ($([math]::Round($totalMemUsedGB,0)) / $([math]::Round($totalHostMemGB,0)) GB)"

# ============================================================
# SECTION 2: Overcommit Ratios
# ============================================================
Write-Host "`n--- Section 2: Overcommit Analysis ---`n" -ForegroundColor White

$totalProvCPU   = 0
$totalProvMemGB = 0
foreach ($vm in $vms) {
    $totalProvCPU   += $vm.NumCpu
    $totalProvMemGB += $vm.MemoryGB
}

$hostThreadCount = ($hosts | Measure-Object -Property NumCpu -Sum).Sum
$vcpuRatio = if ($hostThreadCount -gt 0) { [math]::Round($totalProvCPU / $hostThreadCount, 2) } else { 0 }
$vramRatio = if ($totalHostMemGB  -gt 0) { [math]::Round($totalProvMemGB / $totalHostMemGB,  2) } else { 0 }

$cpuOverSev = if ($vcpuRatio -ge 8) { 'WARNING' } elseif ($vcpuRatio -ge 4) { 'INFO' } else { 'OK' }
$memOverSev = if ($vramRatio -ge 1.5) { 'WARNING' } elseif ($vramRatio -ge 1.2) { 'INFO' } else { 'OK' }

Add-Result 'Overcommit' $cpuOverSev 'Cluster' $scopeName 'vCPU Overcommit Ratio' `
    "${vcpuRatio}:1  ($totalProvCPU vCPU provisioned / $hostThreadCount pCPU threads)" `
    'Warn: >8:1' `
    $(if ($vcpuRatio -ge 8) { 'High overcommit — monitor CPU ready time on VMs (>5% is a problem); reduce or redistribute vCPUs' } else { '' })

Add-Result 'Overcommit' $memOverSev 'Cluster' $scopeName 'vRAM Overcommit Ratio' `
    "${vramRatio}:1  ($([math]::Round($totalProvMemGB,0)) GB provisioned / $([math]::Round($totalHostMemGB,0)) GB physical)" `
    'Warn: >1.5:1' `
    $(if ($vramRatio -ge 1.5) { 'Memory overcommitted — guests may balloon or swap under load; add physical RAM or reduce provisioning' } else { '' })

# ============================================================
# SECTION 3: Balloon and Swap Pressure
# ============================================================
Write-Host "`n--- Section 3: Balloon / Swap Pressure ---`n" -ForegroundColor White

$pressureVMs = $vms | Where-Object {
    $qs = $_.ExtensionData.Summary.QuickStats
    $qs.BalloonedMemory -gt 0 -or $qs.SwappedMemory -gt 0
} | Sort-Object Name

if ($pressureVMs) {
    foreach ($vm in $pressureVMs) {
        $qs       = $vm.ExtensionData.Summary.QuickStats
        $balloon  = $qs.BalloonedMemory   # MB
        $swap     = $qs.SwappedMemory     # MB
        $sev      = if ($swap -gt 100) { 'CRITICAL' } elseif ($balloon -gt 100 -or $swap -gt 0) { 'WARNING' } else { 'INFO' }
        $detail   = "Balloon: $balloon MB  |  Swap: $swap MB"
        Add-Result 'Memory Pressure' $sev 'VM' $vm.Name 'Balloon/Swap' $detail '' `
            $(if ($swap -gt 100) { 'SEVERE: VM is swapping to disk — immediately vMotion to a host with free memory or power off non-critical VMs' } `
              elseif ($balloon -gt 100) { 'Host is reclaiming guest memory via balloon driver — migrate VM to a host with more free memory' } `
              else { '' })
    }
}
else {
    Add-Result 'Memory Pressure' 'OK' 'Cluster' $scopeName 'Balloon/Swap' 'No VMs ballooning or swapping'
}

# ============================================================
# SECTION 4: Top VMs by CPU Usage
# ============================================================
Write-Host "`n--- Section 4: Top $TopVMCount VMs by CPU Usage ---`n" -ForegroundColor White

$topCPU = $vms |
    Where-Object { $_.PowerState -eq 'PoweredOn' } |
    Sort-Object { $_.ExtensionData.Summary.QuickStats.OverallCpuUsage } -Descending |
    Select-Object -First $TopVMCount

foreach ($vm in $topCPU) {
    $cpuMhz     = $vm.ExtensionData.Summary.QuickStats.OverallCpuUsage
    $cpuAlloc   = $vm.NumCpu * ($vm.VMHost.CpuTotalMhz / [math]::Max(1, $vm.VMHost.NumCpu))
    $cpuPct     = if ($cpuAlloc -gt 0) { [math]::Round($cpuMhz / $cpuAlloc * 100, 1) } else { 0 }
    $vmHostName = $vm.VMHost.Name

    Add-Result 'Top CPU VMs' 'INFO' 'VM' $vm.Name 'CPU Usage' `
        "$cpuMhz MHz ($cpuPct% of $($vm.NumCpu) vCPU allocation) on $vmHostName"
}

# ============================================================
# SECTION 5: Top VMs by Memory Consumption
# ============================================================
Write-Host "`n--- Section 5: Top $TopVMCount VMs by Memory Consumption ---`n" -ForegroundColor White

$topMem = $vms |
    Where-Object { $_.PowerState -eq 'PoweredOn' } |
    Sort-Object { $_.ExtensionData.Summary.QuickStats.HostMemoryUsage } -Descending |
    Select-Object -First $TopVMCount

foreach ($vm in $topMem) {
    $qs         = $vm.ExtensionData.Summary.QuickStats
    $hostMB     = $qs.HostMemoryUsage    # total consumed on host (MB)
    $guestMB    = $qs.GuestMemoryUsage   # active in guest (MB)
    $balloonMB  = $qs.BalloonedMemory
    $pct        = if ($vm.MemoryGB -gt 0) { [math]::Round($hostMB / ($vm.MemoryGB * 1024) * 100, 1) } else { 0 }
    $vmHostName = $vm.VMHost.Name

    $detail   = "$hostMB MB consumed ($pct% of $($vm.MemoryGB) GB) | Guest active: $guestMB MB"
    if ($balloonMB -gt 0) { $detail += " | Balloon: $balloonMB MB" }

    Add-Result 'Top Memory VMs' 'INFO' 'VM' $vm.Name 'Memory Consumed' "$detail  on $vmHostName"
}

# ============================================================
# SUMMARY
# ============================================================
$critical = ($results | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$warnings = ($results | Where-Object { $_.Severity -eq 'WARNING'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Scope         : $scopeName" -ForegroundColor White
Write-Host "  Hosts checked : $($hosts.Count)" -ForegroundColor White
Write-Host "  VMs checked   : $($vms.Count)" -ForegroundColor White
Write-Host "  CRITICAL      : $critical" -ForegroundColor $(if ($critical -gt 0) { 'Red'    } else { 'White' })
Write-Host "  WARNING       : $warnings" -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'White' })

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Where-Object { $_.Severity -in @('CRITICAL', 'WARNING') } |
        Select-Object Section, ObjectType, Object, Metric, Value, Recommendation |
        Format-Table -AutoSize
}
