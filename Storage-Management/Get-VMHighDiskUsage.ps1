<#
.SYNOPSIS
    Reports VMs with guest disk volumes exceeding a utilization threshold (default 80%).

.DESCRIPTION
    Uses VMware Tools guest disk information to calculate per-volume used space for
    every powered-on VM in scope, then flags volumes at or above the threshold.
    VMs without VMware Tools running cannot report guest disk data and are listed
    separately so the gaps in coverage are visible.

.PARAMETER ClusterName
    Optional. Scope the report to a specific cluster. Defaults to all clusters.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER ThresholdPercent
    Optional. Utilization percentage that triggers a finding. Default 80.

.PARAMETER OutputFile
    Optional. Path to export the findings as CSV. Defaults to a timestamped file in
    the current directory. Pass an empty string to skip the export.

.EXAMPLE
    .\Get-VMHighDiskUsage.ps1 -ClusterName "Production"
    Lists all volumes over 80% full on powered-on VMs in the Production cluster.

.EXAMPLE
    .\Get-VMHighDiskUsage.ps1 -ThresholdPercent 90 -OutputFile "disk-pressure.csv"
    Reports volumes over 90% full across all clusters and exports to CSV.

.OUTPUTS
    Objects with: VMName, Cluster, PowerState, ToolsStatus, Volume, CapacityGB,
    UsedGB, FreeGB, UsedPercent

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running in the guest for disk data to be reported
    - Read access to VM guest configuration

    How to use:
      Get-Help .\Get-VMHighDiskUsage.ps1 -Full
      Get-Help .\Get-VMHighDiskUsage.ps1 -Examples

    Author:  Mike Zomer
    Version: 1.0
    Date:    August 18, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,100)]
    [int]$ThresholdPercent = 80,

    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$OutputFile = ".\VM-HighDiskUsage-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
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
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = @(Get-VM -Location $cluster)
}
else {
    $vms = @(Get-VM)
}

$poweredOn = @($vms | Where-Object { $_.PowerState -eq 'PoweredOn' })
Write-Host "Checking guest disk usage on $($poweredOn.Count) powered-on VM(s) (threshold: $ThresholdPercent%)..." -ForegroundColor Cyan

# Cluster lookup by host, avoids a Get-Cluster call per VM
$clusterByHost = @{}
foreach ($c in (Get-Cluster)) {
    foreach ($h in ($c | Get-VMHost)) { $clusterByHost[$h.Name] = $c.Name }
}

$results   = [System.Collections.Generic.List[PSCustomObject]]::new()
$noToolsVM = [System.Collections.Generic.List[string]]::new()
$vmCount   = 0

foreach ($vm in $poweredOn) {
    $vmCount++
    Write-Progress -Activity 'Collecting guest disk usage' -Status $vm.Name -PercentComplete (($vmCount / $poweredOn.Count) * 100)

    try {
        $view  = $vm | Get-View -Property Name, Guest
        $disks = @($view.Guest.Disk | Where-Object { $_ })

        if ($disks.Count -eq 0) {
            $noToolsVM.Add("$($vm.Name) [Tools: $($view.Guest.ToolsRunningStatus)]")
            continue
        }

        $clusterNameForVM = if ($clusterByHost.ContainsKey($vm.VMHost.Name)) { $clusterByHost[$vm.VMHost.Name] } else { 'N/A' }

        foreach ($disk in $disks) {
            if ($disk.Capacity -le 0) { continue }

            $usedBytes   = $disk.Capacity - $disk.FreeSpace
            $usedPercent = [math]::Round(($usedBytes / $disk.Capacity) * 100, 2)

            if ($usedPercent -ge $ThresholdPercent) {
                $results.Add([PSCustomObject]@{
                    VMName      = $vm.Name
                    Cluster     = $clusterNameForVM
                    PowerState  = $vm.PowerState
                    ToolsStatus = $view.Guest.ToolsRunningStatus
                    Volume      = $disk.DiskPath
                    CapacityGB  = [math]::Round($disk.Capacity / 1GB, 2)
                    UsedGB      = [math]::Round($usedBytes / 1GB, 2)
                    FreeGB      = [math]::Round($disk.FreeSpace / 1GB, 2)
                    UsedPercent = $usedPercent
                })
            }
        }
    }
    catch {
        Write-Warning "Error collecting guest disk usage for $($vm.Name): $_"
    }
}

Write-Progress -Activity 'Collecting guest disk usage' -Completed

$sorted = @($results | Sort-Object UsedPercent -Descending)

if ($OutputFile) {
    Write-Host "Exporting $($sorted.Count) finding(s) to: $OutputFile" -ForegroundColor Cyan
    $sorted | Export-Csv -Path $OutputFile -NoTypeInformation
}

Write-Host "`n=== VMs Over $ThresholdPercent% Disk Utilization ===" -ForegroundColor Cyan
if ($sorted.Count -gt 0) {
    $sorted | Format-Table VMName, Cluster, Volume, CapacityGB, UsedGB, FreeGB, UsedPercent -AutoSize
}
else {
    Write-Host "  No volumes at or above $ThresholdPercent% utilization." -ForegroundColor Green
}

Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  VMs in scope        : $($vms.Count)" -ForegroundColor White
Write-Host "  Powered-on VMs      : $($poweredOn.Count)" -ForegroundColor White
Write-Host "  Volumes flagged     : $($sorted.Count)" -ForegroundColor White
Write-Host "  Distinct VMs flagged: $(@($sorted | Select-Object -ExpandProperty VMName -Unique).Count)" -ForegroundColor White
if ($OutputFile) {
    Write-Host "  Output              : $OutputFile" -ForegroundColor White
}
if ($noToolsVM.Count -gt 0) {
    Write-Host "  No guest disk data  : $($noToolsVM.Count) VM(s) (VMware Tools not reporting)" -ForegroundColor Yellow
    $noToolsVM | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
}

$sorted
