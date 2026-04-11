<#
.SYNOPSIS
    Detects configuration drift between current vSphere state and a saved baseline.

.DESCRIPTION
    Compares the live cluster configuration against a JSON baseline file previously
    created by Export-ClusterConfiguration.ps1. Highlights any differences in HA,
    DRS, host versions, NTP servers, services, and resource pool settings.
    Produces a drift report CSV showing each changed setting.

.PARAMETER ClusterName
    Required. The cluster to compare against the baseline.

.PARAMETER BaselineFile
    Required. Path to the JSON baseline file from Export-ClusterConfiguration.ps1.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the drift report as CSV.

.PARAMETER IncludeHostDetails
    Optional switch. Compare per-host service and advanced setting details.

.EXAMPLE
    .\Test-ConfigurationDrift.ps1 -ClusterName "Production" -BaselineFile "prod-baseline.json" -OutputFile "drift-report.csv"
    Compares current Production cluster state against the saved baseline.

.OUTPUTS
    CSV with columns: Category, Item, Setting, BaselineValue, CurrentValue, Drifted

.NOTES
    Requires:
    - VMware PowerCLI module
    - Baseline file from Export-ClusterConfiguration.ps1

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$BaselineFile,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeHostDetails
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

if (-not (Test-Path $BaselineFile)) {
    Write-Error "Baseline file not found: $BaselineFile"
    exit 1
}

$baseline = Get-Content $BaselineFile -Raw | ConvertFrom-Json
$cluster  = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

Write-Host "Comparing current configuration to baseline: $BaselineFile" -ForegroundColor Cyan
Write-Host "  Baseline Date: $($baseline.ExportDate)" -ForegroundColor Yellow

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Compare-Setting {
    param($Category, $Item, $Setting, $BaselineValue, $CurrentValue)
    $drifted = ($BaselineValue -ne $null) -and ($BaselineValue.ToString() -ne $CurrentValue.ToString())
    $results.Add([PSCustomObject]@{
        Category       = $Category
        Item           = $Item
        Setting        = $Setting
        BaselineValue  = if ($BaselineValue -ne $null) { $BaselineValue.ToString() } else { 'N/A' }
        CurrentValue   = if ($CurrentValue  -ne $null) { $CurrentValue.ToString()  } else { 'N/A' }
        Drifted        = $drifted
    })
}

$clusterView = $cluster | Get-View -Property ConfigurationEx
$dasConfig   = $clusterView.ConfigurationEx.DasConfig
$drsConfig   = $clusterView.ConfigurationEx.DrsConfig

# HA
Compare-Setting 'HA' $ClusterName 'Enabled'                 $baseline.HA.Enabled                 $cluster.HAEnabled
Compare-Setting 'HA' $ClusterName 'AdmissionControlEnabled' $baseline.HA.AdmissionControlEnabled  $dasConfig.AdmissionControlEnabled
Compare-Setting 'HA' $ClusterName 'RestartPriority'         $baseline.HA.RestartPriority           $dasConfig.DefaultVmSettings.RestartPriority
Compare-Setting 'HA' $ClusterName 'IsolationResponse'       $baseline.HA.IsolationResponse         $dasConfig.DefaultVmSettings.IsolationResponse

# DRS
Compare-Setting 'DRS' $ClusterName 'Enabled'            $baseline.DRS.Enabled             $cluster.DrsEnabled
Compare-Setting 'DRS' $ClusterName 'AutomationLevel'    $baseline.DRS.Automation          $cluster.DrsAutomationLevel.ToString()
Compare-Setting 'DRS' $ClusterName 'MigrationThreshold' $baseline.DRS.MigrationThreshold  $drsConfig.VmotionRate

# EVC
Compare-Setting 'EVC' $ClusterName 'Mode' $baseline.EVC.Mode $cluster.EVCMode

# Hosts
$currentHosts = Get-VMHost -Location $cluster | Sort-Object Name
$baselineHosts = $baseline.Hosts

foreach ($bHost in $baselineHosts) {
    $cHost = $currentHosts | Where-Object { $_.Name -eq $bHost.Name }
    if (-not $cHost) {
        $results.Add([PSCustomObject]@{
            Category='Host'; Item=$bHost.Name; Setting='Existence'; BaselineValue='Present'; CurrentValue='Removed'; Drifted=$true
        })
        continue
    }

    Compare-Setting 'Host' $bHost.Name 'Version'         $bHost.Version    $cHost.Version
    Compare-Setting 'Host' $bHost.Name 'Build'           $bHost.Build      $cHost.Build
    Compare-Setting 'Host' $bHost.Name 'ConnectionState' $bHost.ConnectionState $cHost.ConnectionState.ToString()

    $curNTP = (Get-VMHostNtpServer -VMHost $cHost -ErrorAction SilentlyContinue) -join ','
    Compare-Setting 'Host' $bHost.Name 'NTPServers' $bHost.NTPServers $curNTP

    if ($IncludeHostDetails -and $bHost.Services) {
        $curServices = Get-VMHostService -VMHost $cHost -ErrorAction SilentlyContinue
        foreach ($bSvc in $bHost.Services) {
            $cSvc = $curServices | Where-Object { $_.Key -eq $bSvc.Key }
            if ($cSvc) {
                Compare-Setting 'Service' "$($bHost.Name)/$($bSvc.Key)" 'Running' $bSvc.Running  $cSvc.Running
                Compare-Setting 'Service' "$($bHost.Name)/$($bSvc.Key)" 'Policy'  $bSvc.Policy   $cSvc.Policy
            }
        }
    }
}

# Check for newly added hosts
foreach ($cHost in $currentHosts) {
    $bHost = $baselineHosts | Where-Object { $_.Name -eq $cHost.Name }
    if (-not $bHost) {
        $results.Add([PSCustomObject]@{
            Category='Host'; Item=$cHost.Name; Setting='Existence'; BaselineValue='Absent'; CurrentValue='Added'; Drifted=$true
        })
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$driftedCount = ($results | Where-Object { $_.Drifted -eq $true }).Count
$totalChecks  = $results.Count

Write-Host "`n=== Configuration Drift Summary ===" -ForegroundColor Cyan
Write-Host "  Total Checks   : $totalChecks"    -ForegroundColor White
Write-Host "  Drifted Items  : $driftedCount"   -ForegroundColor $(if ($driftedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Clean Items    : $($totalChecks - $driftedCount)" -ForegroundColor Green
Write-Host "  Output         : $OutputFile"     -ForegroundColor White

if ($driftedCount -gt 0) {
    Write-Host "`nDrifted Settings:" -ForegroundColor Yellow
    $results | Where-Object { $_.Drifted } | Format-Table Category, Item, Setting, BaselineValue, CurrentValue -AutoSize
}
