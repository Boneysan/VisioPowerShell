<#
.SYNOPSIS
    Creates a named snapshot across all VMs in a vSphere folder, powering running VMs off and back on by default.

.DESCRIPTION
    Enumerates all VMs in the specified folder (and optionally subfolders) and creates
    a consistent, named snapshot on each. By default, running VMs are shut down before
    snapshot creation and then powered back on after the snapshot completes. Designed for
    capturing a known-good state of an entire cyber range environment before an exercise
    begins. Optionally skips VMs that already have a snapshot with the given name.
    IncludeMemory and Quiesce only apply when the VM is still powered on at snapshot time.
    Supports DryRun mode.

.PARAMETER Folder
    Required. The vSphere folder path containing the target VMs (e.g. "CyberRange\Exercise01").

.PARAMETER SnapshotName
    Required. The name to give the snapshot on each VM.

.PARAMETER Description
    Optional. A description to attach to each snapshot.

.PARAMETER IncludeMemory
    Optional switch. Capture the VM's memory state in the snapshot (quiesced, running state).
    Not supported for powered-off VMs; will be automatically skipped for those.
    Because PowerOffBeforeSnapshot is enabled by default, this is usually only effective
    when PowerOffBeforeSnapshot is explicitly disabled.

.PARAMETER Quiesce
    Optional switch. Quiesce the guest file system before snapshotting (requires VMware Tools).
    Incompatible with -IncludeMemory. Will be ignored if -IncludeMemory is set.
    Because PowerOffBeforeSnapshot is enabled by default, this is usually only effective
    when PowerOffBeforeSnapshot is explicitly disabled.

.PARAMETER OverwriteExisting
    Optional switch. If a snapshot with the same name already exists on a VM, remove it
    before creating the new one.

.PARAMETER IncludeSubfolders
    Optional switch. Also snapshot VMs in subfolders of the target folder.

.PARAMETER PowerOffBeforeSnapshot
    Optional switch. If a VM is powered on, attempt a graceful guest shutdown first,
    then force power off if needed before taking the snapshot. Enabled by default.
    Set PowerOffBeforeSnapshot:$false to keep current VM power state unchanged.

.PARAMETER PowerOnAfterSnapshot
    Optional switch. Power VMs back on after snapshot creation, but only if they were
    originally powered on and this script powered them off. Enabled by default.
    Set PowerOnAfterSnapshot:$false to leave VMs off after the snapshot when they were
    powered off by this script.

.PARAMETER GuestShutdownTimeoutSec
    Optional. Number of seconds to wait for a graceful guest shutdown before forcing
    power off. Default: 120.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -DryRun
    Preview which VMs would be powered off, snapshotted, and powered back on without making changes.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Pre-Exercise" -Description "Baseline before red team exercise" -OutputFile "snapshot-log.csv"
    Create a "Pre-Exercise" snapshot on all VMs in Exercise01 using the default power-cycle workflow.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Clean-State" -OverwriteExisting -IncludeSubfolders
    Refresh the "Clean-State" snapshot across all VMs, replacing any existing one.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Pre-Patch" -PowerOnAfterSnapshot:$false
    Power off running VMs, create the snapshot, and leave them powered off afterward.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Memory-State" -PowerOffBeforeSnapshot:$false -PowerOnAfterSnapshot:$false -IncludeMemory
    Keep current power state unchanged and create a memory snapshot where supported.

.EXAMPLE
    .\New-RangeSnapshot.ps1 -Folder "CyberRange\Exercise01" -SnapshotName "Quiesced-State" -PowerOffBeforeSnapshot:$false -PowerOnAfterSnapshot:$false -Quiesce
    Keep running VMs on and create a quiesced snapshot where VMware Tools supports it.

.OUTPUTS
    CSV with columns: VMName, Folder, PowerState, SnapshotName, ExistingRemoved,
         PowerOffStatus, PowerOnStatus, Status, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Snapshot management permissions in vCenter
    - VMware Tools installed in guest VMs for -Quiesce
    - VMware Tools recommended for graceful shutdown when -PowerOffBeforeSnapshot is used

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
    [switch]$PowerOffBeforeSnapshot = $true,

    [Parameter(Mandatory=$false)]
    [switch]$PowerOnAfterSnapshot = $true,

    [Parameter(Mandatory=$false)]
    [int]$GuestShutdownTimeoutSec = 120,

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

if ($PowerOnAfterSnapshot -and -not $PowerOffBeforeSnapshot) {
    Write-Warning "-PowerOnAfterSnapshot only applies when -PowerOffBeforeSnapshot is used. It will be ignored."
    $PowerOnAfterSnapshot = $false
}

if ($IncludeMemory -and $PowerOffBeforeSnapshot) {
    Write-Warning "-IncludeMemory may be skipped for powered-on VMs because -PowerOffBeforeSnapshot snapshots them after shutdown."
}

if ($Quiesce -and $PowerOffBeforeSnapshot) {
    Write-Warning "-Quiesce may be skipped for powered-on VMs because -PowerOffBeforeSnapshot snapshots them after shutdown."
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
Write-Host "  Power Off Before   : $PowerOffBeforeSnapshot" -ForegroundColor White
Write-Host "  Power On After     : $PowerOnAfterSnapshot" -ForegroundColor White
Write-Host "  DryRun             : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$VMName, [string]$FolderPath, [string]$PowerState, [string]$SnapName,
          [string]$ExistingRemoved, [string]$PowerOffStatus, [string]$PowerOnStatus,
          [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{
        VMName           = $VMName
        Folder           = $FolderPath
        PowerState       = $PowerState
        SnapshotName     = $SnapName
        ExistingRemoved  = $ExistingRemoved
        PowerOffStatus   = $PowerOffStatus
        PowerOnStatus    = $PowerOnStatus
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
    $powerOffStatus = if ($PowerOffBeforeSnapshot) { 'PENDING' } else { 'SKIPPED_BY_PARAM' }
    $powerOnStatus = if ($PowerOnAfterSnapshot) { 'PENDING' } else { 'SKIPPED_BY_PARAM' }
    $poweredOffByScript = $false

    # Check for existing snapshot with this name
    $existing = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($existing -and -not $OverwriteExisting) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved 'No' -PowerOffStatus 'SKIPPED' -PowerOnStatus 'SKIPPED' -Status 'SKIPPED' `
            -Detail "Snapshot '$SnapshotName' already exists (created $($existing.Created.ToString('yyyy-MM-dd'))). Use -OverwriteExisting to replace."
        continue
    }

    if ($DryRun) {
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($existing -and $OverwriteExisting) { $notes.Add("would remove existing snapshot first") }
        if ($PowerOffBeforeSnapshot -and $powerState -eq 'PoweredOn') { $notes.Add("would power off first") }
        if ($PowerOnAfterSnapshot -and $powerState -eq 'PoweredOn') { $notes.Add("would power back on afterward") }
        if ($IncludeMemory -and $powerState -eq 'PoweredOff') { $notes.Add("-IncludeMemory skipped (VM is off)") }
        if ($IncludeMemory -and $PowerOffBeforeSnapshot -and $powerState -eq 'PoweredOn') { $notes.Add("-IncludeMemory skipped after shutdown") }
        if ($Quiesce -and $PowerOffBeforeSnapshot -and $powerState -eq 'PoweredOn') {
            $notes.Add("-Quiesce skipped after shutdown")
        }
        elseif ($Quiesce) {
            $notes.Add("quiesced")
        }
        $noteStr = if ($notes.Count -gt 0) { " (" + ($notes -join '; ') + ")" } else { '' }
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
            -ExistingRemoved $(if ($existing -and $OverwriteExisting) { 'DRYRUN' } else { 'No' }) `
            -PowerOffStatus $(if ($PowerOffBeforeSnapshot -and $powerState -eq 'PoweredOn') { 'DRYRUN' } elseif ($PowerOffBeforeSnapshot) { 'ALREADY_OFF' } else { 'SKIPPED_BY_PARAM' }) `
            -PowerOnStatus $(if ($PowerOnAfterSnapshot -and $powerState -eq 'PoweredOn') { 'DRYRUN' } else { 'SKIPPED_BY_PARAM' }) `
            -Status 'DRYRUN' -Detail "Would create snapshot '$SnapshotName'$noteStr"
        continue
    }

    if ($PowerOffBeforeSnapshot) {
        if ($powerState -eq 'PoweredOn') {
            try {
                Write-Host "  Powering off $($vm.Name)..." -ForegroundColor Yellow
                if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
                    Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    $deadline = (Get-Date).AddSeconds($GuestShutdownTimeoutSec)
                    do {
                        Start-Sleep -Seconds 5
                        $vm = Get-VM -Id $vm.Id
                    } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
                }

                if ($vm.PowerState -eq 'PoweredOn') {
                    Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                    $vm = Get-VM -Id $vm.Id
                }

                $powerOffStatus = 'SUCCESS'
                $poweredOffByScript = $true
            }
            catch {
                Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
                    -ExistingRemoved $existingRemoved -PowerOffStatus 'ERROR' -PowerOnStatus 'SKIPPED' -Status 'ERROR' `
                    -Detail "Power off failed: $_"
                continue
            }
        }
        else {
            $powerOffStatus = 'ALREADY_OFF'
            $powerOnStatus = 'SKIPPED'
        }
    }

    # Remove existing snapshot if overwrite requested
    if ($existing -and $OverwriteExisting) {
        try {
            Remove-Snapshot -Snapshot $existing -Confirm:$false -ErrorAction Stop | Out-Null
            $existingRemoved = 'Yes'
        }
        catch {
            if ($PowerOnAfterSnapshot -and $poweredOffByScript) {
                try {
                    Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                    $powerOnStatus = 'SUCCESS'
                }
                catch {
                    $powerOnStatus = 'ERROR'
                }
            }
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
                -ExistingRemoved 'ERROR' -PowerOffStatus $powerOffStatus -PowerOnStatus $powerOnStatus -Status 'ERROR' `
                -Detail "Failed to remove existing snapshot: $_"
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
    if ($Description) { $snapParams['Description'] = $Description }
    if ($IncludeMemory -and $vm.PowerState -ne 'PoweredOff') { $snapParams['Memory'] = $true }
    if ($Quiesce -and $vm.PowerState -ne 'PoweredOff') { $snapParams['Quiesce'] = $true }

    $status = 'SUCCESS'
    $detail = ''
    try {
        New-Snapshot @snapParams | Out-Null
        $memNote = if ($IncludeMemory -and $vm.PowerState -eq 'PoweredOff') { ' (memory skipped: VM off)' } else { '' }
        $detail = "Snapshot '$SnapshotName' created$memNote"
    }
    catch {
        $status = 'ERROR'
        $detail = "Snapshot creation failed: $_"
    }

    if ($PowerOnAfterSnapshot -and $poweredOffByScript) {
        try {
            Write-Host "  Powering on $($vm.Name)..." -ForegroundColor Yellow
            Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
            $powerOnStatus = 'SUCCESS'
            if ($status -eq 'SUCCESS') {
                $detail += '; powered back on'
            }
            else {
                $detail += ' | powered back on'
            }
        }
        catch {
            $powerOnStatus = 'ERROR'
            $detail += " | power-on failed: $_"
        }
    }
    elseif ($PowerOnAfterSnapshot) {
        $powerOnStatus = 'SKIPPED'
    }

    Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerState $powerState -SnapName $SnapshotName `
        -ExistingRemoved $existingRemoved -PowerOffStatus $powerOffStatus -PowerOnStatus $powerOnStatus -Status $status `
        -Detail $detail
}

# --- Summary ---
$success    = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
$skipped    = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$errors     = ($results | Where-Object { $_.Status -eq 'ERROR'   }).Count
$dryrunCount = ($results | Where-Object { $_.Status -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total VMs  : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would snapshot : $dryrunCount" -ForegroundColor Cyan
} else {
    Write-Host "  Success    : $success" -ForegroundColor Green
    Write-Host "  Skipped    : $skipped" -ForegroundColor Yellow
    Write-Host "  Errors     : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
