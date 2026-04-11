<#
.SYNOPSIS
    Shuts down VMs matching a name pattern, expands their hard disk, and powers them back on.

.DESCRIPTION
    Finds all VMs whose names match the specified pattern across all vCenter folders/clusters,
    powers each one off gracefully (or hard-powers off if guest tools don't respond),
    expands the specified virtual disk by the requested amount of GB, then powers the VM
    back on and waits for VMware Tools to confirm the guest is up.

    Designed for bulk disk expansion tasks such as:
    "Add 10 GB to all Office-WKS3 VMs across all classrooms."

    Supports DryRun mode to preview all changes before committing them.

.PARAMETER VMNamePattern
    Required. Wildcard pattern to match VM names (e.g. "Office-WKS3*" or "*WKS3*").

.PARAMETER ExpandGB
    Required. Number of GB to ADD to the existing disk size (not the new total — the delta).

.PARAMETER DiskNumber
    Optional. Which virtual disk to expand (1 = first disk, 2 = second, etc.). Default: 1.

.PARAMETER Folder
    Optional. Limit scope to VMs inside this vSphere folder path.
    If omitted, searches all VMs in the vCenter.

.PARAMETER PowerOnAfter
    Optional switch (default: enabled). Power VMs back on after the disk is expanded.
    Use -PowerOnAfter:$false to leave VMs powered off after expansion.

.PARAMETER WaitForToolsSec
    Optional. Seconds to wait for VMware Tools to come up after power-on before moving to
    the next VM. Default: 120.

.PARAMETER GuestShutdownTimeoutSec
    Optional. Seconds to wait for a graceful guest shutdown before forcing a hard power-off.
    Default: 90.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Expand-VMDiskSpace.ps1 -VMNamePattern "Office-WKS3*" -ExpandGB 10 -DryRun
    Preview which VMs would be expanded without making any changes.

.EXAMPLE
    .\Expand-VMDiskSpace.ps1 -VMNamePattern "Office-WKS3*" -ExpandGB 10 -OutputFile "disk-expansion.csv"
    Add 10 GB to disk 1 of every VM matching "Office-WKS3*", power off, expand, power on.

.EXAMPLE
    .\Expand-VMDiskSpace.ps1 -VMNamePattern "*WKS3*" -ExpandGB 10 -DiskNumber 1 -Folder "Classrooms" -OutputFile "expansion.csv"
    Expand VMs only within the "Classrooms" folder.

.OUTPUTS
    CSV with columns: VMName, Folder, DiskNumber, OriginalSizeGB, NewSizeGB, ExpandedByGB,
                      PowerOffStatus, ExpandStatus, PowerOnStatus, ToolsStatus, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - VM administrative permissions in vCenter
    - NOTE: Expanding the virtual disk only grows the VMDK. The guest OS partition/filesystem
      must be extended separately (using disk management / growpart / resize2fs inside the VM).

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMNamePattern,

    [Parameter(Mandatory=$true)]
    [ValidateRange(1, 10000)]
    [int]$ExpandGB,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 20)]
    [int]$DiskNumber = 1,

    [Parameter(Mandatory=$false)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [bool]$PowerOnAfter = $true,

    [Parameter(Mandatory=$false)]
    [int]$WaitForToolsSec = 120,

    [Parameter(Mandatory=$false)]
    [int]$GuestShutdownTimeoutSec = 90,

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

# --- Discover matching VMs ---
if ($Folder) {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }
    $vms = Get-VM -Location $targetFolder -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $VMNamePattern }
}
else {
    $vms = Get-VM -Name $VMNamePattern -ErrorAction SilentlyContinue
}

if (-not $vms) {
    Write-Warning "No VMs found matching pattern '$VMNamePattern'."
    exit 0
}

Write-Host "`n=== VM Disk Expansion ===" -ForegroundColor Cyan
Write-Host "  Pattern      : $VMNamePattern" -ForegroundColor White
Write-Host "  VMs found    : $($vms.Count)" -ForegroundColor White
Write-Host "  Expand by    : +$ExpandGB GB" -ForegroundColor White
Write-Host "  Disk number  : $DiskNumber" -ForegroundColor White
Write-Host "  Power on after: $PowerOnAfter" -ForegroundColor White
Write-Host "  DryRun       : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param(
        [string]$VMName, [string]$FolderPath, [int]$DiskNum,
        [double]$OriginalSizeGB, [double]$NewSizeGB, [double]$ExpandedByGB,
        [string]$PowerOffStatus, [string]$ExpandStatus,
        [string]$PowerOnStatus, [string]$ToolsStatus, [string]$Detail
    )
    $entry = [PSCustomObject]@{
        VMName          = $VMName
        Folder          = $FolderPath
        DiskNumber      = $DiskNum
        OriginalSizeGB  = [math]::Round($OriginalSizeGB, 1)
        NewSizeGB       = [math]::Round($NewSizeGB, 1)
        ExpandedByGB    = [math]::Round($ExpandedByGB, 1)
        PowerOffStatus  = $PowerOffStatus
        ExpandStatus    = $ExpandStatus
        PowerOnStatus   = $PowerOnStatus
        ToolsStatus     = $ToolsStatus
        Detail          = $Detail
        Timestamp       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)

    $expandColor = switch ($ExpandStatus) { 'SUCCESS' { 'Green' } 'DRYRUN' { 'Cyan' } 'SKIPPED' { 'Yellow' } default { 'Red' } }
    Write-Host "  [$ExpandStatus] $VMName" -ForegroundColor $expandColor
    Write-Host "           Disk $DiskNum | $OriginalSizeGB GB -> $NewSizeGB GB (+$ExpandedByGB GB) | $Detail" -ForegroundColor Gray
}

foreach ($vm in $vms | Sort-Object Name) {
    $vmFolder = (Get-Folder -Id $vm.FolderId -ErrorAction SilentlyContinue).Name

    # --- Get the target disk ---
    $disks = Get-HardDisk -VM $vm -ErrorAction SilentlyContinue | Sort-Object Name
    if ($disks.Count -lt $DiskNumber) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -DiskNum $DiskNumber `
            -OriginalSizeGB 0 -NewSizeGB 0 -ExpandedByGB 0 `
            -PowerOffStatus 'SKIP' -ExpandStatus 'ERROR' -PowerOnStatus 'SKIP' -ToolsStatus 'SKIP' `
            -Detail "VM only has $($disks.Count) disk(s) — disk $DiskNumber does not exist"
        continue
    }

    $disk = $disks[$DiskNumber - 1]
    $originalGB = [math]::Round($disk.CapacityGB, 1)
    $newGB      = [math]::Round($originalGB + $ExpandGB, 1)

    if ($DryRun) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -DiskNum $DiskNumber `
            -OriginalSizeGB $originalGB -NewSizeGB $newGB -ExpandedByGB $ExpandGB `
            -PowerOffStatus 'DRYRUN' -ExpandStatus 'DRYRUN' `
            -PowerOnStatus $(if ($PowerOnAfter) { 'DRYRUN' } else { 'N/A' }) `
            -ToolsStatus 'DRYRUN' `
            -Detail "Would power off, expand disk '$($disk.Name)' ($($disk.Filename)), then power on"
        continue
    }

    $powerOffStatus = 'N/A'
    $powerWasOn     = ($vm.PowerState -eq 'PoweredOn')

    # --- Power off ---
    if ($powerWasOn) {
        Write-Host "  Powering off $($vm.Name)..." -ForegroundColor Yellow
        try {
            # Try graceful shutdown first
            if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
                Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                $deadline = (Get-Date).AddSeconds($GuestShutdownTimeoutSec)
                do {
                    Start-Sleep -Seconds 5
                    $vm = Get-VM -Id $vm.Id
                } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
            }

            # Force power off if still on
            if ($vm.PowerState -eq 'PoweredOn') {
                Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                $vm = Get-VM -Id $vm.Id
            }
            $powerOffStatus = 'SUCCESS'
        }
        catch {
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -DiskNum $DiskNumber `
                -OriginalSizeGB $originalGB -NewSizeGB $originalGB -ExpandedByGB 0 `
                -PowerOffStatus 'ERROR' -ExpandStatus 'SKIPPED' -PowerOnStatus 'SKIPPED' -ToolsStatus 'SKIPPED' `
                -Detail "Power off failed: $_"
            continue
        }
    }
    else {
        $powerOffStatus = 'ALREADY_OFF'
    }

    # --- Expand disk ---
    $expandStatus = 'ERROR'
    $expandDetail = ''
    try {
        $disk = @(Get-HardDisk -VM $vm -ErrorAction Stop | Sort-Object Name)[$DiskNumber - 1]
        if (-not $disk) { throw "Disk number $DiskNumber not found on VM $($vm.Name)" }
        Set-HardDisk -HardDisk $disk -CapacityGB $newGB -Confirm:$false -ErrorAction Stop | Out-Null
        $expandStatus = 'SUCCESS'
        $expandDetail = "Disk '$($disk.Name)' expanded from $originalGB GB to $newGB GB"
        Write-Host "  [EXPANDED] $($vm.Name): $originalGB GB -> $newGB GB" -ForegroundColor Green
    }
    catch {
        $expandDetail = "Disk expand failed: $_"
        $vm = Get-VM -Id $vm.Id
        # Still try to power it back on
    }

    # --- Power on ---
    $powerOnStatus = 'N/A'
    $toolsStatus   = 'N/A'

    if ($PowerOnAfter -and $powerWasOn) {
        try {
            Write-Host "  Powering on $($vm.Name)..." -ForegroundColor Yellow
            Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null

            # Wait for VMware Tools
            $deadline = (Get-Date).AddSeconds($WaitForToolsSec)
            do {
                Start-Sleep -Seconds 5
                $vm = Get-VM -Id $vm.Id
            } while ($vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning' -and (Get-Date) -lt $deadline)

            $powerOnStatus = 'SUCCESS'
            $toolsStatus = if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
                'UP'
            } else {
                'TIMEOUT'
            }
        }
        catch {
            $powerOnStatus = 'ERROR'
            $expandDetail += " | Power-on failed: $_"
        }
    }
    elseif (-not $PowerOnAfter) {
        $powerOnStatus = 'SKIPPED_BY_PARAM'
    }

    Add-Result -VMName $vm.Name -FolderPath $vmFolder -DiskNum $DiskNumber `
        -OriginalSizeGB $originalGB -NewSizeGB $newGB -ExpandedByGB $ExpandGB `
        -PowerOffStatus $powerOffStatus -ExpandStatus $expandStatus `
        -PowerOnStatus $powerOnStatus -ToolsStatus $toolsStatus `
        -Detail $expandDetail
}

# --- Summary ---
$success = ($results | Where-Object { $_.ExpandStatus -eq 'SUCCESS' }).Count
$errors  = ($results | Where-Object { $_.ExpandStatus -eq 'ERROR'   }).Count
$dryrun  = ($results | Where-Object { $_.ExpandStatus -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  VMs matched  : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would expand : $dryrun" -ForegroundColor Cyan
}
else {
    Write-Host "  Expanded     : $success" -ForegroundColor Green
    Write-Host "  Errors       : $errors"  -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($success -gt 0) {
    Write-Host "`n  REMINDER: The VMDK has been expanded but the guest OS partition and" -ForegroundColor Yellow
    Write-Host "  filesystem still need to be extended inside each VM." -ForegroundColor Yellow
    Write-Host "  Windows: Disk Management or 'Extend Volume'" -ForegroundColor Gray
    Write-Host "  Linux: growpart /dev/sdX N && resize2fs /dev/sdXN (or xfs_growfs)" -ForegroundColor Gray
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
