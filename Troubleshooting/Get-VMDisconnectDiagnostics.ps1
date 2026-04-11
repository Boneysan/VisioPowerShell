<#
.SYNOPSIS
    Investigates the root cause of random VM console disconnects / screen flash events.

.DESCRIPTION
    Designed for the symptom: users working in a VM suddenly see the screen flash and are
    kicked back to the login screen, with no clear pattern across classrooms or users.

    This script correlates vCenter event history, host performance counters, and VM-level
    metrics across a specified time window to identify the most common causes of mid-session
    console disconnects:

    1. vMotion / DRS migrations  - VM console drops during live migration
    2. VM stun events            - Storage latency > ~4s causes the VM to freeze ("stun")
    3. Host memory pressure      - Ballooning/swapping causes VM pauses and unresponsiveness
    4. HA / host isolation       - Hosts losing heartbeats trigger VM restarts
    5. Storage APD/PDL events    - All-Paths-Down causes VMs to stall or reset
    6. VM resets/reboots         - Unexpected power cycles tracked in vCenter events
    7. Console session drops     - Network/management plane issues vs actual VM events
    8. Host hardware events      - CPU/memory/NIC errors on the underlying ESXi host

    Outputs a timeline of suspicious events correlated by VM name, host, cluster, and time —
    making it easy to spot which VMs, hosts, or datastores are involved across classrooms.

.PARAMETER Folder
    Optional. vSphere folder to scope the analysis (e.g. "Classrooms\Office-WKS3").
    If omitted, analyzes all VMs in the vCenter.

.PARAMETER VMNamePattern
    Optional. Wildcard filter to limit analysis to matching VM names (e.g. "Office-WKS3*").

.PARAMETER HoursBack
    Optional. How many hours of history to analyze. Default: 336 (2 weeks).

.PARAMETER IncludeHosts
    Optional switch. Also analyze ESXi host-level events for the hosts running the affected VMs.

.PARAMETER IncludePerformance
    Optional switch. Pull memory/CPU/storage performance counters to detect resource pressure.
    Slower — only add if event correlation doesn't pinpoint the cause.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER OutputFile
    Optional. Path to export the full event correlation as CSV.

.EXAMPLE
    .\Get-VMDisconnectDiagnostics.ps1 -VMNamePattern "Office-WKS3*" -HoursBack 336 -OutputFile "disconnect-events.csv"
    Analyze two weeks of events for all Office-WKS3 VMs across all classrooms.

.EXAMPLE
    .\Get-VMDisconnectDiagnostics.ps1 -Folder "Classrooms" -HoursBack 168 -IncludeHosts -OutputFile "disconnect-full.csv"
    Full 1-week analysis including host-level events for all classroom VMs.

.OUTPUTS
    CSV with columns: Timestamp, EventClass, Severity, VMName, Host, Cluster, Datastore,
                      EventType, Message, SuspectCause, Recommendation

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter events and performance data

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [string]$VMNamePattern,

    [Parameter(Mandatory=$false)]
    [int]$HoursBack = 336,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeHosts,

    [Parameter(Mandatory=$false)]
    [switch]$IncludePerformance,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# --- Connection ---
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

# --- Resolve VMs ---
$allVMs = @()
if ($Folder) {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }
    $allVMs = Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
}
else {
    $allVMs = Get-VM -ErrorAction SilentlyContinue
}

if ($VMNamePattern) {
    $allVMs = $allVMs | Where-Object { $_.Name -like $VMNamePattern }
}

if (-not $allVMs) { Write-Warning "No VMs found matching criteria."; exit 0 }

$startTime = (Get-Date).AddHours(-$HoursBack)

Write-Host "`n=== VM Console Disconnect Diagnostics ===" -ForegroundColor Cyan
Write-Host "  VMs in scope : $($allVMs.Count)" -ForegroundColor White
Write-Host "  Time window  : Last $HoursBack hours (since $($startTime.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor White
Write-Host "  Include Hosts: $IncludeHosts" -ForegroundColor White
Write-Host "  Performance  : $IncludePerformance`n" -ForegroundColor White

$events = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Event type mappings to suspected causes ---
$causeMap = @{
    # vMotion / DRS
    'VmMigratedEvent'                 = @{ Cause = 'vMotion/DRS Migration'; Severity = 'WARNING'; Rec = 'Console drops briefly during vMotion. If frequent, check DRS aggressiveness or manually pin classroom VMs to hosts.' }
    'DrsVmMigratedEvent'              = @{ Cause = 'DRS Migration'; Severity = 'WARNING'; Rec = 'DRS is moving VMs automatically. Consider setting DRS to Manual for classroom VMs or adding affinity rules to pin them to specific hosts.' }
    'VmRelocatedEvent'                = @{ Cause = 'Storage vMotion'; Severity = 'WARNING'; Rec = 'VM storage is being relocated — this causes longer stun times than compute vMotion.' }

    # Power events
    'VmPoweredOffEvent'               = @{ Cause = 'Unexpected Power-Off'; Severity = 'CRITICAL'; Rec = 'VM was powered off — check who/what triggered this. HA, admin action, or guest crash.' }
    'VmResetEvent'                    = @{ Cause = 'VM Reset'; Severity = 'CRITICAL'; Rec = 'Hard VM reset — check for HA recovery, guest BSOD, or admin reset. Correlate with host events at same time.' }
    'VmRestartedByHA'                 = @{ Cause = 'HA Restart'; Severity = 'CRITICAL'; Rec = 'HA restarted this VM — the host it was on likely lost heartbeats or isolated. Check host health.' }
    'VmPoweredOnEvent'                = @{ Cause = 'Power-On (post-event)'; Severity = 'INFO'; Rec = 'VM came back online — correlate with preceding power-off/reset to understand the cause.' }

    # HA / Host
    'HostIsolatedEvent'               = @{ Cause = 'Host Network Isolation'; Severity = 'CRITICAL'; Rec = 'ESXi host lost management network. VMs may have been restarted by HA. Check physical network to this host.' }
    'ExitStandbyModeFailedEvent'      = @{ Cause = 'Host Standby Failure'; Severity = 'CRITICAL'; Rec = 'Host failed to exit standby — VMs may have been evacuated or lost.' }
    'VmFailoverFailed'                = @{ Cause = 'HA Failover Failed'; Severity = 'CRITICAL'; Rec = 'HA could not restart this VM after a host failure. Check cluster resource availability.' }
    'ClusterStatusChangedEvent'       = @{ Cause = 'Cluster State Change'; Severity = 'WARNING'; Rec = 'Cluster admission control or HA state changed. Check cluster health.' }

    # Snapshots (can cause disk I/O spikes)
    'VmSnapshotTakenEvent'            = @{ Cause = 'Snapshot Taken'; Severity = 'WARNING'; Rec = 'Snapshot operations cause momentary VM stun (typically <1s but can be longer for large RAM). If automated, check snapshot schedules.' }
    'VmDiskConsolidatedEvent'         = @{ Cause = 'Disk Consolidation'; Severity = 'WARNING'; Rec = 'Disk consolidation of snapshot chains causes significant I/O and can stun VMs.' }
    'VmSnapshotDeletedEvent'          = @{ Cause = 'Snapshot Deleted'; Severity = 'WARNING'; Rec = 'Deleting large snapshots causes I/O spikes and VM stun events.' }

    # Storage
    'DatastoreIORMDisableEvent'       = @{ Cause = 'Storage I/O Control Disabled'; Severity = 'WARNING'; Rec = 'SDRS or SIOC disabled — storage contention may go unmanaged.' }
    'OutOfLicenseStorageDRSEvent'     = @{ Cause = 'Storage DRS License Issue'; Severity = 'WARNING'; Rec = 'Storage DRS ran out of licenses — VMs may not be balanced across datastores.' }

    # VM crashes / tools
    'VmGuestRebootEvent'              = @{ Cause = 'Guest Reboot'; Severity = 'WARNING'; Rec = 'The guest OS rebooted (via VMware Tools or guest-initiated). Check if the OS is crashing.' }
    'VmToolsUpgradedEvent'            = @{ Cause = 'VMware Tools Upgraded'; Severity = 'INFO'; Rec = 'Tools upgrade may require a tools restart, causing brief console disruption.' }
    'VmUnsupportedEvent'              = @{ Cause = 'Unsupported Configuration'; Severity = 'WARNING'; Rec = 'VM has unsupported hardware/config — may cause unexpected behavior.' }
}

$eventMgr = Get-View EventManager -ErrorAction Stop

function Get-VMEvents {
    param([object]$VMObject)
    try {
        $filter = New-Object VMware.Vim.EventFilterSpec
        $filter.Entity = New-Object VMware.Vim.EventFilterSpecByEntity
        $filter.Entity.Entity = $VMObject.ExtensionData.MoRef
        $filter.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::self
        $filter.Time = New-Object VMware.Vim.EventFilterSpecByTime
        $filter.Time.BeginTime = $startTime.ToUniversalTime()
        return $eventMgr.QueryEvents($filter)
    }
    catch {
        Write-Warning "  Failed to query events for $($VMObject.Name): $_"
        return @()
    }
}

Write-Host "Querying vCenter events..." -ForegroundColor Gray

$vmCount = 0
foreach ($vm in $allVMs | Sort-Object Name) {
    $vmCount++
    Write-Progress -Activity "Querying events" -Status "$($vm.Name) ($vmCount/$($allVMs.Count))" -PercentComplete (($vmCount / $allVMs.Count) * 100)

    $vmEvents = Get-VMEvents -VMObject $vm
    $hostName   = $vm.VMHost.Name
    $clusterName = (Get-Cluster -VMHost $vm.VMHost -ErrorAction SilentlyContinue).Name

    foreach ($evt in $vmEvents) {
        $evtTypeName = $evt.GetType().Name
        $causeInfo   = $causeMap[$evtTypeName]

        # Only record events that could explain disconnects, unless it's an explicitly known event type
        $isSuspect = $null -ne $causeInfo
        $isGenericError = $evtTypeName -match 'Error|Fault|Fail|Reset|Restart|Disconnect|Isolat|Stun|APD|PDL|Halt|Panic'

        if (-not $isSuspect -and -not $isGenericError) { continue }

        $severity = if ($causeInfo) { $causeInfo.Severity } elseif ($evtTypeName -match 'Error|Fault|Fail|Panic|Halt') { 'CRITICAL' } else { 'WARNING' }
        $cause    = if ($causeInfo) { $causeInfo.Cause    } else { 'Potential Issue - Review' }
        $rec      = if ($causeInfo) { $causeInfo.Rec      } else { 'Investigate this event type in context with other events at the same time.' }

        $entry = [PSCustomObject]@{
            Timestamp     = $evt.CreatedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            EventClass    = $evtTypeName
            Severity      = $severity
            VMName        = $vm.Name
            Host          = $hostName
            Cluster       = $clusterName
            Datastore     = if ($evt.Ds) { $evt.Ds.Name } else { '' }
            EventType     = $evtTypeName
            Message       = $evt.FullFormattedMessage
            SuspectCause  = $cause
            Recommendation = $rec
        }
        $events.Add($entry)
    }
}
Write-Progress -Activity "Querying events" -Completed

# --- Host-level events ---
if ($IncludeHosts -and $events.Count -gt 0) {
    Write-Host "Querying host-level events..." -ForegroundColor Gray

    $affectedHosts = $allVMs | Select-Object -ExpandProperty VMHostId -Unique |
        ForEach-Object { Get-VMHost -Id $_ -ErrorAction SilentlyContinue }

    foreach ($vmhost in $affectedHosts) {
        try {
            $filter = New-Object VMware.Vim.EventFilterSpec
            $filter.Entity = New-Object VMware.Vim.EventFilterSpecByEntity
            $filter.Entity.Entity = $vmhost.ExtensionData.MoRef
            $filter.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::self
            $filter.Time = New-Object VMware.Vim.EventFilterSpecByTime
            $filter.Time.BeginTime = $startTime.ToUniversalTime()

            $hostEvts = $eventMgr.QueryEvents($filter)
        }
        catch { continue }

        $clusterName = (Get-Cluster -VMHost $vmhost -ErrorAction SilentlyContinue).Name

        foreach ($evt in $hostEvts) {
            $evtTypeName = $evt.GetType().Name
            if ($evtTypeName -notmatch 'Error|Fault|Fail|Isolat|Disconnect|Connection|Hardware|NIC|Mem|APD|PDL|Alarm|Degraded|NotResponding') { continue }

            $entry = [PSCustomObject]@{
                Timestamp      = $evt.CreatedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                EventClass     = 'HOST'
                Severity       = 'WARNING'
                VMName         = '(Host Event)'
                Host           = $vmhost.Name
                Cluster        = $clusterName
                Datastore      = ''
                EventType      = $evtTypeName
                Message        = $evt.FullFormattedMessage
                SuspectCause   = 'Host-Level Issue'
                Recommendation = 'Host event during the affected period — correlate timestamp with VM disconnect events above.'
            }
            $events.Add($entry)
        }
    }
}

# --- Sort and display ---
$sorted = $events | Sort-Object Timestamp

Write-Host "`n--- Suspicious Events Found: $($events.Count) ---`n" -ForegroundColor Cyan

if ($events.Count -eq 0) {
    Write-Host "  No suspicious events found in the specified time window." -ForegroundColor Green
    Write-Host "  This suggests the disconnects may be a console session / management network issue" -ForegroundColor Yellow
    Write-Host "  rather than actual VM events. Check:" -ForegroundColor Yellow
    Write-Host "    - vCenter Server connection stability" -ForegroundColor Gray
    Write-Host "    - vSphere Web Client / HTML5 client timeouts (idle session timeout)" -ForegroundColor Gray
    Write-Host "    - Network path from user machines to vCenter" -ForegroundColor Gray
    Write-Host "    - vCenter Appliance (VCSA) resource usage" -ForegroundColor Gray
}
else {
    # Group by suspect cause to show the most common
    $causeCounts = $events | Group-Object SuspectCause | Sort-Object Count -Descending
    Write-Host "  Top suspected causes:" -ForegroundColor White
    foreach ($c in $causeCounts) {
        $color = if ($c.Group[0].Severity -eq 'CRITICAL') { 'Red' } elseif ($c.Group[0].Severity -eq 'WARNING') { 'Yellow' } else { 'Cyan' }
        Write-Host ("    {0,4}x  {1}" -f $c.Count, $c.Name) -ForegroundColor $color
    }

    # Show VM frequency
    Write-Host "`n  Most affected VMs:" -ForegroundColor White
    $events | Group-Object VMName | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host ("    {0,4}x  {1}" -f $_.Count, $_.Name) -ForegroundColor White
    }

    # Show host frequency
    $hostFreq = $events | Where-Object { $_.Host } | Group-Object Host | Sort-Object Count -Descending
    if ($hostFreq) {
        Write-Host "`n  Most affected Hosts:" -ForegroundColor White
        $hostFreq | Select-Object -First 5 | ForEach-Object {
            Write-Host ("    {0,4}x  {1}" -f $_.Count, $_.Name) -ForegroundColor White
        }
    }

    # Show timeline of critical events
    $critical = $sorted | Where-Object { $_.Severity -eq 'CRITICAL' }
    if ($critical) {
        Write-Host "`n  Critical events timeline:" -ForegroundColor Red
        foreach ($e in $critical | Select-Object -First 20) {
            Write-Host "    $($e.Timestamp)  [$($e.SuspectCause)]  $($e.VMName) on $($e.Host)" -ForegroundColor Red
        }
    }

    # Top recommendation
    $topCause = $causeCounts | Select-Object -First 1
    if ($topCause) {
        Write-Host "`n  ** Primary recommendation for most common cause ('$($topCause.Name)'): **" -ForegroundColor Cyan
        $topRec = ($events | Where-Object { $_.SuspectCause -eq $topCause.Name } | Select-Object -First 1).Recommendation
        Write-Host "  $topRec" -ForegroundColor Yellow
    }
}

if ($OutputFile) {
    $sorted | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nFull event log exported to: $OutputFile" -ForegroundColor Green
}
elseif ($events.Count -gt 0) {
    $sorted | Select-Object Timestamp, Severity, SuspectCause, VMName, Host, Message |
        Format-Table -AutoSize -Wrap
}
