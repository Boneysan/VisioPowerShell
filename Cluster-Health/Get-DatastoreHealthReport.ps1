<#
.SYNOPSIS
    Reports datastore health for a cluster: capacity, accessibility, cross-host consistency,
    and VMFS storage path health.

.DESCRIPTION
    Performs four categories of datastore checks:

    1. Capacity and free space
       Flags datastores that exceed configurable warning and critical usage thresholds.

    2. Accessibility
       Verifies that each datastore reports as accessible. An inaccessible datastore means
       running VMs cannot write to their disks and any I/O will fail.

    3. Cross-host consistency
       Identifies datastores that are mounted on some cluster hosts but not all. This
       condition commonly causes DRS/HA migrations to fail with "unable to access datastore"
       if vCenter tries to place a VM on a host that cannot see its storage.

    4. VMFS storage path health (per host)
       For VMFS datastores, checks that each underlying LUN has at least two active paths.
       LUNs with no active paths are inaccessible; LUNs with only one active path have no
       multipathing redundancy.

    NFS datastores are checked for capacity and accessibility only; multipath does not apply.

.PARAMETER ClusterName
    Optional. Scope to a specific cluster. If omitted, all hosts in vCenter are used to
    enumerate datastores.

.PARAMETER WarnPct
    Optional. Datastore used-space percentage that triggers a WARNING. Default: 80.

.PARAMETER CritPct
    Optional. Datastore used-space percentage that triggers a CRITICAL alert. Default: 90.

.PARAMETER SkipPathCheck
    Optional switch. Skip the per-host SCSI LUN path check. Use this to speed up the report
    in large environments or when the path health is known-good.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. Default: c1r1r12-vcsa-01.texnet1.net.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Get-DatastoreHealthReport.ps1 -ClusterName "Cluster01"
    Run the full datastore health report for Cluster01.

.EXAMPLE
    .\Get-DatastoreHealthReport.ps1 -ClusterName "Cluster01" -WarnPct 75 -CritPct 85 -OutputFile "ds-health.csv"
    Use tighter thresholds and export results.

.EXAMPLE
    .\Get-DatastoreHealthReport.ps1 -ClusterName "Cluster01" -SkipPathCheck
    Run capacity, accessibility, and consistency checks only (faster).

.OUTPUTS
    CSV with columns: Section, Severity, ObjectType, Object, Check, Value,
                      AffectedHosts, Recommendation, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to datastore and storage information in vCenter
    - For path health checks: access to host storage adapter configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 99)]
    [int]$WarnPct = 80,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$CritPct = 90,

    [Parameter(Mandatory=$false)]
    [switch]$SkipPathCheck,

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

# --- Resolve scope ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $hosts = Get-VMHost -Location $cluster -ErrorAction SilentlyContinue
}
else {
    $hosts = Get-VMHost -ErrorAction SilentlyContinue
}

if (-not $hosts) { Write-Warning "No hosts found."; exit 0 }

$scopeName = if ($ClusterName) { $ClusterName } else { 'vCenter' }

Write-Host "`n=== Datastore Health Report ===" -ForegroundColor Cyan
Write-Host "  Scope         : $scopeName" -ForegroundColor White
Write-Host "  Hosts         : $($hosts.Count)" -ForegroundColor White
Write-Host "  Warn / Crit   : $WarnPct% / $CritPct%" -ForegroundColor White
if ($SkipPathCheck) { Write-Host "  Path Check    : DISABLED" -ForegroundColor Yellow }
Write-Host ""

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Section, [string]$Severity, [string]$ObjectType, [string]$Object,
          [string]$Check, [string]$Value, [string]$AffectedHosts = '',
          [string]$Recommendation = '')
    $entry = [PSCustomObject]@{
        Section        = $Section
        Severity       = $Severity
        ObjectType     = $ObjectType
        Object         = $Object
        Check          = $Check
        Value          = $Value
        AffectedHosts  = $AffectedHosts
        Recommendation = $Recommendation
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color  = switch ($Severity) { 'CRITICAL' { 'Red' } 'WARNING' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    $marker = switch ($Severity) { 'CRITICAL' { '[CRIT]' } 'WARNING' { '[WARN]' } 'OK' { '[OK]  ' } default { '[INFO]' } }
    Write-Host ("  $marker {0,-12} {1,-30} {2} = {3}" -f $ObjectType, $Object, $Check, $Value) -ForegroundColor $color
    if ($AffectedHosts)  { Write-Host "          Hosts: $AffectedHosts" -ForegroundColor Gray   }
    if ($Recommendation) { Write-Host "          -> $Recommendation"    -ForegroundColor Yellow }
}

# ============================================================
# Build datastore-to-host map (needed for multiple sections)
# ============================================================
Write-Host "Collecting datastore inventory..." -ForegroundColor Gray

# Map: DatastoreId -> @{ DS = obj; HostNames = list }
$dsMap = @{}
foreach ($vmhost in $hosts) {
    $hostDs = Get-Datastore -VMHost $vmhost -ErrorAction SilentlyContinue
    foreach ($ds in $hostDs) {
        if (-not $dsMap.ContainsKey($ds.Id)) {
            $dsMap[$ds.Id] = @{
                DS        = $ds
                HostNames = [System.Collections.Generic.List[string]]::new()
            }
        }
        $dsMap[$ds.Id].HostNames.Add($vmhost.Name)
    }
}

$clusteredDsCount = $dsMap.Keys.Count
$hostNames        = $hosts.Name
Write-Host "  Found $clusteredDsCount datastores across $($hosts.Count) hosts`n" -ForegroundColor Gray

# ============================================================
# SECTION 1: Capacity and Free Space
# ============================================================
Write-Host "--- Section 1: Capacity and Free Space ---`n" -ForegroundColor White

foreach ($dsId in $dsMap.Keys | Sort-Object) {
    $ds          = $dsMap[$dsId].DS
    $capacityGB  = [math]::Round($ds.CapacityGB, 1)
    $freeGB      = [math]::Round($ds.FreeSpaceGB, 1)
    $usedGB      = [math]::Round($capacityGB - $freeGB, 1)
    $usedPct     = if ($capacityGB -gt 0) { [math]::Round($usedGB / $capacityGB * 100, 1) } else { 0 }
    $dsType      = $ds.Type   # VMFS, NFS, NFS41, VSAN, etc.

    $sev = if ($usedPct -ge $CritPct) { 'CRITICAL' } elseif ($usedPct -ge $WarnPct) { 'WARNING' } else { 'OK' }

    Add-Result 'Capacity' $sev 'Datastore' $ds.Name 'Used Space' `
        "$usedPct% ($freeGB GB free of $capacityGB GB) [$dsType]" `
        '' `
        $(if ($usedPct -ge $CritPct) { "CRITICAL: Less than $([math]::Round(100-$CritPct,0))% free — storage VMs before space is exhausted" } `
          elseif ($usedPct -ge $WarnPct) { "Less than $([math]::Round(100-$WarnPct,0))% free — delete snapshots, old templates, and orphaned VMDKs to recover space" } `
          else { '' })
}

# ============================================================
# SECTION 2: Datastore Accessibility
# ============================================================
Write-Host "`n--- Section 2: Accessibility ---`n" -ForegroundColor White

foreach ($dsId in $dsMap.Keys | Sort-Object) {
    $ds         = $dsMap[$dsId].DS
    $accessible = $ds.Accessible

    Add-Result 'Accessibility' $(if ($accessible) { 'OK' } else { 'CRITICAL' }) `
        'Datastore' $ds.Name 'Accessible' $accessible `
        ($dsMap[$dsId].HostNames -join ', ') `
        $(if (-not $accessible) { 'Datastore is inaccessible — check SAN/NFS connectivity and rescan HBAs. VMs with files here will have I/O errors.' } else { '' })
}

# ============================================================
# SECTION 3: Cross-Host Consistency
# ============================================================
Write-Host "`n--- Section 3: Cross-Host Mount Consistency ---`n" -ForegroundColor White

$clusterHostCount = $hosts.Count

foreach ($dsId in $dsMap.Keys | Sort-Object) {
    $dsEntry      = $dsMap[$dsId]
    $ds           = $dsEntry.DS
    $mountCount   = $dsEntry.HostNames.Count
    $missingNames = $hostNames | Where-Object { $_ -notin $dsEntry.HostNames }

    if ($missingNames) {
        Add-Result 'Consistency' 'WARNING' 'Datastore' $ds.Name 'Mount Coverage' `
            "$mountCount / $clusterHostCount hosts" `
            "Missing from: $($missingNames -join ', ')" `
            'Datastore not mounted on all hosts — DRS/HA may fail to migrate VMs to those hosts. Rescan storage on missing hosts or add the datastore manually.'
    }
    else {
        Add-Result 'Consistency' 'OK' 'Datastore' $ds.Name 'Mount Coverage' `
            "All $clusterHostCount hosts"
    }
}

# ============================================================
# SECTION 4: VMFS Storage Path Health
# ============================================================
if (-not $SkipPathCheck) {
    Write-Host "`n--- Section 4: VMFS Storage Path Health ---`n" -ForegroundColor White

    # Build: CanonicalName -> list of (HostName, PathState, PathCount)
    # Flag LUNs with all-dead paths or single-path on any host
    $lunIssues = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($vmhost in $hosts | Sort-Object Name) {
        if ($vmhost.ConnectionState -ne 'Connected') { continue }

        try {
            $scsiLuns = Get-ScsiLun -VMHost $vmhost -LunType disk -ErrorAction SilentlyContinue
            foreach ($lun in $scsiLuns) {
                $paths       = Get-ScsiLunPath -ScsiLun $lun -ErrorAction SilentlyContinue
                $activePaths = @($paths | Where-Object { $_.State -eq 'Active' })
                $deadPaths   = @($paths | Where-Object { $_.State -eq 'Dead'   })
                $totalPaths  = $paths.Count

                $sev = $null
                if ($activePaths.Count -eq 0) {
                    $sev = 'CRITICAL'
                }
                elseif ($activePaths.Count -lt 2) {
                    $sev = 'WARNING'
                }

                if ($sev) {
                    $lunIssues.Add([PSCustomObject]@{
                        Host          = $vmhost.Name
                        LUN           = $lun.CanonicalName
                        ActivePaths   = $activePaths.Count
                        DeadPaths     = $deadPaths.Count
                        TotalPaths    = $totalPaths
                        Severity      = $sev
                    })
                }
            }
        }
        catch {
            Write-Warning "  Could not check paths on $($vmhost.Name): $_"
        }
    }

    if ($lunIssues) {
        foreach ($issue in $lunIssues | Sort-Object Severity, Host, LUN) {
            $detail = "$($issue.ActivePaths) active / $($issue.TotalPaths) total paths ($($issue.DeadPaths) dead)"
            Add-Result 'Path Health' $issue.Severity 'LUN' $issue.LUN 'Active Paths' $detail `
                "Host: $($issue.Host)" `
                $(if ($issue.ActivePaths -eq 0) { 'CRITICAL: LUN has no active paths — VMs on this storage are I/O-disconnected. Check HBA, zoning, and SAN switches immediately.' } `
                  else { 'Only one active path — no multipath redundancy. If this path fails, storage will become inaccessible. Check HBA and SAN switch configuration.' })
        }
    }
    else {
        Add-Result 'Path Health' 'OK' 'Cluster' $scopeName 'VMFS Path Health' 'All VMFS LUNs have 2+ active paths'
    }
}
else {
    Write-Host "  (Path check skipped — use without -SkipPathCheck to include)" -ForegroundColor Gray
}

# ============================================================
# SUMMARY
# ============================================================
$critical = ($results | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$warnings = ($results | Where-Object { $_.Severity -eq 'WARNING'  }).Count
$ok       = ($results | Where-Object { $_.Severity -eq 'OK'       }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Datastores    : $clusteredDsCount" -ForegroundColor White
Write-Host "  Hosts         : $($hosts.Count)" -ForegroundColor White
Write-Host "  CRITICAL      : $critical" -ForegroundColor $(if ($critical -gt 0) { 'Red'    } else { 'White' })
Write-Host "  WARNING       : $warnings" -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  OK            : $ok"        -ForegroundColor Green

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Where-Object { $_.Severity -in @('CRITICAL', 'WARNING') } |
        Select-Object Section, ObjectType, Object, Check, Value, AffectedHosts, Recommendation |
        Format-Table -AutoSize
}
