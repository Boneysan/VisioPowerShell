<#
.SYNOPSIS
    Extracts failed login and permission-change events from vCenter for security auditing.

.DESCRIPTION
    Queries the vCenter event stream for authentication failures and optionally
    permission modification events, supporting incident investigation and
    compliance evidence collection. Lookback window is configurable via -Hours.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Hours
    Optional. Number of hours to look back for events. Default: 168 (7 days).

.PARAMETER OutputFile
    Required. Path to export the audit log as CSV.

.PARAMETER IncludePermissionChanges
    Optional. Switch. Also capture permission add/remove/modify events.

.EXAMPLE
    .\Get-FailedLoginAudit.ps1 -vCenter "vc.example.com" -OutputFile "login-audit.csv"
    Exports failed logins from the last 7 days.

.EXAMPLE
    .\Get-FailedLoginAudit.ps1 -Hours 24 -IncludePermissionChanges -OutputFile "last24h.csv"
    Exports failed logins and permission changes from the last 24 hours.

.OUTPUTS
    CSV with columns: Timestamp, Username, SourceIP, EventType, Entity,
    Success, Message, Severity

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
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [int]$Hours = 168,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludePermissionChanges
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

$start = (Get-Date).AddHours(-$Hours)
Write-Host "Querying events from last $Hours hours (since $start)..." -ForegroundColor Cyan

# Event types to collect
$failedLoginTypes = @(
    'vim.event.BadUsernameSessionEvent',
    'vim.event.NoPermissionEvent',
    'vim.event.UserLoginFailedEvent',
    'com.vmware.sso.LoginFailure'
)

$permChangetypes = @(
    'vim.event.PermissionAddedEvent',
    'vim.event.PermissionRemovedEvent',
    'vim.event.PermissionUpdatedEvent',
    'vim.event.RoleAddedEvent',
    'vim.event.RoleRemovedEvent',
    'vim.event.RoleUpdatedEvent'
)

$targetTypes = $failedLoginTypes
if ($IncludePermissionChanges) {
    $targetTypes += $permChangetypes
}

# Build event filter
$eventManager  = Get-View (Get-View ServiceInstance).Content.EventManager
$eventFilter   = New-Object VMware.Vim.EventFilterSpec
$eventFilter.Time = New-Object VMware.Vim.EventFilterSpecByTime
$eventFilter.Time.BeginTime = $start
$eventFilter.Type = $targetTypes

Write-Host "Collecting events..." -ForegroundColor Cyan
$events = @()
try {
    $collector = $eventManager.CreateCollectorForEvents($eventFilter)
    $collectorView = Get-View $collector
    do {
        $page = $collectorView.ReadNextEvents(1000)
        $events += $page
    } while ($page.Count -gt 0)
    $collectorView.DestroyCollector()
}
catch {
    Write-Warning "Event collection via filter failed, falling back to Get-VIEvent: $_"
    $events = Get-VIEvent -Start $start -MaxSamples ([int]::MaxValue) -ErrorAction SilentlyContinue |
              Where-Object { $_.GetType().FullName -in $targetTypes -or $_.Message -match 'Login|Permission|password|denied' }
}

Write-Host "  Found $($events.Count) matching event(s)" -ForegroundColor White

$results = foreach ($evt in $events) {
    $isFailure = $failedLoginTypes -contains $evt.GetType().FullName -or
                 $evt.Message -match 'fail|denied|invalid|incorrect'

    [PSCustomObject]@{
        Timestamp   = $evt.CreatedTime.ToString('yyyy-MM-dd HH:mm:ss')
        Username    = if ($evt.UserName) { $evt.UserName } elseif ($evt.Principal) { $evt.Principal } else { 'Unknown' }
        SourceIP    = if ($evt.IpAddress) { $evt.IpAddress } else { 'N/A' }
        EventType   = $evt.GetType().Name
        Entity      = if ($evt.Vm) { "VM:$($evt.Vm.Name)" } elseif ($evt.Host) { "Host:$($evt.Host.Name)" } else { 'vCenter' }
        Success     = -not $isFailure
        Message     = $evt.FullFormattedMessage
        Severity    = if ($isFailure) { 'Warning' } else { 'Info' }
    }
}

Write-Host "Exporting $($results.Count) events to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$failures = ($results | Where-Object { -not $_.Success }).Count
$permEvts = ($results | Where-Object { $_.EventType -match 'Permission|Role' }).Count

Write-Host "`n=== Failed Login Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Period        : Last $Hours hours" -ForegroundColor White
Write-Host "  Total events  : $($results.Count)" -ForegroundColor White
Write-Host "  Auth failures : $failures" -ForegroundColor $(if ($failures -gt 0) { 'Red' } else { 'Green' })
if ($IncludePermissionChanges) {
    Write-Host "  Perm changes  : $permEvts" -ForegroundColor Yellow
}
Write-Host "  Output        : $OutputFile" -ForegroundColor White
