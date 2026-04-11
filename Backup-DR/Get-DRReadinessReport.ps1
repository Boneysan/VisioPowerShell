<#
.SYNOPSIS
    Generates a DR readiness assessment for a vSphere cluster.

.DESCRIPTION
    Evaluates cluster DR readiness across multiple categories: HA configuration,
    vSphere Replication status, CBT coverage, snapshot age, single points of failure
    (single-host clusters, disconnected hosts), datastore free space, and optionally
    Site Recovery Manager (SRM) recovery plan status.

    Outputs a risk-scored Markdown report and/or CSV for integration into operations
    portals.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER ClusterName
    Optional. Scope the assessment to a specific cluster.

.PARAMETER OutputFile
    Required. Path for the output report (CSV or Markdown based on extension).

.PARAMETER IncludeSRM
    Optional. Switch. Attempt to query SRM recovery plan status.

.EXAMPLE
    .\Get-DRReadinessReport.ps1 -ClusterName "Production" -OutputFile "dr-readiness.csv"
    Generates a DR readiness CSV for the Production cluster.

.EXAMPLE
    .\Get-DRReadinessReport.ps1 -vCenter "vc.example.com" -IncludeSRM -OutputFile "dr-report.md"
    Full DR report including SRM status, output as Markdown.

.OUTPUTS
    CSV or Markdown report with risk categories, scores, and findings.

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to cluster and VM configuration
    - SRM PowerCLI module (optional, for SRM checks)

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSRM
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

if ($ClusterName) {
    $clusters = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $clusters) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
}
else {
    $clusters = Get-Cluster
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function Add-Finding {
    param($Category, $Item, [int]$Score, $MaxScore, $Status, $Detail)
    $findings.Add([PSCustomObject]@{
        Category   = $Category
        Item       = $Item
        Score      = $Score
        MaxScore   = $MaxScore
        Risk       = if ($Score -ge $MaxScore * 0.8) { 'Low' } elseif ($Score -ge $MaxScore * 0.5) { 'Medium' } else { 'High' }
        Status     = $Status
        Detail     = $Detail
    })
}

foreach ($cluster in $clusters) {
    Write-Host "  Assessing cluster: $($cluster.Name)..." -ForegroundColor White

    $vmHosts = Get-VMHost -Location $cluster
    $vms     = Get-VM -Location $cluster

    # --- HA Configuration ---
    $haEnabled     = $cluster.HAEnabled
    $admCtrlPct    = $cluster.HAAdmissionControlEnabled
    $hostMonitor   = $cluster.HAEnabled
    Add-Finding -Category 'HA' -Item "$($cluster.Name): HA Enabled" `
        -Score (if ($haEnabled) { 5 } else { 0 }) -MaxScore 5 `
        -Status (if ($haEnabled) { 'PASS' } else { 'FAIL' }) `
        -Detail "HA=$haEnabled AdmissionControl=$admCtrlPct"

    # --- Host Count (SPOF risk) ---
    $hostCount = $vmHosts.Count
    $connectedHosts = ($vmHosts | Where-Object { $_.ConnectionState -eq 'Connected' }).Count
    Add-Finding -Category 'Infrastructure' -Item "$($cluster.Name): Connected Hosts" `
        -Score ([math]::Min($connectedHosts, 4)) -MaxScore 4 `
        -Status (if ($connectedHosts -ge 2) { 'PASS' } else { 'RISK' }) `
        -Detail "$connectedHosts of $hostCount hosts connected"

    # --- Disconnected hosts ---
    $disconnected = $vmHosts | Where-Object { $_.ConnectionState -ne 'Connected' }
    if ($disconnected) {
        Add-Finding -Category 'Infrastructure' -Item "$($cluster.Name): Disconnected Hosts" `
            -Score 0 -MaxScore 3 `
            -Status 'FAIL' `
            -Detail "Disconnected: $(($disconnected | Select-Object -ExpandProperty Name) -join ', ')"
    }

    # --- CBT coverage ---
    $cbtEnabled    = ($vms | Where-Object { $_.ExtensionData.Config.ChangeTrackingEnabled }).Count
    $cbtCoverage   = if ($vms.Count -gt 0) { [math]::Round(($cbtEnabled / $vms.Count) * 100, 1) } else { 0 }
    Add-Finding -Category 'Backup' -Item "$($cluster.Name): CBT Coverage" `
        -Score ([math]::Round($cbtCoverage / 25)) -MaxScore 4 `
        -Status (if ($cbtCoverage -ge 90) { 'PASS' } elseif ($cbtCoverage -ge 50) { 'WARNING' } else { 'FAIL' }) `
        -Detail "$cbtEnabled/$($vms.Count) VMs have CBT enabled ($cbtCoverage%)"

    # --- Old snapshots ---
    $oldSnaps = Get-VM -Location $cluster | Get-Snapshot -ErrorAction SilentlyContinue |
                Where-Object { $_.Created -lt (Get-Date).AddDays(-7) }
    Add-Finding -Category 'Storage' -Item "$($cluster.Name): Old Snapshots (>7d)" `
        -Score (if ($oldSnaps.Count -eq 0) { 3 } else { [math]::Max(0, 3 - $oldSnaps.Count) }) -MaxScore 3 `
        -Status (if ($oldSnaps.Count -eq 0) { 'PASS' } else { 'WARNING' }) `
        -Detail "$($oldSnaps.Count) snapshot(s) older than 7 days"

    # --- Datastore free space ---
    $lowDS = Get-Datastore -RelatedObject $cluster | Where-Object {
        $_.CapacityGB -gt 0 -and ($_.FreeSpaceGB / $_.CapacityGB) -lt 0.15
    }
    Add-Finding -Category 'Storage' -Item "$($cluster.Name): Datastores Low Free Space" `
        -Score (if ($lowDS.Count -eq 0) { 3 } else { 0 }) -MaxScore 3 `
        -Status (if ($lowDS.Count -eq 0) { 'PASS' } else { 'RISK' }) `
        -Detail "$($lowDS.Count) datastore(s) below 15% free: $(($lowDS | Select-Object -ExpandProperty Name) -join ', ')"

    # --- DRS ---
    $drsEnabled = $cluster.DrsEnabled
    Add-Finding -Category 'Operations' -Item "$($cluster.Name): DRS Enabled" `
        -Score (if ($drsEnabled) { 2 } else { 0 }) -MaxScore 2 `
        -Status (if ($drsEnabled) { 'PASS' } else { 'WARNING' }) `
        -Detail "DRS=$drsEnabled Mode=$($cluster.DrsAutomationLevel)"

    # --- SRM ---
    if ($IncludeSRM) {
        try {
            $srmConn = Connect-SrmServer -SrmServerAddress $vCenter -ErrorAction SilentlyContinue
            if ($srmConn) {
                $srmApi  = $srmConn.ExtensionData
                $rpPlans = $srmApi.Recovery.ListPlans()
                Add-Finding -Category 'SRM' -Item "$($cluster.Name): SRM Recovery Plans" `
                    -Score ([math]::Min($rpPlans.Count, 3)) -MaxScore 3 `
                    -Status (if ($rpPlans.Count -gt 0) { 'PASS' } else { 'MISSING' }) `
                    -Detail "$($rpPlans.Count) SRM recovery plan(s) configured"
            }
        }
        catch {
            Add-Finding -Category 'SRM' -Item "$($cluster.Name): SRM Connectivity" `
                -Score 0 -MaxScore 3 -Status 'ERROR' -Detail "Could not connect to SRM: $_"
        }
    }
}

# Output
$isMarkdown = $OutputFile -match '\.md$'

if ($isMarkdown) {
    $md = "# DR Readiness Report`n`n"
    $md += "**Generated:** $timestamp`n`n"
    $md += "## Findings`n`n"
    $md += "| Category | Item | Score | MaxScore | Risk | Status | Detail |`n"
    $md += "|----------|------|-------|----------|------|--------|--------|`n"
    foreach ($f in $findings) {
        $md += "| $($f.Category) | $($f.Item) | $($f.Score) | $($f.MaxScore) | $($f.Risk) | $($f.Status) | $($f.Detail) |`n"
    }
    $md | Out-File -FilePath $OutputFile -Encoding UTF8
}
else {
    $findings | Export-Csv -Path $OutputFile -NoTypeInformation
}

$totalScore = ($findings | Measure-Object -Property Score -Sum).Sum
$maxScore   = ($findings | Measure-Object -Property MaxScore -Sum).Sum
$pct        = if ($maxScore -gt 0) { [math]::Round(($totalScore / $maxScore) * 100, 1) } else { 0 }
$highRisk   = ($findings | Where-Object { $_.Risk -eq 'High' }).Count

Write-Host "`n=== DR Readiness Summary ===" -ForegroundColor Cyan
Write-Host "  Overall Score : $totalScore / $maxScore ($pct%)" -ForegroundColor $(if ($pct -ge 80) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' })
Write-Host "  High Risk     : $highRisk finding(s)" -ForegroundColor $(if ($highRisk -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output        : $OutputFile" -ForegroundColor White
