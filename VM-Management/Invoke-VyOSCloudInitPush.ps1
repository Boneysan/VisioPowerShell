<#
.SYNOPSIS
    Pushes cloud-init guestinfo properties to VyOS switch VMs in vCenter and
    optionally triggers cloud-init to apply the configuration.

.DESCRIPTION
    Sets guestinfo.userdata, guestinfo.metadata, and their encoding keys directly
    on VyOS switch VMs using the vSphere API (ReconfigVM). This is the workaround
    when the Terraform vSphere provider fails to set extra_config on linked clone
    VMs deployed in-place (the provider only sets new keys on initial creation).

    After setting the guestinfo properties, the script can optionally:
      - Reboot the VM (cloud-init runs automatically on next boot)
      - Run cloud-init stages in-guest via VMware Tools (Invoke-VMScript)

    guestinfo keys set on each VM:
      guestinfo.metadata          Base64-encoded JSON: instance-id, local-hostname
      guestinfo.metadata.encoding "base64"
      guestinfo.userdata          Base64-encoded cloud-init YAML
      guestinfo.userdata.encoding "base64"

.PARAMETER Switches
    Optional. One or more switch keys to process (e.g. "VYOS-SW1","VYOS-SW3").
    Defaults to all five: VYOS-SW1 through VYOS-SW5.
    Ignored when -VMName/-YamlFile are used.

.PARAMETER VMName
    Optional. Exact name of a single VyOS VM to target instead of the built-in
    switch map. Must be used together with -YamlFile. If neither -VMName,
    -YamlFile, nor -Switches is supplied, the script prompts for a VM name and
    YAML file (press Enter at the VM name prompt to use the built-in map).

.PARAMETER YamlFile
    Optional. Cloud-init YAML file for the VM given in -VMName. Accepts a full
    path, or a filename resolved relative to -YamlDir. Must be used together
    with -VMName.

.PARAMETER EventName
    Optional. The Caster/Terraform event name appended to VM names (e.g. "CCH").
    VM lookup tries "<SwitchKey>-<EventName>" first, then "<SwitchKey>".
    Defaults to "CCH".

.PARAMETER YamlDir
    Optional. Directory containing the cloud-init YAML files. Defaults to the
    directory the script is located in. The YAML filenames are fixed per switch
    (e.g. vyos-sw1-dungeonnet-core.yml) unless -YamlFile is used.

.PARAMETER RebootAfterPush
    Optional switch. Gracefully reboots each VM after setting guestinfo so
    cloud-init runs automatically on the next boot. Mutually exclusive with
    -TriggerCloudInit.

.PARAMETER TriggerCloudInit
    Optional switch. Runs cloud-init stages inside the running VM via
    Invoke-VMScript (VMware Tools). Requires -GuestCredential and open-vm-tools
    running inside VyOS. Mutually exclusive with -RebootAfterPush.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to.
    Defaults to c1r1r12-vcsa-01.texnet1.net.

.PARAMETER VCenterCredential
    Optional. PSCredential for vCenter. If not provided you will be prompted.

.PARAMETER GuestCredential
    Optional. PSCredential for the VyOS guest OS. Required only when
    -TriggerCloudInit is specified.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Invoke-VyOSCloudInitPush.ps1 -YamlDir "H:\IQT\New Classes\CCH\Caster\CCH\02_routers" -DryRun
    Preview what would be set on all five VyOS switches.

.EXAMPLE
    .\Invoke-VyOSCloudInitPush.ps1 -YamlDir "H:\IQT\New Classes\CCH\Caster\CCH\02_routers" -RebootAfterPush
    Push guestinfo to all switches and reboot each one so cloud-init runs on next boot.

.EXAMPLE
    .\Invoke-VyOSCloudInitPush.ps1 -Switches "VYOS-SW1","VYOS-SW2" -YamlDir "H:\IQT\New Classes\CCH\Caster\CCH\02_routers" -RebootAfterPush
    Push and reboot SW1 and SW2 only.

.EXAMPLE
    .\Invoke-VyOSCloudInitPush.ps1 -VMName "VYOS-R1-CCH" -YamlFile "H:\IQT\New Classes\CCH\Caster\CCH\02_routers\vyos-r1-dungeonnet.yml" -RebootAfterPush
    Push an arbitrary YAML to a specific VM (bypasses the built-in switch map).

.EXAMPLE
    .\Invoke-VyOSCloudInitPush.ps1 -YamlDir "." -TriggerCloudInit -OutputFile "cloudinit-push.csv"
    Push guestinfo and trigger cloud-init in-guest; export results to CSV.

.OUTPUTS
    CSV with columns: VMName, SwitchKey, YamlFile, PushStatus, RebootStatus, CloudInitStatus, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - vCenter permissions: VM reconfigure (extraConfig)
    - open-vm-tools running in VyOS guests (required for -TriggerCloudInit only)

    YAML filenames per switch (must exist in -YamlDir):
      VYOS-SW1  vyos-sw1-dungeonnet-core.yml
      VYOS-SW2  vyos-sw2-dungeonnet-servers.yml
      VYOS-SW3  vyos-sw3-dungeonnet-admin.yml
      VYOS-SW4  vyos-sw4-dungeonnet-operations.yml
      VYOS-SW5  vyos-sw5-cleared-defense-contractor.yml

    Author: GitHub Copilot
    Version: 1.0
    Date: June 27, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$Switches = @('VYOS-SW1','VYOS-SW2','VYOS-SW3','VYOS-SW4','VYOS-SW5'),

    [Parameter(Mandatory=$false)]
    [string]$EventName = 'CCH',

    [Parameter(Mandatory=$false)]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [string]$YamlFile,

    [Parameter(Mandatory=$false)]
    [string]$YamlDir = $PSScriptRoot,

    [Parameter(Mandatory=$false)]
    [switch]$RebootAfterPush,

    [Parameter(Mandatory=$false)]
    [switch]$TriggerCloudInit,

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

# --- Preflight ---
if ($RebootAfterPush -and $TriggerCloudInit) {
    Write-Error "-RebootAfterPush and -TriggerCloudInit are mutually exclusive."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name 'VMware.PowerCLI')) {
    Write-Error "Required module 'VMware.PowerCLI' is not installed."
    exit 1
}
Import-Module VMware.PowerCLI -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

# YAML filename for each switch key
$yamlMap = [ordered]@{
    'VYOS-SW1' = 'vyos-sw1-dungeonnet-core.yml'
    'VYOS-SW2' = 'vyos-sw2-dungeonnet-servers.yml'
    'VYOS-SW3' = 'vyos-sw3-dungeonnet-admin.yml'
    'VYOS-SW4' = 'vyos-sw4-dungeonnet-operations.yml'
    'VYOS-SW5' = 'vyos-sw5-cleared-defense-contractor.yml'
}

# Custom single-VM mode: -VMName/-YamlFile override the built-in map.
# If neither is supplied (and -Switches wasn't explicitly given), prompt for them.
if (-not $VMName -and -not $YamlFile -and -not $PSBoundParameters.ContainsKey('Switches')) {
    $VMName = Read-Host "VyOS VM name (press Enter to use the built-in switch map)"
    if ($VMName) {
        while (-not $YamlFile) {
            $YamlFile = Read-Host "Cloud-init YAML file (full path, or filename relative to $YamlDir)"
        }
    }
}

if ($VMName -or $YamlFile) {
    if (-not ($VMName -and $YamlFile)) {
        Write-Error "-VMName and -YamlFile must be specified together."
        exit 1
    }
    $yamlMap  = [ordered]@{ $VMName = $YamlFile }
    $Switches = @($VMName)
    $customMode = $true
} else {
    $customMode = $false
}

function Resolve-YamlPath {
    param([string]$File)
    if ([System.IO.Path]::IsPathRooted($File)) { return $File }
    return (Join-Path $YamlDir $File)
}

# Validate -Switches values
foreach ($sw in $Switches) {
    if (-not $yamlMap.Contains($sw)) {
        Write-Error "Unknown switch key '$sw'. Valid values: $($yamlMap.Keys -join ', ')"
        exit 1
    }
}

# Validate YAML files exist (skip in DryRun)
if (-not $DryRun) {
    foreach ($sw in $Switches) {
        $yamlPath = Resolve-YamlPath $yamlMap[$sw]
        if (-not (Test-Path -LiteralPath $yamlPath)) {
            Write-Error "YAML file not found: $yamlPath"
            exit 1
        }
    }
}

# Guest credential prompt (only needed for -TriggerCloudInit)
if ($TriggerCloudInit -and -not $DryRun -and -not $GuestCredential) {
    Write-Host "Enter VyOS guest credentials (vyos user):" -ForegroundColor Yellow
    $GuestCredential = Get-Credential -Message "VyOS guest OS credentials"
}

# vCenter credential prompt
if (-not $VCenterCredential) {
    Write-Host "Enter vCenter credentials:" -ForegroundColor Yellow
    $VCenterCredential = Get-Credential -Message "vCenter credentials for $vCenter"
}

# --- Connection ---
$vi = $null
if (-not $DryRun) {
    try {
        Write-Host "Connecting to vCenter: $vCenter ..." -ForegroundColor Cyan
        $vi = Connect-VIServer -Server $vCenter -Credential $VCenterCredential -ErrorAction Stop
        Write-Host "Connected." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter: $_"
        exit 1
    }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param(
        [string]$VMName,
        [string]$SwitchKey,
        [string]$YamlFile,
        [string]$PushStatus,
        [string]$RebootStatus   = 'N/A',
        [string]$CloudInitStatus = 'N/A',
        [string]$Detail
    )
    $entry = [PSCustomObject]@{
        VMName           = $VMName
        SwitchKey        = $SwitchKey
        YamlFile         = $YamlFile
        PushStatus       = $PushStatus
        RebootStatus     = $RebootStatus
        CloudInitStatus  = $CloudInitStatus
        Detail           = $Detail
        Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($PushStatus) {
        'SUCCESS' { 'Green'  }
        'SKIPPED' { 'Yellow' }
        'ERROR'   { 'Red'    }
        'DRYRUN'  { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host "  [$PushStatus] $VMName : $Detail" -ForegroundColor $color
}

function Wait-VimTask {
    param([VMware.Vim.ManagedObjectReference]$TaskMoRef)
    $taskView = Get-View -Id $TaskMoRef
    while ($taskView.Info.State -eq 'running') {
        Start-Sleep -Milliseconds 500
        $taskView.UpdateViewData('Info.State')
    }
    if ($taskView.Info.State -ne 'success') {
        throw $taskView.Info.Error.LocalizedMessage
    }
}

Write-Host "`n=== VyOS Cloud-Init GuestInfo Push ===" -ForegroundColor Cyan
Write-Host "  Event          : $EventName" -ForegroundColor White
Write-Host "  Yaml Dir       : $YamlDir" -ForegroundColor White
Write-Host "  Switches       : $($Switches -join ', ')" -ForegroundColor White
Write-Host "  Reboot         : $RebootAfterPush" -ForegroundColor White
Write-Host "  TriggerCI      : $TriggerCloudInit" -ForegroundColor White
Write-Host "  DryRun         : $DryRun`n" -ForegroundColor White

try {
    foreach ($switchKey in $Switches) {
        $yamlFile = $yamlMap[$switchKey]
        $yamlPath = Resolve-YamlPath $yamlFile

        Write-Host "--- $switchKey ---" -ForegroundColor Cyan

        if ($DryRun) {
            $action = if ($RebootAfterPush) { ', then reboot' } elseif ($TriggerCloudInit) { ', then trigger cloud-init in-guest' } else { '' }
            $dryName = if ($customMode) { $switchKey } else { "$switchKey-$EventName" }
            Add-Result -VMName $dryName -SwitchKey $switchKey -YamlFile $yamlFile `
                -PushStatus 'DRYRUN' -Detail "Would set guestinfo from $yamlFile$action"
            continue
        }

        # Locate VM: custom mode uses the exact name; otherwise try "<key>-<event>" then bare key
        if ($customMode) {
            $vm = Get-VM -Name $switchKey -ErrorAction SilentlyContinue | Select-Object -First 1
            $notFoundDetail = "VM not found as '$switchKey'"
        }
        else {
            $vm = Get-VM -Name "$switchKey-$EventName" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
            if (-not $vm) {
                $vm = Get-VM -Name $switchKey -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            $notFoundDetail = "VM not found as '$switchKey-$EventName' or '$switchKey'"
        }
        if (-not $vm) {
            Add-Result -VMName $switchKey -SwitchKey $switchKey -YamlFile $yamlFile `
                -PushStatus 'ERROR' -Detail $notFoundDetail
            continue
        }

        $vmDisplayName = $vm.Name

        # Build base64 values
        $yamlBytes   = [System.IO.File]::ReadAllBytes($yamlPath)
        $userdataB64 = [Convert]::ToBase64String($yamlBytes)

        $instanceId = if ($customMode) { $switchKey } else { "$switchKey-$EventName" }
        $metadataJson = (@{
            'instance-id'    = $instanceId
            'local-hostname' = $switchKey
        } | ConvertTo-Json -Compress)
        $metadataB64 = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes($metadataJson)
        )

        # ReconfigVM to set guestinfo keys
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.ExtraConfig = @(
            [VMware.Vim.OptionValue]@{ Key = 'guestinfo.metadata';          Value = $metadataB64  }
            [VMware.Vim.OptionValue]@{ Key = 'guestinfo.metadata.encoding'; Value = 'base64'      }
            [VMware.Vim.OptionValue]@{ Key = 'guestinfo.userdata';          Value = $userdataB64  }
            [VMware.Vim.OptionValue]@{ Key = 'guestinfo.userdata.encoding'; Value = 'base64'      }
        )

        $pushDetail = "Set guestinfo from $yamlFile ($($yamlBytes.Length) bytes)"
        try {
            $taskMoRef = $vm.ExtensionData.ReconfigVM_Task($spec)
            Wait-VimTask -TaskMoRef $taskMoRef
        }
        catch {
            Add-Result -VMName $vmDisplayName -SwitchKey $switchKey -YamlFile $yamlFile `
                -PushStatus 'ERROR' -Detail "ReconfigVM failed: $_"
            continue
        }

        $rebootStatus    = 'N/A'
        $cloudInitStatus = 'N/A'

        # Optional: reboot via VMware Tools
        if ($RebootAfterPush) {
            try {
                Restart-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                $rebootStatus = 'SUCCESS'
                $pushDetail  += '; rebooting (cloud-init will run on next boot)'
            }
            catch {
                $rebootStatus = 'ERROR'
                $pushDetail  += "; reboot failed: $_"
            }
        }

        # Optional: trigger cloud-init in-guest without reboot
        if ($TriggerCloudInit) {
            $ciScript = 'cloud-init clean && cloud-init init --local && cloud-init init && cloud-init modules --mode=config && cloud-init modules --mode=final'
            try {
                Invoke-VMScript -VM $vm -GuestCredential $GuestCredential `
                    -ScriptText $ciScript -ScriptType Bash -ErrorAction Stop | Out-Null
                $cloudInitStatus = 'SUCCESS'
                $pushDetail     += '; cloud-init triggered in-guest'
            }
            catch {
                $cloudInitStatus = 'ERROR'
                $pushDetail     += "; Invoke-VMScript failed: $_"
            }
        }

        Add-Result -VMName $vmDisplayName -SwitchKey $switchKey -YamlFile $yamlFile `
            -PushStatus 'SUCCESS' -RebootStatus $rebootStatus `
            -CloudInitStatus $cloudInitStatus -Detail $pushDetail
    }
}
finally {
    if ($vi) {
        Disconnect-VIServer -Server $vi -Confirm:$false | Out-Null
    }
}

# --- Summary ---
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
$results | ForEach-Object {
    $color = switch ($_.PushStatus) { 'SUCCESS' { 'Green' } 'DRYRUN' { 'Cyan' } default { 'Red' } }
    Write-Host ("  [{0,-7}] {1,-20} {2}" -f $_.PushStatus, $_.VMName, $_.Detail) -ForegroundColor $color
}

$successCount = ($results | Where-Object { $_.PushStatus -in 'SUCCESS','DRYRUN' }).Count
Write-Host "`n  $successCount / $($results.Count) switches processed." -ForegroundColor White

if (($results | Where-Object { $_.PushStatus -eq 'SUCCESS' -and $_.RebootStatus -eq 'N/A' -and $_.CloudInitStatus -eq 'N/A' }).Count -gt 0) {
    Write-Host @"

  GuestInfo is set. To apply the cloud-init config, either:
    1. Rerun with -RebootAfterPush  (VM reboots; cloud-init runs on next boot)
    2. SSH to each switch and run:
         sudo cloud-init clean
         sudo cloud-init init --local
         sudo cloud-init init
         sudo cloud-init modules --mode=config
"@ -ForegroundColor Yellow
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
