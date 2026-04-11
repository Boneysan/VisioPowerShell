<#
.SYNOPSIS
    Models capacity scenarios (add VMs, remove host, expand cluster) to assess impact.

.DESCRIPTION
    Performs what-if capacity analysis by simulating changes to the cluster and
    calculating the resulting CPU, memory, and storage headroom. Supports three
    scenario types: adding VMs of a specified profile, removing a host from the
    cluster (failure simulation), and expanding the cluster by adding a new host.
    Reports current headroom and projected headroom for each scenario.

.PARAMETER ClusterName
    Required. The cluster to analyze.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Scenario
    Required. The what-if scenario to model.
    Valid values: AddVMs, RemoveHost, ExpandCluster.

.PARAMETER OutputFile
    Required. Path to export the what-if analysis report as CSV.

.PARAMETER VMCount
    Optional. Number of VMs to add (used with AddVMs scenario). Default: 10.

.PARAMETER VMvCPU
    Optional. vCPUs per new VM (used with AddVMs scenario). Default: 4.

.PARAMETER VMMemGB
    Optional. Memory per new VM in GB (used with AddVMs scenario). Default: 8.

.PARAMETER VMDiskGB
    Optional. Disk per new VM in GB (used with AddVMs scenario). Default: 100.

.PARAMETER TargetHostName
    Optional. Host to simulate removing (used with RemoveHost scenario). If omitted, removes smallest host.

.PARAMETER NewHostCpuGHz
    Optional. CPU capacity of new host in GHz (used with ExpandCluster scenario). Default: matches cluster average.

.PARAMETER NewHostMemGB
    Optional. Memory of new host in GB (used with ExpandCluster scenario). Default: matches cluster average.

.EXAMPLE
    .\Get-WhatIfCapacityAnalysis.ps1 -ClusterName "Production" -Scenario AddVMs -VMCount 20 -OutputFile "whatif-addvms.csv"
    Models the impact of adding 20 VMs to the Production cluster.

.EXAMPLE
    .\Get-WhatIfCapacityAnalysis.ps1 -ClusterName "Production" -Scenario RemoveHost -OutputFile "whatif-removehost.csv"
    Models the N-1 failure scenario for the Production cluster.

.OUTPUTS
    CSV with columns: Scenario, ResourceType, CurrentCapacityGB,
    CurrentUsedGB, CurrentFreeGB, CurrentUtilPct, ProjectedUsedGB,
    ProjectedFreeGB, ProjectedUtilPct, HeadroomChange, Feasible

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to cluster and host configuration

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
    [ValidateSet('AddVMs', 'RemoveHost', 'ExpandCluster')]
    [string]$Scenario,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$VMCount = 10,

    [Parameter(Mandatory=$false)]
    [int]$VMvCPU = 4,

    [Parameter(Mandatory=$false)]
    [double]$VMMemGB = 8,

    [Parameter(Mandatory=$false)]
    [double]$VMDiskGB = 100,

    [Parameter(Mandatory=$false)]
    [string]$TargetHostName,

    [Parameter(Mandatory=$false)]
    [double]$NewHostCpuGHz = 0,

    [Parameter(Mandatory=$false)]
    [double]$NewHostMemGB = 0
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

$hosts      = Get-VMHost -Location $cluster
$vms        = Get-VM -Location $cluster
$datastores = Get-Datastore -RelatedObject $cluster

# Current totals
$totalCpuGHz  = [math]::Round(($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum / 1000, 1)
$usedCpuGHz   = [math]::Round(($hosts | Measure-Object -Property CpuUsageMhz  -Sum).Sum / 1000, 1)
$totalMemGB   = [math]::Round(($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum, 1)
$usedMemGB    = [math]::Round(($hosts | Measure-Object -Property MemoryUsageGB -Sum).Sum, 1)
$totalStoreGB = [math]::Round(($datastores | Measure-Object -Property CapacityGB    -Sum).Sum, 1)
$usedStoreGB  = [math]::Round(($datastores | ForEach-Object { $_.CapacityGB - $_.FreeSpaceGB } | Measure-Object -Sum).Sum, 1)

Write-Host "Cluster '$ClusterName' — Scenario: $Scenario" -ForegroundColor Cyan
Write-Host "  Total CPU    : $totalCpuGHz GHz  Used: $usedCpuGHz GHz"     -ForegroundColor White
Write-Host "  Total Mem    : $totalMemGB GB    Used: $usedMemGB GB"         -ForegroundColor White
Write-Host "  Total Storage: $totalStoreGB GB  Used: $usedStoreGB GB"       -ForegroundColor White

# Calculate scenario deltas
$deltaCpuGHz  = 0
$deltaMemGB   = 0
$deltaStoreGB = 0
$scenarioDesc = ''

switch ($Scenario) {
    'AddVMs' {
        $cpuPerVMGHz  = [math]::Round($VMvCPU * 2.5, 1)  # Assume 2.5 GHz per vCPU (typical)
        $deltaCpuGHz  = [math]::Round($cpuPerVMGHz * $VMCount, 1)
        $deltaMemGB   = [math]::Round($VMMemGB * $VMCount, 1)
        $deltaStoreGB = [math]::Round($VMDiskGB * $VMCount, 1)
        $scenarioDesc = "Add $VMCount VMs ($VMvCPU vCPU, $VMMemGB GB RAM, $VMDiskGB GB disk each)"
    }
    'RemoveHost' {
        $targetHost = if ($TargetHostName) {
            $hosts | Where-Object { $_.Name -eq $TargetHostName }
        }
        else {
            $hosts | Sort-Object CpuTotalMhz | Select-Object -First 1
        }
        if (-not $targetHost) { Write-Error "Target host not found."; exit 1 }
        $deltaCpuGHz  = -[math]::Round($targetHost.CpuTotalMhz / 1000, 1)
        $deltaMemGB   = -[math]::Round($targetHost.MemoryTotalGB, 1)
        $deltaStoreGB = 0  # Datastores typically shared
        $scenarioDesc = "Remove host: $($targetHost.Name)"
        Write-Host "  Removing host: $($targetHost.Name) ($(-$deltaCpuGHz) GHz, $(-$deltaMemGB) GB)" -ForegroundColor Yellow
    }
    'ExpandCluster' {
        $avgCpu = if ($NewHostCpuGHz -gt 0) { $NewHostCpuGHz } else { [math]::Round($totalCpuGHz / $hosts.Count, 1) }
        $avgMem = if ($NewHostMemGB  -gt 0) { $NewHostMemGB  } else { [math]::Round($totalMemGB  / $hosts.Count, 1) }
        $deltaCpuGHz  = $avgCpu
        $deltaMemGB   = $avgMem
        $deltaStoreGB = 0
        $scenarioDesc = "Add 1 host ($avgCpu GHz CPU, $avgMem GB RAM)"
    }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-ResourceRow {
    param($ResourceType, $currentTotal, $currentUsed, $delta, $unit='GB')

    $projUsed    = [math]::Round($currentUsed + $delta, 1)
    $projTotal   = if ($Scenario -eq 'ExpandCluster' -and $ResourceType -ne 'Storage') { [math]::Round($currentTotal + $delta, 1) } elseif ($Scenario -eq 'RemoveHost' -and $ResourceType -ne 'Storage') { [math]::Round($currentTotal + $delta, 1) } else { $currentTotal }

    $curFree     = [math]::Round($currentTotal - $currentUsed, 1)
    $projFree    = [math]::Round($projTotal - $projUsed, 1)
    $curPct      = if ($currentTotal -gt 0) { [math]::Round($currentUsed / $currentTotal * 100, 1) } else { 0 }
    $projPct     = if ($projTotal    -gt 0) { [math]::Round($projUsed    / $projTotal    * 100, 1) } else { 0 }
    $feasible    = $projFree -ge 0 -and $projPct -le 100

    $results.Add([PSCustomObject]@{
        Scenario           = $scenarioDesc
        ResourceType       = $ResourceType
        CurrentCapacity    = "$currentTotal $unit"
        CurrentUsed        = "$currentUsed $unit"
        CurrentFree        = "$curFree $unit"
        CurrentUtilPct     = "$curPct%"
        ProjectedCapacity  = "$projTotal $unit"
        ProjectedUsed      = "$projUsed $unit"
        ProjectedFree      = "$projFree $unit"
        ProjectedUtilPct   = "$projPct%"
        HeadroomChange     = "$([math]::Round($projFree - $curFree, 1)) $unit"
        UtilizationChange  = "$([math]::Round($projPct - $curPct, 1))%"
        Feasible           = $feasible
    })
}

Add-ResourceRow -ResourceType 'CPU'     -currentTotal $totalCpuGHz  -currentUsed $usedCpuGHz  -delta $deltaCpuGHz  -unit 'GHz'
Add-ResourceRow -ResourceType 'Memory'  -currentTotal $totalMemGB   -currentUsed $usedMemGB   -delta $deltaMemGB   -unit 'GB'
Add-ResourceRow -ResourceType 'Storage' -currentTotal $totalStoreGB -currentUsed $usedStoreGB -delta $deltaStoreGB -unit 'GB'

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$feasible = ($results | Where-Object { $_.Feasible -eq $true }).Count -eq $results.Count

Write-Host "`n=== What-If Analysis: $Scenario ===" -ForegroundColor Cyan
Write-Host "  Scenario: $scenarioDesc" -ForegroundColor White
$results | Format-Table ResourceType, CurrentUtilPct, ProjectedUtilPct, HeadroomChange, Feasible -AutoSize
Write-Host "  Overall Feasible : $feasible" -ForegroundColor $(if ($feasible) { 'Green' } else { 'Red' })
Write-Host "  Output           : $OutputFile" -ForegroundColor White
