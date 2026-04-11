<#
.SYNOPSIS
    Creates a named snapshot across all VMs in a vSphere folder.

.DESCRIPTION
    Enumerates all VMs in the specified folder (and optionally subfolders) and creates
    a consistent, named snapshot on each. Designed for capturing a known-good state of
    an entire cyber range environment before an exercise begins. Optionally skips VMs
    that already have a snapshot with the given name. Supports DryRun mode.

.PARAMETER Folder
    Required. The vSphere folder path containing the target VMs (e.g. "CyberRange\Exercise01").

.PARAMETER SnapshotName
    Required. The name to give the snapshot on each VM.

.PARAMETER Description
    Optional. A description to attach to each snapshot.

.PARAMETER IncludeMemory
    Optional switch. Capture the VM's memory state in the snapshot (quiesced, running state).
    Not supported for powered-off VMs; will be automatically skipped for those.

.PARAMETER Quiesce
    Optional switch. Quiesce the guest file system before snapshotting (requires VMware Tools).
    Incompatible with -IncludeMemory. Will be ignored if -IncludeMemory is set.

.PARAMETER OverwriteExisting
    Optional switch. If a snapshot with the same name already exists on a VM, remove it
    before creating the new one.

.PARAMETER IncludeSubfolders
    Optional switch. Also snapshot VMs in subfolders of the target folder.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -DryRun
    Preview which VMs would be snapshotted without making changes.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Pre-Exercise" -Description "Baseline before red team exercise" -Quiesce -OutputFile "snapshot-log.csv"
    Create a quiesced "Pre-Exercise" snapshot on all VMs in Exercise01.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -OverwriteExisting -IncludeSubfolders
    Refresh the "Clean-State" snapshot across all VMs, replacing any existing one.

.OUTPUTS
    CSV with columns: VMName, Folder, PowerState, SnapshotName, ExistingRemoved, Status, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Snapshot management permissions in vCenter
    - VMware Tools installed in guest VMs for -Quiesce

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Folder,

    [Parameter(Mandatory=$true)]
    [string]$SnapshotName,

    [Parameter(Mandatory=$false)]
    [string]$Description = '',

    [Parameter(Mandatory=$false)]
    [switch]$IncludeMemory,

    [Parameter(Mandatory=$false)]
    [switch]$Quiesce,

    [Parameter(Mandatory=$false)]
    [switch]$OverwriteExisting,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# IncludeMemory and Quiesce are mutually exclusive
if ($IncludeMemory -and $Quiesce) {
    Write-Warning "-IncludeMemory and -Quiesce are mutually exclusive. -Quiesce will be ignored."
    $Quiesce = $false
}

# --- Connection ---
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

# --- Resolve folder ---
$targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } |
    Select-Object -First 1

if (-not $targetFolder) {
    Write-Error "Folder '$Folder' not found."
    exit 1
}

# --- Get VMs ---
$vms = if ($IncludeSubfolders) {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
} else {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
        Where-Object { $_.FolderId -eq $targetFolder.Id }
}

if (-not $vms) {
    Write-Warning "No VMs found in folder '$Folder'."
    exit 0
}

Write-Host "`n=== New Range Snapshot ===" -ForegroundColor Cyan
Write-Host "  Folder             : $Folder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Snapshot Name      : $SnapshotName" -ForegroundColor White
Write-Host "  Include Memory     : $IncludeMemory" -ForegroundColor White
Write-Host "  Quiesce            : $Quiesce" -ForegroundColor White
Write-Host "  Overwrite Existing : $OverwriteExisting" -ForegroundColor White
Write-Host "  Include Subfolders : $IncludeSubfolders" -ForegroundColor White
Write-Host "  DryRun             : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$VMName, [string]$FolderPath, [string]$PowerState, [string]$SnapName,
          [string]$ExistingRemoved, [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{
        VMName           = $VMName
        Folder           = $FolderPath
        PowerState       = $PowerState
        SnapshotName     = $SnapName
        ExistingRemoved  = $ExistingRemoved
        Status           = $Status
        Detail           = $Detail
        Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($Status) { 'SUCCESS' { 'Green' } 'SKIPPED' { 'Yellow' } 'ERROR' { 'Red' } 'DRYRUN' { 'Cyan' } default { 'White' } }
    Write-Host "  [$Status] $VMName : $Detail" -ForegroundColor $color
}

foreach ($vm in $vms | Sort-Object Name) {
    $vmFolder = (Get-Folder -Id $vm.FolderId -ErrorAction SilentlyContinue).Name
    $powerState = $vm.PowerState
    $existingRemoved = 'No'

    # Check for existing snapshot with this name
    $existing = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($existing -and -not $OverwriteExisting) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved 'No' -Status 'SKIPPED' `
            -Detail "Snapshot '$SnapshotName' already exists (created $($existing.Created.ToString('yyyy-MM-dd'))). Use -OverwriteExisting to replace."
        continue
    }

    if ($DryRun) {
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($existing -and $OverwriteExisting) { $notes.Add("would remove existing snapshot first") }
        if ($IncludeMemory -and $powerState -eq 'PoweredOff') { $notes.Add("-IncludeMemory skipped (VM is off)") }
        if ($Quiesce) { $notes.Add("quiesced") }
        $noteStr = if ($notes.Count -gt 0) { " (" + ($notes -join '; ') + ")" } else { '' }
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved $(if ($existing -and $OverwriteExisting) { 'DRYRUN' } else { 'No' }) `
            -Status 'DRYRUN' -Detail "Would create snapshot '$SnapshotName'$noteStr"
        continue
    }

    # Remove existing snapshot if overwrite requested
    if ($existing -and $OverwriteExisting) {
        try {
            Remove-Snapshot -Snapshot $existing -Confirm:$false -ErrorAction Stop | Out-Null
            $existingRemoved = 'Yes'
        }
        catch {
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
                -ExistingRemoved 'ERROR' -Status 'ERROR' -Detail "Failed to remove existing snapshot: $_"
            continue
        }
    }

    # Build snapshot parameters
    $snapParams = @{
        VM          = $vm
        Name        = $SnapshotName
        Confirm     = $false
        ErrorAction = 'Stop'
    }
    if ($Description)                                     { $snapParams['Description'] = $Description }
    if ($IncludeMemory -and $powerState -ne 'PoweredOff') { $snapParams['Memory']      = $true }
    if ($Quiesce)                                         { $snapParams['Quiesce']     = $true }

    try {
        New-Snapshot @snapParams | Out-Null
        $memNote     = if ($IncludeMemory -and $powerState -eq 'PoweredOff') { ' (memory skipped: VM off)' } else { '' }
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved $existingRemoved -Status 'SUCCESS' `
            -Detail "Snapshot '$SnapshotName' created$memNote"
    }
    catch {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved $existingRemoved -Status 'ERROR' -Detail "Snapshot creation failed: $_"
    }
}

# --- Summary ---
$success = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
$skipped = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$errors  = ($results | Where-Object { $_.Status -eq 'ERROR'   }).Count
$dryrun  = ($results | Where-Object { $_.Status -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total VMs  : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would snapshot : $dryrun" -ForegroundColor Cyan
} else {
    Write-Host "  Success    : $success" -ForegroundColor Green
    Write-Host "  Skipped    : $skipped" -ForegroundColor Yellow
    Write-Host "  Errors     : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
