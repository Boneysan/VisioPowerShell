<#
.SYNOPSIS
    Verifies storage multipath health per host — path counts, dead paths, and PSP policy consistency.

.DESCRIPTION
    For every ESXi host in scope, inspects the NMP (Native Multipathing Plugin) multipath
    information for each LUN. Reports active, standby, and dead path counts, flags devices
    with dead paths or fewer than the minimum required active paths, and detects PSP
    (Path Selection Policy) inconsistencies between hosts presenting the same LUN.

.PARAMETER ClusterName
    Optional. Scope to hosts in this cluster.

.PARAMETER HostName
    Optional. Audit a single ESXi host.

.PARAMETER MinActivePaths
    Minimum number of active paths required per LUN before flagging. Default: 1

.PARAMETER vCenter
    Optional. vCenter Server. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Test-StoragePathHealth.ps1 -ClusterName "IQT-Alpha" -MinActivePaths 2 -OutputFile "paths.csv"

.EXAMPLE
    .\Test-StoragePathHealth.ps1 -HostName "esxi-01.texnet1.net"

.OUTPUTS
    CSV: HostName, Cluster, LunId, LunCanonicalName, AssociatedDatastore, PSPPolicy,
         TotalPaths, ActivePaths, StandbyPaths, DeadPaths, DisabledPaths, Status, FlagReason

.NOTES
    Only reports LUNs managed by NMP (the native multipathing plugin). Third-party MPIOs
    may not appear.
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$HostName,

    [Parameter(Mandatory=$false)]
    [int]$MinActivePaths = 1,

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

# --- Get Hosts ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vmHosts = Get-VMHost -Location $cluster
}
elseif ($HostName) {
    $vmHosts = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
    if (-not $vmHosts) { Write-Error "Host '$HostName' not found."; exit 1 }
}
else {
    $vmHosts = Get-VMHost
}

$hostList = @($vmHosts | Where-Object { $_.ConnectionState -eq 'Connected' })

Write-Host "`n=== Storage Path Health ===" -ForegroundColor Cyan
Write-Host "  Scope          : $(if ($ClusterName) { $ClusterName } elseif ($HostName) { $HostName } else { 'All Hosts' })" -ForegroundColor White
Write-Host "  Host Count     : $($hostList.Count)" -ForegroundColor White
Write-Host "  Min Active Req : $MinActivePaths" -ForegroundColor White

# --- Build datastore name lookup: canonical name (naa.xxx) -> datastore name ---
Write-Host "  Building datastore map..." -ForegroundColor Yellow
$lunToDatastore = @{}
foreach ($ds in Get-Datastore -ErrorAction SilentlyContinue) {
    try {
        $dsView = $ds | Get-View -Property Info -ErrorAction SilentlyContinue
        if ($dsView -and $dsView.Info -and $dsView.Info.PSObject.Properties['Vmfs'] -and $dsView.Info.Vmfs) {
            foreach ($extent in $dsView.Info.Vmfs.Extent) {
                if ($extent.DiskName) {
                    $lunToDatastore[$extent.DiskName] = $ds.Name
                }
            }
        }
    }
    catch { }
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Track per-LUN PSP policies across hosts to detect inconsistency
# Key: canonical name, Value: hashtable of psp -> list of hosts
$lunPspMap = @{}

$hostCount = 0

foreach ($vmHost in $hostList | Sort-Object Name) {
    $hostCount++
    $clusterLabel = $vmHost.Parent.Name
    Write-Host "  [$hostCount/$($hostList.Count)] $($vmHost.Name)..." -ForegroundColor White

    try {
        $hostView = $vmHost | Get-View -Property `
            Config.StorageDevice.MultipathInfo, `
            Config.StorageDevice.ScsiLun `
            -ErrorAction Stop

        $multipathInfo = $hostView.Config.StorageDevice.MultipathInfo
        if (-not $multipathInfo -or -not $multipathInfo.Lun) {
            Write-Host "    No multipath LUNs found on this host." -ForegroundColor DarkGray
            continue
        }

        # Build canonical name lookup from ScsiLun list (Key -> CanonicalName)
        $keyToCanonical = @{}
        if ($hostView.Config.StorageDevice.ScsiLun) {
            foreach ($lun in $hostView.Config.StorageDevice.ScsiLun) {
                if ($lun.Key -and $lun.CanonicalName) {
                    $keyToCanonical[$lun.Key] = $lun.CanonicalName
                }
            }
        }

        foreach ($lun in $multipathInfo.Lun) {
            $canonicalName = if ($keyToCanonical[$lun.Id]) { $keyToCanonical[$lun.Id] } else { $lun.Id }
            $dsName        = if ($lunToDatastore[$canonicalName]) { $lunToDatastore[$canonicalName] } else { 'N/A' }
            $pspPolicy     = if ($lun.Policy -and $lun.Policy.Policy) { $lun.Policy.Policy } else { 'Unknown' }

            $activePaths   = 0
            $standbyPaths  = 0
            $deadPaths     = 0
            $disabledPaths = 0
            $totalPaths    = 0

            if ($lun.Path) {
                foreach ($path in $lun.Path) {
                    $totalPaths++
                    $state = $path.State.ToString().ToLower()
                    switch ($state) {
                        'active'   { $activePaths++ }
                        'standby'  { $standbyPaths++ }
                        'dead'     { $deadPaths++ }
                        'disabled' { $disabledPaths++ }
                    }
                }
            }

            # Record this host's PSP for cross-host consistency check
            if (-not $lunPspMap.ContainsKey($canonicalName)) {
                $lunPspMap[$canonicalName] = @{}
            }
            if (-not $lunPspMap[$canonicalName].ContainsKey($pspPolicy)) {
                $lunPspMap[$canonicalName][$pspPolicy] = [System.Collections.Generic.List[string]]::new()
            }
            $lunPspMap[$canonicalName][$pspPolicy].Add($vmHost.Name)

            # Build flags
            $flags = [System.Collections.Generic.List[string]]::new()
            if ($deadPaths -gt 0)                   { $flags.Add("$deadPaths dead path(s)") }
            if ($activePaths -lt $MinActivePaths)    { $flags.Add("Active paths ($activePaths) below minimum ($MinActivePaths)") }

            $status     = if ($flags.Count -gt 0) { 'FLAGGED' } else { 'OK' }
            $flagReason = $flags -join '; '

            $results.Add([PSCustomObject]@{
                HostName           = $vmHost.Name
                Cluster            = $clusterLabel
                LunId              = $lun.Id
                LunCanonicalName   = $canonicalName
                AssociatedDatastore= $dsName
                PSPPolicy          = $pspPolicy
                TotalPaths         = $totalPaths
                ActivePaths        = $activePaths
                StandbyPaths       = $standbyPaths
                DeadPaths          = $deadPaths
                DisabledPaths      = $disabledPaths
                Status             = $status
                FlagReason         = $flagReason
            })

            if ($status -eq 'FLAGGED') {
                Write-Host "    [FLAGGED] $canonicalName ($dsName) : $flagReason" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Warning "  Error reading storage info for $($vmHost.Name): $_"
    }
}

# --- Post-process: flag PSP policy inconsistencies across hosts ---
Write-Host "`n  Checking PSP consistency across hosts..." -ForegroundColor Yellow
$inconsistencyCount = 0
foreach ($canonicalName in $lunPspMap.Keys) {
    if ($lunPspMap[$canonicalName].Count -gt 1) {
        # Multiple PSPs for same LUN -> inconsistency
        $inconsistencyCount++
        $pspList = $lunPspMap[$canonicalName].Keys -join ' vs '
        Write-Host "  [PSP INCONSISTENT] $canonicalName : $pspList" -ForegroundColor Magenta

        # Update existing results entries for this LUN to add the PSP inconsistency flag
        foreach ($row in $results) {
            if ($row.LunCanonicalName -eq $canonicalName) {
                $existing = if ($row.FlagReason) { $row.FlagReason + '; ' } else { '' }
                $row.FlagReason = "${existing}PSP inconsistent ($pspList)"
                $row.Status     = 'FLAGGED'
            }
        }
    }
}

# --- Summary ---
$totalLuns   = ($results | Select-Object -Property LunCanonicalName -Unique).Count
$flaggedRows = ($results | Where-Object { $_.Status -eq 'FLAGGED' }).Count
$deadCount   = ($results | Where-Object { $_.DeadPaths -gt 0 }).Count
$lowActCount = ($results | Where-Object { $_.ActivePaths -lt $MinActivePaths }).Count

Write-Host "`n--- Storage Path Health Summary ---" -ForegroundColor Cyan
Write-Host "  Hosts Scanned            : $($hostList.Count)"   -ForegroundColor White
Write-Host "  Unique LUNs              : $totalLuns"           -ForegroundColor White
Write-Host "  Flagged LUN/Host Pairs   : $flaggedRows"         -ForegroundColor $(if ($flaggedRows    -gt 0) { 'Red'     } else { 'Green' })
Write-Host "    With Dead Paths        : $deadCount"           -ForegroundColor $(if ($deadCount      -gt 0) { 'Red'     } else { 'White' })
Write-Host "    Below Min Active Paths : $lowActCount"         -ForegroundColor $(if ($lowActCount    -gt 0) { 'Red'     } else { 'White' })
Write-Host "    PSP Inconsistencies    : $inconsistencyCount"  -ForegroundColor $(if ($inconsistencyCount -gt 0) { 'Magenta'} else { 'White' })

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}
