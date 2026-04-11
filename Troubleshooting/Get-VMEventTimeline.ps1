<#
.SYNOPSIS
    Pulls a chronological event timeline for one or more VMs to reconstruct "what happened."

.DESCRIPTION
    Queries the vCenter event history for the specified VM(s) and presents every event in
    chronological order, colour-coded by category. Useful for root-cause analysis: see
    exactly when a VM was powered off, migrated, reconfigured, had an alarm fire, or
    hit an error — all in one view.

    Event categories detected:
        POWER       — Power on/off, reset, reboot, shutdown
        MIGRATE     — vMotion, Storage vMotion, cold migrate, DRS migration
        SNAPSHOT    — Create, delete, revert snapshot
        CLONE       — Clone, convert to template
        RECONFIGURE — VM config changes (CPU, memory, disk, NIC, hardware version)
        ALARM       — Alarm created, acknowledged, cleared
        DEPLOY      — Customization, guest reconfig, deploy from template
        TOOLS       — VMware Tools install, upgrade, status changes
        ERROR       — Any event whose class name contains 'Error' or 'Fail'
        OTHER       — Everything else

.PARAMETER VMName
    Required. Name of the VM to retrieve events for. Wildcards not supported.

.PARAMETER HoursBack
    How many hours of history to retrieve. Default: 24

.PARAMETER MaxEvents
    Maximum number of events to retrieve per read batch. Default: 1000

.PARAMETER vCenter
    Optional. vCenter Server. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export the timeline as CSV.

.EXAMPLE
    .\Get-VMEventTimeline.ps1 -VMName "WIN-DC-01" -HoursBack 48

.EXAMPLE
    .\Get-VMEventTimeline.ps1 -VMName "kali-attacker" -HoursBack 6 -OutputFile "timeline.csv"

.OUTPUTS
    CSV: Timestamp, Category, EventType, Message, UserName, Host, Datacenter

.NOTES
    Uses the vSphere EventManager collector API for efficient, server-side filtering
    rather than transferring the full event log.
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [int]$HoursBack = 24,

    [Parameter(Mandatory=$false)]
    [int]$MaxEvents = 1000,

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
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter."
        exit 1
    }
}

# --- Helper: categorise an event by its type name ---
function Get-EventCategory {
    param([string]$TypeName)

    if ($TypeName -match 'Powered|PowerOff|Reboot|Reset|Shutdown|Suspend|VmStarting|VmStopping') { return 'POWER'      }
    if ($TypeName -match 'Migrat|vMotion|Reloc|DrsVm')                                            { return 'MIGRATE'    }
    if ($TypeName -match 'Snapshot|Revert')                                                        { return 'SNAPSHOT'   }
    if ($TypeName -match 'Clone|Template|Convert')                                                 { return 'CLONE'      }
    if ($TypeName -match 'Reconfig|MemorySize|NumCpu|DiskAdd|DiskRemov|Network|HardVer')           { return 'RECONFIGURE'}
    if ($TypeName -match 'Alarm')                                                                   { return 'ALARM'      }
    if ($TypeName -match 'Customiz|Deploy|Sysprep|GuestReboot')                                    { return 'DEPLOY'     }
    if ($TypeName -match 'Tools|VmToolsUpgrade')                                                   { return 'TOOLS'      }
    if ($TypeName -match 'Error|Fail|Invalid|Exception')                                           { return 'ERROR'      }
    return 'OTHER'
}

# --- Resolve VM ---
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VMName' not found."
    exit 1
}

$startTime = (Get-Date).AddHours(-$HoursBack)

Write-Host "`n=== VM Event Timeline ===" -ForegroundColor Cyan
Write-Host "  VM        : $VMName  ($($vm.PowerState))" -ForegroundColor White
Write-Host "  Host      : $($vm.VMHost.Name)" -ForegroundColor White
Write-Host "  Window    : Last $HoursBack hours  (from $($startTime.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor White

# --- Build EventFilterSpec targeting this VM ---
$si         = Get-View ServiceInstance -ErrorAction Stop
$em         = Get-View $si.Content.EventManager -ErrorAction Stop

$filterSpec         = New-Object VMware.Vim.EventFilterSpec
$filterSpec.Time    = New-Object VMware.Vim.EventFilterSpecByTime
$filterSpec.Time.BeginTime = $startTime

$filterSpec.Entity  = New-Object VMware.Vim.EventFilterSpecByEntity
$filterSpec.Entity.Entity    = $vm.ExtensionData.MoRef
$filterSpec.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::self

$collectorRef = $em.CreateCollectorForEvents($filterSpec)
$colView      = Get-View $collectorRef -ErrorAction Stop

$events = [System.Collections.Generic.List[object]]::new()
do {
    $batch = $colView.ReadNextEvents($MaxEvents)
    if (-not $batch) { break }
    foreach ($evt in $batch) { $events.Add($evt) }
} while ($batch.Count -eq $MaxEvents)

# Destroy collector to release server resources
try { $colView.DestroyCollector() } catch { }

Write-Host "  Events found : $($events.Count)" -ForegroundColor White
Write-Host ""

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Sort ascending by creation time for a proper timeline
$sorted = $events | Sort-Object -Property CreatedTime

$categoryColors = @{
    'POWER'       = 'Cyan'
    'MIGRATE'     = 'Blue'
    'SNAPSHOT'    = 'DarkYellow'
    'CLONE'       = 'Magenta'
    'RECONFIGURE' = 'White'
    'ALARM'       = 'Yellow'
    'DEPLOY'      = 'Green'
    'TOOLS'       = 'DarkGreen'
    'ERROR'       = 'Red'
    'OTHER'       = 'DarkGray'
}

foreach ($evt in $sorted) {
    $typeName  = $evt.GetType().Name
    $category  = Get-EventCategory -TypeName $typeName
    $timestamp = $evt.CreatedTime.ToString('yyyy-MM-dd HH:mm:ss')
    $message   = $evt.FullFormattedMessage
    $user      = if ($evt.UserName) { $evt.UserName } else { '' }
    $hostName  = if ($evt.Host -and $evt.Host.Name) { $evt.Host.Name } else { '' }
    $dc        = if ($evt.Datacenter -and $evt.Datacenter.Name) { $evt.Datacenter.Name } else { '' }

    $results.Add([PSCustomObject]@{
        Timestamp  = $timestamp
        Category   = $category
        EventType  = $typeName
        Message    = $message
        UserName   = $user
        Host       = $hostName
        Datacenter = $dc
    })

    $color = if ($categoryColors.ContainsKey($category)) { $categoryColors[$category] } else { 'White' }
    Write-Host "  $timestamp  [$category] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$message" -ForegroundColor $color
}

if ($results.Count -eq 0) {
    Write-Host "  (No events found in the last $HoursBack hours for '$VMName')" -ForegroundColor DarkGray
}

# --- Category summary ---
Write-Host "`n--- Event Category Counts ---" -ForegroundColor Cyan
foreach ($cat in 'POWER','MIGRATE','SNAPSHOT','CLONE','RECONFIGURE','ALARM','DEPLOY','TOOLS','ERROR','OTHER') {
    $count = ($results | Where-Object { $_.Category -eq $cat }).Count
    if ($count -gt 0) {
        $col = if ($categoryColors.ContainsKey($cat)) { $categoryColors[$cat] } else { 'White' }
        Write-Host ("  {0,-12} : {1}" -f $cat, $count) -ForegroundColor $col
    }
}

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nTimeline exported to: $OutputFile" -ForegroundColor Cyan
}
