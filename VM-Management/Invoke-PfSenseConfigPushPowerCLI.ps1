<#
.SYNOPSIS
    Pushes a pfSense XML configuration file to a router VM via VMware Tools (PowerCLI).

.DESCRIPTION
    Copies a pfSense XML configuration file to a target VM using PowerCLI guest file
    operations (Copy-VMGuestFile). Does not require direct network access to the pfSense
    management IP — all operations go through vCenter and VMware Tools.

    Optionally applies the configuration by backing up the existing config.xml, replacing
    it with the staged file, and rebooting the router via Invoke-VMScript.

.PARAMETER VMName
    Required. The name of the pfSense VM in vCenter (e.g. "PFSENSE-R1-CCH").

.PARAMETER XmlPath
    Required. The pfSense XML configuration file to push. Can be a filename only
    (e.g. "CCH-pfSense-r1-defended-dcw.xml") or a full path. If only a filename is
    provided it is resolved against -XmlDir.

.PARAMETER XmlDir
    Optional. Directory containing pfSense XML configuration files.
    Defaults to the current working directory.
    Used to resolve -XmlPath when only a filename is provided.

.PARAMETER Folder
    Optional. vSphere folder containing the target VM (e.g. "CCH"). Used to scope
    the VM lookup and avoid ambiguity if the same VM name exists in multiple folders.

.PARAMETER GuestStageDir
    Optional. Directory inside the pfSense VM to stage the config file. Defaults to '/tmp'.

.PARAMETER ApplyAfterStage
    Optional switch. After staging, backs up the existing config.xml, replaces it with
    the staged file, and reboots the router via Invoke-VMScript. Requires VMware Tools
    guest operations and a shell-capable account in pfSense.
    If this fails, stage only and restore via the pfSense WebGUI.

.PARAMETER vCenter
    Optional. vCenter Server to connect to. Defaults to c1r1r12-vcsa-01.texnet1.net.

.PARAMETER VCenterCredential
    Optional. PSCredential for vCenter. If not provided, you will be prompted interactively.

.PARAMETER GuestCredential
    Optional. PSCredential for the pfSense guest OS. If not provided, you will be
    prompted interactively (skipped in DryRun mode).

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the result as CSV.

.EXAMPLE
    .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Folder "CCH" -VMName "PFSENSE-R1-CCH" -XmlPath "CCH-pfSense-r1-defended-dcw.xml"
    Stage R1 config using the default XmlDir — just pass the filename.

.EXAMPLE
    .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Folder "CCH" -VMName "PFSENSE-R1-CCH" -XmlPath "CCH-pfSense-r1-defended-dcw.xml" -ApplyAfterStage
    Stage and apply the config, then reboot the router.

.EXAMPLE
    .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Folder "CCH" -VMName "PFSENSE-R1-CCH" -XmlPath "CCH-pfSense-r1-defended-dcw.xml" -DryRun
    Preview what would happen without making any changes.

.EXAMPLE
    .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Folder "CCH" -VMName "PFSENSE-R1-CCH" -XmlPath "CCH-pfSense-r1-defended-dcw.xml" -XmlDir "D:\Configs\pfSense"
    Stage using an alternate XML directory.

.OUTPUTS
    CSV with columns: VMName, Folder, XmlFile, StageStatus, ApplyStatus, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - vCenter permissions: VM guest operations (file copy, script execution)
    - VMware Tools running inside the pfSense VM

    How to use:
      Get-Help .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Full
      Get-Help .\Invoke-PfSenseConfigPushPowerCLI.ps1 -Examples

    Author:  Mike Zomer
    Version: 2.0
    Date:    June 25, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$true)]
    [string]$XmlPath,

    [Parameter(Mandatory=$false)]
    [string]$XmlDir = $PWD,

    [Parameter(Mandatory=$false)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [string]$GuestStageDir = '/tmp',

    [Parameter(Mandatory=$false)]
    [switch]$ApplyAfterStage,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [PSCredential]$VCenterCredential,

    [Parameter(Mandatory=$false)]
    [PSCredential]$GuestCredential,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# --- Preflight checks ---
if (-not (Get-Module -ListAvailable -Name 'VMware.PowerCLI')) {
    Write-Error "Required module 'VMware.PowerCLI' is not installed."
    exit 1
}
Import-Module VMware.PowerCLI -ErrorAction Stop

# Resolve XmlPath against XmlDir if only a filename was provided
if (-not [System.IO.Path]::IsPathRooted($XmlPath)) {
    $XmlPath = Join-Path $XmlDir $XmlPath
}

if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "XML config file not found: $XmlPath"
    exit 1
}

# --- Guest credentials ---
# Skip prompt in DryRun — credentials are not used when no changes are made.
if (-not $DryRun -and -not $GuestCredential) {
    Write-Host "Enter pfSense guest credentials:" -ForegroundColor Yellow
    $GuestCredential = Get-Credential -Message "pfSense guest OS credentials for $VMName"
}

# --- vCenter credentials ---
if (-not $VCenterCredential) {
    Write-Host "Enter vCenter credentials:" -ForegroundColor Yellow
    $VCenterCredential = Get-Credential -Message "vCenter credentials for $vCenter"
}

# --- Connection ---
$vi = $null
try {
    Write-Host "Connecting to vCenter: $vCenter..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $vCenter -Credential $VCenterCredential -ErrorAction Stop
    Write-Host "Connected successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to vCenter: $_"
    exit 1
}

$xmlLeaf   = Split-Path -Path $XmlPath -Leaf
$guestDest = "$GuestStageDir/$xmlLeaf"
$folderDisplay = if ($Folder) { $Folder } else { '(any)' }

Write-Host "`n=== pfSense Config Push (PowerCLI) ===" -ForegroundColor Cyan
Write-Host "  VM Name           : $VMName" -ForegroundColor White
Write-Host "  Folder            : $folderDisplay" -ForegroundColor White
Write-Host "  XML File          : $XmlPath" -ForegroundColor White
Write-Host "  Guest Dest        : $guestDest" -ForegroundColor White
Write-Host "  Apply After Stage : $ApplyAfterStage" -ForegroundColor White
Write-Host "  DryRun            : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param(
        [string]$VMNameVal,
        [string]$FolderVal,
        [string]$XmlFile,
        [string]$StageStatus,
        [string]$ApplyStatus,
        [string]$Detail
    )
    $entry = [PSCustomObject]@{
        VMName      = $VMNameVal
        Folder      = $FolderVal
        XmlFile     = $XmlFile
        StageStatus = $StageStatus
        ApplyStatus = $ApplyStatus
        Detail      = $Detail
        Timestamp   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($StageStatus) {
        'SUCCESS' { 'Green'  }
        'SKIPPED' { 'Yellow' }
        'ERROR'   { 'Red'    }
        'DRYRUN'  { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host "  [$StageStatus] $VMNameVal : $Detail" -ForegroundColor $color
}

try {
    if ($DryRun) {
        $applyNote = if ($ApplyAfterStage) { ', then apply and reboot via VMware Tools' } else { '' }
        Add-Result -VMNameVal $VMName -FolderVal $folderDisplay -XmlFile $xmlLeaf `
            -StageStatus 'DRYRUN' -ApplyStatus $(if ($ApplyAfterStage) { 'DRYRUN' } else { 'N/A' }) `
            -Detail "Would copy $xmlLeaf to ${VMName}:${guestDest}$applyNote"
    }
    else {
        # Locate folder (if specified)
        $targetFolder = $null
        if ($Folder) {
            $targetFolder = Get-Folder -Name $Folder -ErrorAction SilentlyContinue |
                Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
            if (-not $targetFolder) {
                Add-Result -VMNameVal $VMName -FolderVal $folderDisplay -XmlFile $xmlLeaf `
                    -StageStatus 'ERROR' -ApplyStatus 'N/A' -Detail "Folder '$Folder' not found"
            }
        }

        # Locate VM (only if folder lookup succeeded or no folder was specified)
        $vm = $null
        if (-not $Folder -or $targetFolder) {
            $vm = if ($targetFolder) {
                Get-VM -Name $VMName -Location $targetFolder -ErrorAction SilentlyContinue | Select-Object -First 1
            } else {
                Get-VM -Name $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
            }

            if (-not $vm) {
                $folderHint = if ($Folder) { " in folder '$Folder'" } else { '' }
                Add-Result -VMNameVal $VMName -FolderVal $folderDisplay -XmlFile $xmlLeaf `
                    -StageStatus 'ERROR' -ApplyStatus 'N/A' -Detail "VM '$VMName' not found$folderHint"
            }
        }

        # Stage and optionally apply (only if VM was found)
        if ($vm) {
            $stageFailed = $false
            try {
                Copy-VMGuestFile -VM $vm -Source $XmlPath -Destination $guestDest `
                    -LocalToGuest -GuestCredential $GuestCredential -Force -ErrorAction Stop
            }
            catch {
                Add-Result -VMNameVal $VMName -FolderVal $folderDisplay -XmlFile $xmlLeaf `
                    -StageStatus 'ERROR' -ApplyStatus 'N/A' -Detail "Copy-VMGuestFile failed: $_"
                $stageFailed = $true
            }

            if (-not $stageFailed) {
                $applyStatus = 'N/A'
                $detail      = "Staged to ${VMName}:${guestDest}"

                # Apply and reboot via VMware Tools (optional)
                # Uses Copy-VMGuestFile + Restart-VMGuest to avoid Invoke-VMScript bash
                # dependency — pfSense/FreeBSD does not ship /bin/bash.
                if ($ApplyAfterStage) {
                    try {
                        Copy-VMGuestFile -VM $vm -Source $XmlPath `
                            -Destination '/cf/conf/config.xml' `
                            -LocalToGuest -GuestCredential $GuestCredential `
                            -Force -ErrorAction Stop
                        Restart-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                        $applyStatus = 'SUCCESS'
                        $detail      += '; applied and rebooting'
                    }
                    catch {
                        $applyStatus = 'ERROR'
                        $detail      += "; apply failed: $_"
                    }
                }

                Add-Result -VMNameVal $VMName -FolderVal $folderDisplay -XmlFile $xmlLeaf `
                    -StageStatus 'SUCCESS' -ApplyStatus $applyStatus -Detail $detail
            }
        }
    }
}
finally {
    if ($vi) {
        Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null
    }
}

# --- Summary ---
$stageStatus = $results[0].StageStatus
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  VM Name     : $VMName" -ForegroundColor White
Write-Host "  XML File    : $xmlLeaf" -ForegroundColor White
Write-Host "  Stage       : $stageStatus" -ForegroundColor $(switch ($stageStatus) { 'SUCCESS' { 'Green' } 'DRYRUN' { 'Cyan' } default { 'Red' } })
if ($results[0].ApplyStatus -ne 'N/A') {
    $applyStatus = $results[0].ApplyStatus
    Write-Host "  Apply       : $applyStatus" -ForegroundColor $(switch ($applyStatus) { 'SUCCESS' { 'Green' } 'DRYRUN' { 'Cyan' } default { 'Red' } })
}
if ($stageStatus -eq 'SUCCESS' -and -not $ApplyAfterStage) {
    Write-Host "`n  Config staged only. Restore via pfSense WebGUI or rerun with -ApplyAfterStage." -ForegroundColor Yellow
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
