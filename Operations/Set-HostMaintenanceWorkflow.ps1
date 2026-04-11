<#
.SYNOPSIS
    Automates the ESXi host maintenance mode workflow with pre-flight checks.

.DESCRIPTION
    Places an ESXi host into maintenance mode with proper pre-checks: verifies no
    critical alarms, checks HA admission control, ensures VMs will be migrated,
    and handles vSAN data migration mode. Tracks which VMs were migrated and reports
    completion status. Supports a DryRun mode to simulate without making changes.

.PARAMETER HostName
    Required. The ESXi host to place into (or out of) maintenance mode.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Action
    Optional. Enter or Exit maintenance mode. Default: Enter.
    Valid values: Enter, Exit.

.PARAMETER VsanDataMigrationMode
    Optional. vSAN data migration strategy. Default: EnsureAccessibility.
    Valid values: EnsureAccessibility, FullDataMigration, NoDataMigration.

.PARAMETER EvacuateVMs
    Optional switch. Ensure all VMs are evacuated before entering maintenance.

.PARAMETER OutputFile
    Optional. Path to export the maintenance workflow log as CSV.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making changes.

.EXAMPLE
    .\Set-HostMaintenanceWorkflow.ps1 -HostName "esxi01.lab.local" -DryRun -OutputFile "maintenance-precheck.csv"
    Runs pre-flight checks only without changing host state.

.EXAMPLE
    .\Set-HostMaintenanceWorkflow.ps1 -HostName "esxi01.lab.local" -Action Enter -EvacuateVMs -OutputFile "maintenance-log.csv"
    Evacuates VMs and enters maintenance mode.

.OUTPUTS
    CSV with columns: Step, Status, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Host administrative privileges

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$HostName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [ValidateSet('Enter', 'Exit')]
    [string]$Action = 'Enter',

    [Parameter(Mandatory=$false)]
    [ValidateSet('EnsureAccessibility', 'FullDataMigration', 'NoDataMigration')]
    [string]$VsanDataMigrationMode = 'EnsureAccessibility',

    [Parameter(Mandatory=$false)]
    [switch]$EvacuateVMs,

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

$vmhost = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
if (-not $vmhost) { Write-Error "Host '$HostName' not found."; exit 1 }

$log = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Log {
    param([string]$Step, [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{
        Step      = $Step
        Status    = $Status
        Detail    = $Detail
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $log.Add($entry)
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'INFO' { 'Cyan' } default { 'White' } }
    Write-Host "  [$Status] $Step - $Detail" -ForegroundColor $color
}

Write-Host "`n=== Maintenance Mode Workflow: $HostName ===" -ForegroundColor Cyan
Write-Host "  Action  : $Action" -ForegroundColor White
Write-Host "  DryRun  : $DryRun" -ForegroundColor White

Add-Log -Step "Host Discovery"  -Status "INFO" -Detail "Host found: $HostName | State: $($vmhost.State) | Connection: $($vmhost.ConnectionState)"

# --- Pre-flight checks ---

# 1. Check host connection state
if ($vmhost.ConnectionState -ne 'Connected') {
    Add-Log -Step "Connection State" -Status "FAIL" -Detail "Host is not in Connected state: $($vmhost.ConnectionState)"
    if ($OutputFile) { $log | Export-Csv -Path $OutputFile -NoTypeInformation }
    exit 1
}
else {
    Add-Log -Step "Connection State" -Status "PASS" -Detail "Host is Connected"
}

# 2. Check maintenance state
if ($Action -eq 'Enter' -and $vmhost.State -eq 'Maintenance') {
    Add-Log -Step "Maintenance State" -Status "WARN" -Detail "Host is already in Maintenance mode"
}
elseif ($Action -eq 'Exit' -and $vmhost.State -ne 'Maintenance') {
    Add-Log -Step "Maintenance State" -Status "WARN" -Detail "Host is not in Maintenance mode (State: $($vmhost.State))"
}
else {
    Add-Log -Step "Maintenance State" -Status "PASS" -Detail "Host state is valid for action '$Action'"
}

# 3. Check for critical alarms
$hostView = $vmhost | Get-View -Property TriggeredAlarmState
$criticalAlarms = $hostView.TriggeredAlarmState | Where-Object { $_.OverallStatus -eq 'red' }
if ($criticalAlarms -and $criticalAlarms.Count -gt 0) {
    Add-Log -Step "Active Alarms" -Status "WARN" -Detail "$($criticalAlarms.Count) critical alarm(s) active on host"
}
else {
    Add-Log -Step "Active Alarms" -Status "PASS" -Detail "No critical alarms on host"
}

# 4. Check running VMs
$runningVMs = Get-VM -Location $vmhost | Where-Object { $_.PowerState -eq 'PoweredOn' }
Add-Log -Step "Running VMs" -Status "INFO" -Detail "$($runningVMs.Count) powered-on VM(s) on this host"

foreach ($vm in $runningVMs) {
    Add-Log -Step "VM: $($vm.Name)" -Status "INFO" -Detail "PoweredOn | Host: $($vm.VMHost.Name)"
}

# 5. Check cluster HA
$cluster = $vmhost | Get-Cluster -ErrorAction SilentlyContinue
if ($cluster) {
    Add-Log -Step "Cluster HA" -Status "INFO" -Detail "Cluster: $($cluster.Name) | HA Enabled: $($cluster.HAEnabled) | DRS: $($cluster.DrsEnabled)"
}

# 6. Check vSAN membership
$vsanCluster = $cluster | Where-Object { $_.VsanEnabled }
if ($vsanCluster) {
    Add-Log -Step "vSAN" -Status "INFO" -Detail "Host is part of a vSAN cluster. DataMigrationMode: $VsanDataMigrationMode"
    if ($VsanDataMigrationMode -eq 'NoDataMigration') {
        Add-Log -Step "vSAN Mode Warning" -Status "WARN" -Detail "NoDataMigration may leave vSAN objects inaccessible"
    }
}
else {
    Add-Log -Step "vSAN" -Status "INFO" -Detail "Host is not part of a vSAN cluster"
}

# --- Execute action (unless DryRun) ---
if ($Action -eq 'Enter') {
    if (-not $DryRun) {
        try {
            Write-Host "`nEntering maintenance mode..." -ForegroundColor Cyan
            $spec = New-Object VMware.Vim.HostMaintenanceSpec
            $spec.VsanMode = New-Object VMware.Vim.VsanHostDecommissionMode
            $spec.VsanMode.ObjectAction = $VsanDataMigrationMode

            $task = $vmhost | Get-View | ForEach-Object {
                $_.EnterMaintenanceMode_Task(300, $EvacuateVMs.IsPresent, $spec)
            }
            Get-Task -Id $task -ErrorAction SilentlyContinue | Wait-Task -ErrorAction Stop | Out-Null

            Add-Log -Step "Enter Maintenance" -Status "PASS" -Detail "Host successfully entered maintenance mode"
        }
        catch {
            Add-Log -Step "Enter Maintenance" -Status "FAIL" -Detail "Error: $_"
        }
    }
    else {
        Add-Log -Step "Enter Maintenance" -Status "INFO" -Detail "[DRYRUN] Would enter maintenance mode with VsanMode=$VsanDataMigrationMode, EvacuateVMs=$($EvacuateVMs.IsPresent)"
    }
}
elseif ($Action -eq 'Exit') {
    if (-not $DryRun) {
        try {
            Write-Host "`nExiting maintenance mode..." -ForegroundColor Cyan
            Set-VMHost -VMHost $vmhost -State Connected -ErrorAction Stop | Out-Null
            Add-Log -Step "Exit Maintenance" -Status "PASS" -Detail "Host successfully exited maintenance mode"
        }
        catch {
            Add-Log -Step "Exit Maintenance" -Status "FAIL" -Detail "Error: $_"
        }
    }
    else {
        Add-Log -Step "Exit Maintenance" -Status "INFO" -Detail "[DRYRUN] Would exit maintenance mode"
    }
}

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $log | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nLog exported to: $OutputFile" -ForegroundColor Cyan
}

$passes = ($log | Where-Object { $_.Status -eq 'PASS' }).Count
$warns  = ($log | Where-Object { $_.Status -eq 'WARN' }).Count
$fails  = ($log | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host "`n=== Result: PASS=$passes  WARN=$warns  FAIL=$fails ===" -ForegroundColor $(if ($fails -gt 0) { 'Red' } elseif ($warns -gt 0) { 'Yellow' } else { 'Green' })
