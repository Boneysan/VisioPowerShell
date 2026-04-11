<#
.SYNOPSIS
    Reports resource pool hierarchy with CPU/memory shares, reservations, and limits.

.DESCRIPTION
    Enumerates all resource pools in a cluster, reporting parent/child relationships,
    CPU and memory shares, reservations, limits, expandable reservation settings,
    and the number of VMs in each pool. Useful for capacity governance audits and
    identifying misconfigured resource pools.

.PARAMETER ClusterName
    Optional. Cluster to scope the report.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the resource pool report as CSV.

.EXAMPLE
    .\Get-ResourcePoolConfiguration.ps1 -ClusterName "Production" -OutputFile "respools.csv"
    Reports all resource pools in the Production cluster.

.OUTPUTS
    CSV with columns: ClusterName, PoolName, Parent, CPUShares, CPUShareLevel,
    CPUReservationMHz, CPULimitMHz, CPUExpandable, MemShareLevel, MemReservationMB,
    MemLimitMB, MemExpandable, VMCount

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to resource pool configuration

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
    [string]$OutputFile
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
    $resourcePools = Get-ResourcePool -Location $cluster
}
else {
    $resourcePools = Get-ResourcePool
}

# Exclude the hidden root "Resources" pool
$resourcePools = $resourcePools | Where-Object { $_.Name -ne 'Resources' }

Write-Host "Reporting on $($resourcePools.Count) resource pool(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pool in $resourcePools) {
    try {
        $parentName = try { $pool.Parent.Name } catch { 'Unknown' }
        $vmCount    = (Get-VM -Location $pool -ErrorAction SilentlyContinue).Count
        $poolView   = $pool | Get-View -Property Config, Parent

        $cpuAlloc = $poolView.Config.CpuAllocation
        $memAlloc = $poolView.Config.MemoryAllocation

        # Get cluster name
        $clName = try {
            ($pool | Get-View -Property Parent).Parent | ForEach-Object {
                $obj = Get-View $_ -ErrorAction SilentlyContinue
                if ($obj -and $obj.GetType().Name -match 'ClusterCompute') { $obj.Name }
            } | Select-Object -First 1
        } catch { $ClusterName }

        $results.Add([PSCustomObject]@{
            ClusterName      = if ($clName) { $clName } else { $ClusterName }
            PoolName         = $pool.Name
            Parent           = $parentName
            CPUShares        = if ($cpuAlloc.Shares) { $cpuAlloc.Shares.Shares } else { 'N/A' }
            CPUShareLevel    = if ($cpuAlloc.Shares) { $cpuAlloc.Shares.Level } else { 'N/A' }
            CPUReservationMHz= if ($cpuAlloc.Reservation) { $cpuAlloc.Reservation } else { 0 }
            CPULimitMHz      = if ($cpuAlloc.Limit -eq -1) { 'Unlimited' } else { $cpuAlloc.Limit }
            CPUExpandable    = $cpuAlloc.ExpandableReservation
            MemShareLevel    = if ($memAlloc.Shares) { $memAlloc.Shares.Level } else { 'N/A' }
            MemShares        = if ($memAlloc.Shares) { $memAlloc.Shares.Shares } else { 'N/A' }
            MemReservationMB = if ($memAlloc.Reservation) { $memAlloc.Reservation } else { 0 }
            MemLimitMB       = if ($memAlloc.Limit -eq -1) { 'Unlimited' } else { $memAlloc.Limit }
            MemExpandable    = $memAlloc.ExpandableReservation
            VMCount          = $vmCount
        })
    }
    catch {
        Write-Warning "Error processing pool $($pool.Name): $_"
    }
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== Resource Pool Summary ===" -ForegroundColor Cyan
Write-Host "  Resource pools : $($results.Count)" -ForegroundColor White
Write-Host "  Output         : $OutputFile" -ForegroundColor White
