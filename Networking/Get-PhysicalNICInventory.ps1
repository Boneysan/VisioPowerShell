<#
.SYNOPSIS
    Inventories physical NICs (vmnics) per ESXi host.

.DESCRIPTION
    Collects detailed physical NIC information for all hosts in a cluster including
    driver name, driver version, firmware version, link speed, duplex, MAC address,
    link state, and which virtual switch each NIC is associated with.

.PARAMETER ClusterName
    Optional. Scope the report to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the physical NIC inventory as CSV.

.EXAMPLE
    .\Get-PhysicalNICInventory.ps1 -ClusterName "Production" -OutputFile "pnic-inventory.csv"
    Reports physical NIC details for all hosts in Production cluster.

.OUTPUTS
    CSV with columns: HostName, NICName, Driver, DriverVersion, FirmwareVersion,
    LinkSpeedMbps, Duplex, MACAddress, LinkState, AssociatedvSwitch, AssociatedVDS

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi host hardware configuration

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

Write-Host "Inventorying physical NICs for $($vmHosts.Count) host(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$hostCount = 0

foreach ($vmHost in $vmHosts) {
    $hostCount++
    Write-Host "  [$hostCount/$($vmHosts.Count)] $($vmHost.Name)..." -ForegroundColor White

    try {
        $esxcli    = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction SilentlyContinue
        $hostView  = $vmHost | Get-View -Property Config.Network.Pnic, Config.Network.Vswitch, Config.Network.ProxySwitch
        $pnics     = $hostView.Config.Network.Pnic

        # Build vmnic -> vswitch mapping
        $vswitchMap = @{}
        foreach ($vs in $hostView.Config.Network.Vswitch) {
            foreach ($nic in $vs.Pnic) {
                $vswitchMap[$nic] = "vSS:$($vs.Name)"
            }
        }
        foreach ($ps in $hostView.Config.Network.ProxySwitch) {
            foreach ($nic in $ps.Pnic) {
                $vswitchMap[$nic] = "VDS:$($ps.DvsName)"
            }
        }

        foreach ($pnic in $pnics) {
            $nicName   = $pnic.Device
            $driver    = $pnic.Driver
            $mac       = $pnic.Mac
            $linkUp    = $null -ne $pnic.LinkSpeed
            $speedMbps = if ($pnic.LinkSpeed) { $pnic.LinkSpeed.SpeedMb } else { 0 }
            $duplex    = if ($pnic.LinkSpeed) { if ($pnic.LinkSpeed.Duplex) { 'Full' } else { 'Half' } } else { 'N/A' }

            # Driver/firmware via esxcli
            $driverVersion  = 'N/A'
            $firmwareVersion = 'N/A'
            if ($esxcli) {
                try {
                    $nicInfo = $esxcli.network.nic.get.Invoke(@{ nicname = $nicName })
                    $driverVersion   = $nicInfo.DriverInfo.Version
                    $firmwareVersion = $nicInfo.DriverInfo.FirmwareVersion
                } catch {}
            }

            $assocSwitch = if ($vswitchMap["key-vim.host.PhysicalNic-$nicName"]) {
                $vswitchMap["key-vim.host.PhysicalNic-$nicName"]
            } else { 'Unassigned' }

            $results.Add([PSCustomObject]@{
                HostName        = $vmHost.Name
                NICName         = $nicName
                Driver          = $driver
                DriverVersion   = $driverVersion
                FirmwareVersion = $firmwareVersion
                LinkSpeedMbps   = $speedMbps
                Duplex          = $duplex
                MACAddress      = $mac
                LinkState       = if ($linkUp) { 'Up' } else { 'Down' }
                AssociatedSwitch= $assocSwitch
            })
        }
    }
    catch {
        Write-Warning "Error collecting NICs for $($vmHost.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) NIC records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$downNICs = ($results | Where-Object { $_.LinkState -eq 'Down' }).Count
Write-Host "`n=== Physical NIC Inventory Summary ===" -ForegroundColor Cyan
Write-Host "  Hosts    : $($vmHosts.Count)" -ForegroundColor White
Write-Host "  NICs     : $($results.Count)" -ForegroundColor White
Write-Host "  Down NICs: $downNICs" -ForegroundColor $(if ($downNICs -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output   : $OutputFile" -ForegroundColor White
