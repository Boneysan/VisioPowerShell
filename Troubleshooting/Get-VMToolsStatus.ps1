<#
.SYNOPSIS
    Reports VMware Tools version, running state, and upgrade availability across a folder.

.DESCRIPTION
    Enumerates all VMs in the specified folder and reports the VMware Tools install status,
    running state, version number, and whether an upgrade is available. Useful for diagnosing
    connectivity issues (Tools not running), IP reporting gaps, and maintenance planning.
    Flags VMs with Tools not installed, not running, or outdated.

.PARAMETER Folder
    Optional. vSphere folder path. Reports all VMs in the folder.
    Mutually exclusive with -VMName.

.PARAMETER VMName
    Optional. Name of a specific VM to check.
    Mutually exclusive with -Folder.

.PARAMETER IncludeSubfolders
    Optional switch. Include VMs in subfolders when -Folder is specified.

.PARAMETER FlagOutdatedOnly
    Optional switch. Only output VMs where Tools are outdated or not installed.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Get-VMToolsStatus.ps1 -Folder "CyberRange\Exercise01"
    Report VMware Tools status for all VMs in Exercise01.

.EXAMPLE
    .\Get-VMToolsStatus.ps1 -Folder "CyberRange\Exercise01" -FlagOutdatedOnly -OutputFile "tools-issues.csv"
    Export only VMs with missing or outdated Tools.

.OUTPUTS
    CSV with columns: VMName, PowerState, GuestOS, ToolsStatus, ToolsRunningState, ToolsVersion,
                      ToolsVersionStatus, UpgradeAvailable, IPAddress

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM guest information in vCenter

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false, ParameterSetName='ByFolder')]
    [string]$Folder,

    [Parameter(Mandatory=$false, ParameterSetName='ByVM')]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [switch]$FlagOutdatedOnly,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

if (-not $Folder -and -not $VMName) {
    Write-Error "Specify either -Folder or -VMName."
    exit 1
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

# --- Resolve VMs ---
$vms = @()
if ($VMName) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Error "VM '$VMName' not found."; exit 1 }
    $vms = @($vm)
}
else {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }

    $vms = if ($IncludeSubfolders) {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
    } else {
        Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
            Where-Object { $_.FolderId -eq $targetFolder.Id }
    }
}

if (-not $vms) { Write-Warning "No VMs found."; exit 0 }

$target = if ($VMName) { $VMName } else { $Folder }
Write-Host "`n=== VMware Tools Status ===" -ForegroundColor Cyan
Write-Host "  Target            : $target ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Flagged Only      : $FlagOutdatedOnly`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vm in $vms | Sort-Object Name) {
    $guest    = $vm.Guest
    $guestExt = $vm.ExtensionData.Guest
    $toolsVer = $guest.ToolsVersion
    $toolsStatus    = $guestExt.ToolsStatus        # toolsOk, toolsOld, toolsNotInstalled, toolsNotRunning
    $toolsRunning   = $guestExt.ToolsRunningStatus  # guestToolsRunning, guestToolsNotRunning, guestToolsExecutingScripts
    $toolsVerStatus = $guestExt.ToolsVersionStatus2 # guestToolsCurrent, guestToolsNeedUpgrade, guestToolsNotInstalled, guestToolsBlacklisted

    $upgradeAvailable = $toolsVerStatus -in @('guestToolsNeedUpgrade', 'guestToolsBlacklisted', 'guestToolsTooNew')
    $ipAddress = $guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1

    $isFlagged = ($toolsStatus -eq 'toolsNotInstalled') -or
                 ($toolsStatus -eq 'toolsNotRunning')   -or
                 $upgradeAvailable

    if ($FlagOutdatedOnly -and -not $isFlagged) { continue }

    $entry = [PSCustomObject]@{
        VMName            = $vm.Name
        PowerState        = $vm.PowerState
        GuestOS           = $guest.OSFullName
        ToolsStatus       = $toolsStatus
        ToolsRunningState = $toolsRunning
        ToolsVersion      = if ($toolsVer) { $toolsVer } else { 'N/A' }
        ToolsVersionStatus = $toolsVerStatus
        UpgradeAvailable  = $upgradeAvailable
        IPAddress         = if ($ipAddress) { $ipAddress } else { '(none)' }
    }
    $results.Add($entry)

    $color = if     ($toolsStatus -eq 'toolsNotInstalled')               { 'Red'    }
             elseif ($toolsStatus -eq 'toolsNotRunning')                  { 'Yellow' }
             elseif ($upgradeAvailable)                                    { 'Yellow' }
             else                                                          { 'Green'  }

    $flag = if ($isFlagged) { '!' } else { ' ' }
    Write-Host "  [$flag] $($vm.Name.PadRight(30)) Status:$($toolsStatus.PadRight(22)) Running:$($toolsRunning.PadRight(30)) Ver:$toolsVer" -ForegroundColor $color
}

# --- Summary ---
$notInstalled = ($results | Where-Object { $_.ToolsStatus -eq 'toolsNotInstalled' }).Count
$notRunning   = ($results | Where-Object { $_.ToolsStatus -eq 'toolsNotRunning'   }).Count
$needUpgrade  = ($results | Where-Object { $_.UpgradeAvailable -eq $true          }).Count
$ok           = ($results | Where-Object { $_.ToolsStatus -eq 'toolsOk' -and -not $_.UpgradeAvailable }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  VMs checked      : $($vms.Count)"    -ForegroundColor White
Write-Host "  Tools OK         : $ok"               -ForegroundColor Green
Write-Host "  Not Installed    : $notInstalled"     -ForegroundColor $(if ($notInstalled -gt 0) { 'Red'    } else { 'White' })
Write-Host "  Not Running      : $notRunning"       -ForegroundColor $(if ($notRunning   -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  Upgrade Available: $needUpgrade"      -ForegroundColor $(if ($needUpgrade  -gt 0) { 'Yellow' } else { 'White' })

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}
