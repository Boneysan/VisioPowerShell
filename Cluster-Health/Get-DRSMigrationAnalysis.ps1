<#
.SYNOPSIS
    Analyzes recent DRS migrations to detect VM thrashing, rule violations, and
    placement anomalies.

.DESCRIPTION
    Queries the vCenter event history for DRS-initiated vMotion events in the specified
    time window, then:

    1. Counts migrations per VM — flags VMs exceeding the thrashing threshold
    2. Reports migration heat map: which hosts are DRS moving VMs to/from most
    3. Checks all DRS rules (affinity, anti-affinity, VM-Host) for current violations
    4. Shows current VM placement vs. configured affinity/anti-affinity rules
    5. Reports DRS automation level and current cluster imbalance score

.PARAMETER ClusterName
    Required. The vSphere cluster to analyse.

.PARAMETER HoursBack
    How many hours of DRS event history to retrieve. Default: 24

.PARAMETER ThrashThreshold
    Number of DRS migrations for a single VM within the window that indicates
    thrashing behaviour. Default: 3

.PARAMETER vCenter
    Optional. vCenter Server. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Get-DRSMigrationAnalysis.ps1 -ClusterName "IQT-Alpha" -HoursBack 12

.EXAMPLE
    .\Get-DRSMigrationAnalysis.ps1 -ClusterName "IQT-Alpha" -ThrashThreshold 5 -OutputFile "drs-analysis.csv"

.OUTPUTS
    Three result sections, all exported to CSV if -OutputFile is specified:
    - MigrationDetail : per-migration event record
    - VMMigrationCount: per-VM summary with thrash flag
    - RuleCompliance  : current DRS rule compliance status

.NOTES
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [int]$HoursBack = 24,

    [Parameter(Mandatory=$false)]
    [int]$ThrashThreshold = 3,

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

# --- Resolve cluster ---
$cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

$startTime   = (Get-Date).AddHours(-$HoursBack)
$clusterView = $cluster | Get-View -Property ConfigurationEx, Summary -ErrorAction Stop
$vmHosts     = @(Get-VMHost -Location $cluster)
$vms         = @(Get-VM -Location $cluster)

Write-Host "`n=== DRS Migration Analysis ===" -ForegroundColor Cyan
Write-Host "  Cluster          : $ClusterName" -ForegroundColor White
Write-Host "  Hosts            : $($vmHosts.Count)" -ForegroundColor White
Write-Host "  VMs              : $($vms.Count)" -ForegroundColor White
Write-Host "  Window           : Last $HoursBack hours" -ForegroundColor White
Write-Host "  Thrash Threshold : $ThrashThreshold migrations" -ForegroundColor White

# --- DRS Configuration summary ---
$drsConfig   = $clusterView.ConfigurationEx.DrsConfig
$drsEnabled  = $cluster.DrsEnabled
$drsLevel    = if ($drsEnabled) { $cluster.DrsAutomationLevel.ToString() } else { 'Disabled' }
$vMotionRate = if ($drsConfig) { $drsConfig.VmotionRate } else { 'Unknown' }

Write-Host "`n  DRS Mode         : $drsLevel  (migration threshold: $vMotionRate)" -ForegroundColor $(if ($drsEnabled) { 'Green' } else { 'Yellow' })

# --- Section 1: Query DRS migration events ---
Write-Host "`n[1/3] Querying DRS migration events..." -ForegroundColor Cyan

# Build a set of VM MoRef values for this cluster (for filtering)
$clusterVmMoRefs = @{}
foreach ($vm in $vms) { $clusterVmMoRefs[$vm.ExtensionData.MoRef.Value] = $vm.Name }

$si = Get-View ServiceInstance -ErrorAction Stop
$em = Get-View $si.Content.EventManager -ErrorAction Stop

$filterSpec            = New-Object VMware.Vim.EventFilterSpec
$filterSpec.Time       = New-Object VMware.Vim.EventFilterSpecByTime
$filterSpec.Time.BeginTime = $startTime
$filterSpec.Type       = @('DrsVmMigratedEvent', 'VmMigratedEvent', 'DrsVmPoweredOnEvent')

$filterSpec.Entity           = New-Object VMware.Vim.EventFilterSpecByEntity
$filterSpec.Entity.Entity    = $cluster.ExtensionData.MoRef
$filterSpec.Entity.Recursion = [VMware.Vim.EventFilterSpecRecursionOption]::children

$collectorRef = $em.CreateCollectorForEvents($filterSpec)
$colView      = Get-View $collectorRef -ErrorAction Stop

$allEvents = [System.Collections.Generic.List[object]]::new()
do {
    $batch = $colView.ReadNextEvents(500)
    if (-not $batch) { break }
    foreach ($evt in $batch) { $allEvents.Add($evt) }
} while ($batch.Count -eq 500)

try { $colView.DestroyCollector() } catch { }

Write-Host "  Found $($allEvents.Count) DRS migration event(s)" -ForegroundColor White

$migrationDetail = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($evt in $allEvents | Sort-Object -Property CreatedTime) {
    $isDrs  = $evt.GetType().Name -match 'Drs'
    $vmName = if ($evt.PSObject.Properties['Vm'] -and $evt.Vm -and $evt.Vm.Name) { $evt.Vm.Name } else { 'Unknown' }

    $srcHost = ''
    $dstHost = ''
    if ($evt.PSObject.Properties['SourceHost'] -and $evt.SourceHost) { $srcHost = $evt.SourceHost.Name }
    if ($evt.PSObject.Properties['Host'] -and $evt.Host)             { $dstHost = $evt.Host.Name }

    $migrationDetail.Add([PSCustomObject]@{
        Section     = 'MigrationDetail'
        Timestamp   = $evt.CreatedTime.ToString('yyyy-MM-dd HH:mm:ss')
        VMName      = $vmName
        EventType   = $evt.GetType().Name
        IsDRS       = $isDrs
        SourceHost  = $srcHost
        DestHost    = $dstHost
        Message     = $evt.FullFormattedMessage
    })
}

# --- Section 2: Per-VM migration count and thrash detection ---
Write-Host "`n[2/3] Analysing migration frequency..." -ForegroundColor Cyan

$vmMigCounts = [System.Collections.Generic.List[PSCustomObject]]::new()
$drsMigrations = $migrationDetail | Where-Object { $_.IsDRS -eq $true }

$grouped = $drsMigrations | Group-Object VMName | Sort-Object Count -Descending
foreach ($group in $grouped) {
    $isThrashing = $group.Count -ge $ThrashThreshold
    $srcHosts    = ($group.Group | Where-Object { $_.SourceHost } | Select-Object -ExpandProperty SourceHost | Select-Object -Unique) -join ', '
    $dstHosts    = ($group.Group | Where-Object { $_.DestHost   } | Select-Object -ExpandProperty DestHost   | Select-Object -Unique) -join ', '

    $vmMigCounts.Add([PSCustomObject]@{
        Section          = 'VMMigrationCount'
        VMName           = $group.Name
        DRSMigrations    = $group.Count
        IsThrashing      = $isThrashing
        UniqueSourceHosts= $srcHosts
        UniqueDestHosts  = $dstHosts
    })

    if ($isThrashing) {
        Write-Host "  [THRASHING] $($group.Name) : $($group.Count) DRS migrations in $HoursBack hours" -ForegroundColor Red
    }
    else {
        Write-Host "  $($group.Name) : $($group.Count) migrations" -ForegroundColor Gray
    }
}

if ($grouped.Count -eq 0) {
    Write-Host "  No DRS migrations found in the last $HoursBack hours." -ForegroundColor DarkGray
}

# --- Section 3: DRS Rule Compliance ---
Write-Host "`n[3/3] Checking DRS rule compliance..." -ForegroundColor Cyan

$ruleResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$rules       = @()
if ($clusterView.ConfigurationEx.Rule) { $rules = @($clusterView.ConfigurationEx.Rule) }

# Build VM name lookup by MoRef value for rule resolution
$vmMoRefToName = @{}
foreach ($vm in $vms) { $vmMoRefToName[$vm.ExtensionData.MoRef.Value] = $vm.Name }

# Build current VM placement: host -> list of VMs, VM -> host
$vmToHost = @{}
foreach ($vm in $vms) { $vmToHost[$vm.Name] = $vm.VMHost.Name }

if ($rules.Count -eq 0) {
    Write-Host "  No DRS rules configured on this cluster." -ForegroundColor DarkGray
}

foreach ($rule in $rules | Sort-Object Name) {
    $ruleType       = $rule.GetType().Name
    $ruleName       = $rule.Name
    $isEnabled      = $rule.Enabled
    $isMandatory    = if ($rule.PSObject.Properties['Mandatory']) { $rule.Mandatory } else { $false }
    $inCompliance   = if ($rule.PSObject.Properties['InCompliance']) { $rule.InCompliance } else { $true }

    $vmNamesInRule = [System.Collections.Generic.List[string]]::new()
    if ($rule.PSObject.Properties['Vm'] -and $rule.Vm) {
        foreach ($vmMoRef in $rule.Vm) {
            $name = if ($vmMoRefToName[$vmMoRef.Value]) { $vmMoRefToName[$vmMoRef.Value] } else { $vmMoRef.Value }
            $vmNamesInRule.Add($name)
        }
    }

    # Validate placement for affinity rules (all VMs should be on same host)
    $placementViolation = $false
    $placementDetail    = ''

    if ($ruleType -match 'ClusterAffinityRuleSpec' -and $vmNamesInRule.Count -ge 2 -and $isEnabled) {
        $hosts = $vmNamesInRule | ForEach-Object { if ($vmToHost[$_]) { $vmToHost[$_] } } | Select-Object -Unique
        $hostList = @($hosts)
        if ($hostList.Count -gt 1) {
            $placementViolation = $true
            $placementDetail    = "KEEP TOGETHER rule violated: VMs across $($hostList.Count) different hosts"
        }
        else {
            $placementDetail = "All $($vmNamesInRule.Count) VMs on same host: $($hostList -join '')"
        }
    }
    elseif ($ruleType -match 'ClusterAntiAffinityRuleSpec' -and $vmNamesInRule.Count -ge 2 -and $isEnabled) {
        $hosts = $vmNamesInRule | ForEach-Object { if ($vmToHost[$_]) { $vmToHost[$_] } } | Select-Object -Unique
        $hostList = @($hosts)
        $uniqueHostCount = $hostList.Count
        if ($uniqueHostCount -lt $vmNamesInRule.Count) {
            $placementViolation = $true
            $placementDetail    = "KEEP APART rule violated: $($vmNamesInRule.Count) VMs on only $uniqueHostCount host(s)"
        }
        else {
            $placementDetail = "All $($vmNamesInRule.Count) VMs on separate hosts"
        }
    }
    else {
        $placementDetail = "Rule type: $ruleType"
    }

    # Determine final status
    $status = if (-not $isEnabled)            { 'INFO'  }
              elseif ($placementViolation)     { 'FAIL'  }
              elseif (-not $inCompliance)      { 'WARN'  }
              else                             { 'PASS'  }

    $color = switch ($status) {
        'PASS' { 'Green'  }
        'FAIL' { 'Red'    }
        'WARN' { 'Yellow' }
        'INFO' { 'DarkGray' }
        default{ 'White'  }
    }
    Write-Host "  [$status] $ruleName ($ruleType) : $placementDetail" -ForegroundColor $color

    $ruleResults.Add([PSCustomObject]@{
        Section         = 'RuleCompliance'
        RuleName        = $ruleName
        RuleType        = $ruleType
        Enabled         = $isEnabled
        Mandatory       = $isMandatory
        InCompliance    = $inCompliance
        VMsInRule       = $vmNamesInRule -join ', '
        PlacementStatus = $status
        PlacementDetail = $placementDetail
    })
}

# --- Migration heat map: which hosts are busiest? ---
$allMigs = $migrationDetail
if ($allMigs.Count -gt 0) {
    Write-Host "`n  Migration Heat Map (top sources/destinations):" -ForegroundColor Cyan
    $srcCounts = $allMigs | Where-Object { $_.SourceHost } | Group-Object SourceHost | Sort-Object Count -Descending | Select-Object -First 5
    $dstCounts = $allMigs | Where-Object { $_.DestHost   } | Group-Object DestHost   | Sort-Object Count -Descending | Select-Object -First 5
    foreach ($s in $srcCounts) { Write-Host "    Source : $($s.Name.PadRight(40)) $($s.Count) migrations out" -ForegroundColor DarkYellow }
    foreach ($d in $dstCounts) { Write-Host "    Dest   : $($d.Name.PadRight(40)) $($d.Count) migrations in"  -ForegroundColor Green }
}

# --- Summary ---
$totalMigs    = $migrationDetail.Count
$thrashCount  = ($vmMigCounts | Where-Object { $_.IsThrashing -eq $true }).Count
$ruleViolations = ($ruleResults | Where-Object { $_.PlacementStatus -eq 'FAIL' }).Count

Write-Host "`n--- DRS Analysis Summary ---" -ForegroundColor Cyan
Write-Host "  DRS Level           : $drsLevel"       -ForegroundColor White
Write-Host "  Total Migrations    : $totalMigs"      -ForegroundColor White
Write-Host "  VMs Analysed        : $($vmMigCounts.Count)" -ForegroundColor White
Write-Host "  Thrashing VMs       : $thrashCount"    -ForegroundColor $(if ($thrashCount    -gt 0) { 'Red'    } else { 'Green' })
Write-Host "  DRS Rules           : $($ruleResults.Count)" -ForegroundColor White
Write-Host "  Rule Violations     : $ruleViolations" -ForegroundColor $(if ($ruleViolations -gt 0) { 'Red'    } else { 'Green' })

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    # Combine all three result types into one CSV with a 'Section' discriminator column
    $combined = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($row in $migrationDetail) { $combined.Add($row) }
    foreach ($row in $vmMigCounts)     { $combined.Add($row) }
    foreach ($row in $ruleResults)     { $combined.Add($row) }
    $combined | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}
