<#
.SYNOPSIS
    Exports all vSphere tags, tag categories, and tag assignments to CSV.

.DESCRIPTION
    Enumerates all tag categories and tags in vCenter, then queries tag assignments
    across all entity types (VMs, hosts, datastores, clusters, networks).
    Useful for validating tagging standards, auditing compliance, and bulk tag
    management planning.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the tag inventory as CSV.

.PARAMETER EntityType
    Optional. Filter assignments to a specific entity type.
    Valid values: All, VM, VMHost, Datastore, Cluster, Network.

.EXAMPLE
    .\Get-TagInventory.ps1 -OutputFile "tag-inventory.csv"
    Exports all tags and assignments to CSV.

.EXAMPLE
    .\Get-TagInventory.ps1 -EntityType VM -OutputFile "vm-tags.csv"
    Exports only VM tag assignments.

.OUTPUTS
    Two CSV files: [OutputFile] for assignments, [OutputFile_categories.csv] for category definitions.

.NOTES
    Requires:
    - VMware PowerCLI module (including VMware.VimAutomation.Core)
    - Tag management privileges

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'VM', 'VMHost', 'Datastore', 'Cluster', 'Network')]
    [string]$EntityType = 'All'
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

Write-Host "Enumerating tag categories and tags..." -ForegroundColor Cyan

# Export categories
$categories = Get-TagCategory -ErrorAction SilentlyContinue
$catResults = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($cat in ($categories | Sort-Object Name)) {
    $catResults.Add([PSCustomObject]@{
        CategoryName  = $cat.Name
        Description   = $cat.Description
        Cardinality   = $cat.Cardinality
        EntityTypes   = ($cat.EntityType | Sort-Object) -join ','
        TagCount      = (Get-Tag -Category $cat -ErrorAction SilentlyContinue).Count
    })
}

$categoryFile = [System.IO.Path]::ChangeExtension($OutputFile, $null).TrimEnd('.') + '_categories.csv'
$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
$catResults | Export-Csv -Path $categoryFile -NoTypeInformation
Write-Host "  Exported $($catResults.Count) categories to: $categoryFile" -ForegroundColor Yellow

# Enumerate assignment entities
Write-Host "Querying tag assignments..." -ForegroundColor Cyan

$entities = [System.Collections.Generic.List[object]]::new()

if ($EntityType -in 'All', 'VM')        { Get-VM        -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'VMHost')    { Get-VMHost    -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'Datastore') { Get-Datastore -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'Cluster')   { Get-Cluster   -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'Network')   { Get-VDPortgroup -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$entityIndex = 0

foreach ($entity in $entities) {
    $entityIndex++
    if ($entityIndex % 50 -eq 0) {
        Write-Progress -Activity "Querying tag assignments" -Status "Entity $entityIndex/$($entities.Count)" -PercentComplete ($entityIndex / $entities.Count * 100)
    }

    try {
        $tags = Get-TagAssignment -Entity $entity -ErrorAction SilentlyContinue
        foreach ($ta in $tags) {
            $results.Add([PSCustomObject]@{
                EntityName    = $entity.Name
                EntityType    = $entity.GetType().Name
                TagName       = $ta.Tag.Name
                CategoryName  = $ta.Tag.Category.Name
                CategoryCardinality = $ta.Tag.Category.Cardinality
                TagDescription= $ta.Tag.Description
            })
        }
        # Entities with no tags
        if (-not $tags) {
            $results.Add([PSCustomObject]@{
                EntityName    = $entity.Name
                EntityType    = $entity.GetType().Name
                TagName       = '(No Tags)'
                CategoryName  = 'N/A'
                CategoryCardinality = 'N/A'
                TagDescription= 'N/A'
            })
        }
    }
    catch { Write-Verbose "Skipped entity '$($entity.Name)': $_" }
}

Write-Progress -Activity "Querying tag assignments" -Completed

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$tagged    = ($results | Where-Object { $_.TagName -ne '(No Tags)' } | Select-Object -ExpandProperty EntityName -Unique).Count
$untagged  = ($results | Where-Object { $_.TagName -eq '(No Tags)' }).Count

Write-Host "`n=== Tag Inventory Summary ===" -ForegroundColor Cyan
Write-Host "  Categories       : $($catResults.Count)"  -ForegroundColor White
Write-Host "  Total Assignments: $(($results | Where-Object { $_.TagName -ne '(No Tags)' }).Count)" -ForegroundColor White
Write-Host "  Tagged Entities  : $tagged"    -ForegroundColor White
Write-Host "  Untagged Entities: $untagged"  -ForegroundColor $(if ($untagged -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output           : $OutputFile" -ForegroundColor White
