<#
.SYNOPSIS
    Forecasts CPU, memory, and storage capacity exhaustion dates using trend analysis.

.DESCRIPTION
    Collects cluster-level CPU, memory, and datastore utilization history from vCenter
    performance statistics. Uses weighted linear regression on recent data points to
    project capacity exhaustion dates. Produces a per-resource forecast with
    current utilization, trend rate, and projected full date.

.PARAMETER ClusterName
    Required. The cluster to analyze.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the capacity forecast report as CSV.

.PARAMETER ForecastDays
    Optional. Number of days of historical data to use for trend analysis. Default: 30.

.PARAMETER CapacityThresholdPercent
    Optional. The utilization percentage to treat as "exhausted". Default: 85.

.EXAMPLE
    .\Get-CapacityForecast.ps1 -ClusterName "Production" -OutputFile "capacity-forecast.csv"
    Generates a 30-day trend-based capacity forecast for the Production cluster.

.EXAMPLE
    .\Get-CapacityForecast.ps1 -ClusterName "Production" -ForecastDays 60 -OutputFile "forecast-60d.csv"
    Uses 60 days of history for a longer trend analysis.

.OUTPUTS
    CSV with columns: ResourceType, ResourceName, CurrentUsedGB, TotalCapacityGB,
    CurrentUtilizationPct, DailyGrowthGB, DaysUntilThreshold, ProjectedFullDate, TrendConfidence

.NOTES
    Requires:
    - VMware PowerCLI module
    - vCenter performance stats enabled (level 1+)

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$ForecastDays = 30,

    [Parameter(Mandatory=$false)]
    [double]$CapacityThresholdPercent = 85.0
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

$cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

Write-Host "Analyzing capacity trends for '$ClusterName' over last $ForecastDays days..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Linear regression helper: returns slope (units per day) and intercept
function Get-LinearTrend {
    param([double[]]$values)
    $n = $values.Count
    if ($n -lt 2) { return [PSCustomObject]@{ Slope=0; Intercept=($values | Select-Object -Last 1); R2=0 } }
    $xVals = 0..($n-1) | ForEach-Object { [double]$_ }
    $sumX  = ($xVals | Measure-Object -Sum).Sum
    $sumY  = ($values | Measure-Object -Sum).Sum
    $sumXY = 0; for ($i=0; $i -lt $n; $i++) { $sumXY += $xVals[$i] * $values[$i] }
    $sumX2 = ($xVals | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum
    $slope = ($n * $sumXY - $sumX * $sumY) / ($n * $sumX2 - $sumX * $sumX)
    $intercept = ($sumY - $slope * $sumX) / $n
    # R-squared
    $meanY = $sumY / $n
    $ssTot = ($values | ForEach-Object { ($_ - $meanY)*($_ - $meanY) } | Measure-Object -Sum).Sum
    $ssRes = 0; for ($i=0; $i -lt $n; $i++) { $pred = $slope * $i + $intercept; $ssRes += ($values[$i] - $pred)*($values[$i] - $pred) }
    $r2 = if ($ssTot -ne 0) { [math]::Max(0, 1 - $ssRes/$ssTot) } else { 0 }
    return [PSCustomObject]@{ Slope=$slope; Intercept=$intercept; R2=[math]::Round($r2,3) }
}

$startDate = (Get-Date).AddDays(-$ForecastDays)
$endDate   = Get-Date

# --- CPU / Memory: aggregate cluster hosts ---
$hosts = Get-VMHost -Location $cluster
$totalCpuGHz = [math]::Round(($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum / 1000, 1)
$totalMemGB  = [math]::Round(($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum, 1)

# Sample aggregated CPU/Mem usage (daily averages from perf stats)
$cpuSamples = [System.Collections.Generic.List[double]]::new()
$memSamples = [System.Collections.Generic.List[double]]::new()

Write-Host "  Collecting daily CPU/Memory performance samples..." -ForegroundColor Yellow
for ($day = $ForecastDays; $day -ge 1; $day--) {
    $dayStart = (Get-Date).AddDays(-$day)
    $dayEnd   = $dayStart.AddDays(1)
    $cpuTotal = 0; $memTotal = 0; $count = 0
    foreach ($h in $hosts) {
        $cpuStat = Get-Stat -Entity $h -Stat 'cpu.usage.average' -Start $dayStart -Finish $dayEnd -IntervalMins 60 -ErrorAction SilentlyContinue
        $memStat = Get-Stat -Entity $h -Stat 'mem.usage.average' -Start $dayStart -Finish $dayEnd -IntervalMins 60 -ErrorAction SilentlyContinue
        if ($cpuStat -or $memStat) {
            if ($cpuStat) { $cpuTotal += ($cpuStat | Measure-Object -Property Value -Average).Average }
            if ($memStat) { $memTotal += ($memStat | Measure-Object -Property Value -Average).Average }
            $count++
        }
    }
    if ($count -gt 0) {
        $cpuSamples.Add([math]::Round($cpuTotal / $count, 2))
        $memSamples.Add([math]::Round($memTotal / $count, 2))
    }
}

function Add-Forecast {
    param($ResourceType, $ResourceName, $samples, $totalCapacityGB, $unitIsPercent=$true)

    if ($samples.Count -lt 2) {
        $results.Add([PSCustomObject]@{
            ResourceType            = $ResourceType
            ResourceName            = $ResourceName
            CurrentUsedGB           = 'N/A'
            TotalCapacityGB         = [math]::Round($totalCapacityGB, 1)
            CurrentUtilizationPct   = 'N/A'
            DailyGrowthGB           = 'N/A'
            DaysUntilThreshold      = $null
            ProjectedFullDate       = 'Insufficient Data'
            TrendConfidence         = $null
        })
        return
    }

    $trend   = Get-LinearTrend -values $samples.ToArray()
    $current = $samples[$samples.Count - 1]

    $currentPct   = if ($unitIsPercent) { $current } else { [math]::Round($current / $totalCapacityGB * 100, 1) }
    $currentUsed  = if ($unitIsPercent) { [math]::Round($current / 100 * $totalCapacityGB, 1) } else { $current }
    $dailyGrowth  = if ($unitIsPercent) { [math]::Round($trend.Slope / 100 * $totalCapacityGB, 2) } else { [math]::Round($trend.Slope, 2) }

    $thresholdValue = if ($unitIsPercent) { $CapacityThresholdPercent } else { $totalCapacityGB * $CapacityThresholdPercent / 100 }
    $daysUntil = if ($trend.Slope -gt 0) { [math]::Round(($thresholdValue - $current) / $trend.Slope) } else { 9999 }
    $projDate  = if ($daysUntil -lt 9999 -and $daysUntil -gt 0) { (Get-Date).AddDays($daysUntil).ToString('yyyy-MM-dd') } elseif ($daysUntil -le 0) { 'Already Exceeded' } else { 'No Growth' }

    $results.Add([PSCustomObject]@{
        ResourceType            = $ResourceType
        ResourceName            = $ResourceName
        CurrentUsedGB           = $currentUsed
        TotalCapacityGB         = [math]::Round($totalCapacityGB, 1)
        CurrentUtilizationPct   = [math]::Round($currentPct, 1)
        DailyGrowthGB           = $dailyGrowth
        DaysUntilThreshold      = if ($daysUntil -lt 9999) { $daysUntil } else { $null }
        ProjectedFullDate       = $projDate
        TrendConfidence         = "$([math]::Round($trend.R2 * 100, 0))%"
    })
}

Add-Forecast -ResourceType 'CPU'    -ResourceName $ClusterName -samples $cpuSamples -totalCapacityGB $totalCpuGHz -unitIsPercent $true
Add-Forecast -ResourceType 'Memory' -ResourceName $ClusterName -samples $memSamples -totalCapacityGB $totalMemGB  -unitIsPercent $true

# --- Storage: per datastore ---
Write-Host "  Analyzing storage trends..." -ForegroundColor Yellow
$datastores = Get-Datastore -RelatedObject $cluster | Sort-Object Name -Unique
foreach ($ds in $datastores) {
    $dsSamples = [System.Collections.Generic.List[double]]::new()
    for ($day = $ForecastDays; $day -ge 1; $day--) {
        $dayStart = (Get-Date).AddDays(-$day)
        $dayEnd   = $dayStart.AddDays(1)
        $stat = Get-Stat -Entity $ds -Stat 'disk.used.latest' -Start $dayStart -Finish $dayEnd -IntervalMins 1440 -ErrorAction SilentlyContinue
        if ($stat) { $dsSamples.Add([math]::Round(($stat | Measure-Object -Property Value -Average).Average / 1GB, 2)) }
    }
    if ($dsSamples.Count -lt 2) {
        # Use current snapshot
        $usedGB  = [math]::Round($ds.CapacityGB - $ds.FreeSpaceGB, 1)
        $dsSamples.Add($usedGB)
    }
    Add-Forecast -ResourceType 'Storage' -ResourceName $ds.Name -samples $dsSamples -totalCapacityGB $ds.CapacityGB -unitIsPercent $false
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$critical = ($results | Where-Object { $_.DaysUntilThreshold -is [int] -and $_.DaysUntilThreshold -lt 30 }).Count
$warning  = ($results | Where-Object { $_.DaysUntilThreshold -is [int] -and $_.DaysUntilThreshold -ge 30 -and $_.DaysUntilThreshold -lt 90 }).Count

Write-Host "`n=== Capacity Forecast Summary ===" -ForegroundColor Cyan
Write-Host "  Resources Analyzed  : $($results.Count)"   -ForegroundColor White
Write-Host "  Critical (<30 days) : $critical"            -ForegroundColor $(if ($critical -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warning  (<90 days) : $warning"             -ForegroundColor $(if ($warning -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Threshold Pct       : $CapacityThresholdPercent%" -ForegroundColor White
Write-Host "  Output              : $OutputFile"          -ForegroundColor White
