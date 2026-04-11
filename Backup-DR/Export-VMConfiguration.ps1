<#
.SYNOPSIS
    Exports full VM configuration to JSON files for DR documentation.

.DESCRIPTION
    Collects the complete configuration of every VM (equivalent to VMX settings)
    and exports each VM to an individual JSON file in the output folder. A master
    index CSV is also written. This enables VM rebuild from documentation if vCenter
    is lost, and serves as a configuration snapshot for change management.

.PARAMETER ClusterName
    Optional. Scope the export to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER VMName
    Optional. Export only the named VM.

.PARAMETER OutputFolder
    Required. Directory to write JSON files and the index CSV to.

.PARAMETER IncludeNetworkMapping
    Optional. Switch. Include resolved network adapter → port group → VLAN mapping.

.EXAMPLE
    .\Export-VMConfiguration.ps1 -ClusterName "Production" -OutputFolder "C:\DR\VMConfigs"
    Exports all Production VM configs to JSON.

.EXAMPLE
    .\Export-VMConfiguration.ps1 -VMName "CriticalDB" -OutputFolder "C:\DR" -IncludeNetworkMapping
    Exports a single VM with network details.

.OUTPUTS
    - OutputFolder\<VMName>.json : One JSON file per VM
    - OutputFolder\index.csv     : Master index of all exported VMs

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$VMName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFolder,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeNetworkMapping
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

# Ensure output folder exists
if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Host "Created output folder: $OutputFolder" -ForegroundColor Green
}

if ($VMName) {
    $vms = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vms) { Write-Error "VM '$VMName' not found."; exit 1 }
}
elseif ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster
}
else {
    $vms = Get-VM
}

Write-Host "Exporting configuration for $($vms.Count) VM(s) to: $OutputFolder" -ForegroundColor Cyan

$index   = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name)..." -ForegroundColor White

    try {
        $vmView = $vm | Get-View -Property Config, Summary, Runtime

        # Build network adapter objects
        $networkAdapters = $vmView.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] } | ForEach-Object {
            $pg = $_.Backing -as [VMware.Vim.VirtualEthernetCardNetworkBackingInfo]
            $dpg = $_.Backing -as [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]

            $netInfo = [ordered]@{
                Label          = $_.DeviceInfo.Label
                Type           = $_.GetType().Name
                MACAddress     = $_.MacAddress
                MacAddressType = $_.AddressType
                Connected      = $_.Connectable.Connected
                Network        = if ($pg) { $pg.DeviceName } elseif ($dpg) { $dpg.Port.PortgroupKey } else { 'Unknown' }
            }

            if ($IncludeNetworkMapping -and $dpg) {
                try {
                    $portgroup = Get-VDPortgroup -Id $dpg.Port.PortgroupKey -ErrorAction SilentlyContinue
                    if ($portgroup) { $netInfo['PortGroupName'] = $portgroup.Name }
                } catch {}
            }
            $netInfo
        }

        # Build disk objects
        $disks = $vmView.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualDisk] } | ForEach-Object {
            [ordered]@{
                Label       = $_.DeviceInfo.Label
                CapacityGB  = [math]::Round($_.CapacityInKB / 1MB, 2)
                Backing     = $_.Backing.GetType().Name
                FileName    = if ($_.Backing.FileName) { $_.Backing.FileName } else { 'N/A' }
                DiskMode    = if ($_.Backing.DiskMode) { $_.Backing.DiskMode } else { 'N/A' }
                ThinProvisioned = if ($_.Backing -is [VMware.Vim.VirtualDiskFlatVer2BackingInfo]) { $_.Backing.ThinProvisioned } else { 'N/A' }
            }
        }

        # Full config object
        $vmClusterName = try { (Get-Cluster -VM $vm -ErrorAction SilentlyContinue).Name } catch { 'N/A' }
        $vmHostMoRef   = try { $vmView.Runtime.Host.ToString() } catch { 'N/A' }
        $configObj = [ordered]@{
            ExportTimestamp    = $timestamp
            VMName             = $vm.Name
            UUID               = $vmView.Config.Uuid
            GuestOS            = $vmView.Config.GuestFullName
            GuestOSId          = $vmView.Config.GuestId
            HardwareVersion    = $vmView.Config.Version
            NumCPU             = $vmView.Config.Hardware.NumCPU
            NumCoresPerSocket  = $vmView.Config.Hardware.NumCoresPerSocket
            MemoryMB           = $vmView.Config.Hardware.MemoryMB
            PowerState         = $vmView.Runtime.PowerState
            Cluster            = $vmClusterName
            VMHost             = $vmHostMoRef
            Folder             = $vm.Folder.Name
            Annotation         = $vmView.Config.Annotation
            CBTEnabled         = $vmView.Config.ChangeTrackingEnabled
            VMXPath            = $vmView.Config.Files.VmPathName
            NetworkAdapters    = @($networkAdapters)
            Disks              = @($disks)
            ExtraConfig        = ($vmView.Config.ExtraConfig | ForEach-Object { [ordered]@{ Key = $_.Key; Value = $_.Value } })
        }

        # Safe filename
        $safeVMName = $vm.Name -replace '[\\/:*?"<>|]', '_'
        $jsonPath = Join-Path $OutputFolder "$safeVMName.json"
        $configObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8

        $index.Add([PSCustomObject]@{
            VMName      = $vm.Name
            JSONFile    = $jsonPath
            GuestOS     = $vmView.Config.GuestFullName
            NumCPU      = $vmView.Config.Hardware.NumCPU
            MemoryGB    = [math]::Round($vmView.Config.Hardware.MemoryMB / 1024, 1)
            DiskCount   = @($disks).Count
            PowerState  = $vmView.Runtime.PowerState
            Exported    = $timestamp
        })
    }
    catch {
        Write-Warning "Error exporting $($vm.Name): $_"
    }
}

$indexPath = Join-Path $OutputFolder 'index.csv'
$index | Export-Csv -Path $indexPath -NoTypeInformation

Write-Host "`n=== VM Configuration Export Summary ===" -ForegroundColor Cyan
Write-Host "  VMs exported   : $($index.Count)" -ForegroundColor White
Write-Host "  Output folder  : $OutputFolder" -ForegroundColor White
Write-Host "  Index CSV      : $indexPath" -ForegroundColor White
