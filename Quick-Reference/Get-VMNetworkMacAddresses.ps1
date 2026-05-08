#Requires -Version 5.1
<#
.SYNOPSIS
    Returns MAC addresses for VM NICs connected to a specific vSphere network.

.DESCRIPTION
    Enumerates VM network adapters and returns the VM name, NIC name, network name,
    MAC address, and connection state for every adapter connected to the target
    vSphere network or portgroup.

.PARAMETER NetworkName
    The vSphere network or portgroup name to match. By default this supports
    wildcard matching, so "mc-internal" matches any adapter whose NetworkName
    contains that value.

.PARAMETER ExactMatch
    Match the network name exactly instead of using a wildcard contains match.

.PARAMETER VIServer
    Optional vCenter server to connect to if no active PowerCLI session exists.

.PARAMETER ExportCsv
    Optional path to export the results as CSV.

.EXAMPLE
    .\Get-VMNetworkMacAddresses.ps1 -NetworkName "IQT-CL-DT2"

.EXAMPLE
    .\Get-VMNetworkMacAddresses.ps1 -NetworkName "mc-internal" -ExactMatch -ExportCsv C:\Temp\mc-internal-macs.csv

.OUTPUTS
    PSCustomObject with columns: VMName, VMHost, PowerState, NIC, NetworkName,
    MacAddress, Type, Connected, StartConnected

.NOTES
    Requires:
    - VMware PowerCLI module
    - Active vCenter connection, or use -VIServer
#>

param(
    [Parameter(Mandatory)]
    [string]$NetworkName,

    [switch]$ExactMatch,

    [string]$VIServer,

    [string]$ExportCsv
)

if ((-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) -and -not $VIServer) {
    throw "No active vCenter connection found. Connect with Connect-VIServer first or pass -VIServer."
}

if ($VIServer) {
    $existingServer = @($global:DefaultVIServers | Where-Object {
        $_.Name -eq $VIServer -or $_.ServiceUri.Host -eq $VIServer
    } | Select-Object -First 1)

    if (-not $existingServer) {
        Connect-VIServer -Server $VIServer | Out-Null
    }
}

$allVMs = Get-VM -ErrorAction Stop

$vmById = @{}
foreach ($vm in $allVMs) {
    $vmById[$vm.Id] = $vm
}

$allAdapters = Get-NetworkAdapter -VM $allVMs -ErrorAction Stop

$results = foreach ($adapter in $allAdapters) {
    if ($ExactMatch) {
        $isMatch = $adapter.NetworkName -eq $NetworkName
    }
    else {
        $isMatch = $adapter.NetworkName -like "*$NetworkName*"
    }

    if (-not $isMatch) {
        continue
    }

    $vm = $vmById[$adapter.Parent.Id]
    if (-not $vm) {
        continue
    }

    [PSCustomObject]@{
        VMName         = $vm.Name
        VMHost         = $vm.VMHost.Name
        PowerState     = $vm.PowerState
        NIC            = $adapter.Name
        NetworkName    = $adapter.NetworkName
        MacAddress     = $adapter.MacAddress
        Type           = $adapter.Type
        Connected      = $adapter.ConnectionState.Connected
        StartConnected = $adapter.ConnectionState.StartConnected
    }
}

$results = $results | Sort-Object VMName, NIC

if ($ExportCsv) {
    $results | Export-Csv -Path $ExportCsv -NoTypeInformation
}

$results