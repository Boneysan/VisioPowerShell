<#
.SYNOPSIS
    Produces detailed right-sizing recommendations for VMs using performance statistics.

.DESCRIPTION
    Analyzes vCenter CPU and memory performance statistics over the specified interval
    to calculate the 95th-percentile utilization for each VM. Compares this against
    the currently provisioned vCPU/vRAM and recommends the appropriate sizing with
    a configurable headroom percentage. Identifies over-provisioned VMs that are
    consuming excess cluster resources.

.PARAMETER ClusterName
    Optional. Cluster to analyze. If omitted, analyzes all VMs.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the right-sizing report as CSV.

.PARAMETER SampleDays
    Optional. Number of days of performance history to analyze. Default: 30.

.PARAMETER HeadroomPercent
    Optional. Percentage headroom to add above P95 for recommended sizing. Default: 20.

.PARAMETER MinSampleCount
    Optional. Minimum number of samples required to generate recommendation. Default: 100.

.EXAMPLE
    .\Get-VMRightSizingDetailed.ps1 -ClusterName "Production" -OutputFile "rightsizing.csv"
    Analyzes Production cluster VMs over 30 days with 20% headroom.

.EXAMPLE
    .\Get-VMRightSizingDetailed.ps1 -SampleDays 14 -HeadroomPercent 25 -OutputFile "rightsizing-2w.csv"
    2-week analysis with 25% headroom.

.OUTPUTS
    CSV with columns: VMName, ClusterName, CurrentvCPU, CurrentMemGB,
    P95CpuUsagePct, P95MemUsagePct, RecommendedvCPU, RecommendedMemGB,
    CPUSavingsPct, MemSavingsPct, Recommendation, SampleCount

.NOTES
    Requires:
    - VMware PowerCLI module
    - vCenter performance stats (level 1+)

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$SampleDays = 30,

    [Parameter(Mandatory=$false)]
    [int]$HeadroomPercent = 20,

    [Parameter(Mandatory=$false)]
    [int]$MinSampleCount = 100
)

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

if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster | Where-Object { $_.PowerState -eq 'PoweredOn' }
}
else {
    $vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
}

Write-Host "Analyzing right-sizing for $($vms.Count) powered-on VMs over $SampleDays days..." -ForegroundColor Cyan
Write-Host "  Headroom: $HeadroomPercent% | Min Samples: $MinSampleCount" -ForegroundColor Yellow

$startTime = (Get-Date).AddDays(-$SampleDays)
$endTime   = Get-Date

function Get-Percentile {
    param([double[]]$values, [int]$percentile)
    if ($values.Count -eq 0) { return 0 }
    $sorted = $values | Sort-Object
    $index  = [math]::Ceiling($percentile / 100.0 * $sorted.Count) - 1
    return $sorted[[math]::Max(0, $index)]
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmIndex = 0

foreach ($vm in ($vms | Sort-Object Name)) {
    $vmIndex++
    Write-Progress -Activity "Analyzing VM performance" -Status "$($vm.Name) ($vmIndex/$($vms.Count))" -PercentComplete ($vmIndex / $vms.Count * 100)

    $clusterObj   = $vm.VMHost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    try {
        $cpuStats = Get-Stat -Entity $vm -Stat 'cpu.usage.average' -Start $startTime -Finish $endTime -IntervalMins 30 -ErrorAction SilentlyContinue
        $memStats = Get-Stat -Entity $vm -Stat 'mem.usage.average' -Start $startTime -Finish $endTime -IntervalMins 30 -ErrorAction SilentlyContinue

        $cpuValues = if ($cpuStats) { $cpuStats.Value | ForEach-Object { [double]$_ } } else { @() }
        $memValues = if ($memStats) { $memStats.Value | ForEach-Object { [double]$_ } } else { @() }

        $sampleCount = [math]::Min($cpuValues.Count, $memValues.Count)

        if ($sampleCount -lt $MinSampleCount) {
            $results.Add([PSCustomObject]@{
                VMName            = $vm.Name
                ClusterName       = $clusterLabel
                CurrentvCPU       = $vm.NumCpu
                CurrentMemGB      = [math]::Round($vm.MemoryGB, 1)
                P95CpuUsagePct    = 'N/A'
                P95MemUsagePct    = 'N/A'
                RecommendedvCPU   = 'N/A'
                RecommendedMemGB  = 'N/A'
                CPUSavingsPct     = 'N/A'
                MemSavingsPct     = 'N/A'
                Recommendation    = "Insufficient data ($sampleCount samples)"
                SampleCount       = $sampleCount
            })
            continue
        }

        $p95Cpu = [math]::Round((Get-Percentile -values $cpuValues -percentile 95), 1)
        $p95Mem = [math]::Round((Get-Percentile -values $memValues -percentile 95), 1)

        # Convert P95 % to required vCPUs with headroom
        $requiredCpuPct = $p95Cpu * (1 + $HeadroomPercent / 100.0)
        $reqvCPU = [math]::Max(1, [math]::Ceiling($vm.NumCpu * $requiredCpuPct / 100.0))

        # Convert P95 mem % to GB with headroom
        $reqMemGB = [math]::Max(0.25, [math]::Round($vm.MemoryGB * $p95Mem / 100.0 * (1 + $HeadroomPercent / 100.0), 1))

        $cpuSavingsPct = [math]::Round((1 - $reqvCPU / $vm.NumCpu) * 100, 0)
        $memSavingsPct = [math]::Round((1 - $reqMemGB / $vm.MemoryGB) * 100, 0)

        $recommendation = 'Right-sized'
        if ($reqvCPU -lt $vm.NumCpu -or $reqMemGB -lt $vm.MemoryGB) { $recommendation = 'Over-provisioned - Downsize' }
        if ($reqvCPU -gt $vm.NumCpu -or $reqMemGB -gt $vm.MemoryGB) { $recommendation = 'Under-provisioned - Upsize' }

        $results.Add([PSCustomObject]@{
            VMName            = $vm.Name
            ClusterName       = $clusterLabel
            CurrentvCPU       = $vm.NumCpu
            CurrentMemGB      = [math]::Round($vm.MemoryGB, 1)
            P95CpuUsagePct    = $p95Cpu
            P95MemUsagePct    = $p95Mem
            RecommendedvCPU   = $reqvCPU
            RecommendedMemGB  = $reqMemGB
            CPUSavingsPct     = [math]::Max(0, $cpuSavingsPct)
            MemSavingsPct     = [math]::Max(0, $memSavingsPct)
            Recommendation    = $recommendation
            SampleCount       = $sampleCount
        })
    }
    catch {
        Write-Warning "  Could not analyze $($vm.Name): $_"
    }
}

Write-Progress -Activity "Analyzing VM performance" -Completed

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$overProvisioned  = ($results | Where-Object { $_.Recommendation -eq 'Over-provisioned - Downsize' }).Count
$underProvisioned = ($results | Where-Object { $_.Recommendation -eq 'Under-provisioned - Upsize' }).Count
$rightSized       = ($results | Where-Object { $_.Recommendation -eq 'Right-sized' }).Count

Write-Host "`n=== VM Right-Sizing Summary ===" -ForegroundColor Cyan
Write-Host "  VMs Analyzed      : $($results.Count)"   -ForegroundColor White
Write-Host "  Over-Provisioned  : $overProvisioned"     -ForegroundColor $(if ($overProvisioned -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Under-Provisioned : $underProvisioned"    -ForegroundColor $(if ($underProvisioned -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Right-Sized       : $rightSized"          -ForegroundColor Green
Write-Host "  Output            : $OutputFile"          -ForegroundColor White
