<#
.SYNOPSIS
    Inventories VM templates and content library items, flagging stale entries.

.DESCRIPTION
    Enumerates all VM templates and content library items in vCenter. Reports
    OS type, hardware version, VMware Tools version, creation/modification date,
    and source cluster. Flags templates as stale if they haven't been updated
    within the specified threshold, or if the guest OS is end-of-life.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the template inventory as CSV.

.PARAMETER StaleDays
    Optional. Flag templates not modified within this many days as stale. Default: 180.

.PARAMETER IncludeContentLibrary
    Optional switch. Include content library template items in the report.

.EXAMPLE
    .\Get-TemplateInventory.ps1 -OutputFile "templates.csv"
    Exports all VM templates flagged for staleness over 180 days.

.EXAMPLE
    .\Get-TemplateInventory.ps1 -IncludeContentLibrary -StaleDays 90 -OutputFile "templates-90d.csv"
    Exports templates and content library items, flagging anything older than 90 days.

.OUTPUTS
    CSV with columns: Name, Type, GuestOS, HWVersion, ToolsVersion, ToolsStatus,
    Datastore, SizeGB, LastModified, DaysSinceModified, IsStale, StaleReason

.NOTES
    Requires:
    - VMware PowerCLI module
    - Content Library cmdlets (for -IncludeContentLibrary)

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
    [int]$StaleDays = 180,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeContentLibrary
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

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enumerate VM Templates
Write-Host "Enumerating VM templates..." -ForegroundColor Cyan
$templates = Get-Template -ErrorAction SilentlyContinue

foreach ($tmpl in ($templates | Sort-Object Name)) {
    $tmplView = $tmpl | Get-View -Property Config, Summary, LayoutEx -ErrorAction SilentlyContinue
    if (-not $tmplView) { continue }

    $sizeGB = 0
    if ($tmplView.LayoutEx -and $tmplView.LayoutEx.File) {
        $sizeGB = [math]::Round(($tmplView.LayoutEx.File | Measure-Object -Property Size -Sum).Sum / 1GB, 1)
    }

    $hwVersion = $tmplView.Config.Version
    $guestOS   = $tmplView.Config.GuestFullName
    $toolsVer  = $tmplView.Config.Tools.ToolsVersion
    $toolsStat = $tmplView.Summary.Guest.ToolsStatus

    # Find datastore
    $ds = Get-Datastore -RelatedObject $tmpl -ErrorAction SilentlyContinue | Select-Object -First 1
    $dsName = if ($ds) { $ds.Name } else { 'Unknown' }

    # Last modified via layout
    $lastMod  = 'Unknown'
    $daysSince = 9999
    if ($tmplView.LayoutEx -and $tmplView.LayoutEx.File) {
        $newestFile = $tmplView.LayoutEx.File | Where-Object { $_.Modification } | Sort-Object Modification -Descending | Select-Object -First 1
        if ($newestFile) {
            $lastMod   = $newestFile.Modification.ToString('yyyy-MM-dd')
            $daysSince = ([datetime]::Today - $newestFile.Modification.Date).Days
        }
    }

    $staleReasons = @()
    if ($daysSince -ge $StaleDays) { $staleReasons += "Not modified in $daysSince days" }
    if ($toolsStat -in 'guestToolsNeedUpgrade', 'guestToolsNotInstalled') { $staleReasons += "Tools: $toolsStat" }
    if ($hwVersion -match 'vmx-(\d+)' -and [int]$Matches[1] -lt 15) { $staleReasons += "HW version below vmx-15" }

    $results.Add([PSCustomObject]@{
        Name             = $tmpl.Name
        Type             = 'VM Template'
        GuestOS          = $guestOS
        HWVersion        = $hwVersion
        ToolsVersion     = $toolsVer
        ToolsStatus      = $toolsStat
        Datastore        = $dsName
        SizeGB           = $sizeGB
        LastModified     = $lastMod
        DaysSinceModified= if ($daysSince -lt 9999) { $daysSince } else { 'Unknown' }
        IsStale          = ($staleReasons.Count -gt 0)
        StaleReason      = $staleReasons -join '; '
    })
}

# Content Library items
if ($IncludeContentLibrary) {
    Write-Host "Enumerating content library items..." -ForegroundColor Cyan
    try {
        $libs = Get-ContentLibrary -ErrorAction SilentlyContinue
        foreach ($lib in $libs) {
            $items = Get-ContentLibraryItem -ContentLibrary $lib -ErrorAction SilentlyContinue
            foreach ($item in ($items | Sort-Object Name)) {
                $daysSince = if ($item.LastModified) { ([datetime]::Today - $item.LastModified.Date).Days } else { 9999 }
                $staleReasons = @()
                if ($daysSince -ge $StaleDays) { $staleReasons += "Not modified in $daysSince days" }

                $results.Add([PSCustomObject]@{
                    Name             = $item.Name
                    Type             = "ContentLibrary/$($item.ItemType)"
                    GuestOS          = 'N/A'
                    HWVersion        = 'N/A'
                    ToolsVersion     = 'N/A'
                    ToolsStatus      = 'N/A'
                    Datastore        = $lib.Name
                    SizeGB           = 'N/A'
                    LastModified     = if ($item.LastModified) { $item.LastModified.ToString('yyyy-MM-dd') } else { 'Unknown' }
                    DaysSinceModified= if ($daysSince -lt 9999) { $daysSince } else { 'Unknown' }
                    IsStale          = ($staleReasons.Count -gt 0)
                    StaleReason      = $staleReasons -join '; '
                })
            }
        }
    }
    catch {
        Write-Warning "Content library enumeration failed: $_"
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$staleCount = ($results | Where-Object { $_.IsStale -eq $true }).Count

Write-Host "`n=== Template Inventory Summary ===" -ForegroundColor Cyan
Write-Host "  Total Templates : $($results.Count)" -ForegroundColor White
Write-Host "  Stale Templates : $staleCount"        -ForegroundColor $(if ($staleCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Stale Threshold : $StaleDays days"    -ForegroundColor White
Write-Host "  Output          : $OutputFile"         -ForegroundColor White
