<#
.SYNOPSIS
    Returns NIC label, VDS port key, and network name for all NICs on a VM.

.DESCRIPTION
    Queries a single VM's hardware configuration via Get-View and returns each
    virtual NIC's label, assigned VDS port key, and resolved portgroup or
    standard switch network name. Useful for quick verification and troubleshooting
    of VM network assignments.

.PARAMETER VMName
    The name of the VM to query.

.EXAMPLE
    .\Get-VMNicPortInfo.ps1 -VMName "FWALL-CLDT2-IQT-Alpha"
    Returns NIC, PortKey, and Network for each NIC on the specified VM.

.OUTPUTS
    PSCustomObject with columns: NIC, PortKey, Network

.NOTES
    Requires:
    - VMware PowerCLI module
    - Active vCenter connection
    - Read access to VM configuration
#>

param(
    [Parameter(Mandatory)]
    [string]$VMName
)

(Get-VM $VMName | Get-View -Property Config).Config.Hardware.Device |
    Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] } |
    Select-Object @{N='NIC';E={$_.DeviceInfo.Label}},
                  @{N='PortKey';E={
                      $dpg = $_.Backing -as [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]
                      if ($dpg) { $dpg.Port.PortKey } else { 'N/A' }
                  }},
                  @{N='Network';E={
                      $dpg = $_.Backing -as [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]
                      $pg  = $_.Backing -as [VMware.Vim.VirtualEthernetCardNetworkBackingInfo]
                      if ($dpg) { (Get-VDPortgroup -Id $dpg.Port.PortgroupKey -ErrorAction SilentlyContinue).Name }
                      elseif ($pg) { $pg.DeviceName }
                      else { 'Unknown' }
                  }}
