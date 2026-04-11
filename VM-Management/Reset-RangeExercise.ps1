<#
.SYNOPSIS
    Reverts all VMs in a vSphere folder to a named snapshot for cyber range exercise reset.

.DESCRIPTION
    Enumerates all VMs in the specified folder (and optionally subfolders), locates
    the named snapshot on each VM, and reverts to it. Designed for rapid cyber range
    exercise reset workflows. Reports per-VM status and logs results to CSV.
    Supports DryRun mode to preview actions without making changes.

.PARAMETER Folder
    Required. The vSphere folder path containing the exercise VMs (e.g. "CyberRange\Exercise01").

.PARAMETER SnapshotName
    Required. The name of the snapshot to revert to on each VM.

.PARAMETER IncludeSubfolders
    Optional switch. Also revert VMs in subfolders of the target folder.

.PARAMETER PowerOnAfterRevert
    Optional switch. Power on VMs after reverting to the snapshot.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Reset-RangeExercise.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -DryRun
    Preview which VMs would be reverted without making changes.

.EXAMPLE
    .\Reset-RangeExercise.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -PowerOnAfterRevert -OutputFile "reset-log.csv"
    Revert all VMs to the "Clean-State" snapshot and power them on.

.OUTPUTS
    CSV with columns: VMName, Folder, SnapshotFound, SnapshotCreated, RevertStatus, PowerOnStatus, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Snapshot and VM power management permissions in vCenter

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
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [switch]$PowerOnAfterRevert,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

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

Write-Host "`n=== Reset Range Exercise ===" -ForegroundColor Cyan
Write-Host "  Folder              : $Folder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Snapshot Name       : $SnapshotName" -ForegroundColor White
Write-Host "  Power On After      : $PowerOnAfterRevert" -ForegroundColor White
Write-Host "  Include Subfolders  : $IncludeSubfolders" -ForegroundColor White
Write-Host "  DryRun              : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$VMName, [string]$FolderPath, [string]$SnapshotFound, [string]$SnapshotCreated,
          [string]$RevertStatus, [string]$PowerOnStatus, [string]$Detail)
    $entry = [PSCustomObject]@{
        VMName          = $VMName
        Folder          = $FolderPath
        SnapshotFound   = $SnapshotFound
        SnapshotCreated = $SnapshotCreated
        RevertStatus    = $RevertStatus
        PowerOnStatus   = $PowerOnStatus
        Detail          = $Detail
        Timestamp       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($RevertStatus) { 'SUCCESS' { 'Green' } 'SKIPPED' { 'Yellow' } 'ERROR' { 'Red' } 'DRYRUN' { 'Cyan' } default { 'White' } }
    Write-Host "  [$RevertStatus] $VMName : $Detail" -ForegroundColor $color
}

foreach ($vm in $vms | Sort-Object Name) {
    $vmFolder = (Get-Folder -Id $vm.FolderId -ErrorAction SilentlyContinue).Name

    # Locate snapshot
    $snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $snapshot) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -SnapshotFound 'No' -SnapshotCreated '' `
            -RevertStatus 'ERROR' -PowerOnStatus 'N/A' `
            -Detail "Snapshot '$SnapshotName' not found on this VM"
        continue
    }

    if ($DryRun) {
        $powerNote = if ($PowerOnAfterRevert) { ', then power on' } else { '' }
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -SnapshotFound 'Yes' `
            -SnapshotCreated $snapshot.Created.ToString('yyyy-MM-dd HH:mm') `
            -RevertStatus 'DRYRUN' -PowerOnStatus $(if ($PowerOnAfterRevert) { 'DRYRUN' } else { 'N/A' }) `
            -Detail "Would revert to snapshot '$SnapshotName' (created $($snapshot.Created.ToString('yyyy-MM-dd')))$powerNote"
        continue
    }

    # Revert
    try {
        Set-VM -VM $vm -Snapshot $snapshot -Confirm:$false -ErrorAction Stop | Out-Null
        $revertStatus = 'SUCCESS'
        $detail       = "Reverted to '$SnapshotName'"
    }
    catch {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -SnapshotFound 'Yes' `
            -SnapshotCreated $snapshot.Created.ToString('yyyy-MM-dd HH:mm') `
            -RevertStatus 'ERROR' -PowerOnStatus 'N/A' `
            -Detail "Revert failed: $_"
        continue
    }

    # Optionally power on
    $powerOnStatus = 'N/A'
    if ($PowerOnAfterRevert) {
        try {
            $vm = Get-VM -Id $vm.Id
            if ($vm.PowerState -ne 'PoweredOn') {
                Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                $powerOnStatus = 'SUCCESS'
                $detail += '; powered on'
            }
            else {
                $powerOnStatus = 'ALREADY_ON'
                $detail += '; already powered on after revert'
            }
        }
        catch {
            $powerOnStatus = 'ERROR'
            $detail += "; power-on failed: $_"
        }
    }

    Add-Result -VMName $vm.Name -FolderPath $vmFolder `
        -SnapshotFound 'Yes' -SnapshotCreated $snapshot.Created.ToString('yyyy-MM-dd HH:mm') `
        -RevertStatus $revertStatus -PowerOnStatus $powerOnStatus -Detail $detail
}

# --- Summary ---
$success = ($results | Where-Object { $_.RevertStatus -eq 'SUCCESS' }).Count
$errors  = ($results | Where-Object { $_.RevertStatus -eq 'ERROR'   }).Count
$dryrun  = ($results | Where-Object { $_.RevertStatus -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total VMs  : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would revert : $dryrun" -ForegroundColor Cyan
} else {
    Write-Host "  Success    : $success" -ForegroundColor Green
    Write-Host "  Errors     : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
