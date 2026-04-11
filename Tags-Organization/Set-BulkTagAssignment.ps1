<#
.SYNOPSIS
    Bulk applies or removes vSphere tags from entities using a CSV input file.

.DESCRIPTION
    Reads a CSV file mapping entities to tags and performs bulk apply or remove
    operations. The CSV must contain EntityName, EntityType, TagName, and
    CategoryName columns. Reports success/failure for each assignment and
    supports a DryRun mode to validate inputs without making changes.

.PARAMETER InputFile
    Required. Path to the input CSV file with columns: EntityName, EntityType, TagName, CategoryName.

.PARAMETER Action
    Optional. Whether to apply or remove the specified tags. Default: Apply.
    Valid values: Apply, Remove.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Optional. Path to export the bulk operation results log as CSV.

.PARAMETER DryRun
    Optional switch. Validates inputs and shows what would happen without making changes.

.EXAMPLE
    .\Set-BulkTagAssignment.ps1 -InputFile "tag-assignments.csv" -OutputFile "tag-results.csv"
    Applies tags as defined in the CSV input file.

.EXAMPLE
    .\Set-BulkTagAssignment.ps1 -InputFile "tag-assignments.csv" -Action Remove -DryRun
    Dry-run simulation of removing tags defined in the CSV.

.OUTPUTS
    CSV with columns: EntityName, EntityType, TagName, CategoryName, Action, Result, Message

.NOTES
    Requires:
    - VMware PowerCLI module (including tag management cmdlets)
    - Tag management privileges

    Input CSV format:
        EntityName,EntityType,TagName,CategoryName
        vm01,VM,Production,Environment
        esxi01.lab.local,VMHost,Tier1,ServiceLevel

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Apply', 'Remove')]
    [string]$Action = 'Apply',

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
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

if (-not (Test-Path $InputFile)) {
    Write-Error "Input file not found: $InputFile"
    exit 1
}

$inputRows = Import-Csv -Path $InputFile
$requiredCols = @('EntityName', 'EntityType', 'TagName', 'CategoryName')
foreach ($col in $requiredCols) {
    if ($col -notin $inputRows[0].PSObject.Properties.Name) {
        Write-Error "Input CSV missing required column: $col"
        exit 1
    }
}

Write-Host "Processing $($inputRows.Count) tag assignment row(s)... [Action: $Action | DryRun: $DryRun]" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $inputRows) {
    $result  = 'SUCCESS'
    $message = ''

    # Find entity
    $entity = $null
    try {
        $entity = switch ($row.EntityType) {
            'VM'        { Get-VM        -Name $row.EntityName -ErrorAction Stop }
            'VMHost'    { Get-VMHost    -Name $row.EntityName -ErrorAction Stop }
            'Datastore' { Get-Datastore -Name $row.EntityName -ErrorAction Stop }
            'Cluster'   { Get-Cluster   -Name $row.EntityName -ErrorAction Stop }
            default     { throw "Unsupported EntityType '$($row.EntityType)'" }
        }
    }
    catch {
        $result  = 'FAILED'
        $message = "Entity not found: $_"
    }

    # Find tag
    $tag = $null
    if ($entity) {
        try {
            $tag = Get-Tag -Name $row.TagName -Category $row.CategoryName -ErrorAction Stop
        }
        catch {
            $result  = 'FAILED'
            $message = "Tag not found: '$($row.TagName)' in category '$($row.CategoryName)'"
        }
    }

    # Perform action
    if ($entity -and $tag -and $result -ne 'FAILED') {
        if ($DryRun) {
            $result  = 'DRYRUN'
            $message = "Would $Action tag '$($row.TagName)' on $($row.EntityType) '$($row.EntityName)'"
        }
        else {
            try {
                if ($Action -eq 'Apply') {
                    $existing = Get-TagAssignment -Entity $entity -Tag $tag -ErrorAction SilentlyContinue
                    if ($existing) {
                        $result  = 'SKIPPED'
                        $message = 'Tag already assigned'
                    }
                    else {
                        New-TagAssignment -Entity $entity -Tag $tag -ErrorAction Stop | Out-Null
                        $message = "Tag applied successfully"
                    }
                }
                else {
                    $existing = Get-TagAssignment -Entity $entity -Tag $tag -ErrorAction SilentlyContinue
                    if ($existing) {
                        Remove-TagAssignment -TagAssignment $existing -Confirm:$false -ErrorAction Stop | Out-Null
                        $message = "Tag removed successfully"
                    }
                    else {
                        $result  = 'SKIPPED'
                        $message = 'Tag was not assigned'
                    }
                }
            }
            catch {
                $result  = 'FAILED'
                $message = $_.Exception.Message
            }
        }
    }

    $results.Add([PSCustomObject]@{
        EntityName   = $row.EntityName
        EntityType   = $row.EntityType
        TagName      = $row.TagName
        CategoryName = $row.CategoryName
        Action       = $Action
        Result       = $result
        Message      = $message
    })

    $color = switch ($result) { 'SUCCESS' { 'Green' } 'FAILED' { 'Red' } 'SKIPPED' { 'Yellow' } default { 'Cyan' } }
    Write-Host "  [$result] $($row.EntityType)/$($row.EntityName) -> $($row.TagName)" -ForegroundColor $color
}

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}

$success = ($results | Where-Object { $_.Result -eq 'SUCCESS' }).Count
$failed  = ($results | Where-Object { $_.Result -eq 'FAILED'  }).Count
$skipped = ($results | Where-Object { $_.Result -eq 'SKIPPED' }).Count

Write-Host "`n=== Bulk Tag Assignment Summary ===" -ForegroundColor Cyan
Write-Host "  Success : $success" -ForegroundColor Green
Write-Host "  Failed  : $failed"  -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped : $skipped" -ForegroundColor Yellow
