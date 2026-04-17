# VM Network Adapter Quick Reference

A collection of useful PowerCLI commands for inspecting and managing VM network adapters.

---

## Basic Adapter Info

Get all network adapters for a specific VM:
```powershell
Get-VM -Name "YourVMName" | Get-NetworkAdapter | Select-Object Name, Type, NetworkName, MacAddress, Connected
```

Get network adapters for all VMs:
```powershell
Get-NetworkAdapter -VM * | Select-Object @{N='VM';E={$_.Parent.Name}}, Name, Type, NetworkName, MacAddress, Connected
```

---

## Filter by Network / Port Group

Find all VMs connected to a specific port group:
```powershell
Get-NetworkAdapter -VM * | Where-Object { $_.NetworkName -eq "YourPortGroupName" } |
    Select-Object @{N='VM';E={$_.Parent.Name}}, Name, NetworkName, MacAddress
```

---

## NIC Label, Port Key, and Network Name (VDS-aware)

Returns each NIC's label, VDS port key, and resolved portgroup name. Useful for VDS environments.  
See also: [Get-VMNicPortInfo.ps1](Get-VMNicPortInfo.ps1)

```powershell
(Get-VM "YourVMName" | Get-View -Property Config).Config.Hardware.Device |
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
```

---

## MAC Address Lookup

Find which VM owns a specific MAC address:
```powershell
Get-NetworkAdapter -VM * | Where-Object { $_.MacAddress -eq "00:50:56:xx:xx:xx" } |
    Select-Object @{N='VM';E={$_.Parent.Name}}, Name, NetworkName, MacAddress
```

---

## Export All VM NICs to CSV

```powershell
Get-NetworkAdapter -VM * |
    Select-Object @{N='VM';E={$_.Parent.Name}}, Name, Type, NetworkName, MacAddress, Connected |
    Export-Csv -Path ".\VM-NetworkAdapters.csv" -NoTypeInformation
```

---

## Connected vs Disconnected NICs

Find all VMs with a disconnected NIC:
```powershell
Get-NetworkAdapter -VM * | Where-Object { $_.Connected -eq $false } |
    Select-Object @{N='VM';E={$_.Parent.Name}}, Name, NetworkName, MacAddress
```

---

## Prerequisites

- VMware PowerCLI module installed
- Active vCenter connection (`Connect-VIServer`)
- Read access to VM configurations
