<#
.SYNOPSIS
    Inventories all Raw Device Mappings (RDMs) in the environment.

.DESCRIPTION
    Iterates all VM hard disks to identify RDMs, reporting LUN IDs, compatibility
    mode (physical/virtual), sharing status, capacity, and associated VMs. Useful
    for storage audits, migration planning, and identifying shared-disk clusters.

.PARAMETER ClusterName
    Optional. Scope the scan to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the RDM inventory as CSV.

.EXAMPLE
    .\Get-RDMInventory.ps1 -ClusterName "Production" -OutputFile "rdm-inventory.csv"
    Inventories all RDMs in the Production cluster.

.EXAMPLE
    .\Get-RDMInventory.ps1 -vCenter "vc.example.com" -OutputFile "rdm-all.csv"
    Inventories all RDMs in the entire vCenter.

.OUTPUTS
    CSV with columns: VMName, DiskLabel, RDMType, LunID, DeviceDisplayName,
    CapacityGB, SharingMode, Datastore, ScsiCanonicalName

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM and datastore configurations

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
    $vms = Get-VM -Location $cluster
}
else {
    $vms = Get-VM
}

Write-Host "Scanning $($vms.Count) VM(s) for RDMs..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    try {
        $hardDisks = $vm | Get-HardDisk -DiskType RawPhysical, RawVirtual -ErrorAction SilentlyContinue
        if (-not $hardDisks) { continue }

        Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name) - $($hardDisks.Count) RDM(s) found" -ForegroundColor Yellow

        foreach ($disk in $hardDisks) {
            $backing = $disk.ExtensionData.Backing

            $dsNameVal = try { $disk.Filename -replace '^\[(.+?)\].*', '$1' } catch { 'N/A' }
            $results.Add([PSCustomObject]@{
                VMName             = $vm.Name
                DiskLabel          = $disk.Name
                RDMType            = $disk.DiskType
                LunID              = $backing.LunUuid
                DeviceDisplayName  = $backing.DeviceName
                CapacityGB         = [math]::Round($disk.CapacityGB, 2)
                SharingMode        = $backing.Sharing
                Datastore          = $dsNameVal
                ScsiCanonicalName  = $backing.BackingObjectId
            })
        }
    }
    catch {
        Write-Warning "Error scanning $($vm.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) RDM records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== RDM Inventory Summary ===" -ForegroundColor Cyan
Write-Host "  VMs scanned   : $($vms.Count)" -ForegroundColor White
Write-Host "  RDMs found    : $($results.Count)" -ForegroundColor White
$prdmCount = ($results | Where-Object { $_.RDMType -eq 'RawPhysical' }).Count
$vrdmCount = ($results | Where-Object { $_.RDMType -eq 'RawVirtual' }).Count
Write-Host "  Physical RDMs : $prdmCount" -ForegroundColor White
Write-Host "  Virtual RDMs  : $vrdmCount" -ForegroundColor White
Write-Host "  Output        : $OutputFile" -ForegroundColor White
