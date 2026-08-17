<#
.SYNOPSIS
    Reports VM names in a Templates folder and summarizes VM usage in other folders.

.DESCRIPTION
    Connects to vCenter, finds VMs located in the specified Templates folder path,
    and reports where those VMs are placed (folder, cluster, host, datastore, network).

    The script also builds VM-level visibility for all folders and highlights current
    template-scope VMs with live dependency indicators.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER TemplateFolderPath
    Optional. Template folder path or leaf folder name. Default: Templates
    Examples: Templates, Templates/CyberRange, Production/Templates

.PARAMETER IncludeTemplateSubfolders
    Optional switch. Include VMs in child folders under TemplateFolderPath.

.PARAMETER OnlyPoweredOn
    Optional switch. Include only powered-on VMs in outputs. Default: include all VMs.

.PARAMETER OutputFile
    Optional. CSV output path for template-folder VM details.

.PARAMETER OtherFolderSummaryFile
    Optional. CSV output path for non-template folder summary.

.PARAMETER AllVMOutputFile
    Optional. CSV output path for all VM rows across template and non-template folders.

.PARAMETER LinkedToTemplateOutputFile
    Optional. CSV output path for a live template-scope dependency report.

.PARAMETER TemplateUsageSummaryFile
    Optional. CSV output path for template-source usage summary (linked VM counts).

.PARAMETER UnusedTemplateOutputFile
    Optional. CSV output path for template-scope sources with zero linked VMs.

.PARAMETER TemplateDependentVmOutputFile
    Optional. CSV output path for VMs dependent on template-scope VMs via linked-disk parent backing.

.PARAMETER TemplateNoChildVmOutputFile
    Optional. CSV output path for template-scope VMs that have no linked-disk child VMs.
    If omitted while TemplateDependentVmOutputFile is provided, a sibling file is auto-created
    using the dependent report name with -no-child-vms appended.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1
    Reports VMs in the Templates folder and prints other-folder usage summary.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -TemplateFolderPath "Templates/CyberRange" -IncludeTemplateSubfolders
    Includes all child folders below Templates/CyberRange.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -OutputFile "template-vms.csv" -OtherFolderSummaryFile "other-folders.csv"
    Exports both detail and summary reports.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -AllVMOutputFile "all-vms.csv"
    Exports all VMs across template and non-template folders.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -AllVMOutputFile "all-vms.csv" -LinkedToTemplateOutputFile "linked-to-template.csv"
    Exports all VMs and a focused template-scope live dependency report.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -TemplateUsageSummaryFile "template-usage-summary.csv" -UnusedTemplateOutputFile "unused-template-sources.csv"
    Exports per-folder template-scope usage counts and a candidate list with no live dependency indicators.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -TemplateDependentVmOutputFile "template-dependent-vms.csv"
    Exports child VMs that reference template-scope VM disk backing parents.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -TemplateDependentVmOutputFile "template-dependent-vms.csv" -TemplateNoChildVmOutputFile "template-no-child-vms.csv"
    Exports dependent child VMs and template-scope VMs that have no linked-disk child VMs.

.OUTPUTS
        Template-scope inventory columns:
        - Name, ObjectType, FolderPath, IsTemplate, PowerState, Cluster, Host, Datastores,
            Networks, NumCPU, MemoryGB, ProvisionedSpaceGB, UsedSpaceGB, CreateDate

    Other folder summary columns:
    - FolderPath, VMCount, PoweredOnCount, TemplateCount, TotalvCPU, TotalMemoryGB,
      Hosts, Clusters

        All VM detail columns:
        - VMName, FolderPath, InTemplateScope, IsTemplate, PowerState, UsageCategory,
            HasLinkedDiskHint, Cluster, Host, Datastores, Networks,
            NumCPU, MemoryGB, ProvisionedSpaceGB, UsedSpaceGB, CreateDate,
            LiveDependencyCount, LiveDependencySummary, LiveSnapshotCount,
            HasLinkedDiskBacking, HasIsoAttachment, HasRdmBacking

        Template usage summary columns:
        - FolderPath, VMCount, PoweredOnCount, TemplateCount,
            LiveDependencyVMCount, LiveDependencyIndicatorCount, CandidateStatus

        Template-linked VM detail columns:
        - VMName, FolderPath, IsTemplate, PowerState, Cluster, Host, CreateDate,
            LiveDependencyCount, LiveDependencySummary, LiveSnapshotCount,
            HasLinkedDiskBacking, HasIsoAttachment, HasRdmBacking

        Template dependent VM columns:
        - ParentTemplateScopeVMName, ParentTemplateScopeFolderPath,
            ParentVMCreateDate, ChildVMName, ChildVMFolderPath, ChildVMCreateDate,
            ChildCluster, ChildHost, DependencyType

        Template-scope VMs with no child VM columns:
        - TemplateScopeVMName, TemplateScopeFolderPath, TemplateScopeVMCreateDate,
            IsTemplate, PowerState, Cluster, Host, ChildVMCount

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter inventory

    Author: GitHub Copilot
    Version: 1.1
    Date: August 7, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$TemplateFolderPath = 'Templates',

    [Parameter(Mandatory=$false)]
    [switch]$IncludeTemplateSubfolders,

    [Parameter(Mandatory=$false)]
    [switch]$OnlyPoweredOn,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [string]$OtherFolderSummaryFile,

    [Parameter(Mandatory=$false)]
    [string]$AllVMOutputFile,

    [Parameter(Mandatory=$false)]
    [string]$LinkedToTemplateOutputFile,

    [Parameter(Mandatory=$false)]
    [string]$TemplateUsageSummaryFile,

    [Parameter(Mandatory=$false)]
    [string]$UnusedTemplateOutputFile,

    [Parameter(Mandatory=$false)]
    [string]$TemplateDependentVmOutputFile,

    [Parameter(Mandatory=$false)]
    [string]$TemplateNoChildVmOutputFile
)

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

function ConvertTo-NormalizedPathString {
    param([string]$Path)
    return (($Path -replace '\\', '/').Trim('/').Trim())
}

function ConvertTo-NormalizedDatastoreFilePath {
    param([string]$Path)

    if (-not $Path) {
        return $null
    }

    # Normalize path text so backing parent matches are stable across minor format differences.
    $normalized = ($Path -replace '\\', '/').Trim()
    if (-not $normalized) {
        return $null
    }

    return $normalized.ToLowerInvariant()
}

$viewCache = @{}
$pathCache = @{}

function Get-ViewCached {
    param($MoRef)

    if (-not $MoRef) { return $null }
    $key = "$($MoRef.Type):$($MoRef.Value)"

    if ($viewCache.ContainsKey($key)) {
        return $viewCache[$key]
    }

    $view = Get-View -Id $MoRef -Property Name, Parent -ErrorAction SilentlyContinue
    $viewCache[$key] = $view
    return $view
}

function Get-FolderPathFromMoRef {
    param($MoRef)

    if (-not $MoRef) { return 'Unknown' }

    $startKey = "$($MoRef.Type):$($MoRef.Value)"
    if ($pathCache.ContainsKey($startKey)) {
        return $pathCache[$startKey]
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $current = $MoRef
    $guard = 0

    while ($current -and $guard -lt 60) {
        $guard++

        $view = Get-ViewCached -MoRef $current
        if (-not $view) { break }

        if ($view.Name -and $view.Name -ne 'vm') {
            $parts.Insert(0, $view.Name)
        }

        if (-not $view.Parent) { break }
        if ($view.Parent.Type -eq 'Datacenter') { break }

        $current = $view.Parent
    }

    $path = if ($parts.Count -gt 0) { $parts -join '/' } else { 'Unknown' }
    $pathCache[$startKey] = $path
    return $path
}

function Get-SnapshotTreeCount {
    param($SnapshotTree)

    if (-not $SnapshotTree) {
        return 0
    }

    $count = 0
    foreach ($snapshot in @($SnapshotTree)) {
        $count++
        if ($snapshot.ChildSnapshotList) {
            $count += Get-SnapshotTreeCount -SnapshotTree $snapshot.ChildSnapshotList
        }
    }

    return $count
}

function Get-LiveVmDependencySummary {
    param($VmView)

    $dependencyFlags = [System.Collections.Generic.List[string]]::new()
    $snapshotCount = 0
    $hasLinkedDiskBacking = $false
    $hasIsoAttachment = $false
    $hasRdmBacking = $false

    if ($VmView -and $VmView.Snapshot -and $VmView.Snapshot.RootSnapshotList) {
        $snapshotCount = Get-SnapshotTreeCount -SnapshotTree $VmView.Snapshot.RootSnapshotList
        if ($snapshotCount -gt 0) {
            [void]$dependencyFlags.Add("Snapshots($snapshotCount)")
        }
    }

    if ($VmView -and $VmView.Config -and $VmView.Config.Hardware -and $VmView.Config.Hardware.Device) {
        foreach ($device in @($VmView.Config.Hardware.Device)) {
            if ($device -is [VMware.Vim.VirtualDisk]) {
                if ($device.Backing -and $device.Backing.PSObject.Properties['Parent'] -and $device.Backing.Parent) {
                    $hasLinkedDiskBacking = $true
                }

                if ($device.Backing) {
                    $backingTypeName = $device.Backing.GetType().Name
                    if ($backingTypeName -match 'RawDeviceMapping') {
                        $hasRdmBacking = $true
                    }
                }
            }
            elseif ($device -is [VMware.Vim.VirtualCdrom]) {
                $hasConnectedCdrom = $false
                if ($device.Connectable) {
                    $hasConnectedCdrom = [bool]($device.Connectable.Connected -or $device.Connectable.StartConnected)
                }

                if ($device.Backing -and $device.Backing.PSObject.Properties['FileName'] -and $device.Backing.FileName) {
                    $hasIsoAttachment = $true
                }
                elseif ($hasConnectedCdrom) {
                    $hasIsoAttachment = $true
                }
            }
        }
    }

    if ($hasLinkedDiskBacking) {
        [void]$dependencyFlags.Add('LinkedDiskBacking')
    }
    if ($hasIsoAttachment) {
        [void]$dependencyFlags.Add('CdromOrIsoAttached')
    }
    if ($hasRdmBacking) {
        [void]$dependencyFlags.Add('RdmBacking')
    }

    return [PSCustomObject]@{
        LiveDependencyCount    = $dependencyFlags.Count
        LiveDependencySummary  = if ($dependencyFlags.Count -gt 0) { $dependencyFlags -join '; ' } else { 'None' }
        LiveSnapshotCount      = $snapshotCount
        HasLinkedDiskBacking   = $hasLinkedDiskBacking
        HasIsoAttachment      = $hasIsoAttachment
        HasRdmBacking         = $hasRdmBacking
    }
}

Write-Host "Retrieving VM folders and VMs..." -ForegroundColor Cyan
$allFolders = Get-Folder -Type VM -ErrorAction SilentlyContinue
$allVMsAll = Get-VM -ErrorAction SilentlyContinue
$allVMs = $allVMsAll
$allTemplates = Get-Template -ErrorAction SilentlyContinue

if (-not $allFolders) {
    Write-Error "No VM folders were found in inventory."
    exit 1
}
if (-not $allVMs) {
    Write-Error "No VMs were found in inventory."
    exit 1
}

if ($OnlyPoweredOn) {
    $allVMs = $allVMs | Where-Object { $_.PowerState -eq 'PoweredOn' }
    Write-Host "Filtering to powered-on VMs only." -ForegroundColor Yellow
    Write-Host "NOTE: Powered-on filter also limits template usage mapping to powered-on VMs." -ForegroundColor Yellow
}

if (-not $allVMs) {
    Write-Error "No VMs matched the selected power-state filter."
    exit 1
}

$folderLookup = foreach ($folder in $allFolders) {
    [PSCustomObject]@{
        Name = $folder.Name
        Path = Get-FolderPathFromMoRef -MoRef $folder.ExtensionData.MoRef
    }
}

$normalizedTemplatePath = ConvertTo-NormalizedPathString -Path $TemplateFolderPath
$pathLooksQualified = $normalizedTemplatePath.Contains('/')

$matchedFolders = if ($pathLooksQualified) {
    $folderLookup | Where-Object { (ConvertTo-NormalizedPathString -Path $_.Path) -ieq $normalizedTemplatePath }
}
else {
    $folderLookup | Where-Object { $_.Name -ieq $TemplateFolderPath }
}

if (-not $matchedFolders) {
    Write-Error "Template folder '$TemplateFolderPath' was not found."
    Write-Host "Sample VM folder paths:" -ForegroundColor Yellow
    $folderLookup | Sort-Object Path | Select-Object -First 20 -ExpandProperty Path | ForEach-Object {
        Write-Host "  - $_" -ForegroundColor White
    }
    exit 1
}

$templateRootPaths = $matchedFolders | Select-Object -ExpandProperty Path -Unique


function Test-IsInTemplateScope {
    param(
        [string]$CandidateFolderPath,
        [string[]]$RootPaths,
        [bool]$IncludeChildren
    )

    $normalizedFolderPath = ConvertTo-NormalizedPathString -Path $CandidateFolderPath

    foreach ($rootPath in $RootPaths) {
        $normalizedRootPath = ConvertTo-NormalizedPathString -Path $rootPath

        if ($IncludeChildren) {
            if (
                $normalizedFolderPath -ieq $normalizedRootPath -or
                $normalizedFolderPath.StartsWith("$normalizedRootPath/", [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                return $true
            }
        }
        else {
            if ($normalizedFolderPath -ieq $normalizedRootPath) {
                return $true
            }
        }
    }

    return $false
}

Write-Host "Template folder scope:" -ForegroundColor Cyan
$templateRootPaths | ForEach-Object {
    Write-Host "  - $_" -ForegroundColor White
}
if ($IncludeTemplateSubfolders) {
    Write-Host "Including subfolders under template path(s)." -ForegroundColor White
}

$templateObjectIndex = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($tmpl in $allTemplates) {
    $tmplFolderPath = Get-FolderPathFromMoRef -MoRef $tmpl.ExtensionData.Parent
    $tmplInScope = Test-IsInTemplateScope -CandidateFolderPath $tmplFolderPath -RootPaths $templateRootPaths -IncludeChildren $IncludeTemplateSubfolders.IsPresent

    $templateObjectIndex.Add([PSCustomObject]@{
        Name            = $tmpl.Name
        FolderPath      = $tmplFolderPath
        InTemplateScope = $tmplInScope
    })
}

$vmIndex = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vm in $allVMs) {
    $folderPath = Get-FolderPathFromMoRef -MoRef $vm.ExtensionData.Parent
    $inTemplateScope = Test-IsInTemplateScope -CandidateFolderPath $folderPath -RootPaths $templateRootPaths -IncludeChildren $IncludeTemplateSubfolders.IsPresent

    $clusterName = 'StandaloneHost'
    if ($vm.VMHost -and $vm.VMHost.Parent) {
        $clusterName = $vm.VMHost.Parent.Name
    }

    $vmIndex.Add([PSCustomObject]@{
        VMObject       = $vm
        VMName         = $vm.Name
        FolderPath     = $folderPath
        InTemplateScope= $inTemplateScope
        IsTemplate     = [bool]$vm.ExtensionData.Config.Template
        PowerState     = $vm.PowerState
        Cluster        = $clusterName
        Host           = if ($vm.VMHost) { $vm.VMHost.Name } else { 'Unknown' }
        NumCPU         = $vm.NumCpu
        MemoryGB       = [math]::Round($vm.MemoryGB, 1)
    })

}

$templateScopedVMs = $vmIndex | Where-Object { $_.InTemplateScope }
$templateScopedTemplates = $templateObjectIndex | Where-Object { $_.InTemplateScope }
if (-not $templateScopedVMs -and -not $templateScopedTemplates) {
    Write-Warning "No template-scope objects (VMs or templates) were found in the selected folder scope."
}

Write-Host "Collecting detailed data for all VMs..." -ForegroundColor Cyan
$allVMDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmDiskRelationshipIndex = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entry in ($vmIndex | Sort-Object VMName)) {
    $vm = $entry.VMObject

    $datastores = Get-Datastore -RelatedObject $vm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $networks = $vm | Get-NetworkAdapter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NetworkName

    $vmView = $vm | Get-View -Property Config.CreateDate, Config.Hardware.Device, Snapshot, LayoutEx.File -ErrorAction SilentlyContinue
    $createDate = if ($vmView -and $vmView.Config.CreateDate) {
        $vmView.Config.CreateDate.ToString('yyyy-MM-dd HH:mm:ss')
    }
    else {
        'Unknown'
    }

    $usageCategory = if ($entry.IsTemplate) {
        'Template'
    }
    elseif ($entry.PowerState -eq 'PoweredOn') {
        'Running'
    }
    else {
        'PoweredOff'
    }

    # Linked clone hint: if any virtual disk backing references a parent backing file,
    # this VM is likely participating in a linked clone chain.
    $hasLinkedDiskHint = $false
    if ($vmView -and $vmView.Config -and $vmView.Config.Hardware -and $vmView.Config.Hardware.Device) {
        $hasLinkedDiskHint = [bool]($vmView.Config.Hardware.Device | Where-Object {
            $_ -is [VMware.Vim.VirtualDisk] -and
            $_.Backing -and
            $_.Backing.PSObject.Properties['Parent'] -and
            $_.Backing.Parent
        })
    }

    $liveDependency = Get-LiveVmDependencySummary -VmView $vmView

    $diskFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $parentDiskFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allVmFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($vmView -and $vmView.LayoutEx -and $vmView.LayoutEx.File) {
        foreach ($layoutFile in @($vmView.LayoutEx.File)) {
            if (-not $layoutFile) { continue }
            $layoutFileName = $null
            if ($layoutFile.PSObject.Properties['Name']) {
                $layoutFileName = ConvertTo-NormalizedDatastoreFilePath -Path $layoutFile.Name
            }
            if ($layoutFileName) {
                [void]$allVmFileNames.Add($layoutFileName)
            }
        }
    }

    if ($vmView -and $vmView.Config -and $vmView.Config.Hardware -and $vmView.Config.Hardware.Device) {
        foreach ($device in @($vmView.Config.Hardware.Device)) {
            if ($device -is [VMware.Vim.VirtualDisk] -and $device.Backing) {
                if ($device.Backing.PSObject.Properties['FileName'] -and $device.Backing.FileName) {
                    $diskFileName = ConvertTo-NormalizedDatastoreFilePath -Path ([string]$device.Backing.FileName)
                    if ($diskFileName) {
                        [void]$diskFileNames.Add($diskFileName)
                        [void]$allVmFileNames.Add($diskFileName)
                    }
                }

                if (
                    $device.Backing.PSObject.Properties['Parent'] -and
                    $device.Backing.Parent -and
                    $device.Backing.Parent.PSObject.Properties['FileName'] -and
                    $device.Backing.Parent.FileName
                ) {
                    $parentDiskFileName = ConvertTo-NormalizedDatastoreFilePath -Path ([string]$device.Backing.Parent.FileName)
                    if ($parentDiskFileName) {
                        [void]$parentDiskFileNames.Add($parentDiskFileName)
                    }
                }
            }
        }
    }

    $allVMDetails.Add([PSCustomObject]@{
        VMName             = $entry.VMName
        FolderPath         = $entry.FolderPath
        InTemplateScope    = $entry.InTemplateScope
        IsTemplate         = $entry.IsTemplate
        PowerState         = $entry.PowerState
        UsageCategory      = $usageCategory
        HasLinkedDiskHint  = $hasLinkedDiskHint
        LiveDependencyCount = $liveDependency.LiveDependencyCount
        LiveDependencySummary = $liveDependency.LiveDependencySummary
        LiveSnapshotCount   = $liveDependency.LiveSnapshotCount
        HasLinkedDiskBacking = $liveDependency.HasLinkedDiskBacking
        HasIsoAttachment    = $liveDependency.HasIsoAttachment
        HasRdmBacking       = $liveDependency.HasRdmBacking
        Cluster            = $entry.Cluster
        Host               = $entry.Host
        Datastores         = if ($datastores) { ($datastores | Sort-Object -Unique) -join '; ' } else { 'Unknown' }
        Networks           = if ($networks) { ($networks | Where-Object { $_ } | Sort-Object -Unique) -join '; ' } else { 'None' }
        NumCPU             = $entry.NumCPU
        MemoryGB           = $entry.MemoryGB
        ProvisionedSpaceGB = [math]::Round($vm.ProvisionedSpaceGB, 1)
        UsedSpaceGB        = [math]::Round($vm.UsedSpaceGB, 1)
        CreateDate         = $createDate
    })

    $vmDiskRelationshipIndex.Add([PSCustomObject]@{
        VMName              = $entry.VMName
        FolderPath          = $entry.FolderPath
        Cluster             = $entry.Cluster
        Host                = $entry.Host
        InTemplateScope     = $entry.InTemplateScope
        IsTemplate          = $entry.IsTemplate
        CreateDate          = $createDate
        DiskFileNames       = @($diskFileNames)
        AllVmFileNames      = @($allVmFileNames)
        ParentDiskFileNames = @($parentDiskFileNames)
    })
}

$templateScopeVMDetails = $allVMDetails | Where-Object { $_.InTemplateScope }

$templateScopeTemplateDetails =
    $templateObjectIndex |
    Where-Object { $_.InTemplateScope } |
    Sort-Object Name |
    ForEach-Object {
        [PSCustomObject]@{
            Name              = $_.Name
            ObjectType        = 'Template'
            FolderPath        = $_.FolderPath
            IsTemplate        = $true
            PowerState        = 'N/A'
            Cluster           = 'N/A'
            Host              = 'N/A'
            Datastores        = 'N/A'
            Networks          = 'N/A'
            NumCPU            = 'N/A'
            MemoryGB          = 'N/A'
            ProvisionedSpaceGB= 'N/A'
            UsedSpaceGB       = 'N/A'
            CreateDate        = 'Unknown'
        }
    }

$templateScopeVMDisplay =
    $templateScopeVMDetails |
    ForEach-Object {
        [PSCustomObject]@{
            Name              = $_.VMName
            ObjectType        = 'VM'
            FolderPath        = $_.FolderPath
            IsTemplate        = $_.IsTemplate
            PowerState        = $_.PowerState
            Cluster           = $_.Cluster
            Host              = $_.Host
            Datastores        = $_.Datastores
            Networks          = $_.Networks
            NumCPU            = $_.NumCPU
            MemoryGB          = $_.MemoryGB
            ProvisionedSpaceGB= $_.ProvisionedSpaceGB
            UsedSpaceGB       = $_.UsedSpaceGB
            CreateDate        = $_.CreateDate
        }
    }

$templateDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($templateScopeTemplateDetails) {
    foreach ($item in @($templateScopeTemplateDetails)) {
        [void]$templateDetails.Add($item)
    }
}
if ($templateScopeVMDisplay) {
    foreach ($item in @($templateScopeVMDisplay)) {
        [void]$templateDetails.Add($item)
    }
}

$linkedToTemplateRows =
    $templateScopeVMDetails |
    Where-Object {
        -not $_.IsTemplate -and
        $_.LiveDependencyCount -gt 0
    } |
    Sort-Object VMName

$templateLinkedVmRows =
    $templateScopeVMDetails |
    ForEach-Object {
        [PSCustomObject]@{
            VMName               = $_.VMName
            FolderPath           = $_.FolderPath
            IsTemplate           = $_.IsTemplate
            PowerState           = $_.PowerState
            Cluster              = $_.Cluster
            Host                 = $_.Host
            CreateDate           = $_.CreateDate
            LiveDependencyCount  = $_.LiveDependencyCount
            LiveDependencySummary= $_.LiveDependencySummary
            LiveSnapshotCount    = $_.LiveSnapshotCount
            HasLinkedDiskBacking = $_.HasLinkedDiskBacking
            HasIsoAttachment     = $_.HasIsoAttachment
            HasRdmBacking        = $_.HasRdmBacking
        }
    } |
    Sort-Object FolderPath, VMName

$templateScopeParentDiskMap = @{}
foreach ($parentVm in @($vmDiskRelationshipIndex | Where-Object { $_.InTemplateScope })) {
    foreach ($parentFile in @($parentVm.AllVmFileNames)) {
        if (-not $parentFile) { continue }
        if (-not $templateScopeParentDiskMap.ContainsKey($parentFile)) {
            $templateScopeParentDiskMap[$parentFile] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        $templateScopeParentDiskMap[$parentFile].Add([PSCustomObject]@{
            ParentTemplateScopeVMName    = $parentVm.VMName
            ParentTemplateScopeFolderPath= $parentVm.FolderPath
            ParentVMCreateDate           = $parentVm.CreateDate
        })
    }
}

$templateDependentVmRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$templateDependentVmSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($childVm in @($vmDiskRelationshipIndex)) {
    foreach ($parentDiskFile in @($childVm.ParentDiskFileNames)) {
        if (-not $parentDiskFile) { continue }
        if (-not $templateScopeParentDiskMap.ContainsKey($parentDiskFile)) { continue }

        foreach ($parentVm in @($templateScopeParentDiskMap[$parentDiskFile])) {
            if ($childVm.VMName -ieq $parentVm.ParentTemplateScopeVMName) { continue }

            $rowKey = "{0}|{1}|{2}|{3}|{4}" -f $parentVm.ParentTemplateScopeVMName, $parentVm.ParentTemplateScopeFolderPath, $childVm.VMName, $childVm.FolderPath, 'LinkedDiskParent'
            if ($templateDependentVmSeen.Contains($rowKey)) { continue }
            [void]$templateDependentVmSeen.Add($rowKey)

            $templateDependentVmRows.Add([PSCustomObject]@{
                ParentTemplateScopeVMName     = $parentVm.ParentTemplateScopeVMName
                ParentTemplateScopeFolderPath = $parentVm.ParentTemplateScopeFolderPath
                ParentVMCreateDate            = $parentVm.ParentVMCreateDate
                ChildVMName                   = $childVm.VMName
                ChildVMFolderPath             = $childVm.FolderPath
                ChildVMCreateDate             = $childVm.CreateDate
                ChildCluster                  = $childVm.Cluster
                ChildHost                     = $childVm.Host
                DependencyType                = 'LinkedDiskParent'
            })
        }
    }
}

$templateDependentVmRows = $templateDependentVmRows | Sort-Object ParentTemplateScopeVMName, ChildVMName

$templateScopeChildParentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in @($templateDependentVmRows)) {
    $parentKey = "{0}|{1}" -f $row.ParentTemplateScopeVMName, $row.ParentTemplateScopeFolderPath
    [void]$templateScopeChildParentKeys.Add($parentKey)
}

$templateScopeNoChildVmRows =
    $templateScopeVMDetails |
    ForEach-Object {
        $key = "{0}|{1}" -f $_.VMName, $_.FolderPath
        [PSCustomObject]@{
            TemplateScopeVMName       = $_.VMName
            TemplateScopeFolderPath   = $_.FolderPath
            TemplateScopeVMCreateDate = $_.CreateDate
            IsTemplate                = $_.IsTemplate
            PowerState                = $_.PowerState
            Cluster                   = $_.Cluster
            Host                      = $_.Host
            ChildVMCount              = if ($templateScopeChildParentKeys.Contains($key)) { 1 } else { 0 }
        }
    } |
    Where-Object { $_.ChildVMCount -eq 0 } |
    Sort-Object TemplateScopeVMName

$templateUsageSummary =
    $templateScopeVMDetails |
    Group-Object FolderPath |
    ForEach-Object {
        [PSCustomObject]@{
            FolderPath              = $_.Name
            VMCount                 = $_.Count
            PoweredOnCount          = ($_.Group | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
            TemplateCount           = ($_.Group | Where-Object { $_.IsTemplate }).Count
            LiveDependencyVMCount   = ($_.Group | Where-Object { $_.LiveDependencyCount -gt 0 }).Count
            LiveDependencyIndicatorCount = ($_.Group | Measure-Object -Property LiveDependencyCount -Sum).Sum
            CandidateStatus         = if (($_.Group | Where-Object { $_.LiveDependencyCount -gt 0 }).Count -eq 0) { 'NoLiveDependencies' } else { 'InUse' }
        }
    } |
    Sort-Object VMCount -Descending

$unusedTemplateSourceRows =
    $templateUsageSummary |
    Where-Object { $_.LiveDependencyVMCount -eq 0 } |
    Sort-Object FolderPath

$otherFolderSummary =
    $vmIndex |
    Where-Object { -not $_.InTemplateScope } |
    Group-Object FolderPath |
    ForEach-Object {
        $group = $_.Group
        [PSCustomObject]@{
            FolderPath      = $_.Name
            VMCount         = $group.Count
            PoweredOnCount  = ($group | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
            TemplateCount   = ($group | Where-Object { $_.IsTemplate }).Count
            TotalvCPU       = ($group | Measure-Object -Property NumCPU -Sum).Sum
            TotalMemoryGB   = [math]::Round((($group | Measure-Object -Property MemoryGB -Sum).Sum), 1)
            Hosts           = (($group | Select-Object -ExpandProperty Host -Unique | Sort-Object) -join '; ')
            Clusters        = (($group | Select-Object -ExpandProperty Cluster -Unique | Sort-Object) -join '; ')
        }
    } |
    Sort-Object VMCount -Descending

if ($OutputFile) {
    $templateDir = Split-Path -Parent $OutputFile
    if ($templateDir -and -not (Test-Path $templateDir)) {
        New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
    }

    $templateDetails | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Template VM detail exported: $OutputFile" -ForegroundColor Green
}

if ($OtherFolderSummaryFile) {
    $summaryDir = Split-Path -Parent $OtherFolderSummaryFile
    if ($summaryDir -and -not (Test-Path $summaryDir)) {
        New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
    }

    $otherFolderSummary | Export-Csv -Path $OtherFolderSummaryFile -NoTypeInformation -Encoding UTF8
    Write-Host "Other-folder summary exported: $OtherFolderSummaryFile" -ForegroundColor Green
}

if ($AllVMOutputFile) {
    $allDir = Split-Path -Parent $AllVMOutputFile
    if ($allDir -and -not (Test-Path $allDir)) {
        New-Item -ItemType Directory -Path $allDir -Force | Out-Null
    }

    $allVMDetails | Export-Csv -Path $AllVMOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "All VM detail exported: $AllVMOutputFile" -ForegroundColor Green
}

if ($LinkedToTemplateOutputFile) {
    $linkedDir = Split-Path -Parent $LinkedToTemplateOutputFile
    if ($linkedDir -and -not (Test-Path $linkedDir)) {
        New-Item -ItemType Directory -Path $linkedDir -Force | Out-Null
    }

    $templateLinkedVmRows | Export-Csv -Path $LinkedToTemplateOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Linked-to-template report exported: $LinkedToTemplateOutputFile" -ForegroundColor Green
}

if ($TemplateUsageSummaryFile) {
    $usageDir = Split-Path -Parent $TemplateUsageSummaryFile
    if ($usageDir -and -not (Test-Path $usageDir)) {
        New-Item -ItemType Directory -Path $usageDir -Force | Out-Null
    }

    $templateUsageSummary | Export-Csv -Path $TemplateUsageSummaryFile -NoTypeInformation -Encoding UTF8
    Write-Host "Template usage summary exported: $TemplateUsageSummaryFile" -ForegroundColor Green
}

if ($UnusedTemplateOutputFile) {
    $unusedDir = Split-Path -Parent $UnusedTemplateOutputFile
    if ($unusedDir -and -not (Test-Path $unusedDir)) {
        New-Item -ItemType Directory -Path $unusedDir -Force | Out-Null
    }

    $unusedTemplateSourceRows | Export-Csv -Path $UnusedTemplateOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Unused template-source candidates exported: $UnusedTemplateOutputFile" -ForegroundColor Green
}

if ($TemplateDependentVmOutputFile) {
    $depDir = Split-Path -Parent $TemplateDependentVmOutputFile
    if ($depDir -and -not (Test-Path $depDir)) {
        New-Item -ItemType Directory -Path $depDir -Force | Out-Null
    }

    $templateDependentVmRows | Export-Csv -Path $TemplateDependentVmOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Template-dependent VM report exported: $TemplateDependentVmOutputFile" -ForegroundColor Green
}

$effectiveTemplateNoChildVmOutputFile = $TemplateNoChildVmOutputFile
if (-not $effectiveTemplateNoChildVmOutputFile -and $TemplateDependentVmOutputFile) {
    $depDir = Split-Path -Parent $TemplateDependentVmOutputFile
    $depFileName = [System.IO.Path]::GetFileNameWithoutExtension($TemplateDependentVmOutputFile)
    $depFileExt = [System.IO.Path]::GetExtension($TemplateDependentVmOutputFile)
    if (-not $depFileExt) {
        $depFileExt = '.csv'
    }

    $autoNoChildFileName = "{0}-no-child-vms{1}" -f $depFileName, $depFileExt
    $effectiveTemplateNoChildVmOutputFile = if ($depDir) {
        Join-Path -Path $depDir -ChildPath $autoNoChildFileName
    }
    else {
        $autoNoChildFileName
    }
}

if ($effectiveTemplateNoChildVmOutputFile) {
    $noChildDir = Split-Path -Parent $effectiveTemplateNoChildVmOutputFile
    if ($noChildDir -and -not (Test-Path $noChildDir)) {
        New-Item -ItemType Directory -Path $noChildDir -Force | Out-Null
    }

    $templateScopeNoChildVmRows | Export-Csv -Path $effectiveTemplateNoChildVmOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Template-scope no-child VM report exported: $effectiveTemplateNoChildVmOutputFile" -ForegroundColor Green
}

Write-Host "`n=== Template Folder VM Report ===" -ForegroundColor Cyan
Write-Host "  Template scope paths : $($templateRootPaths.Count)" -ForegroundColor White
Write-Host "  Objects in scope     : $($templateDetails.Count)" -ForegroundColor White
Write-Host "  Templates in scope   : $(($templateDetails | Where-Object { $_.ObjectType -eq 'Template' }).Count)" -ForegroundColor White
Write-Host "  VMs in scope         : $(($templateDetails | Where-Object { $_.ObjectType -eq 'VM' }).Count)" -ForegroundColor White
Write-Host "  Powered-on VMs       : $(($templateDetails | Where-Object { $_.ObjectType -eq 'VM' -and $_.PowerState -eq 'PoweredOn' }).Count)" -ForegroundColor White
Write-Host "  Template-scope VMs   : $($templateScopeVMDetails.Count)" -ForegroundColor White
Write-Host "  Template-linked VMs  : $($templateLinkedVmRows.Count)" -ForegroundColor White
Write-Host "  Live dependencies    : $(($templateScopeVMDetails | Where-Object { $_.LiveDependencyCount -gt 0 }).Count)" -ForegroundColor White
Write-Host "  Linked-disk hint     : $(($allVMDetails | Where-Object { $_.HasLinkedDiskHint }).Count)" -ForegroundColor White
Write-Host "  In-scope dependencies: $($linkedToTemplateRows.Count)" -ForegroundColor White
Write-Host "  In-use folders       : $(($templateUsageSummary | Where-Object { $_.CandidateStatus -eq 'InUse' }).Count)" -ForegroundColor White
Write-Host "  Unused candidates    : $($unusedTemplateSourceRows.Count)" -ForegroundColor White
Write-Host "  Dependent VMs        : $(@($templateDependentVmRows).Count)" -ForegroundColor White
Write-Host "  No-child VMs         : $(@($templateScopeNoChildVmRows).Count)" -ForegroundColor White

if ($templateDetails.Count -gt 0) {
    Write-Host "`nTemplate-scope objects:" -ForegroundColor Yellow
    $templateDetails | Select-Object Name, ObjectType, FolderPath, IsTemplate, PowerState, Cluster, Host | Format-Table -AutoSize
}

Write-Host "`n=== Other Folder Usage Summary (Top 25 by VM count) ===" -ForegroundColor Cyan
if ($otherFolderSummary.Count -eq 0) {
    Write-Host "No non-template folders with VMs were found." -ForegroundColor Yellow
}
else {
    $otherFolderSummary | Select-Object -First 25 FolderPath, VMCount, PoweredOnCount, TemplateCount, TotalvCPU, TotalMemoryGB | Format-Table -AutoSize
}

Write-Host "`n=== Template Usage Comparison (Top 50 running non-template VMs) ===" -ForegroundColor Cyan
$comparisonRows = $allVMDetails |
    Where-Object { -not $_.InTemplateScope -and -not $_.IsTemplate -and $_.PowerState -eq 'PoweredOn' } |
    Sort-Object VMName

if ($comparisonRows.Count -eq 0) {
    Write-Host "No running non-template VMs found outside template scope." -ForegroundColor Yellow
}
else {
    $comparisonRows |
    Select-Object -First 50 VMName, FolderPath, PowerState, LiveDependencyCount, LiveDependencySummary, LiveSnapshotCount, Cluster, Host |
        Format-Table -AutoSize
}

Write-Host "`n=== Template-Scope VMs With Live Dependencies (Top 100) ===" -ForegroundColor Cyan
if ($linkedToTemplateRows.Count -eq 0) {
    Write-Host "No template-scope VMs showed live dependency indicators." -ForegroundColor Yellow
}
else {
    $linkedToTemplateRows |
        Select-Object -First 100 VMName, FolderPath, PowerState, Cluster, Host, LiveDependencySummary |
        Format-Table -AutoSize
}

Write-Host "`n=== Template-Linked VM CSV Rows (Top 100) ===" -ForegroundColor Cyan
if ($templateLinkedVmRows.Count -eq 0) {
    Write-Host "No template-linked VM rows were identified." -ForegroundColor Yellow
}
else {
    $templateLinkedVmRows |
    Select-Object -First 100 VMName, FolderPath, IsTemplate, PowerState, Cluster, Host, CreateDate, LiveDependencySummary |
        Format-Table -AutoSize
}

Write-Host "`n=== Template Scope Usage Summary (Top 100 by VM count) ===" -ForegroundColor Cyan
if ($templateUsageSummary.Count -eq 0) {
    Write-Host "No template-scope folders were found." -ForegroundColor Yellow
}
else {
    $templateUsageSummary |
        Sort-Object VMCount -Descending |
        Select-Object -First 100 FolderPath, VMCount, PoweredOnCount, TemplateCount, LiveDependencyVMCount, LiveDependencyIndicatorCount, CandidateStatus |
        Format-Table -AutoSize
}

Write-Host "`n=== Template-Scope Folders Without Live Dependencies ===" -ForegroundColor Cyan
if ($unusedTemplateSourceRows.Count -eq 0) {
    Write-Host "No template-scope folders without live dependencies were identified." -ForegroundColor Green
}
else {
    $unusedTemplateSourceRows |
        Select-Object -First 100 FolderPath, VMCount, PoweredOnCount, TemplateCount, LiveDependencyVMCount, LiveDependencyIndicatorCount |
        Format-Table -AutoSize
}

Write-Host "`n=== VMs Dependent On Template-Scope VMs (Top 100) ===" -ForegroundColor Cyan
if (@($templateDependentVmRows).Count -eq 0) {
    Write-Host "No linked-disk parent dependencies were found from template-scope VMs." -ForegroundColor Yellow
}
else {
    $templateDependentVmRows |
    Select-Object -First 100 ParentTemplateScopeVMName, ParentTemplateScopeFolderPath, ParentVMCreateDate, ChildVMName, ChildVMFolderPath, ChildVMCreateDate, ChildCluster, ChildHost, DependencyType |
        Format-Table -AutoSize
}

Write-Host "`n=== Template-Scope VMs Without Child VMs (Top 100) ===" -ForegroundColor Cyan
if (@($templateScopeNoChildVmRows).Count -eq 0) {
    Write-Host "No template-scope VMs without child VMs were found." -ForegroundColor Yellow
}
else {
    $templateScopeNoChildVmRows |
        Select-Object -First 100 TemplateScopeVMName, TemplateScopeFolderPath, TemplateScopeVMCreateDate, IsTemplate, PowerState, Cluster, Host, ChildVMCount |
        Format-Table -AutoSize
}