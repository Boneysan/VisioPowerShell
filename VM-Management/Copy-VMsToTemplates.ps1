<#
.SYNOPSIS
    Clones VMs from a vSphere folder and converts them to templates as clone sources.

.DESCRIPTION
    Enumerates all VMs in the specified source folder, creates a clone of each, and
    converts the clone to a VM template in the target template folder. Designed for
    building a "clone source" snapshot of an entire cyber range network. Powered-on
    VMs can optionally be powered off before cloning. Supports DryRun mode.

.PARAMETER SourceFolder
    Required. The vSphere folder path containing the VMs to clone (e.g. "CyberRange\Exercise01").

.PARAMETER TargetFolder
    Optional. The vSphere folder path where clones will be placed. Default: "Templates".

.PARAMETER Datastore
    Optional. Datastore name for the cloned templates. If not specified, uses the same
    datastore as each source VM.

.PARAMETER ClusterOrHost
    Optional. The cluster or host to place clones on.
    Default: VxRail-Virtual-SAN-Cluster-d891d061-21f0-4c5c-b5fe-49ed281dee99

.PARAMETER NamePrefix
    Optional. Prefix to prepend to each template name. Default: "" (no prefix).

.PARAMETER NameSuffix
    Optional. Suffix to append to each template name to distinguish from the source VM.
    Default: "_template".

.PARAMETER TemplateNetwork
    Optional. Network portgroup to assign all NICs on the clone after creation.
    Default: dead-template

.PARAMETER ForceReclone
    Optional switch. If a clone with the target name already exists, delete it and re-clone.
    WARNING: This permanently deletes the existing VM from disk before cloning.

.PARAMETER PowerOffBeforeClone
    Optional switch. Power off VMs before cloning if they are running.
    Clones of powered-on VMs may contain a crash-consistent (not application-consistent) state.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Copy-VMsToTemplates.ps1 -SourceFolder "CyberRange\Exercise01" -DryRun
    Preview which VMs would be cloned to templates without making changes.

.EXAMPLE
    .\.Copy-VMsToTemplates.ps1 -SourceFolder "CyberRange\Exercise01" -TargetFolder "Templates\CyberRange" -NamePrefix "base_" -NameSuffix "" -PowerOffBeforeClone -OutputFile "clone-results.csv"
    Clone all VMs in Exercise01 with a prefix, powering off running VMs first.

.OUTPUTS
    CSV with columns: VMName, TemplateName, SourceDatastore, TargetDatastore, SourcePowerState, Status, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Permissions to create/manage VMs and templates in vCenter

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceFolder,

    [Parameter(Mandatory=$false)]
    [string]$TargetFolder = 'Templates',

    [Parameter(Mandatory=$false)]
    [string]$Datastore = 'VxRail-Virtual-SAN-Datastore-d891d061-21f0-4c5c-b5fe-49ed281dee99',

    [Parameter(Mandatory=$false)]
    [string]$ClusterOrHost = 'VxRail-Virtual-SAN-Cluster-d891d061-21f0-4c5c-b5fe-49ed281dee99',

    [Parameter(Mandatory=$false)]
    [string]$NamePrefix = '',

    [Parameter(Mandatory=$false)]
    [string]$NameSuffix = '_template',

    [Parameter(Mandatory=$false)]
    [string]$TemplateNetwork = 'dead-template',

    [Parameter(Mandatory=$false)]
    [switch]$ForceReclone,

    [Parameter(Mandatory=$false)]
    [switch]$PowerOffBeforeClone,

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

# --- Resolve source folder ---
$srcFolder = Get-Folder -Name ($SourceFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } |
    Where-Object { ($_.ToString()) -match ($SourceFolder -replace '\\', '.*') } |
    Select-Object -First 1

if (-not $srcFolder) {
    # Fallback: simple name match
    $srcFolder = Get-Folder -Name ($SourceFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } |
        Select-Object -First 1
}

if (-not $srcFolder) {
    Write-Error "Source folder '$SourceFolder' not found."
    exit 1
}

# --- Resolve or create target folder ---
$tgtFolder = Get-Folder -Name ($TargetFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } |
    Select-Object -First 1

if (-not $tgtFolder -and -not $DryRun) {
    Write-Host "Target folder '$TargetFolder' not found. Creating it..." -ForegroundColor Yellow
    try {
        $parentFolderName = ($TargetFolder -split '\\' | Select-Object -SkipLast 1 | Select-Object -Last 1)
        $parentFolder = if ($parentFolderName) {
            Get-Folder -Name $parentFolderName -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
        } else {
            Get-Folder -Name 'vm' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $parentFolder) { $parentFolder = Get-Folder -Name 'vm' | Select-Object -First 1 }
        $tgtFolder = New-Folder -Name ($TargetFolder -split '\\' | Select-Object -Last 1) -Location $parentFolder -ErrorAction Stop
        Write-Host "  Created folder: $TargetFolder" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create target folder: $_"
        exit 1
    }
}
elseif (-not $tgtFolder -and $DryRun) {
    Write-Host "  [DRYRUN] Target folder '$TargetFolder' would be created if it does not exist." -ForegroundColor Yellow
}

# --- Get VMs in source folder ---
$vms = Get-VM -Location $srcFolder -ErrorAction SilentlyContinue
if (-not $vms) {
    Write-Warning "No VMs found in source folder '$SourceFolder'."
    exit 0
}

Write-Host "`n=== Copy VMs to Templates ===" -ForegroundColor Cyan
Write-Host "  Source Folder   : $SourceFolder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Target Folder   : $TargetFolder" -ForegroundColor White
Write-Host "  Name Prefix     : $NamePrefix" -ForegroundColor White
Write-Host "  Name Suffix     : $NameSuffix" -ForegroundColor White
Write-Host "  Template Network: $TemplateNetwork" -ForegroundColor White
Write-Host "  DryRun          : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$VMName, [string]$TemplateName, [string]$SourceDatastore, [string]$TargetDatastore,
          [string]$SourcePowerState, [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{
        VMName           = $VMName
        TemplateName     = $TemplateName
        SourceDatastore  = $SourceDatastore
        TargetDatastore  = $TargetDatastore
        SourcePowerState = $SourcePowerState
        Status           = $Status
        Detail           = $Detail
        Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($Status) { 'SUCCESS' { 'Green' } 'SKIPPED' { 'Yellow' } 'ERROR' { 'Red' } 'DRYRUN' { 'Cyan' } default { 'White' } }
    Write-Host "  [$Status] $VMName -> $TemplateName : $Detail" -ForegroundColor $color
}

foreach ($vm in $vms | Sort-Object Name) {
    $originalPowerState = $vm.PowerState
    $templateName = "$NamePrefix$($vm.Name)$NameSuffix"
    # DatastoreIdList may have multiple IDs; a pipeline Select-Object -First 1 stops it early
    # and causes Get-Datastore to throw "pipeline has been stopped". Use a loop instead.
    $srcDs = $null
    foreach ($dsId in $vm.DatastoreIdList) {
        $srcDs = Get-Datastore -Id $dsId -ErrorAction SilentlyContinue
        if ($srcDs) { break }
    }
    $targetDs = if ($Datastore) { Get-Datastore -Name $Datastore -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $srcDs }

    # Check if a clone with this name already exists in the target folder
    $existingClone = Get-VM -Name $templateName -Location $tgtFolder -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingClone) {
        if ($ForceReclone) {
            Write-Host "  [FORCE] Deleting existing clone '$templateName'..." -ForegroundColor Magenta
            try {
                # Power off first if needed — broken VMs sometimes report as powered on
                if ($existingClone.PowerState -eq 'PoweredOn') {
                    Stop-VM -VM $existingClone -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 3
                }
                # Use API Destroy_Task directly — bypasses PowerCLI validation that
                # rejects VMs in invalid/orphaned states
                $existingClone.ExtensionData.Destroy_Task() | Out-Null
                Start-Sleep -Seconds 5  # brief wait for destroy to propagate
            }
            catch {
                Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                    -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
                    -Status 'ERROR' -Detail "Failed to delete existing clone: $_"
                continue
            }
        }
        else {
            Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
                -Status 'SKIPPED' -Detail "Clone '$templateName' already exists (use -ForceReclone to overwrite)"
            continue
        }
    }

    if ($DryRun) {
        $note = if ($vm.PowerState -eq 'PoweredOn' -and $PowerOffBeforeClone) { "Would power off first, then " } else { "Would " }
        Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
            -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
            -Status 'DRYRUN' -Detail "${note}clone to '$TargetFolder', then move NICs to '$TemplateNetwork'"
        continue
    }

    # Optionally power off the VM
    $poweredOffByScript = $false
    if ($vm.PowerState -eq 'PoweredOn' -and $PowerOffBeforeClone) {
        try {
            Write-Host "  Powering off $($vm.Name)..." -ForegroundColor Yellow
            Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $deadline = (Get-Date).AddSeconds(120)
            do { Start-Sleep -Seconds 5; $vm = Get-VM -Id $vm.Id } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
            if ($vm.PowerState -eq 'PoweredOn') {
                Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                $vm = Get-VM -Id $vm.Id
            }
            $poweredOffByScript = $true
        }
        catch {
            Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                -TargetDatastore $targetDs.Name -SourcePowerState 'PoweredOn' `
                -Status 'ERROR' -Detail "Failed to power off: $_"
            continue
        }
    }

    # Build clone spec
    $cloneParams = @{
        VM          = $vm
        Name        = $templateName
        Location    = $tgtFolder
        Datastore   = $targetDs
        Confirm     = $false
        ErrorAction = 'Stop'
    }
    if ($ClusterOrHost) {
        $resourceTarget = Get-Cluster -Name $ClusterOrHost -ErrorAction SilentlyContinue
        if (-not $resourceTarget) { $resourceTarget = Get-VMHost -Name $ClusterOrHost -ErrorAction SilentlyContinue }
        if ($resourceTarget) {
            # Use a loop to avoid the Select-Object -First 1 pipeline-stop error
            # when a cluster has multiple resource pools.
            $rp = $null
            foreach ($pool in (Get-ResourcePool -Location $resourceTarget -ErrorAction SilentlyContinue)) {
                $rp = $pool; break
            }
            if ($rp) { $cloneParams['ResourcePool'] = $rp }
        }
    }
    else {
        # No ClusterOrHost specified — place clone on the same host as the source VM
        $cloneParams['VMHost'] = $vm.VMHost
    }

    try {
        # Consolidate disks only when needed — skip for powered-off VMs with no snapshots
        # to avoid creating a transient task lock that blocks the subsequent New-VM call.
        try {
            $vmView = $vm | Get-View -Property Runtime, Snapshot -ErrorAction SilentlyContinue
            $needsConsolidate = $vmView -and (
                $vmView.Runtime.ConsolidationNeeded -or
                ($vm.PowerState -eq 'PoweredOn' -and $vmView.Snapshot)
            )
            if ($needsConsolidate) {
                $consolidateTaskRef = $vmView.ConsolidateVMDisks_Task()
                if ($consolidateTaskRef) {
                    Write-Host "  Consolidating disks on $($vm.Name)..." -ForegroundColor Yellow
                    $taskView = Get-View -Id $consolidateTaskRef -ErrorAction SilentlyContinue
                    $deadline = (Get-Date).AddSeconds(180)
                    while ($taskView -and $taskView.Info.State -notin @('success','error') -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Seconds 5
                        $taskView.UpdateViewData('Info')
                    }
                    if ($taskView -and $taskView.Info.State -eq 'error') {
                        Write-Warning "  Consolidation error on $($vm.Name): $($taskView.Info.Error.LocalizedMessage)"
                    }
                    # Brief wait for vCenter to fully release internal locks after consolidation
                    Start-Sleep -Seconds 10
                }
            }
        }
        catch { Write-Warning "  Disk consolidation check failed for $($vm.Name): $_" }

        $clone = $null
        try {
            $clone = New-VM @cloneParams
        }
        catch {
            # New-VM sometimes throws when reading back the VM object even though the
            # underlying vSphere clone task completed successfully. Check if the clone
            # actually exists before treating this as a failure.
            $clone = Get-VM -Name $templateName -Location $tgtFolder -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $clone) {
                Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                    -TargetDatastore $targetDs.Name -SourcePowerState $originalPowerState `
                    -Status 'ERROR' -Detail "Clone/convert failed: $_"
                continue
            }
            Write-Warning "  New-VM threw but clone '$templateName' exists — treating as success. Error was: $_"
        }

        # Move all NICs to the template network so clones don't inherit live networks
        if ($TemplateNetwork) {
            try {
                # Resolve as a distributed portgroup first; fall back to standard network name
                $pg = Get-VDPortgroup -Name $TemplateNetwork -ErrorAction SilentlyContinue | Select-Object -First 1
                foreach ($nic in (Get-NetworkAdapter -VM $clone -ErrorAction SilentlyContinue)) {
                    if ($pg) {
                        Set-NetworkAdapter -NetworkAdapter $nic -Portgroup $pg -Confirm:$false -ErrorAction Stop | Out-Null
                    } else {
                        Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $TemplateNetwork -Confirm:$false -ErrorAction Stop | Out-Null
                    }
                }
                Write-Host "    NICs moved to '$TemplateNetwork'" -ForegroundColor Gray
            }
            catch {
                Write-Warning "  Clone created but failed to move NICs to '$TemplateNetwork': $_"
            }
        }

        # Power the original VM back on if this script shut it down
        if ($poweredOffByScript) {
            try {
                $vm = Get-VM -Id $vm.Id -ErrorAction SilentlyContinue
                if ($vm -and $vm.PowerState -ne 'PoweredOn') {
                    Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Host "  Powered $($vm.Name) back on after cloning." -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "  Clone succeeded but failed to power $($vm.Name) back on: $_"
            }
        }

        Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
            -TargetDatastore $targetDs.Name -SourcePowerState $originalPowerState `
            -Status 'SUCCESS' -Detail "Cloned to '$TargetFolder'"
    }
    catch {
        Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
            -TargetDatastore $targetDs.Name -SourcePowerState $originalPowerState `
            -Status 'ERROR' -Detail "Clone/convert failed: $_"
    }
}

# --- Summary ---
$success = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
$skipped = ($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$errors  = ($results | Where-Object { $_.Status -eq 'ERROR'   }).Count
$dryRunCount = ($results | Where-Object { $_.Status -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total VMs  : $($vms.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would process : $dryRunCount" -ForegroundColor Cyan
} else {
    Write-Host "  Success    : $success" -ForegroundColor Green
    Write-Host "  Skipped    : $skipped" -ForegroundColor Yellow
    Write-Host "  Errors     : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
