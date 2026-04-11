<#
.SYNOPSIS
    Collects all active (triggered) alarms across cluster hosts and VMs.

.DESCRIPTION
    Queries vCenter for all currently triggered alarms across the specified cluster,
    its ESXi hosts, VMs, and datastores. Reports alarm name, entity, severity,
    triggered time, and acknowledgment status. Filters by severity if specified.

.PARAMETER ClusterName
    Optional. Cluster to scope the alarm check.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Severity
    Optional. Filter by severity. Default: All.
    Valid values: Warning, Critical, All.

.PARAMETER OutputFile
    Required. Path to export the active alarm report as CSV.

.EXAMPLE
    .\Get-ActiveAlarms.ps1 -ClusterName "Production" -OutputFile "active-alarms.csv"
    Exports all active alarms for the Production cluster.

.EXAMPLE
    .\Get-ActiveAlarms.ps1 -Severity "Critical" -OutputFile "critical-alarms.csv"
    Exports only critical alarms across all clusters.

.OUTPUTS
    CSV with columns: EntityType, EntityName, AlarmName, Status, TriggeredTime,
    Acknowledged, AcknowledgedBy, AcknowledgedTime

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter alarm states

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
    [ValidateSet('Warning', 'Critical', 'All')]
    [string]$Severity = 'All',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
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

# Collect entities to check
$entities = [System.Collections.Generic.List[object]]::new()

if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $entities.Add($cluster)
    Get-VMHost -Location $cluster | ForEach-Object { $entities.Add($_) }
    Get-VM -Location $cluster | ForEach-Object { $entities.Add($_) }
    Get-Datastore -RelatedObject $cluster | Sort-Object -Property MoRef -Unique | ForEach-Object { $entities.Add($_) }
}
else {
    # Whole vCenter - collect from root
    Get-Cluster | ForEach-Object { $entities.Add($_) }
    Get-VMHost | ForEach-Object { $entities.Add($_) }
    Get-VM | ForEach-Object { $entities.Add($_) }
    Get-Datastore | Sort-Object -Property MoRef -Unique | ForEach-Object { $entities.Add($_) }
}

Write-Host "Checking $($entities.Count) entities for active alarms..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entity in $entities) {
    try {
        $entityView  = $entity | Get-View -Property TriggeredAlarmState -ErrorAction SilentlyContinue
        if (-not $entityView -or -not $entityView.TriggeredAlarmState) { continue }

        foreach ($alarm in $entityView.TriggeredAlarmState) {
            $alarmInfo = Get-View -Id $alarm.Alarm -Property Info -ErrorAction SilentlyContinue
            $alarmName = if ($alarmInfo) { $alarmInfo.Info.Name } else { $alarm.Alarm.Value }

            $statusColor = $alarm.OverallStatus
            if ($Severity -eq 'Warning' -and $statusColor -ne 'yellow') { continue }
            if ($Severity -eq 'Critical' -and $statusColor -ne 'red') { continue }

            $entityType = $entity.GetType().Name
            $entityName = try { $entity.Name } catch { 'Unknown' }

            $results.Add([PSCustomObject]@{
                EntityType      = $entityType
                EntityName      = $entityName
                AlarmName       = $alarmName
                Status          = if ($statusColor -eq 'red') { 'Critical' } elseif ($statusColor -eq 'yellow') { 'Warning' } else { $statusColor }
                TriggeredTime   = if ($alarm.Time) { $alarm.Time.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                Acknowledged    = $alarm.Acknowledged
                AcknowledgedBy  = if ($alarm.AcknowledgedByUser) { $alarm.AcknowledgedByUser } else { 'N/A' }
                AcknowledgedTime= if ($alarm.AcknowledgedTime) { $alarm.AcknowledgedTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
            })
        }
    }
    catch {
        # Skip entities without alarm state
    }
}

Write-Host "Exporting $($results.Count) active alarm records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$critical = ($results | Where-Object { $_.Status -eq 'Critical' }).Count
$warning  = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$unacked  = ($results | Where-Object { $_.Acknowledged -eq $false }).Count

Write-Host "`n=== Active Alarms Summary ===" -ForegroundColor Cyan
Write-Host "  Critical     : $critical" -ForegroundColor $(if ($critical -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warning      : $warning"  -ForegroundColor $(if ($warning -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Unacknowledged: $unacked" -ForegroundColor $(if ($unacked -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output       : $OutputFile" -ForegroundColor White
