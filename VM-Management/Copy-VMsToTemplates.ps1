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

# --- Connection Phase ---
# Connect to vCenter if specified via parameter, otherwise assume an active session exists
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
    # Validate that there is actually an active connection to use
    if (-not (Get-VIServer -ErrorAction SilentlyContinue)) {
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# --- Resolve source folder ---
# Find the specific VM folder object based on the provided path string
$srcFolder = Get-Folder -Name ($SourceFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } |
    Where-Object { ($_.ToString()) -match ($SourceFolder -replace '\\', '.*') } |
    Select-Object -First 1

# Fallback: simple name match if the full path match fails
if (-not $srcFolder) {
    $srcFolder = Get-Folder -Name ($SourceFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } |
        Select-Object -First 1
}

if (-not $srcFolder) {
    Write-Error "Source folder '$SourceFolder' not found."
    exit 1
}

# --- Resolve or create target folder ---
# Find the target folder where templates will be stored
$tgtFolder = Get-Folder -Name ($TargetFolder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } |
    Select-Object -First 1

# Logic: Automatically create the target folder if it doesn't exist (unless in DryRun mode)
if (-not $tgtFolder -and -not $DryRun) {
    Write-Host "Target folder '$TargetFolder' not found. Creating it..." -ForegroundColor Yellow
    try {
        # Determine the parent folder for the new folder
        $parentFolderName = ($TargetFolder -split '\\' | Select-Object -SkipLast 1 | Select-Object -Last 1)
        $parentFolder = if ($parentFolderName) {
            Get-Folder -Name $parentFolderName -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
        } else {
            # Default to the root 'vm' folder
            Get-Folder -Name 'vm' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $parentFolder) { $parentFolder = Get-Folder -Name 'vm' | Select-Object -First 1 }
        
        # Perform the folder creation
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
# Collect all Virtual Machine objects from the source folder
$vms = Get-VM -Location $srcFolder -ErrorAction SilentlyContinue
if (-not $vms) {
    Write-Warning "No VMs found in source folder '$SourceFolder'."
    exit 0
}

# Display configuration summary to the user
Write-Host "`n=== Copy VMs to Templates ===" -ForegroundColor Cyan
Write-Host "  Source Folder   : $SourceFolder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Target Folder   : $TargetFolder" -ForegroundColor White
Write-Host "  Name Prefix     : $NamePrefix" -ForegroundColor White
Write-Host "  Name Suffix     : $NameSuffix" -ForegroundColor White
Write-Host "  Template Network: $TemplateNetwork" -ForegroundColor White
Write-Host "  DryRun          : $DryRun`n" -ForegroundColor White

# Initialize a collection to track the outcome of each VM processing task
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Helper function: Logs the result of a single VM operation and adds it to the master list
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
    # Output to console with status-specific coloring
    $color = switch ($Status) { 'SUCCESS' { 'Green' } 'SKIPPED' { 'Yellow' } 'ERROR' { 'Red' } 'DRYRUN' { 'Cyan' } default { 'White' } }
    Write-Host "  [$Status] $VMName -> $TemplateName : $Detail" -ForegroundColor $color
}

# --- Main Cloning Loop ---
foreach ($vm in $vms | Sort-Object Name) {
    $originalPowerState = $vm.PowerState
    # Construct the target template name using prefix/suffix rules
    $templateName = "$NamePrefix$($vm.Name)$NameSuffix"
    
    # Resolve the source datastore (handling potential multi-ID lists)
    $srcDs = $null
    foreach ($dsId in $vm.DatastoreIdList) {
        $srcDs = Get-Datastore -Id $dsId -ErrorAction SilentlyContinue
        if ($srcDs) { break }
    }
    # Determine the target datastore for the template
    $targetDs = if ($Datastore) { Get-Datastore -Name $Datastore -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $srcDs }

    # Logic Step: Check for existing naming collisions in the target folder
    $existingClone = Get-VM -Name $templateName -Location $tgtFolder -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingClone) {
        if ($ForceReclone) {
            # Overwrite mode: Delete the old clone before starting the new one
            Write-Host "  [FORCE] Deleting existing clone '$templateName'..." -ForegroundColor Magenta
            try {
                # Force power off if the VM is running or in an invalid state
                if ($existingClone.PowerState -eq 'PoweredOn') {
                    Stop-VM -VM $existingClone -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 3
                }
                # Use low-level API call to bypass standard PowerCLI safety checks (handles orphaned VMs)
                $existingClone.ExtensionData.Destroy_Task() | Out-Null
                Start-Sleep -Seconds 5
            }
            catch {
                Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                    -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
                    -Status 'ERROR' -Detail "Failed to delete existing clone: $_"
                continue
            }
        }
        else {
            # Skip mode: Don't overwrite existing templates unless forced
            Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
                -Status 'SKIPPED' -Detail "Clone '$templateName' already exists (use -ForceReclone to overwrite)"
            continue
        }
    }

    # Handle DryRun early exit
    if ($DryRun) {
        $note = if ($vm.PowerState -eq 'PoweredOn' -and $PowerOffBeforeClone) { "Would power off first, then " } else { "Would " }
        Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
            -TargetDatastore $targetDs.Name -SourcePowerState $vm.PowerState `
            -Status 'DRYRUN' -Detail "${note}clone to '$TargetFolder', then move NICs to '$TemplateNetwork'"
        continue
    }

    # Optional: Power off the source VM before cloning for disk consistency
    $poweredOffByScript = $false
    if ($vm.PowerState -eq 'PoweredOn' -and $PowerOffBeforeClone) {
        try {
            Write-Host "  Powering off $($vm.Name)..." -ForegroundColor Yellow
            # Attempt graceful shutdown via VMware Tools
            Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $deadline = (Get-Date).AddSeconds(120)
            # Wait for shutdown to complete
            do { Start-Sleep -Seconds 5; $vm = Get-VM -Id $vm.Id } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
            # Fallback to hard power off if graceful shutdown fails
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

    # Prepare parameters for the New-VM (Clone) operation
    $cloneParams = @{
        VM          = $vm
        Name        = $templateName
        Location    = $tgtFolder
        Datastore   = $targetDs
        Confirm     = $false
        ErrorAction = 'Stop'
    }
    
    # Resolve placement target (Host or Cluster)
    if ($ClusterOrHost) {
        $resourceTarget = Get-Cluster -Name $ClusterOrHost -ErrorAction SilentlyContinue
        if (-not $resourceTarget) { $resourceTarget = Get-VMHost -Name $ClusterOrHost -ErrorAction SilentlyContinue }
        if ($resourceTarget) {
            # Find a valid Resource Pool for the target
            $rp = $null
            foreach ($pool in (Get-ResourcePool -Location $resourceTarget -ErrorAction SilentlyContinue)) {
                $rp = $pool; break
            }
            if ($rp) { $cloneParams['ResourcePool'] = $rp }
        }
    }
    else {
        # Default: Place the clone on the same host as the source VM
        $cloneParams['VMHost'] = $vm.VMHost
    }

    try {
        # Performance/Stability Phase: Disk Consolidation
        # Consolidate disks if vSphere flags it as needed or if snapshots exist on a powered-on VM
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
                    # Wait for vCenter to release internal file locks
                    Start-Sleep -Seconds 10
                }
            }
        }
        catch { Write-Warning "  Disk consolidation check failed for $($vm.Name): $_" }

        # Perform the actual clone operation
        $clone = $null
        try {
            $clone = New-VM @cloneParams
        }
        catch {
            # Edge case: New-VM might throw a timeout/disconnect error even if the vSphere task succeeds.
            # Verify if the VM exists before reporting a failure.
            $clone = Get-VM -Name $templateName -Location $tgtFolder -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $clone) {
                Add-Result -VMName $vm.Name -TemplateName $templateName -SourceDatastore $srcDs.Name `
                    -TargetDatastore $targetDs.Name -SourcePowerState $originalPowerState `
                    -Status 'ERROR' -Detail "Clone failed: $_"
                continue
            }
        }

        # Step: Isolation Phase
        # Move all Network Adapters on the template to the isolated 'dead-template' network
        if ($TemplateNetwork) {
            try {
                # Attempt to find a matching Distributed Portgroup
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

        # Final Step: Restore original power state if we powered off the source
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

        # Log successful completion for this VM
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

# --- Summary Phase ---
# Aggregate results and display a final report
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

# Optional: Export result data to CSV for auditing
if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
