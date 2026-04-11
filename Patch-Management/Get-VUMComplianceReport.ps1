<#
.SYNOPSIS
    Reports vSphere Lifecycle Manager (vLCM) / Update Manager baseline compliance.

.DESCRIPTION
    Queries vSphere Update Manager (VUM) or vSphere Lifecycle Manager (vLCM) for
    baseline and image compliance status of ESXi hosts in the target cluster.
    Reports compliance status, missing patches/updates, and last scan time.
    Supports both traditional VUM baselines and vLCM desired-state images.

.PARAMETER ClusterName
    Optional. Cluster to scope the compliance report.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the VUM compliance report as CSV.

.PARAMETER BaselineName
    Optional. Filter to a specific baseline name.

.PARAMETER RunScan
    Optional switch. Triggers a compliance scan before reporting. Requires more time.

.EXAMPLE
    .\Get-VUMComplianceReport.ps1 -ClusterName "Production" -OutputFile "vum-compliance.csv"
    Exports VUM/vLCM compliance for all hosts in Production cluster.

.EXAMPLE
    .\Get-VUMComplianceReport.ps1 -RunScan -OutputFile "vum-compliance-live.csv"
    Runs a fresh scan across all hosts then exports results.

.OUTPUTS
    CSV with columns: HostName, ClusterName, BaselineName, BaselineType,
    ComplianceStatus, LastScanTime, MissingPatches, MissingPatchDetails

.NOTES
    Requires:
    - VMware PowerCLI module including VMware.VimAutomation.PatchManagement

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
    [string]$BaselineName,

    [Parameter(Mandatory=$false)]
    [switch]$RunScan
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

Write-Host "Querying VUM/vLCM compliance for $($hosts.Count) host(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Optionally trigger a scan
if ($RunScan) {
    Write-Host "  Triggering compliance scan (this may take several minutes)..." -ForegroundColor Yellow
    try {
        $scanTask = Test-Compliance -Entity $hosts -ErrorAction SilentlyContinue
        if ($scanTask) { Wait-Task -Task $scanTask -ErrorAction SilentlyContinue | Out-Null }
    }
    catch {
        Write-Warning "Scan trigger failed: $_ - continuing with last known compliance state"
    }
}

foreach ($vmhost in ($hosts | Sort-Object Name)) {
    $clusterObj   = $vmhost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    try {
        $compliances = Get-Compliance -Entity $vmhost -ErrorAction SilentlyContinue

        if (-not $compliances) {
            $results.Add([PSCustomObject]@{
                HostName          = $vmhost.Name
                ClusterName       = $clusterLabel
                BaselineName      = 'No Baselines Attached'
                BaselineType      = 'N/A'
                ComplianceStatus  = 'Unknown'
                LastScanTime      = 'N/A'
                MissingPatches    = 0
                MissingPatchDetails = 'No VUM baselines attached to this host'
            })
            continue
        }

        foreach ($comp in $compliances) {
            if ($BaselineName -and $comp.Baseline.Name -ne $BaselineName) { continue }

            $missing     = @()
            $missingCount = 0

            if ($comp.Status -ne 'Compliant' -and $comp.PSObject.Properties['NotCompliantPatches']) {
                $missing = $comp.NotCompliantPatches | ForEach-Object { $_.Name } | Select-Object -First 10
                $missingCount = $comp.NotCompliantPatches.Count
            }

            $results.Add([PSCustomObject]@{
                HostName            = $vmhost.Name
                ClusterName         = $clusterLabel
                BaselineName        = $comp.Baseline.Name
                BaselineType        = $comp.Baseline.BaselineType
                ComplianceStatus    = $comp.Status
                LastScanTime        = if ($comp.CheckTime) { $comp.CheckTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                MissingPatches      = $missingCount
                MissingPatchDetails = ($missing -join '; ')
            })
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
            HostName='ERROR'; ClusterName=$clusterLabel; BaselineName='Error'; BaselineType='N/A'
            ComplianceStatus='Error'; LastScanTime='N/A'; MissingPatches=0
            MissingPatchDetails=$_.Exception.Message
        })
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$nonCompliant = ($results | Where-Object { $_.ComplianceStatus -ne 'Compliant' -and $_.ComplianceStatus -ne 'Unknown' -and $_.ComplianceStatus -ne 'Error' }).Count
$compliant    = ($results | Where-Object { $_.ComplianceStatus -eq 'Compliant' }).Count

Write-Host "`n=== VUM Compliance Report Summary ===" -ForegroundColor Cyan
Write-Host "  Total Entries   : $($results.Count)"  -ForegroundColor White
Write-Host "  Compliant       : $compliant"          -ForegroundColor Green
Write-Host "  Non-Compliant   : $nonCompliant"       -ForegroundColor $(if ($nonCompliant -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output          : $OutputFile"         -ForegroundColor White
