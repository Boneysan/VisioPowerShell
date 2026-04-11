<#
.SYNOPSIS
    Comprehensive cluster configuration report covering HA, DRS, EVC, and admission control.

.DESCRIPTION
    Dumps every cluster-level configuration parameter for one or all clusters:
    HA settings (restart priority, isolation response, heartbeat datastores, proactive HA),
    DRS settings (automation level, migration threshold, predictive DRS), EVC mode,
    admission control policy, and vSAN enablement.

.PARAMETER ClusterName
    Optional. Specific cluster to report on. If not specified, reports all clusters.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the cluster configuration report as CSV.

.EXAMPLE
    .\Get-ClusterConfigurationReport.ps1 -ClusterName "Production" -OutputFile "cluster-config.csv"
    Reports configuration for the Production cluster.

.EXAMPLE
    .\Get-ClusterConfigurationReport.ps1 -vCenter "vc.example.com" -OutputFile "all-clusters.csv"
    Reports all cluster configurations.

.OUTPUTS
    CSV with one row per configuration parameter per cluster.

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
    $clusters = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $clusters) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
}
else {
    $clusters = Get-Cluster
}

Write-Host "Collecting configuration for $($clusters.Count) cluster(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($cluster in $clusters) {
    Write-Host "  Processing: $($cluster.Name)..." -ForegroundColor White

    try {
        $clusterView = $cluster | Get-View -Property Configuration, ConfigurationEx

        $cfgEx = $clusterView.ConfigurationEx

        # Helper to add a config row
        function Add-Config {
            param($Category, $Parameter, $Value)
            $results.Add([PSCustomObject]@{
                ClusterName = $cluster.Name
                Category    = $Category
                Parameter   = $Parameter
                Value       = $Value
            })
        }

        # General
        Add-Config 'General' 'TotalHosts'      (Get-VMHost -Location $cluster).Count
        Add-Config 'General' 'TotalVMs'        (Get-VM -Location $cluster).Count
        Add-Config 'General' 'EVCMode'         $cluster.EVCMode
        Add-Config 'General' 'vSANEnabled'     $cluster.VsanEnabled

        # HA
        Add-Config 'HA' 'HAEnabled'                $cluster.HAEnabled
        Add-Config 'HA' 'AdmissionControlEnabled'  $cluster.HAAdmissionControlEnabled
        Add-Config 'HA' 'AdmissionControlPolicy'   (if ($cfgEx.DasConfig.AdmissionControlPolicy) { $cfgEx.DasConfig.AdmissionControlPolicy.GetType().Name } else { 'N/A' })
        Add-Config 'HA' 'HostMonitoring'           $cfgEx.DasConfig.HostMonitoring
        Add-Config 'HA' 'VMMonitoring'             $cfgEx.DasConfig.VmMonitoring
        Add-Config 'HA' 'DefaultVMRestartPriority' $cfgEx.DasConfig.DefaultVmSettings.RestartPriority
        Add-Config 'HA' 'IsolationResponse'        $cfgEx.DasConfig.DefaultVmSettings.IsolationResponse
        Add-Config 'HA' 'HeartbeatDatastorePolicy' $cfgEx.DasConfig.HBDatastoreCandidatePolicy
        Add-Config 'HA' 'HeartbeatDatastoreCount'  $cfgEx.DasConfig.HeartbeatDatastore.Count
        Add-Config 'HA' 'ProactiveHAEnabled'       (if ($cfgEx.ProactiveDrsConfig) { $cfgEx.ProactiveDrsConfig.Enabled } else { $false })

        # DRS
        Add-Config 'DRS' 'DRSEnabled'              $cluster.DrsEnabled
        Add-Config 'DRS' 'DRSAutomationLevel'      $cluster.DrsAutomationLevel
        Add-Config 'DRS' 'MigrationThreshold'      $cfgEx.DrsConfig.VmotionRate
        Add-Config 'DRS' 'PredictiveDRS'           ($cfgEx.DrsConfig.Option | Where-Object { $_.Key -eq 'ExpectedMigrationCount' } | Select-Object -ExpandProperty Value)
        Add-Config 'DRS' 'ScaleDescendantsShares'  ($cfgEx.DrsConfig.Option | Where-Object { $_.Key -eq 'ScaleDescendantsShares' } | Select-Object -ExpandProperty Value)

        # Admission Control (percentage based)
        $acPolicy = $cfgEx.DasConfig.AdmissionControlPolicy
        if ($acPolicy -is [VMware.Vim.ClusterFailoverResourcesAdmissionControlPolicy]) {
            Add-Config 'AdmissionControl' 'CPUFailoverResourcePercent'    $acPolicy.CpuFailoverResourcesPercent
            Add-Config 'AdmissionControl' 'MemoryFailoverResourcePercent' $acPolicy.MemoryFailoverResourcesPercent
            Add-Config 'AdmissionControl' 'FailoverLevel'                 $acPolicy.FailoverLevel
        }
        elseif ($acPolicy -is [VMware.Vim.ClusterFailoverLevelAdmissionControlPolicy]) {
            Add-Config 'AdmissionControl' 'FailoverLevel'                 $acPolicy.FailoverLevel
        }
    }
    catch {
        Write-Warning "Error processing cluster $($cluster.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) configuration parameters to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== Cluster Configuration Summary ===" -ForegroundColor Cyan
Write-Host "  Clusters     : $($clusters.Count)" -ForegroundColor White
Write-Host "  Config rows  : $($results.Count)" -ForegroundColor White
Write-Host "  Output       : $OutputFile" -ForegroundColor White
