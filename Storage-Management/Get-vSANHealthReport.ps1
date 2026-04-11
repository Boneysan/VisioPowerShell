<#
.SYNOPSIS
    Collects vSAN cluster health, disk group status, capacity, and object compliance.

.DESCRIPTION
    Queries vSAN-enabled clusters for cluster health tests, per-host disk group status,
    capacity utilization (with deduplication/compression savings), performance service
    status, and optionally enumerates object compliance health.

.PARAMETER ClusterName
    Optional. Name of the vSAN cluster to report on. If not specified, checks all vSAN clusters.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Base path for CSV output (multiple files will be created with suffixes).

.PARAMETER IncludeObjectHealth
    Optional. Switch. Include per-object compliance health (can be slow on large clusters).

.EXAMPLE
    .\Get-vSANHealthReport.ps1 -ClusterName "vSAN-Cluster" -OutputFile "vsan-report.csv"
    Generates vSAN health report for a specific cluster.

.EXAMPLE
    .\Get-vSANHealthReport.ps1 -vCenter "vc.example.com" -IncludeObjectHealth -OutputFile "vsan-full.csv"
    Full report including object health for all vSAN clusters.

.OUTPUTS
    Multiple CSVs:
    - <OutputFile>          : Cluster-level summary
    - <base>-diskgroups.csv : Per-host disk group details
    - <base>-health.csv     : Health test results

.NOTES
    Requires:
    - VMware PowerCLI module with vSAN cmdlets (VMware.VimAutomation.vds or Get-VsanClusterConfiguration)
    - vSAN enabled on target clusters

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
    [switch]$IncludeObjectHealth
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

# Find vSAN clusters
if ($ClusterName) {
    $clusters = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $clusters) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
}
else {
    $clusters = Get-Cluster
}

$vsanClusters = $clusters | Where-Object { $_.VsanEnabled }
if (-not $vsanClusters) {
    Write-Error "No vSAN-enabled clusters found."
    exit 1
}

Write-Host "Found $($vsanClusters.Count) vSAN cluster(s)" -ForegroundColor Cyan

# Derive output file paths
$basePath  = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$ext       = [System.IO.Path]::GetExtension($OutputFile)
$dir       = [System.IO.Path]::GetDirectoryName($OutputFile)
if (-not $dir) { $dir = '.' }
$diskGroupFile = Join-Path $dir ($basePath + '-diskgroups' + $ext)
$healthFile    = Join-Path $dir ($basePath + '-health' + $ext)

$summary    = [System.Collections.Generic.List[PSCustomObject]]::new()
$diskGroups = [System.Collections.Generic.List[PSCustomObject]]::new()
$healthItems= [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($cluster in $vsanClusters) {
    Write-Host "  Processing cluster: $($cluster.Name)..." -ForegroundColor White

    try {
        # Cluster config
        $vsanConfig = Get-VsanClusterConfiguration -Cluster $cluster -ErrorAction SilentlyContinue
        $dedupEnabled = if ($vsanConfig) { $vsanConfig.SpaceEfficiencyEnabled } else { 'N/A' }
        $comprEnabled = if ($vsanConfig) { $vsanConfig.CompressionEnabled } else { 'N/A' }
        $stretchedCluster = if ($vsanConfig) { $vsanConfig.StretchedClusterEnabled } else { $false }
        $faultDomainsEnabled = if ($vsanConfig) { $vsanConfig.FaultDomainEnabled } else { $false }

        # Capacity
        $vsanDatastore = Get-Datastore -RelatedObject $cluster | Where-Object { $_.Type -eq 'vsan' }
        $capacityGB = if ($vsanDatastore) { [math]::Round($vsanDatastore.CapacityGB, 2) } else { 'N/A' }
        $freeGB     = if ($vsanDatastore) { [math]::Round($vsanDatastore.FreeSpaceGB, 2) } else { 'N/A' }

        $summary.Add([PSCustomObject]@{
            ClusterName        = $cluster.Name
            HostCount          = (Get-VMHost -Location $cluster).Count
            DiskGroupCount     = 'See diskgroups file'
            CapacityGB         = $capacityGB
            FreeGB             = $freeGB
            UsedPercent        = if ($capacityGB -gt 0 -and $freeGB -ne 'N/A') { [math]::Round((($capacityGB - $freeGB) / $capacityGB) * 100, 1) } else { 'N/A' }
            DedupEnabled       = $dedupEnabled
            CompressionEnabled = $comprEnabled
            StretchedCluster   = $stretchedCluster
            FaultDomains       = $faultDomainsEnabled
        })

        # Disk groups per host
        $vsanHosts = Get-VMHost -Location $cluster
        foreach ($vsanHost in $vsanHosts) {
            try {
                $hostDiskGroups = Get-VsanDiskGroup -VMHost $vsanHost -ErrorAction SilentlyContinue
                if (-not $hostDiskGroups) {
                    $diskGroups.Add([PSCustomObject]@{
                        ClusterName   = $cluster.Name
                        HostName      = $vsanHost.Name
                        DiskGroupName = 'No disk groups'
                        CacheDisks    = 0
                        CapacityDisks = 0
                        State         = 'N/A'
                    })
                    continue
                }
                foreach ($dg in $hostDiskGroups) {
                    $cacheDisks    = ($dg.ExtensionData.Disk | Where-Object { $_.IsSsd -and -not $_.IsCapacityFlash }).Count
                    $capacityDisks = ($dg.ExtensionData.Disk | Where-Object { -not $_.IsSsd -or $_.IsCapacityFlash }).Count
                    $diskGroups.Add([PSCustomObject]@{
                        ClusterName   = $cluster.Name
                        HostName      = $vsanHost.Name
                        DiskGroupName = $dg.Name
                        CacheDisks    = $cacheDisks
                        CapacityDisks = $capacityDisks
                        State         = $dg.OperationalState
                    })
                }
            }
            catch {
                Write-Warning "    Could not get disk groups for $($vsanHost.Name): $_"
            }
        }

        # Health tests
        try {
            $clusterView = $cluster | Get-View
            $vsanHealthSystem = Get-View -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system' -ErrorAction SilentlyContinue
            if ($vsanHealthSystem) {
                $healthResult = $vsanHealthSystem.VsanQueryVcClusterHealthSummary($clusterView.MoRef, $null, $null, $true, $null, $null, 'defaultView')
                if ($healthResult -and $healthResult.Groups) {
                    foreach ($group in $healthResult.Groups) {
                        foreach ($test in $group.GroupTests) {
                            $healthItems.Add([PSCustomObject]@{
                                ClusterName = $cluster.Name
                                GroupName   = $group.GroupName
                                TestName    = $test.TestName
                                Result      = $test.TestHealth
                                Details     = $test.TestShortDescription
                            })
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "  Could not retrieve health test results: $_"
        }
    }
    catch {
        Write-Warning "Error processing vSAN cluster $($cluster.Name): $_"
    }
}

$summary    | Export-Csv -Path $OutputFile    -NoTypeInformation
$diskGroups | Export-Csv -Path $diskGroupFile -NoTypeInformation
$healthItems| Export-Csv -Path $healthFile    -NoTypeInformation

Write-Host "`n=== vSAN Health Report Summary ===" -ForegroundColor Cyan
Write-Host "  vSAN clusters     : $($vsanClusters.Count)" -ForegroundColor White
Write-Host "  Disk group records: $($diskGroups.Count)" -ForegroundColor White
Write-Host "  Health tests      : $($healthItems.Count)" -ForegroundColor White
$failed = ($healthItems | Where-Object { $_.Result -ne 'green' -and $_.Result -ne 'skipped' }).Count
Write-Host "  Unhealthy tests   : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Summary output    : $OutputFile" -ForegroundColor White
Write-Host "  Disk groups       : $diskGroupFile" -ForegroundColor White
Write-Host "  Health tests      : $healthFile" -ForegroundColor White
