<#
.SYNOPSIS
    Creates a snapshot on all VMs whose names match a partial-name pattern.

.DESCRIPTION
    Finds VMs by name pattern (for example "*-8May26") across all inventory or
    within a specific folder, then creates a named snapshot on each matching VM.
    Supports optional replacement when a snapshot with the same name already
    exists, and supports DryRun mode.

.PARAMETER VMNamePattern
    Required. Wildcard pattern used to match VM names.
    If no wildcard is provided, the value is treated as a contains match
    by wrapping it as "*value*".

.PARAMETER SnapshotName
    Required. Name of the snapshot to create on each matched VM.

.PARAMETER Folder
    Optional. Limit matching to a specific vSphere VM folder path
    (for example "CyberRange\Templates").

.PARAMETER IncludeSubfolders
    Optional switch. Include VMs in subfolders when -Folder is used.

.PARAMETER Description
    Optional. Snapshot description.

.PARAMETER OverwriteExisting
    Optional switch. If a snapshot with the same name exists on a VM,
    remove it before creating a new one.

.PARAMETER IncludeMemory
    Optional switch. Capture memory state (only valid for powered-on VMs).

.PARAMETER Quiesce
    Optional switch. Quiesce guest file system (requires VMware Tools).
    Incompatible with -IncludeMemory.

.PARAMETER vCenter
    Optional. vCenter Server to connect to. If omitted, uses current session.

.PARAMETER DryRun
    Optional switch. Show what would happen without making changes.

.PARAMETER OutputFile
    Optional. CSV path for results.

.EXAMPLE
    .\New-PatternSnapshot.ps1 -VMNamePattern "-8May26" -SnapshotName "Exam-Baseline"

.EXAMPLE
    .\New-PatternSnapshot.ps1 -VMNamePattern "*-8May26" -SnapshotName "Exam-Baseline" -Folder "Templates" -IncludeSubfolders

.OUTPUTS
    CSV with columns: VMName, Folder, PowerState, SnapshotName, ExistingRemoved,
         Status, Detail, Timestamp

.NOTES
    Requires VMware PowerCLI and snapshot permissions.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMNamePattern,

    [Parameter(Mandatory=$true)]
    [string]$SnapshotName,

    [Parameter(Mandatory=$false)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [string]$Description = '',

    [Parameter(Mandatory=$false)]
    [switch]$OverwriteExisting,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeMemory,

    [Parameter(Mandatory=$false)]
    [switch]$Quiesce,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

if ($IncludeMemory -and $Quiesce) {
    Write-Warning "-IncludeMemory and -Quiesce are mutually exclusive. -Quiesce will be ignored."
    $Quiesce = $false
}

# If user provides a plain fragment like "-8May26", convert to contains-style wildcard.
if ($VMNamePattern -notmatch '[\*\?]') {
    $VMNamePattern = "*$VMNamePattern*"
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
    if (-not (Get-VIServer -ErrorAction SilentlyContinue)) {
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# --- VM Discovery ---
$vms = @()
$targetFolder = $null
if ($Folder) {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } |
        Where-Object { ($_.ToString()) -match ($Folder -replace '\\', '.*') } |
        Select-Object -First 1

    if (-not $targetFolder) {
        $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq 'VM' } |
            Select-Object -First 1
    }

    if (-not $targetFolder) {
        Write-Error "Folder '$Folder' not found."
        exit 1
    }

    $folderVMs = if ($IncludeSubfolders) {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
    }
    else {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
            Where-Object { $_.FolderId -eq $targetFolder.Id }
    }

    $vms = $folderVMs | Where-Object { $_.Name -like $VMNamePattern }
}
else {
    $vms = Get-VM -Name $VMNamePattern -ErrorAction SilentlyContinue
}

if (-not $vms) {
    Write-Warning "No VMs found matching pattern '$VMNamePattern'."
    exit 0
}

Write-Host "`n=== New Pattern Snapshot ===" -ForegroundColor Cyan
Write-Host "  Pattern            : $VMNamePattern" -ForegroundColor White
if ($Folder) {
    Write-Host "  Folder             : $Folder" -ForegroundColor White
    Write-Host "  Include Subfolders : $IncludeSubfolders" -ForegroundColor White
}
Write-Host "  Matched VMs        : $($vms.Count)" -ForegroundColor White
Write-Host "  Snapshot Name      : $SnapshotName" -ForegroundColor White
Write-Host "  Overwrite Existing : $OverwriteExisting" -ForegroundColor White
Write-Host "  Include Memory     : $IncludeMemory" -ForegroundColor White
Write-Host "  Quiesce            : $Quiesce" -ForegroundColor White
Write-Host "  DryRun             : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param(
        [string]$VMName,
        [string]$FolderPath,
        [string]$PowerState,
        [string]$SnapName,
        [string]$ExistingRemoved,
        [string]$Status,
        [string]$Detail
    )

    $entry = [PSCustomObject]@{
        VMName          = $VMName
        Folder          = $FolderPath
        PowerState      = $PowerState
        SnapshotName    = $SnapName
        ExistingRemoved = $ExistingRemoved
        Status          = $Status
        Detail          = $Detail
        Timestamp       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)

    $color = switch ($Status) {
        'SUCCESS' { 'Green' }
        'SKIPPED' { 'Yellow' }
        'ERROR'   { 'Red' }
        'DRYRUN'  { 'Cyan' }
        default   { 'White' }
    }

    Write-Host "  [$Status] $VMName : $Detail" -ForegroundColor $color
}

foreach ($vm in $vms | Sort-Object Name) {
    $vmFolder = (Get-Folder -Id $vm.FolderId -ErrorAction SilentlyContinue).Name
    $existingRemoved = 'No'

    $existing = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing -and -not $OverwriteExisting) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $vm.PowerState -SnapName $SnapshotName `
            -ExistingRemoved 'No' -Status 'SKIPPED' `
            -Detail "Snapshot '$SnapshotName' already exists (created $($existing.Created.ToString('yyyy-MM-dd'))). Use -OverwriteExisting to replace."
        continue
    }

    if ($DryRun) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $vm.PowerState -SnapName $SnapshotName `
            -ExistingRemoved $existingRemoved -Status 'DRYRUN' `
            -Detail "Would create snapshot '$SnapshotName'"
        continue
    }

    if ($existing -and $OverwriteExisting) {
        try {
            Remove-Snapshot -Snapshot $existing -Confirm:$false -ErrorAction Stop | Out-Null
            $existingRemoved = 'Yes'
        }
        catch {
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $vm.PowerState -SnapName $SnapshotName `
                -ExistingRemoved 'No' -Status 'ERROR' `
                -Detail "Failed to remove existing snapshot '$SnapshotName': $_"
            continue
        }
    }

    try {
        $snapParams = @{
            VM          = $vm
            Name        = $SnapshotName
            Confirm     = $false
            ErrorAction = 'Stop'
        }

        if ($Description) { $snapParams['Description'] = $Description }
        if ($IncludeMemory -and $vm.PowerState -ne 'PoweredOff') { $snapParams['Memory'] = $true }
        if ($Quiesce -and $vm.PowerState -ne 'PoweredOff') { $snapParams['Quiesce'] = $true }

        New-Snapshot @snapParams | Out-Null

        $note = if ($IncludeMemory -and $vm.PowerState -eq 'PoweredOff') {
            ' (memory skipped: VM off)'
        }
        elseif ($Quiesce -and $vm.PowerState -eq 'PoweredOff') {
            ' (quiesce skipped: VM off)'
        }
        else {
            ''
        }

        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $vm.PowerState -SnapName $SnapshotName `
            -ExistingRemoved $existingRemoved -Status 'SUCCESS' -Detail "Snapshot '$SnapshotName' created$note"
    }
    catch {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $vm.PowerState -SnapName $SnapshotName `
            -ExistingRemoved $existingRemoved -Status 'ERROR' -Detail "Snapshot failed: $_"
    }
}

$success = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
$skipped = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$errors  = ($results | Where-Object { $_.Status -eq 'ERROR'   }).Count
$dryRunCount = ($results | Where-Object { $_.Status -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total matched : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would process : $dryRunCount" -ForegroundColor Cyan
}
else {
    Write-Host "  Success       : $success" -ForegroundColor Green
    Write-Host "  Skipped       : $skipped" -ForegroundColor Yellow
    Write-Host "  Errors        : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
