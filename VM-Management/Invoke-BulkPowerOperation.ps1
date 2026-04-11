<#
.SYNOPSIS
    Performs a bulk power operation on all VMs in a vSphere folder.

.DESCRIPTION
    Enumerates all VMs in the specified folder (and optionally subfolders) and applies
    a power operation to each. Useful for starting up or shutting down an entire cyber
    range exercise environment in a single command. Supports graceful guest shutdown and
    restart in addition to hard power operations. Reports per-VM status.

.PARAMETER Folder
    Required. The vSphere folder path containing the target VMs (e.g. "CyberRange\Exercise01").

.PARAMETER Action
    Required. The power action to perform on each VM.
    Valid values:
      PowerOn       - Power on the VM.
      PowerOff      - Hard power off (equivalent to pulling the power cord).
      Suspend       - Suspend the VM to memory.
      Reset         - Hard reset (equivalent to pressing the reset button).
      ShutdownGuest - Gracefully shut down the guest OS via VMware Tools.
      RestartGuest  - Gracefully restart the guest OS via VMware Tools.

.PARAMETER IncludeSubfolders
    Optional switch. Also act on VMs in subfolders of the target folder.

.PARAMETER SkipAlreadyInState
    Optional switch. Silently skip VMs that are already in the desired power state
    (e.g. skip powered-on VMs when action is PowerOn).

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Invoke-BulkPowerOperation.ps1 -Folder "CyberRange\Exercise01" -Action PowerOn -DryRun
    Preview which VMs would be powered on without making changes.

.EXAMPLE
    .\Invoke-BulkPowerOperation.ps1 -Folder "CyberRange\Exercise01" -Action ShutdownGuest -IncludeSubfolders -OutputFile "shutdown-log.csv"
    Gracefully shut down all VMs in Exercise01 and its subfolders.

.EXAMPLE
    .\Invoke-BulkPowerOperation.ps1 -Folder "CyberRange\Exercise01" -Action PowerOn -SkipAlreadyInState
    Power on any VMs in Exercise01 that are not already running.

.OUTPUTS
    CSV with columns: VMName, Folder, PowerStateBefore, Action, Status, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - VM power management permissions in vCenter
    - VMware Tools installed in guest VMs for ShutdownGuest / RestartGuest actions

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Folder,

    [Parameter(Mandatory=$true)]
    [ValidateSet('PowerOn', 'PowerOff', 'Suspend', 'Reset', 'ShutdownGuest', 'RestartGuest')]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [switch]$SkipAlreadyInState,

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

Write-Host "`n=== Bulk Power Operation ===" -ForegroundColor Cyan
Write-Host "  Folder             : $Folder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Action             : $Action" -ForegroundColor White
Write-Host "  Include Subfolders : $IncludeSubfolders" -ForegroundColor White
Write-Host "  DryRun             : $DryRun`n" -ForegroundColor White

# Map actions to required current power state for skip logic
$requiredOffStates  = @('PowerOn')
$requiredOnStates   = @('PowerOff', 'Suspend', 'Reset', 'ShutdownGuest', 'RestartGuest')

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$VMName, [string]$FolderPath, [string]$PowerStateBefore, [string]$ActionTaken, [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{
        VMName           = $VMName
        Folder           = $FolderPath
        PowerStateBefore = $PowerStateBefore
        Action           = $ActionTaken
        Status           = $Status
        Detail           = $Detail
        Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($Status) { 'SUCCESS' { 'Green' } 'SKIPPED' { 'Yellow' } 'ERROR' { 'Red' } 'DRYRUN' { 'Cyan' } default { 'White' } }
    Write-Host "  [$Status] $VMName ($PowerStateBefore) : $Detail" -ForegroundColor $color
}

foreach ($vm in $vms | Sort-Object Name) {
    $vmFolder = (Get-Folder -Id $vm.FolderId -ErrorAction SilentlyContinue).Name
    $currentState = $vm.PowerState

    # Skip check
    if ($SkipAlreadyInState) {
        if ($Action -in $requiredOffStates -and $currentState -eq 'PoweredOn') {
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerStateBefore $currentState `
                -ActionTaken $Action -Status 'SKIPPED' -Detail "Already powered on"
            continue
        }
        if ($Action -in $requiredOnStates -and $currentState -ne 'PoweredOn') {
            Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerStateBefore $currentState `
                -ActionTaken $Action -Status 'SKIPPED' -Detail "Already in non-running state: $currentState"
            continue
        }
    }

    if ($DryRun) {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerStateBefore $currentState `
            -ActionTaken $Action -Status 'DRYRUN' -Detail "Would perform: $Action"
        continue
    }

    try {
        switch ($Action) {
            'PowerOn'       { Start-VM    -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
            'PowerOff'      { Stop-VM     -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
            'Suspend'       { Suspend-VM  -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
            'Reset'         { Restart-VM  -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
            'ShutdownGuest' { Stop-VMGuest    -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
            'RestartGuest'  { Restart-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null }
        }
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerStateBefore $currentState `
            -ActionTaken $Action -Status 'SUCCESS' -Detail "Action '$Action' completed"
    }
    catch {
        Add-Result -VMName $vm.Name -FolderPath $vmFolder -PowerStateBefore $currentState `
            -ActionTaken $Action -Status 'ERROR' -Detail "$Action failed: $_"
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
    Write-Host "  Would act    : $dryrun" -ForegroundColor Cyan
} else {
    Write-Host "  Success    : $success" -ForegroundColor Green
    Write-Host "  Skipped    : $skipped" -ForegroundColor Yellow
    Write-Host "  Errors     : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
