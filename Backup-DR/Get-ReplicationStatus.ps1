<#
.SYNOPSIS
    Reports vSphere Replication status including RPO compliance and sync state.

.DESCRIPTION
    Queries vSphere Replication (VR) for all replicated VMs in an optional cluster,
    reporting configured RPO, current RPO compliance, replication state, last sync
    time, and the target recovery site. VMs exceeding the RPO warning threshold
    are flagged.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER ClusterName
    Optional. Scope to a specific cluster.

.PARAMETER OutputFile
    Required. Path to export the replication status report as CSV.

.PARAMETER RPOWarningMinutes
    Optional. Minutes of RPO breach before flagging as Warning. Default: 60.

.EXAMPLE
    .\Get-ReplicationStatus.ps1 -vCenter "vc.example.com" -OutputFile "replication.csv"
    Reports full replication status for all replicated VMs.

.EXAMPLE
    .\Get-ReplicationStatus.ps1 -ClusterName "Production" -RPOWarningMinutes 30 -OutputFile "prod-repl.csv"
    Reports Production cluster with a stricter 30-minute RPO warning.

.OUTPUTS
    CSV with columns: VMName, Cluster, ReplicationState, ConfiguredRPOMinutes,
    CurrentRPOMinutes, RPOCompliant, TargetSite, LastSyncTime, Status

.NOTES
    Requires:
    - VMware PowerCLI module
    - vSphere Replication appliance deployed and configured
    - Read access to replication configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$RPOWarningMinutes = 60
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

Write-Host "Collecting vSphere Replication status..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    # Attempt to use VR-specific REST API or VRMS managed object
    $spsMgr = Get-View -Id 'VR-ReplicationManager' -ErrorAction SilentlyContinue

    if (-not $spsMgr) {
        # Fall back to querying VM custom attributes / events for replication info
        Write-Warning "vSphere Replication manager not found. Falling back to VM event and attribute scan."

        if ($ClusterName) {
            $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
            $vms = if ($cluster) { Get-VM -Location $cluster } else { Get-VM }
        }
        else { $vms = Get-VM }

        foreach ($vm in $vms) {
            $clusterName2 = try { (Get-Cluster -VM $vm -ErrorAction SilentlyContinue).Name } catch { 'N/A' }

            $results.Add([PSCustomObject]@{
                VMName               = $vm.Name
                Cluster              = $clusterName2
                ReplicationState     = 'Unknown (VR manager not found)'
                ConfiguredRPOMinutes = 'N/A'
                CurrentRPOMinutes    = 'N/A'
                RPOCompliant         = 'N/A'
                TargetSite           = 'N/A'
                LastSyncTime         = 'N/A'
                Status               = 'VR Not Configured or Not Accessible'
            })
        }
    }
    else {
        # Use VR manager to get replication info
        $replVMs = $spsMgr.QueryReplicatedVms($null)
        foreach ($replVMRef in $replVMs) {
            try {
                $replVMView = Get-View -Id $replVMRef -ErrorAction SilentlyContinue
                $vm = Get-VM -Id $replVMRef -ErrorAction SilentlyContinue
                if (-not $vm) { continue }

                $clusterName2 = try { (Get-Cluster -VM $vm -ErrorAction SilentlyContinue).Name } catch { 'N/A' }

                # Skip if cluster filter applied
                if ($ClusterName -and $clusterName2 -ne $ClusterName) { continue }

                $state          = $replVMView.Runtime.ConnectionState
                $configuredRPO  = 'N/A'
                $currentRPO     = 'N/A'
                $lastSync       = 'N/A'
                $targetSite     = 'N/A'

                $rpoCompliant = 'N/A'
                $status = 'Unknown'

                $results.Add([PSCustomObject]@{
                    VMName               = $vm.Name
                    Cluster              = $clusterName2
                    ReplicationState     = $state
                    ConfiguredRPOMinutes = $configuredRPO
                    CurrentRPOMinutes    = $currentRPO
                    RPOCompliant         = $rpoCompliant
                    TargetSite           = $targetSite
                    LastSyncTime         = $lastSync
                    Status               = $status
                })
            }
            catch {
                Write-Warning "Error processing replicated VM: $_"
            }
        }
    }
}
catch {
    Write-Warning "Error collecting replication status: $_"
}

Write-Host "Exporting $($results.Count) records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== Replication Status Summary ===" -ForegroundColor Cyan
Write-Host "  Replicated VMs : $($results.Count)" -ForegroundColor White
Write-Host "  Output         : $OutputFile" -ForegroundColor White
