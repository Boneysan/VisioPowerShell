<#
.SYNOPSIS
    Reports VM names in a Templates folder and summarizes VM usage in other folders.

.DESCRIPTION
    Connects to vCenter, finds VMs located in the specified Templates folder path,
    and reports where those VMs are placed (folder, cluster, host, datastore, network).

    The script also builds VM-level visibility for all folders and highlights non-template
    VMs that are linked to template-folder VMs via clone/deploy source history.

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
    Optional. CSV output path for non-template VMs linked to template-folder VMs.

.PARAMETER SourceLookbackDays
    Optional. Number of days of vCenter events to search when mapping VMs to source
    templates or source VMs. Default: 365.

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
    .\Get-TemplateFolderUsage.ps1 -OnlyPoweredOn -SourceLookbackDays 730
    Includes only running VMs and searches 2 years of clone/deploy history.

.EXAMPLE
    .\Get-TemplateFolderUsage.ps1 -AllVMOutputFile "all-vms.csv" -LinkedToTemplateOutputFile "linked-to-template.csv"
    Exports all VMs and a focused linked-to-template report.

.OUTPUTS
    Template VM details columns:
    - VMName, FolderPath, IsTemplate, PowerState, Cluster, Host, Datastores, Networks,
      NumCPU, MemoryGB, ProvisionedSpaceGB, UsedSpaceGB, CreateDate

    Other folder summary columns:
    - FolderPath, VMCount, PoweredOnCount, TemplateCount, TotalvCPU, TotalMemoryGB,
      Hosts, Clusters

        All VM detail columns:
        - VMName, FolderPath, InTemplateScope, IsTemplate, PowerState, UsageCategory,
            SourceType, SourceName, SourceFoundVia, HasLinkedDiskHint,
            LinkedToTemplateScope, LinkedTemplateName, Cluster, Host, Datastores, Networks,
            NumCPU, MemoryGB, ProvisionedSpaceGB, UsedSpaceGB, CreateDate

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter inventory

    Author: GitHub Copilot
    Version: 1.0
    Date: August 6, 2026
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
    [ValidateRange(1, 3650)]
    [int]$SourceLookbackDays = 365
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

Write-Host "Retrieving VM folders and VMs..." -ForegroundColor Cyan
$allFolders = Get-Folder -Type VM -ErrorAction SilentlyContinue
$allVMs = Get-VM -ErrorAction SilentlyContinue

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
$templateNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

Write-Host "Template folder scope:" -ForegroundColor Cyan
$templateRootPaths | ForEach-Object {
    Write-Host "  - $_" -ForegroundColor White
}
if ($IncludeTemplateSubfolders) {
    Write-Host "Including subfolders under template path(s)." -ForegroundColor White
}

# Build source relationship index from vCenter events.
# NOTE: vSphere does not always keep a permanent template-origin link on VM objects,
# so event history is used when available.
$sourceByVmName = @{}
try {
    $startEventTime = (Get-Date).AddDays(-$SourceLookbackDays)
    Write-Host "Building source map from clone/deploy events since $($startEventTime.ToString('yyyy-MM-dd'))..." -ForegroundColor Cyan
    $sourceEvents = Get-VIEvent -Start $startEventTime -MaxSamples 200000 -ErrorAction Stop |
        Where-Object {
            $_ -is [VMware.Vim.VmClonedEvent] -or
            $_ -is [VMware.Vim.VmBeingDeployedEvent] -or
            $_ -is [VMware.Vim.VmDeployedEvent]
        } |
        Sort-Object CreatedTime -Descending

    foreach ($evt in $sourceEvents) {
        $targetName = $null
        if ($evt.Vm -and $evt.Vm.Name) { $targetName = $evt.Vm.Name }
        if (-not $targetName) { continue }
        if ($sourceByVmName.ContainsKey($targetName)) { continue }

        $sourceType = 'Unknown'
        $sourceName = 'Unknown'
        $foundVia = $evt.GetType().Name

        if ($evt.PSObject.Properties['SourceTemplate'] -and $evt.SourceTemplate -and $evt.SourceTemplate.Name) {
            $sourceType = 'Template'
            $sourceName = $evt.SourceTemplate.Name
        }
        elseif ($evt.PSObject.Properties['SourceVm'] -and $evt.SourceVm -and $evt.SourceVm.Name) {
            $sourceType = 'VM'
            $sourceName = $evt.SourceVm.Name
        }
        elseif ($evt.PSObject.Properties['Source'] -and $evt.Source) {
            if ($evt.Source.Name) {
                $sourceType = 'SourceObject'
                $sourceName = $evt.Source.Name
            }
        }
        elseif ($evt.FullFormattedMessage) {
            if ($evt.FullFormattedMessage -match "from template '([^']+)'") {
                $sourceType = 'Template'
                $sourceName = $Matches[1]
            }
            elseif ($evt.FullFormattedMessage -match "from VM '([^']+)'") {
                $sourceType = 'VM'
                $sourceName = $Matches[1]
            }
        }

        $sourceByVmName[$targetName] = [PSCustomObject]@{
            SourceType  = $sourceType
            SourceName  = $sourceName
            SourceFoundVia = $foundVia
            EventTime   = $evt.CreatedTime
        }
    }

    Write-Host "  Source mappings found: $($sourceByVmName.Count)" -ForegroundColor White
}
catch {
    Write-Warning "Unable to build source map from events: $_"
}

$vmIndex = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vm in $allVMs) {
    $folderPath = Get-FolderPathFromMoRef -MoRef $vm.ExtensionData.Parent
    $normalizedFolderPath = ConvertTo-NormalizedPathString -Path $folderPath

    $inTemplateScope = $false
    foreach ($rootPath in $templateRootPaths) {
        $normalizedRootPath = ConvertTo-NormalizedPathString -Path $rootPath

        if ($IncludeTemplateSubfolders) {
            if ($normalizedFolderPath -ieq $normalizedRootPath -or $normalizedFolderPath.StartsWith("$normalizedRootPath/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $inTemplateScope = $true
                break
            }
        }
        else {
            if ($normalizedFolderPath -ieq $normalizedRootPath) {
                $inTemplateScope = $true
                break
            }
        }
    }

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

    if ($inTemplateScope) {
        [void]$templateNameSet.Add($vm.Name)
    }
}

$templateScopedVMs = $vmIndex | Where-Object { $_.InTemplateScope }
if (-not $templateScopedVMs) {
    Write-Warning "No VMs found in the selected template folder scope."
}

Write-Host "Collecting detailed data for all VMs..." -ForegroundColor Cyan
$allVMDetails = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entry in ($vmIndex | Sort-Object VMName)) {
    $vm = $entry.VMObject

    $datastores = Get-Datastore -RelatedObject $vm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $networks = $vm | Get-NetworkAdapter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NetworkName

    $vmView = $vm | Get-View -Property Config.CreateDate -ErrorAction SilentlyContinue
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

    $sourceType = 'Unknown'
    $sourceName = 'Unknown'
    $sourceFoundVia = 'None'
    if ($sourceByVmName.ContainsKey($entry.VMName)) {
        $sourceType = $sourceByVmName[$entry.VMName].SourceType
        $sourceName = $sourceByVmName[$entry.VMName].SourceName
        $sourceFoundVia = $sourceByVmName[$entry.VMName].SourceFoundVia
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

    $linkedToTemplateScope = $false
    $linkedTemplateName = 'Unknown'
    if ($sourceType -eq 'Template' -and $templateNameSet.Contains($sourceName)) {
        $linkedToTemplateScope = $true
        $linkedTemplateName = $sourceName
    }

    $allVMDetails.Add([PSCustomObject]@{
        VMName             = $entry.VMName
        FolderPath         = $entry.FolderPath
        InTemplateScope    = $entry.InTemplateScope
        IsTemplate         = $entry.IsTemplate
        PowerState         = $entry.PowerState
        UsageCategory      = $usageCategory
        SourceType         = $sourceType
        SourceName         = $sourceName
        SourceFoundVia     = $sourceFoundVia
        HasLinkedDiskHint  = $hasLinkedDiskHint
        LinkedToTemplateScope = $linkedToTemplateScope
        LinkedTemplateName = $linkedTemplateName
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
}

$templateDetails = $allVMDetails | Where-Object { $_.InTemplateScope }

$linkedToTemplateRows =
    $allVMDetails |
    Where-Object {
        -not $_.InTemplateScope -and
        -not $_.IsTemplate -and
        $_.LinkedToTemplateScope
    } |
    Sort-Object VMName

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

    $linkedToTemplateRows | Export-Csv -Path $LinkedToTemplateOutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Linked-to-template report exported: $LinkedToTemplateOutputFile" -ForegroundColor Green
}

Write-Host "`n=== Template Folder VM Report ===" -ForegroundColor Cyan
Write-Host "  Template scope paths : $($templateRootPaths.Count)" -ForegroundColor White
Write-Host "  VMs in scope         : $($templateDetails.Count)" -ForegroundColor White
Write-Host "  Marked as templates  : $(($templateDetails | Where-Object { $_.IsTemplate }).Count)" -ForegroundColor White
Write-Host "  Powered on           : $(($templateDetails | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count)" -ForegroundColor White
Write-Host "  Source mapped        : $(($allVMDetails | Where-Object { $_.SourceName -ne 'Unknown' }).Count)" -ForegroundColor White
Write-Host "  Linked-disk hint     : $(($allVMDetails | Where-Object { $_.HasLinkedDiskHint }).Count)" -ForegroundColor White
Write-Host "  Linked to templates  : $($linkedToTemplateRows.Count)" -ForegroundColor White

if ($templateDetails.Count -gt 0) {
    Write-Host "`nTemplate-scope VM names:" -ForegroundColor Yellow
    $templateDetails | Select-Object VMName, FolderPath, IsTemplate, PowerState, Cluster, Host | Format-Table -AutoSize
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
    Where-Object { -not $_.InTemplateScope -and -not $_.IsTemplate } |
    Sort-Object VMName

if ($comparisonRows.Count -eq 0) {
    Write-Host "No running non-template VMs found outside template scope." -ForegroundColor Yellow
}
else {
    $comparisonRows |
        Select-Object -First 50 VMName, FolderPath, PowerState, SourceType, SourceName, LinkedToTemplateScope, LinkedTemplateName, HasLinkedDiskHint, Cluster, Host |
        Format-Table -AutoSize
}

Write-Host "`n=== Non-Template VMs Linked To Template Folder (Top 100) ===" -ForegroundColor Cyan
if ($linkedToTemplateRows.Count -eq 0) {
    Write-Host "No non-template VMs were mapped to template-folder VMs in event history." -ForegroundColor Yellow
}
else {
    $linkedToTemplateRows |
        Select-Object -First 100 VMName, FolderPath, LinkedTemplateName, SourceFoundVia, PowerState, Cluster, Host |
        Format-Table -AutoSize
}
