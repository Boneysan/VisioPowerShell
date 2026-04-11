<#
.SYNOPSIS
    Exports a complete cluster and host configuration snapshot to JSON as a baseline.

.DESCRIPTION
    Captures a point-in-time configuration baseline of the target cluster including
    HA, DRS, EVC, admission control settings, host configurations, network profiles,
    and resource pool hierarchy. The output JSON file is intended for use with
    Test-ConfigurationDrift.ps1 to detect changes over time.

.PARAMETER ClusterName
    Required. The cluster to export configuration for.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to save the JSON baseline file.

.PARAMETER IncludeHostDetails
    Optional switch. Include per-host network, service, and advanced setting details.

.EXAMPLE
    .\Export-ClusterConfiguration.ps1 -ClusterName "Production" -OutputFile "prod-baseline.json"
    Exports the Production cluster configuration as a JSON baseline.

.EXAMPLE
    .\Export-ClusterConfiguration.ps1 -ClusterName "Production" -IncludeHostDetails -OutputFile "prod-detailed-baseline.json"
    Exports cluster and per-host configuration.

.OUTPUTS
    JSON file with cluster configuration baseline.

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

$cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

Write-Host "Exporting cluster configuration for '$ClusterName'..." -ForegroundColor Cyan

$clusterView = $cluster | Get-View -Property Name, ConfigurationEx, Summary

$dasConfig  = $clusterView.ConfigurationEx.DasConfig
$drsConfig  = $clusterView.ConfigurationEx.DrsConfig

$baseline = [ordered]@{
    ExportDate      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ExportedBy      = $env:USERNAME
    vCenter         = ($global:DefaultVIServer).Name
    ClusterName     = $ClusterName

    HA = [ordered]@{
        Enabled                = $cluster.HAEnabled
        AdmissionControlEnabled= $dasConfig.AdmissionControlEnabled
        AdmissionControlPolicy = $dasConfig.AdmissionControlPolicy.GetType().Name
        FailoverLevel          = if ($dasConfig.AdmissionControlPolicy.PSObject.Properties['FailoverLevel']) { $dasConfig.AdmissionControlPolicy.FailoverLevel } else { $null }
        HBDatastorePolicy      = $dasConfig.HBDatastoreCandidatePolicy
        RestartPriority        = $dasConfig.DefaultVmSettings.RestartPriority
        IsolationResponse      = $dasConfig.DefaultVmSettings.IsolationResponse
        APDResponse            = $dasConfig.DefaultVmSettings.VmComponentProtectionSettings.VmStorageProtectionForAPD
        PDLResponse            = $dasConfig.DefaultVmSettings.VmComponentProtectionSettings.VmStorageProtectionForPDL
    }

    DRS = [ordered]@{
        Enabled                = $cluster.DrsEnabled
        Automation             = $cluster.DrsAutomationLevel.ToString()
        MigrationThreshold     = $drsConfig.VmotionRate
        PredictiveDRS          = $drsConfig.Option | Where-Object { $_.Key -eq 'config.enablePredictiveDRS' } | Select-Object -ExpandProperty Value
    }

    EVC = [ordered]@{
        Enabled = ($cluster.EVCMode -ne $null -and $cluster.EVCMode -ne '')
        Mode    = $cluster.EVCMode
    }

    ResourcePools = @(
        Get-ResourcePool -Location $cluster | Select-Object Name, CpuSharesLevel, CpuReservationMHz, CpuLimitMHz, MemSharesLevel, MemReservationGB, MemLimitGB |
        ForEach-Object {
            [ordered]@{
                Name              = $_.Name
                CpuSharesLevel    = $_.CpuSharesLevel.ToString()
                CpuReservationMHz = $_.CpuReservationMHz
                CpuLimitMHz       = $_.CpuLimitMHz
                MemSharesLevel    = $_.MemSharesLevel.ToString()
                MemReservationGB  = [math]::Round($_.MemReservationGB, 1)
                MemLimitGB        = $_.MemLimitGB
            }
        }
    )

    Hosts = @(
        Get-VMHost -Location $cluster | Sort-Object Name | ForEach-Object {
            $h = $_
            $hView = $h | Get-View -Property Config, Summary

            $hostEntry = [ordered]@{
                Name          = $h.Name
                Version       = $h.Version
                Build         = $h.Build
                ConnectionState = $h.ConnectionState.ToString()
                State         = $h.State.ToString()
                NumCpuCores   = $h.NumCpu
                MemoryGB      = [math]::Round($h.MemoryTotalGB, 1)
                Model         = $h.Model
                NTPServers    = (Get-VMHostNtpServer -VMHost $h -ErrorAction SilentlyContinue) -join ','
                SyslogServer  = (Get-VMHostSysLogServer -VMHost $h -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { "$($_.Host):$($_.Port)" })
            }

            if ($IncludeHostDetails) {
                $hostEntry['Services'] = @(
                    Get-VMHostService -VMHost $h -ErrorAction SilentlyContinue |
                    Select-Object Key, Running, Policy |
                    ForEach-Object { [ordered]@{ Key=$_.Key; Running=$_.Running; Policy=$_.Policy } }
                )
                $hostEntry['AdvancedSettings'] = @(
                    Get-AdvancedSetting -Entity $h -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'Security|UserVars|Net\.Block|Syslog' } |
                    ForEach-Object { [ordered]@{ Name=$_.Name; Value=$_.Value.ToString() } }
                )
            }
            $hostEntry
        }
    )
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$baseline | ConvertTo-Json -Depth 15 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host "`n=== Export Complete ===" -ForegroundColor Green
Write-Host "  Cluster     : $ClusterName" -ForegroundColor White
Write-Host "  Hosts       : $($baseline.Hosts.Count)" -ForegroundColor White
Write-Host "  Res. Pools  : $($baseline.ResourcePools.Count)" -ForegroundColor White
Write-Host "  Output      : $OutputFile" -ForegroundColor White
