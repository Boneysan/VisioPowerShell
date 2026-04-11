<#
.SYNOPSIS
    Reports ESXi host patch levels and compares against a target build number.

.DESCRIPTION
    Enumerates all ESXi hosts and reports their version, build number, installed
    VIBs, and security patches. Compares each host's build against a configurable
    target build number to identify hosts requiring patching. Can also identify
    hosts on different build levels within the same cluster (patch drift).

.PARAMETER ClusterName
    Optional. Cluster to scope the report.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the patch level report as CSV.

.PARAMETER TargetBuild
    Optional. Target build number to compare against. Hosts below this build are flagged.

.PARAMETER IncludeVIBs
    Optional switch. Include per-VIB details in a second output file.

.EXAMPLE
    .\Get-ESXiPatchLevel.ps1 -ClusterName "Production" -TargetBuild 21495797 -OutputFile "patch-levels.csv"
    Reports hosts not at the specified build.

.EXAMPLE
    .\Get-ESXiPatchLevel.ps1 -IncludeVIBs -OutputFile "esxi-patch-report.csv"
    Full patch report with VIB details.

.OUTPUTS
    CSV with columns: HostName, ClusterName, Version, Build, FullVersion,
    PatchStatus, TargetBuild, DriftFromCluster

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi host configuration

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
    [long]$TargetBuild = 0,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeVIBs
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
    $hosts = Get-VMHost -Location $cluster
}
else {
    $hosts = Get-VMHost
}

Write-Host "Checking patch levels for $($hosts.Count) host(s)..." -ForegroundColor Cyan

$results    = [System.Collections.Generic.List[PSCustomObject]]::new()
$vibResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# Determine cluster build consensus for drift detection
$clusterBuilds = $hosts | Group-Object {
    $cl = $_ | Get-Cluster -ErrorAction SilentlyContinue
    if ($cl) { $cl.Name } else { 'Standalone' }
} | ForEach-Object {
    $maxBuild = ($_.Group | Measure-Object -Property Build -Maximum).Maximum
    [PSCustomObject]@{ ClusterName=$_.Name; ConsensusMaxBuild=$maxBuild }
}
$buildMap = @{}
foreach ($cb in $clusterBuilds) { $buildMap[$cb.ClusterName] = $cb.ConsensusMaxBuild }

foreach ($vmhost in ($hosts | Sort-Object Name)) {
    $clusterObj   = $vmhost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    $build     = [long]$vmhost.Build
    $maxBuild  = if ($buildMap.ContainsKey($clusterLabel)) { $buildMap[$clusterLabel] } else { $build }

    $patchStatus  = 'Current'
    if ($TargetBuild -gt 0 -and $build -lt $TargetBuild) { $patchStatus = 'BEHIND TARGET' }
    if ($TargetBuild -eq 0 -and $build -lt $maxBuild)    { $patchStatus = 'CLUSTER DRIFT' }

    $clusterDrift = if ($build -lt $maxBuild) { "Behind by ~$($maxBuild - $build) build units" } else { 'None' }

    $results.Add([PSCustomObject]@{
        HostName         = $vmhost.Name
        ClusterName      = $clusterLabel
        Version          = $vmhost.Version
        Build            = $build
        FullVersion      = $vmhost.ExtensionData.Config.Product.FullName
        PatchStatus      = $patchStatus
        TargetBuild      = if ($TargetBuild -gt 0) { $TargetBuild } else { 'N/A' }
        ClusterMaxBuild  = $maxBuild
        DriftFromCluster = $clusterDrift
    })

    # VIBs
    if ($IncludeVIBs) {
        try {
            $esxcli = Get-EsxCli -VMHost $vmhost -V2 -ErrorAction SilentlyContinue
            if ($esxcli) {
                $vibs = $esxcli.software.vib.list.Invoke()
                foreach ($vib in $vibs) {
                    $vibResults.Add([PSCustomObject]@{
                        HostName    = $vmhost.Name
                        VIBName     = $vib.Name
                        Version     = $vib.Version
                        Vendor      = $vib.Vendor
                        InstallDate = $vib.InstallDate
                        Category    = $vib.Type
                    })
                }
            }
        }
        catch {
            Write-Warning "Could not enumerate VIBs for $($vmhost.Name): $_"
        }
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

if ($IncludeVIBs -and $vibResults.Count -gt 0) {
    $vibFile = [System.IO.Path]::ChangeExtension($OutputFile, $null).TrimEnd('.') + '_vibs.csv'
    $vibResults | Export-Csv -Path $vibFile -NoTypeInformation
    Write-Host "VIB details exported to: $vibFile" -ForegroundColor Yellow
}

$behindTarget = ($results | Where-Object { $_.PatchStatus -eq 'BEHIND TARGET' }).Count
$drifted      = ($results | Where-Object { $_.PatchStatus -eq 'CLUSTER DRIFT' }).Count

Write-Host "`n=== ESXi Patch Level Summary ===" -ForegroundColor Cyan
Write-Host "  Total Hosts    : $($results.Count)"  -ForegroundColor White
Write-Host "  Behind Target  : $behindTarget"       -ForegroundColor $(if ($behindTarget -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Cluster Drift  : $drifted"            -ForegroundColor $(if ($drifted -gt 0) { 'Yellow' } else { 'Green' })
if ($TargetBuild -gt 0) { Write-Host "  Target Build   : $TargetBuild" -ForegroundColor White }
Write-Host "  Output         : $OutputFile"         -ForegroundColor White
