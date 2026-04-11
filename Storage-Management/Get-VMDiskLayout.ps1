<#
.SYNOPSIS
    Reports detailed per-VM disk layout for all virtual disks.

.DESCRIPTION
    Collects comprehensive disk configuration for every VM virtual disk including
    VMDK path, provisioning type, controller type, bus/unit numbers, persistence
    mode, and assigned storage policy. Useful for storage audits, migration planning,
    and compliance validation.

.PARAMETER ClusterName
    Optional. Scope the report to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER VMName
    Optional. Limit report to a single VM.

.PARAMETER OutputFile
    Required. Path to export the disk layout report as CSV.

.EXAMPLE
    .\Get-VMDiskLayout.ps1 -ClusterName "Production" -OutputFile "disk-layout.csv"
    Reports disk layout for all VMs in Production cluster.

.EXAMPLE
    .\Get-VMDiskLayout.ps1 -VMName "DatabaseServer" -OutputFile "db-disks.csv"
    Reports disk layout for a single VM.

.OUTPUTS
    CSV with columns: VMName, DiskLabel, VMDKPath, CapacityGB, Provisioning,
    ControllerType, BusNumber, UnitNumber, PersistenceMode, StoragePolicy

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM and storage configurations

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

Write-Host "Collecting disk layout for $($vms.Count) VM(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name)..." -ForegroundColor White

    try {
        $vmView  = $vm | Get-View -Property Config.Hardware
        $devices = $vmView.Config.Hardware.Device

        # Build controller lookup: key -> type+bus
        $controllers = @{}
        foreach ($dev in $devices) {
            if ($dev -is [VMware.Vim.VirtualController]) {
                $busNum = if ($dev.PSObject.Properties['BusNumber']) { $dev.BusNumber } else { 0 }
                $controllers[$dev.Key] = [PSCustomObject]@{
                    Type   = $dev.GetType().Name -replace 'Virtual', ''
                    BusNum = $busNum
                }
            }
        }

        # Storage policies
        $spbmMap = @{}
        try {
            $spbmEntities = Get-SpbmEntityConfiguration -VM $vm -ErrorAction SilentlyContinue
            foreach ($e in $spbmEntities) {
                if ($e.Entity -and $e.StoragePolicy) {
                    $key = try { $e.Entity.ExtensionData.Key } catch { $null }
                    if ($key) { $spbmMap[$key] = $e.StoragePolicy.Name }
                }
            }
        } catch {}

        foreach ($disk in ($vm | Get-HardDisk -ErrorAction SilentlyContinue)) {
            $diskDev    = $devices | Where-Object { $_ -is [VMware.Vim.VirtualDisk] -and $_.Key -eq $disk.ExtensionData.Key } | Select-Object -First 1
            $ctrlInfo   = if ($diskDev -and $controllers[$diskDev.ControllerKey]) { $controllers[$diskDev.ControllerKey] } else { $null }
            $policy     = if ($diskDev -and $spbmMap[$diskDev.Key]) { $spbmMap[$diskDev.Key] } else { '(none)' }
            $diskMode   = if ($disk.ExtensionData.Backing.DiskMode) { $disk.ExtensionData.Backing.DiskMode } else { 'N/A' }

            $results.Add([PSCustomObject]@{
                VMName          = $vm.Name
                DiskLabel       = $disk.Name
                VMDKPath        = $disk.Filename
                CapacityGB      = [math]::Round($disk.CapacityGB, 2)
                Provisioning    = $disk.StorageFormat
                ControllerType  = if ($ctrlInfo) { $ctrlInfo.Type } else { 'Unknown' }
                BusNumber       = if ($ctrlInfo) { $ctrlInfo.BusNum } else { 'N/A' }
                UnitNumber      = if ($diskDev) { $diskDev.UnitNumber } else { 'N/A' }
                PersistenceMode = $diskMode
                StoragePolicy   = $policy
            })
        }
    }
    catch {
        Write-Warning "Error collecting disk layout for $($vm.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) disk records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$totalCapGB = [math]::Round(($results | Measure-Object -Property CapacityGB -Sum).Sum, 2)

Write-Host "`n=== VM Disk Layout Summary ===" -ForegroundColor Cyan
Write-Host "  VMs processed   : $($vms.Count)" -ForegroundColor White
Write-Host "  Total disks     : $($results.Count)" -ForegroundColor White
Write-Host "  Total capacity  : $totalCapGB GB" -ForegroundColor White
Write-Host "  Output          : $OutputFile" -ForegroundColor White
