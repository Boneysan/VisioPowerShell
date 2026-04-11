<#
.SYNOPSIS
    Retrieves vMotion and Storage vMotion history for cluster VMs.

.DESCRIPTION
    Queries vCenter event history for VmMigratedEvent and VmRelocatedEvent records
    within the specified time window. Reports source/destination host, trigger type,
    migration duration, and result. Useful for identifying live migration patterns,
    troubleshooting DRS behavior, and tracking storage migrations.

.PARAMETER ClusterName
    Optional. Filter events to VMs in the specified cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Hours
    Optional. Number of hours of history to retrieve. Default: 168 (7 days).

.PARAMETER OutputFile
    Required. Path to export the vMotion history as CSV.

.PARAMETER IncludeSvMotion
    Optional switch. Include Storage vMotion events in addition to vMotion events.

.EXAMPLE
    .\Get-vMotionHistory.ps1 -ClusterName "Production" -Hours 24 -OutputFile "vmotion-24h.csv"
    Exports the last 24 hours of vMotion history for Production cluster.

.EXAMPLE
    .\Get-vMotionHistory.ps1 -Hours 168 -IncludeSvMotion -OutputFile "migrations-7d.csv"
    Exports a week of vMotion and Storage vMotion events.

.OUTPUTS
    CSV with columns: Timestamp, VMName, SourceHost, DestinationHost, SourceDatastore,
    DestinationDatastore, TriggerType, DurationSeconds, Result, Message

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter event history

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [int]$Hours = 168,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSvMotion
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

$startTime = (Get-Date).AddHours(-$Hours)
Write-Host "Querying vMotion events from $($startTime.ToString('yyyy-MM-dd HH:mm')) to now..." -ForegroundColor Cyan

# Build event type filter
$eventTypes = [System.Collections.Generic.List[string]]::new()
$eventTypes.Add('VmMigratedEvent')
if ($IncludeSvMotion) { $eventTypes.Add('VmRelocatedEvent') }

# Use EventFilterSpec for efficient query
$si = Get-View ServiceInstance
$em = Get-View $si.Content.EventManager

$filterSpec = New-Object VMware.Vim.EventFilterSpec
$filterSpec.Time = New-Object VMware.Vim.EventFilterSpecByTime
$filterSpec.Time.BeginTime = $startTime
$filterSpec.Type = $eventTypes.ToArray()

# If cluster filter specified, get VM MoRefs for that cluster
$clusterVMIds = $null
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $clusterVMIds = (Get-VM -Location $cluster).ExtensionData.MoRef | ForEach-Object { $_.Value }
    Write-Host "Filtering to $($clusterVMIds.Count) VMs in cluster '$ClusterName'..." -ForegroundColor Cyan
}

$collector = $em.CreateCollectorForEvents($filterSpec)
$colView   = Get-View $collector

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$batch = $null

do {
    $batch = $colView.ReadNextEvents(500)
    if (-not $batch) { break }

    foreach ($evt in $batch) {
        if ($clusterVMIds -and $clusterVMIds -notcontains $evt.Vm.Vm.Value) { continue }

        $triggerType = 'Unknown'
        if ($evt.UserName -match '.') {
            $triggerType = if ($evt.UserName -match 'vpxd|vmkernel') { 'DRS' } else { 'Manual' }
        }

        $sourceHost = 'N/A'
        $destHost   = 'N/A'
        $sourceds   = 'N/A'
        $destds     = 'N/A'

        if ($evt.PSObject.Properties['SourceHost']) { $sourceHost = $evt.SourceHost.Name }
        if ($evt.PSObject.Properties['Host'])       { $destHost   = $evt.Host.Name }
        if ($evt.PSObject.Properties['SourceDatacenter']) { /* not used */ }
        if ($evt.PSObject.Properties['Ds'])         { $destds     = $evt.Ds.Name }

        # Estimate duration from message
        $durationSec = 'N/A'
        if ($evt.FullFormattedMessage -match '(\d+)\s+second') { $durationSec = [int]$Matches[1] }

        $eventTypeFriendly = switch ($evt.GetType().Name) {
            'VmMigratedEvent'  { 'vMotion' }
            'VmRelocatedEvent' { 'Storage vMotion' }
            default            { $evt.GetType().Name }
        }

        $results.Add([PSCustomObject]@{
            Timestamp          = $evt.CreatedTime.ToString('yyyy-MM-dd HH:mm:ss')
            VMName             = $evt.Vm.Name
            SourceHost         = $sourceHost
            DestinationHost    = $destHost
            SourceDatastore    = $sourceds
            DestinationDatastore = $destds
            TriggerType        = $triggerType
            MigrationType      = $eventTypeFriendly
            DurationSeconds    = $durationSec
            User               = if ($evt.UserName) { $evt.UserName } else { 'N/A' }
            Message            = $evt.FullFormattedMessage
        })
    }
} while ($batch.Count -gt 0)

$colView.DestroyCollector()

Write-Host "Exporting $($results.Count) migration events to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$vmotionCount = ($results | Where-Object { $_.MigrationType -eq 'vMotion' }).Count
$svmotionCount = ($results | Where-Object { $_.MigrationType -eq 'Storage vMotion' }).Count
$drsCount     = ($results | Where-Object { $_.TriggerType -eq 'DRS' }).Count

Write-Host "`n=== vMotion History Summary ===" -ForegroundColor Cyan
Write-Host "  Time Window       : Last $Hours hours" -ForegroundColor White
Write-Host "  vMotion Events    : $vmotionCount"     -ForegroundColor White
Write-Host "  Storage vMotion   : $svmotionCount"    -ForegroundColor White
Write-Host "  DRS-Triggered     : $drsCount"         -ForegroundColor White
Write-Host "  Output            : $OutputFile"       -ForegroundColor White
