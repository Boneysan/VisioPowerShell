<#
.SYNOPSIS
    Audits VM snapshots across all VMs for age, chain depth, and stale snapshot detection.

.DESCRIPTION
    Identifies VMs with snapshots, calculates snapshot age and chain depth, and flags
    snapshots that exceed configurable thresholds. Useful for tracking down forgotten
    snapshots that waste datastore space and for enforcing snapshot hygiene policies
    across a cyber range environment.

.PARAMETER ClusterName
    Optional. Scope audit to VMs in this cluster.

.PARAMETER FolderName
    Optional. Scope audit to VMs in this vSphere folder.

.PARAMETER MaxAgeDays
    Snapshots older than this many days are flagged. Default: 7

.PARAMETER MaxChainDepth
    VMs with a snapshot chain longer than this are flagged. Default: 3

.PARAMETER vCenter
    Optional. vCenter Server. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Get-VMSnapshotAudit.ps1 -MaxAgeDays 3 -OutputFile "snapshot-audit.csv"

.EXAMPLE
    .\Get-VMSnapshotAudit.ps1 -ClusterName "IQT-Alpha" -MaxAgeDays 1 -MaxChainDepth 2

.OUTPUTS
    CSV: VMName, Cluster, VMHost, PowerState, SnapshotName, Description, CreatedDate,
         AgeDays, SnapshotDepth, TotalSnapshotsOnVM, IsCurrent, IsQuiesced, Status, FlagReason

.NOTES
    Pre-screens VMs using ExtensionData.Snapshot to skip VMs without snapshots
    quickly, avoiding a slow Get-Snapshot call on the entire inventory.
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$FolderName,

    [Parameter(Mandatory=$false)]
    [int]$MaxAgeDays = 7,

    [Parameter(Mandatory=$false)]
    [int]$MaxChainDepth = 3,

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

# --- Helper: calculate how deep this snapshot is in its chain (root = 1) ---
function Get-SnapshotDepth {
    param($Snap)
    $depth  = 1
    $parent = $Snap.ParentSnapshot
    while ($parent -ne $null) {
        $depth++
        $parent = $parent.ParentSnapshot
    }
    return $depth
}

# --- Get VMs ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster
}
elseif ($FolderName) {
    $folder = Get-Folder -Name $FolderName -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $folder) { Write-Error "Folder '$FolderName' not found."; exit 1 }
    $vms = Get-VM -Location $folder
}
else {
    $vms = Get-VM
}

$vmList = @($vms)
Write-Host "`n=== VM Snapshot Audit ===" -ForegroundColor Cyan
Write-Host "  Scope          : $(if ($ClusterName) { $ClusterName } elseif ($FolderName) { $FolderName } else { 'All VMs' })" -ForegroundColor White
Write-Host "  Max Age Flag   : $MaxAgeDays days" -ForegroundColor White
Write-Host "  Max Depth Flag : $MaxChainDepth levels" -ForegroundColor White
Write-Host "  VM Count       : $($vmList.Count)" -ForegroundColor White

# Pre-screen: skip VMs that don't have any snapshots (fast, avoids Get-Snapshot API calls)
Write-Host "`n  Pre-screening for snapshots..." -ForegroundColor Yellow
$vmsWithSnaps = [System.Collections.Generic.List[object]]::new()
foreach ($vm in $vmList) {
    if ($vm.ExtensionData.Snapshot -ne $null) {
        $vmsWithSnaps.Add($vm)
    }
}
Write-Host "  VMs with snapshots: $($vmsWithSnaps.Count) of $($vmList.Count)" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0
$now     = Get-Date

foreach ($vm in $vmsWithSnaps | Sort-Object Name) {
    $vmCount++
    Write-Host "  [$vmCount/$($vmsWithSnaps.Count)] $($vm.Name)..." -ForegroundColor Gray

    try {
        $snapshots = @(Get-Snapshot -VM $vm -ErrorAction Stop)
        if ($snapshots.Count -eq 0) { continue }

        $totalSnapsOnVm = $snapshots.Count

        foreach ($snap in $snapshots) {
            $ageDays    = [math]::Round(($now - $snap.Created).TotalDays, 1)
            $snapDepth  = Get-SnapshotDepth -Snap $snap

            # Build flag list
            $flags = [System.Collections.Generic.List[string]]::new()
            if ($ageDays   -gt $MaxAgeDays)   { $flags.Add("Age>${MaxAgeDays}d")    }
            if ($snapDepth -gt $MaxChainDepth) { $flags.Add("Chain>$MaxChainDepth") }

            $status     = if ($flags.Count -gt 0) { 'FLAGGED' } else { 'OK' }
            $flagReason = $flags -join ', '

            $results.Add([PSCustomObject]@{
                VMName             = $vm.Name
                Cluster            = $vm.VMHost.Parent.Name
                VMHost             = $vm.VMHost.Name
                PowerState         = $vm.PowerState.ToString()
                SnapshotName       = $snap.Name
                Description        = $snap.Description
                CreatedDate        = $snap.Created.ToString('yyyy-MM-dd HH:mm:ss')
                AgeDays            = $ageDays
                SnapshotDepth      = $snapDepth
                TotalSnapshotsOnVM = $totalSnapsOnVm
                IsCurrent          = $snap.IsCurrent
                IsQuiesced         = $snap.Quiesced
                Status             = $status
                FlagReason         = $flagReason
            })

            if ($status -eq 'FLAGGED') {
                Write-Host "    [FLAGGED] '$($snap.Name)'  Age=${ageDays}d  Chain=$totalSnapsOnVm  Depth=$snapDepth" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Warning "  Error reading snapshots for $($vm.Name): $_"
    }
}

# --- Summary ---
$total   = $results.Count
$flagged = ($results | Where-Object { $_.Status -eq 'FLAGGED' }).Count
$aged    = ($results | Where-Object { $_.FlagReason -match 'Age>'   }).Count
$deep    = ($results | Where-Object { $_.FlagReason -match 'Chain>' }).Count
$current = ($results | Where-Object { $_.IsCurrent -eq $true }).Count

Write-Host "`n--- Snapshot Audit Summary ---" -ForegroundColor Cyan
Write-Host "  VMs With Snapshots   : $($vmsWithSnaps.Count)"   -ForegroundColor White
Write-Host "  Total Snapshots      : $total"                    -ForegroundColor White
Write-Host "  Current Snapshots    : $current"                  -ForegroundColor White
Write-Host "  Flagged              : $flagged"                  -ForegroundColor $(if ($flagged -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "    Aged (>$MaxAgeDays d)    : $aged"              -ForegroundColor $(if ($aged    -gt 0) { 'Yellow' } else { 'White' })
Write-Host "    Deep Chain (>$MaxChainDepth) : $deep"          -ForegroundColor $(if ($deep    -gt 0) { 'Yellow' } else { 'White' })

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}
