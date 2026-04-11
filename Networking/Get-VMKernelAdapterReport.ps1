<#
.SYNOPSIS
    Reports all VMkernel adapters per host with IP, services, MTU, and TCP/IP stack.

.DESCRIPTION
    Enumerates every VMkernel adapter (vmk) on every ESXi host in a cluster, reporting
    IP address, subnet mask, default gateway, enabled services (management, vMotion, vSAN,
    FT, provisioning, replication), MTU, TCP/IP stack, and VLAN ID.

.PARAMETER ClusterName
    Optional. Scope the report to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the VMkernel adapter report as CSV.

.EXAMPLE
    .\Get-VMKernelAdapterReport.ps1 -ClusterName "Production" -OutputFile "vmk-report.csv"
    Reports all VMkernel adapters for hosts in the Production cluster.

.OUTPUTS
    CSV with columns: HostName, AdapterName, IPAddress, SubnetMask, DefaultGateway,
    MTU, VLAN, TCPIPStack, ManagementEnabled, vMotionEnabled, vSANEnabled,
    FTEnabled, ProvisioningEnabled, ReplicationEnabled

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi network configuration

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
    $vmHosts = Get-VMHost -Location $cluster
}
else {
    $vmHosts = Get-VMHost
}

Write-Host "Collecting VMkernel adapters for $($vmHosts.Count) host(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$hostCount = 0

foreach ($vmHost in $vmHosts) {
    $hostCount++
    Write-Host "  [$hostCount/$($vmHosts.Count)] $($vmHost.Name)..." -ForegroundColor White

    try {
        $vmks = Get-VMHostNetworkAdapter -VMHost $vmHost -VMKernel -ErrorAction SilentlyContinue
        $hostNetConfig = ($vmHost | Get-View).Config.Network

        foreach ($vmk in $vmks) {
            # Get VLAN and TCP/IP stack from host network config
            $vlanId   = 'N/A'
            $tcpStack = 'N/A'
            try {
                $vnicSpec = $hostNetConfig.Vnic | Where-Object { $_.Device -eq $vmk.Name } | Select-Object -First 1
                if ($vnicSpec) {
                    $tcpStack  = if ($vnicSpec.Spec.NetStackInstanceKey) { $vnicSpec.Spec.NetStackInstanceKey } else { 'defaultTcpipStack' }
                    # VLAN from the port group
                    $pg = $hostNetConfig.Portgroup | Where-Object { $_.Spec.Name -eq $vnicSpec.Portgroup }
                    if ($pg) { $vlanId = $pg.Spec.VlanId }
                }
            } catch {}

            $defaultGW = try { $hostNetConfig.IpRouteConfig.DefaultGateway } catch { 'N/A' }
            $results.Add([PSCustomObject]@{
                HostName            = $vmHost.Name
                AdapterName         = $vmk.Name
                IPAddress           = $vmk.IP
                SubnetMask          = $vmk.SubnetMask
                DefaultGateway      = $defaultGW
                MTU                 = $vmk.Mtu
                VLAN                = $vlanId
                TCPIPStack          = $tcpStack
                ManagementEnabled   = $vmk.ManagementTrafficEnabled
                vMotionEnabled      = $vmk.VMotionEnabled
                vSANEnabled         = $vmk.VsanTrafficEnabled
                FTEnabled           = $vmk.FaultToleranceLoggingEnabled
                ProvisioningEnabled = $vmk.ProvisioningEnabled
                ReplicationEnabled  = $vmk.VsphereReplicationEnabled
            })
        }
    }
    catch {
        Write-Warning "Error collecting VMkernel adapters for $($vmHost.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) VMkernel adapter records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== VMkernel Adapter Summary ===" -ForegroundColor Cyan
Write-Host "  Hosts      : $($vmHosts.Count)" -ForegroundColor White
Write-Host "  Adapters   : $($results.Count)" -ForegroundColor White
Write-Host "  Output     : $OutputFile" -ForegroundColor White
