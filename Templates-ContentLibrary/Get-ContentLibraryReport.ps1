<#
.SYNOPSIS
    Reports content library configuration, synchronization status, and storage usage.

.DESCRIPTION
    Enumerates all content libraries in vCenter, reporting their type (local/subscribed),
    storage backing, synchronization status, item counts, and total storage consumed.
    For subscribed libraries, reports whether sync is on-demand or immediate and the
    last sync time.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the content library report as CSV.

.PARAMETER IncludeItems
    Optional switch. Include per-item details for each library.

.EXAMPLE
    .\Get-ContentLibraryReport.ps1 -OutputFile "content-libraries.csv"
    Exports a summary of all content libraries.

.EXAMPLE
    .\Get-ContentLibraryReport.ps1 -IncludeItems -OutputFile "content-library-items.csv"
    Exports each library and all its items.

.OUTPUTS
    CSV with columns: LibraryName, LibraryType, Datastore, SubscriptionURL,
    OnDemandSync, LastSyncTime, ItemCount, StorageGB, State

.NOTES
    Requires:
    - VMware PowerCLI module with content library support

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
    [switch]$IncludeItems
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

Write-Host "Enumerating content libraries..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $libraries = Get-ContentLibrary -ErrorAction Stop
}
catch {
    Write-Error "Failed to enumerate content libraries. Ensure the ContentLibrary module is available: $_"
    exit 1
}

foreach ($lib in ($libraries | Sort-Object Name)) {
    $items = Get-ContentLibraryItem -ContentLibrary $lib -ErrorAction SilentlyContinue
    $itemCount = if ($items) { $items.Count } else { 0 }

    # Library view for detailed backing info
    $libView = $lib | Get-View -ErrorAction SilentlyContinue

    $libType      = $lib.Type
    $datastoreName = 'N/A'
    $subscriptionUrl = 'N/A'
    $onDemandSync  = 'N/A'
    $lastSyncTime  = 'N/A'
    $storageGB     = 'N/A'
    $state         = 'OK'

    if ($libView) {
        # Storage backing
        if ($libView.StorageBacks) {
            $backing = $libView.StorageBacks | Select-Object -First 1
            if ($backing.DatastoreId) {
                $ds = Get-Datastore | Where-Object { $_.ExtensionData.MoRef.Value -eq $backing.DatastoreId.Value } | Select-Object -First 1
                $datastoreName = if ($ds) { $ds.Name } else { $backing.DatastoreId.Value }
            }
        }

        # Subscription info
        if ($libView.Subscription) {
            $subscriptionUrl = $libView.Subscription.SubscriptionUrl
            $onDemandSync    = $libView.Subscription.OnDemand
            $lastSyncTime    = if ($libView.LastSyncTime) { $libView.LastSyncTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Never' }
        }

        # Storage
        if ($libView.StorageTotal -gt 0) {
            $storageGB = [math]::Round($libView.StorageTotal / 1GB, 2)
        }
    }

    # Check sync state for subscribed libraries
    if ($libType -eq 'Subscribed' -and $lastSyncTime -eq 'Never') {
        $state = 'WARN - Never synced'
    }

    $results.Add([PSCustomObject]@{
        LibraryName     = $lib.Name
        LibraryType     = $libType
        Datastore       = $datastoreName
        SubscriptionURL = $subscriptionUrl
        OnDemandSync    = $onDemandSync
        LastSyncTime    = $lastSyncTime
        ItemCount       = $itemCount
        StorageGB       = $storageGB
        State           = $state
        Description     = $lib.Description
    })

    # Per-item rows if requested
    if ($IncludeItems -and $items) {
        foreach ($item in ($items | Sort-Object Name)) {
            $results.Add([PSCustomObject]@{
                LibraryName     = "  -> $($lib.Name)"
                LibraryType     = $item.ItemType
                Datastore       = '(item)'
                SubscriptionURL = 'N/A'
                OnDemandSync    = 'N/A'
                LastSyncTime    = if ($item.LastModified) { $item.LastModified.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Unknown' }
                ItemCount       = 'N/A'
                StorageGB       = 'N/A'
                State           = if ($item.Cached) { 'Cached' } else { 'Not Cached' }
                Description     = $item.Name
            })
        }
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$local      = ($results | Where-Object { $_.LibraryType -eq 'Local'      -and $_.Datastore -ne '(item)' }).Count
$subscribed = ($results | Where-Object { $_.LibraryType -eq 'Subscribed' -and $_.Datastore -ne '(item)' }).Count
$warnings   = ($results | Where-Object { $_.State -like 'WARN*' }).Count

Write-Host "`n=== Content Library Report Summary ===" -ForegroundColor Cyan
Write-Host "  Total Libraries   : $($local + $subscribed)"  -ForegroundColor White
Write-Host "  Local             : $local"       -ForegroundColor White
Write-Host "  Subscribed        : $subscribed"  -ForegroundColor White
Write-Host "  Warnings          : $warnings"    -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output            : $OutputFile"  -ForegroundColor White
