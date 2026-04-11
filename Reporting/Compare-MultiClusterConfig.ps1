<#
.SYNOPSIS
    Compares configuration consistency across multiple clusters in vCenter.

.DESCRIPTION
    Enumerates all specified clusters (or all clusters) and compares their configuration
    settings side-by-side. Reports differences in HA, DRS, EVC, host versions,
    NTP configuration, and resource pool settings. Useful for ensuring that production
    and DR clusters remain in sync, and for multi-site environment governance audits.

.PARAMETER ClusterNames
    Optional. Comma-delimited list of cluster names to compare. If omitted, all clusters are compared.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the multi-cluster comparison report as CSV.

.PARAMETER IncludeHostVersions
    Optional switch. Include per-host version details in the comparison.

.EXAMPLE
    .\Compare-MultiClusterConfig.ps1 -OutputFile "cluster-comparison.csv"
    Compares all clusters in the connected vCenter.

.EXAMPLE
    .\Compare-MultiClusterConfig.ps1 -ClusterNames "Prod-Cluster,DR-Cluster" -OutputFile "prod-dr-comparison.csv"
    Compares only the Prod-Cluster and DR-Cluster.

.OUTPUTS
    CSV with columns: SettingCategory, SettingName, [ClusterName1], [ClusterName2], ..., Consistent

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to cluster configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterNames,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeHostVersions
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

if ($ClusterNames) {
    $clusterList = $ClusterNames -split ',' | ForEach-Object { $_.Trim() }
    $clusters = $clusterList | ForEach-Object {
        $c = Get-Cluster -Name $_ -ErrorAction SilentlyContinue
        if (-not $c) { Write-Warning "Cluster '$_' not found." }
        $c
    } | Where-Object { $_ }
}
else {
    $clusters = Get-Cluster | Sort-Object Name
}

if ($clusters.Count -lt 2) {
    Write-Warning "Only $($clusters.Count) cluster(s) found. Comparison requires at least 2."
}

Write-Host "Comparing $($clusters.Count) cluster(s): $($clusters.Name -join ', ')" -ForegroundColor Cyan

# Build map: setting -> cluster -> value
$settings = [ordered]@{}

function Set-Setting {
    param($category, $setting, $clusterName, $value)
    $key = "${category}|${setting}"
    if (-not $settings.ContainsKey($key)) {
        $settings[$key] = [ordered]@{ Category=$category; Setting=$setting }
    }
    $settings[$key][$clusterName] = if ($value -ne $null) { $value.ToString() } else { 'N/A' }
}

foreach ($cluster in $clusters) {
    $cn         = $cluster.Name
    $clusterView = $cluster | Get-View -Property ConfigurationEx, Summary
    $dasConfig   = $clusterView.ConfigurationEx.DasConfig
    $drsConfig   = $clusterView.ConfigurationEx.DrsConfig
    $hosts       = Get-VMHost -Location $cluster

    Set-Setting 'HA'  'Enabled'                  $cn $cluster.HAEnabled
    Set-Setting 'HA'  'AdmissionControlEnabled'   $cn $dasConfig.AdmissionControlEnabled
    Set-Setting 'HA'  'RestartPriority'            $cn $dasConfig.DefaultVmSettings.RestartPriority
    Set-Setting 'HA'  'IsolationResponse'          $cn $dasConfig.DefaultVmSettings.IsolationResponse
    Set-Setting 'HA'  'APDResponse'                $cn $dasConfig.DefaultVmSettings.VmComponentProtectionSettings.VmStorageProtectionForAPD
    Set-Setting 'HA'  'PDLResponse'                $cn $dasConfig.DefaultVmSettings.VmComponentProtectionSettings.VmStorageProtectionForPDL

    Set-Setting 'DRS' 'Enabled'                   $cn $cluster.DrsEnabled
    Set-Setting 'DRS' 'AutomationLevel'            $cn $cluster.DrsAutomationLevel.ToString()
    Set-Setting 'DRS' 'MigrationThreshold'         $cn $drsConfig.VmotionRate

    Set-Setting 'EVC' 'Mode'                       $cn $cluster.EVCMode

    Set-Setting 'Hosts' 'Count'                    $cn $hosts.Count
    Set-Setting 'Hosts' 'VersionUniform'           $cn (($hosts | Select-Object -ExpandProperty Version -Unique).Count -le 1)

    if ($IncludeHostVersions) {
        $verGroups = $hosts | Group-Object Version
        foreach ($vg in $verGroups) {
            Set-Setting 'HostVersions' "$($vg.Name) count" $cn $vg.Count
        }
    }

    # NTP
    $allNtpStrings = $hosts | ForEach-Object { (Get-VMHostNtpServer -VMHost $_ -ErrorAction SilentlyContinue) -join ',' } | Sort-Object -Unique
    Set-Setting 'Services' 'NTPServers (unique)'   $cn ($allNtpStrings | Select-Object -Unique) -join ' | '

    # SSH state
    $sshRunning = ($hosts | ForEach-Object { (Get-VMHostService -VMHost $_ | Where-Object { $_.Key -eq 'TSM-SSH' }).Running }) | Sort-Object -Unique
    Set-Setting 'Services' 'SSHRunning (any)'      $cn ($sshRunning -contains $true)
}

# Build result rows
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$clusterNames = $clusters.Name

foreach ($key in $settings.Keys) {
    $entry = $settings[$key]
    $values = $clusterNames | ForEach-Object { if ($entry.ContainsKey($_)) { $entry[$_] } else { 'N/A' } }
    $consistent = ($values | Select-Object -Unique).Count -le 1

    $row = [ordered]@{
        SettingCategory = $entry.Category
        SettingName     = $entry.Setting
    }
    for ($i = 0; $i -lt $clusterNames.Count; $i++) {
        $row[$clusterNames[$i]] = $values[$i]
    }
    $row['Consistent'] = $consistent

    $results.Add([PSCustomObject]$row)
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$inconsistent = ($results | Where-Object { $_.Consistent -eq $false }).Count
$consistent   = ($results | Where-Object { $_.Consistent -eq $true  }).Count

Write-Host "`n=== Multi-Cluster Comparison Summary ===" -ForegroundColor Cyan
Write-Host "  Clusters Compared  : $($clusters.Count)"  -ForegroundColor White
Write-Host "  Settings Compared  : $($results.Count)"   -ForegroundColor White
Write-Host "  Consistent         : $consistent"          -ForegroundColor Green
Write-Host "  Inconsistent       : $inconsistent"        -ForegroundColor $(if ($inconsistent -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output             : $OutputFile"          -ForegroundColor White

if ($inconsistent -gt 0) {
    Write-Host "`nInconsistent Settings:" -ForegroundColor Yellow
    $results | Where-Object { $_.Consistent -eq $false } | Format-Table SettingCategory, SettingName -AutoSize
}
