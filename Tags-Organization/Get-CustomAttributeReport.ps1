<#
.SYNOPSIS
    Reports custom attribute definitions and their values across all entity types.

.DESCRIPTION
    Enumerates all custom attribute definitions in vCenter, then queries the attribute
    values for VMs, ESXi hosts, datastores, and clusters. Useful for validating
    that CMDB fields, backup timestamps, owner metadata, and other custom fields
    are populated correctly.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the custom attribute report as CSV.

.PARAMETER EntityType
    Optional. Filter report to a specific entity type.
    Valid values: All, VM, VMHost, Datastore, Cluster.

.PARAMETER AttributeName
    Optional. Filter report to a specific attribute name.

.EXAMPLE
    .\Get-CustomAttributeReport.ps1 -OutputFile "custom-attributes.csv"
    Exports all custom attribute values across all entity types.

.EXAMPLE
    .\Get-CustomAttributeReport.ps1 -AttributeName "LastBackupDate" -EntityType VM -OutputFile "backup-dates.csv"
    Exports the LastBackupDate attribute for all VMs.

.OUTPUTS
    CSV with columns: EntityName, EntityType, AttributeName, AttributeValue, IsEmpty

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to entity custom fields

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
    [ValidateSet('All', 'VM', 'VMHost', 'Datastore', 'Cluster')]
    [string]$EntityType = 'All',

    [Parameter(Mandatory=$false)]
    [string]$AttributeName
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

# Get all custom attribute definitions
$allAttributes = Get-CustomAttribute -ErrorAction SilentlyContinue
if ($AttributeName) {
    $allAttributes = $allAttributes | Where-Object { $_.Name -eq $AttributeName }
}
Write-Host "Found $($allAttributes.Count) custom attribute definition(s)" -ForegroundColor Cyan

$entities = [System.Collections.Generic.List[object]]::new()
if ($EntityType -in 'All', 'VM')        { Get-VM        -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'VMHost')    { Get-VMHost    -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'Datastore') { Get-Datastore -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }
if ($EntityType -in 'All', 'Cluster')   { Get-Cluster   -ErrorAction SilentlyContinue | ForEach-Object { $entities.Add($_) } }

Write-Host "Querying attribute values for $($entities.Count) entities..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$idx = 0

foreach ($entity in ($entities | Sort-Object { $_.GetType().Name }, Name)) {
    $idx++
    if ($idx % 100 -eq 0) {
        Write-Progress -Activity "Reading custom attributes" -Status "Entity $idx/$($entities.Count)" -PercentComplete ($idx / $entities.Count * 100)
    }

    $entityTypeName = $entity.GetType().Name

    foreach ($attr in $allAttributes) {
        # Skip attributes not applicable to this entity type
        if ($attr.TargetType -and $attr.TargetType -ne 'All' -and $attr.TargetType -ne $entityTypeName) { continue }

        try {
            $annotation = Get-Annotation -Entity $entity -CustomAttribute $attr -ErrorAction SilentlyContinue
            $value = if ($annotation) { $annotation.Value } else { '' }

            $results.Add([PSCustomObject]@{
                EntityName     = $entity.Name
                EntityType     = $entityTypeName
                AttributeName  = $attr.Name
                AttributeValue = $value
                IsEmpty        = [string]::IsNullOrWhiteSpace($value)
            })
        }
        catch { Write-Verbose "Skipped entity '$($entity.Name)': $_" }
    }
}

Write-Progress -Activity "Reading custom attributes" -Completed

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$empty    = ($results | Where-Object { $_.IsEmpty -eq $true }).Count
$populated= ($results | Where-Object { $_.IsEmpty -eq $false }).Count

Write-Host "`n=== Custom Attribute Report Summary ===" -ForegroundColor Cyan
Write-Host "  Attributes Defined : $($allAttributes.Count)"  -ForegroundColor White
Write-Host "  Total Records      : $($results.Count)"         -ForegroundColor White
Write-Host "  Populated          : $populated"                 -ForegroundColor Green
Write-Host "  Empty              : $empty"                     -ForegroundColor $(if ($empty -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output             : $OutputFile"                -ForegroundColor White
