<#
.SYNOPSIS
    Collects host and VM utilization, including VM folder paths.

.DESCRIPTION
    This script retrieves utilization details for all ESXi hosts and virtual machines in vCenter.
    It also includes each VM's folder path. Designed to be fast by using Summary/QuickStats
    from vCenter (no historical Get-Stat sampling). Optional CSV exports.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER IncludePoweredOff
    Optional. Include powered-off VMs in the results. Default: Only powered-on VMs.

.PARAMETER ExcludeTemplates
    Optional. Exclude template VMs from the list. Default: Include templates.

.PARAMETER OutputFolder
    Optional. Directory to export results as CSV. If not specified, displays results in console only.

.PARAMETER OutputFile
    Optional. Path to export a single combined CSV with both host and VM rows.

.PARAMETER SingleCsv
    Optional. If set (with -OutputFolder), writes a single combined CSV named InfraUtilization.csv.

.PARAMETER IncludeStats
    Optional. Include historical CPU stats (max, avg) from vCenter. Requires Get-Stat queries which are slower.

.PARAMETER Days
    Optional. Lookback period in days for historical stats. Default: 7 days. Only used with -IncludeStats.

.PARAMETER StatInterval
    Optional. Stat sampling interval in seconds. Default: 300 (5 minutes). Only used with -IncludeStats.

.EXAMPLE
    .\Get-InfraUtilizationWithFolders.ps1
    Shows host and VM utilization in console; VMs include folder paths.

.EXAMPLE
    .\Get-InfraUtilizationWithFolders.ps1 -OutputFolder .
    Exports HostUtilization.csv and VMUtilization.csv to the current directory.

.EXAMPLE
    .\Get-InfraUtilizationWithFolders.ps1 -IncludePoweredOff -ExcludeTemplates -OutputFolder C:\Reports
    Exports all VMs (including powered-off) but excludes templates.

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,

    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff,

    [Parameter(Mandatory=$false)]
    [switch]$ExcludeTemplates,

    [Parameter(Mandatory=$false)]
    [string]$OutputFolder,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$SingleCsv,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeStats,

    [Parameter(Mandatory=$false)]
    [int]$Days = 7,

    [Parameter(Mandatory=$false)]
    [int]$StatInterval = 300
)

# Connect to vCenter if specified or prompt if needed
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
    # Check for existing connection
    $existingConnection = Get-VIServer -ErrorAction SilentlyContinue
    if ($existingConnection) {
        Write-Host "Using existing vCenter connection: $($existingConnection.Name)" -ForegroundColor Yellow
    }
    else {
        # Prompt for vCenter server
        Write-Host "No active vCenter connection found." -ForegroundColor Yellow
        $vCenterInput = Read-Host "Enter vCenter server name or IP address"

        if ([string]::IsNullOrWhiteSpace($vCenterInput)) {
            Write-Error "No vCenter server specified. Exiting."
            exit 1
        }

        try {
            Write-Host "Connecting to vCenter: $vCenterInput..." -ForegroundColor Cyan
            Connect-VIServer -Server $vCenterInput -ErrorAction Stop | Out-Null
            Write-Host "Connected successfully" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to connect to vCenter: $_"
            exit 1
        }
    }
}

# Helper: Get cluster name for a HostSystem view
function Get-ClusterNameForHostView {
    param(
        [Parameter(Mandatory=$true)] [VMware.Vim.HostSystem] $HostView
    )
    try {
        $compute = Get-View -Id $HostView.Parent -ErrorAction SilentlyContinue
        return $compute.Name
    } catch {
        return $null
    }
}

# Helper: Get CPU stats for a VM (max/avg over period)
function Get-VMCpuStats {
    param(
        [Parameter(Mandatory=$true)] $VmObject,
        [Parameter(Mandatory=$true)] [int]$Days,
        [Parameter(Mandatory=$true)] [int]$StatInterval
    )
    $startTime = (Get-Date).AddDays(-$Days)
    $endTime = Get-Date
    
    try {
        $stats = Get-Stat -Entity $VmObject -Stat 'cpu.usage.average' -Start $startTime -End $endTime -IntervalMins ($StatInterval / 60) -ErrorAction SilentlyContinue
        if ($stats) {
            $maxCpuPct = [math]::Round(($stats.Value | Measure-Object -Maximum).Maximum, 1)
            $avgCpuPct = [math]::Round(($stats.Value | Measure-Object -Average).Average, 1)
            return @{ MaxCpuPct = $maxCpuPct; AvgCpuPct = $avgCpuPct }
        }
    } catch {}
    
    return @{ MaxCpuPct = $null; AvgCpuPct = $null }
}

# Helper: Compute VM folder path by walking parent folders up to root 'vm'
function Get-VMFolderPath {
    param(
        [Parameter(Mandatory=$true)] $VmView
    )
    $parts = @()
    $parentRef = $VmView.Parent
    while ($parentRef) {
        $parentView = Get-View -Id $parentRef -ErrorAction SilentlyContinue
        if ($null -eq $parentView) { break }
        if ($parentView.GetType().Name -eq 'Folder') {
            if ($parentView.Name -eq 'vm') { break }
            $parts += $parentView.Name
        }
        $parentRef = $parentView.Parent
    }
    [System.Array]::Reverse($parts)
    $parts -join '/'
}

# Collect Host Utilization
Write-Host "Retrieving host utilization..." -ForegroundColor Cyan
$hostViews = Get-View -ViewType HostSystem -ErrorAction SilentlyContinue
$hostResults = @()
foreach ($hv in $hostViews) {
    $summary = $hv.Summary
    $hw = $summary.Hardware
    $qs = $summary.QuickStats

    $cpuTotalMhz = $hw.CpuMhz * $hw.NumCpuCores
    $cpuUsedMhz = $qs.OverallCpuUsage
    $cpuPct = if ($cpuTotalMhz -gt 0) { [math]::Round(($cpuUsedMhz / $cpuTotalMhz) * 100, 1) } else { 0 }

    $memTotalMB = [math]::Round($hw.MemorySize / 1MB)
    $memUsedMB = $qs.OverallMemoryUsage
    $memPct = if ($memTotalMB -gt 0) { [math]::Round(($memUsedMB / $memTotalMB) * 100, 1) } else { 0 }

    $clusterName = Get-ClusterNameForHostView -HostView $hv

    $hostResults += [PSCustomObject]@{
        HostName      = $hv.Name
        Cluster       = $clusterName
        CpuUsedMhz    = $cpuUsedMhz
        CpuTotalMhz   = $cpuTotalMhz
        CpuUsagePct   = $cpuPct
        MemUsedMB     = $memUsedMB
        MemTotalMB    = $memTotalMB
        MemUsagePct   = $memPct
        ConnectionState = $summary.Runtime.ConnectionState
        InMaintenance   = $summary.Runtime.InMaintenanceMode
    }
}

Write-Host "  Found $($hostResults.Count) host(s)" -ForegroundColor White

# Collect VM Utilization (+ Folder Path + Core Count + Optional Stats)
Write-Host "Retrieving VM utilization and folders..." -ForegroundColor Cyan
if ($IncludeStats) {
    Write-Host "  Note: Including historical stats - this may take a while..." -ForegroundColor Yellow
}

$vmViews = Get-View -ViewType VirtualMachine -ErrorAction SilentlyContinue
if (-not $IncludePoweredOff) {
    $vmViews = $vmViews | Where-Object { $_.Runtime.PowerState -eq 'poweredOn' }
}
if ($ExcludeTemplates) {
    $vmViews = $vmViews | Where-Object { -not $_.Config.Template }
}

$vmResults = @()
foreach ($vm in $vmViews) {
    $qs = $vm.Summary.QuickStats
    $hostName = $null
    $clusterName = $null
    try {
        $hostView = Get-View -Id $vm.Runtime.Host -ErrorAction SilentlyContinue
        if ($hostView) {
            $hostName = $hostView.Name
            $clusterName = Get-ClusterNameForHostView -HostView $hostView
        }
    } catch {}

    $folderPath = Get-VMFolderPath -VmView $vm
    $numCpus = $vm.Config.Hardware.NumCpu
    
    # Get historical stats if requested
    $maxCpuPct = $null
    $avgCpuPct = $null
    $currentCpuPct = $null
    if ($IncludeStats) {
        $vmObj = Get-VM -Id $vm.MoRef -ErrorAction SilentlyContinue
        if ($vmObj) {
            $statsResult = Get-VMCpuStats -VmObject $vmObj -Days $Days -StatInterval $StatInterval
            $maxCpuPct = $statsResult.MaxCpuPct
            $avgCpuPct = $statsResult.AvgCpuPct
            
            # Calculate current CPU as percentage of available
            if ($numCpus -gt 0) {
                $currentCpuPct = [math]::Round(($qs.OverallCpuUsage / ($numCpus * 1000)) * 100, 1)
            }
        }
    }

    $vmResults += [PSCustomObject]@{
        VMName       = $vm.Name
        PowerState   = $vm.Runtime.PowerState
        IsTemplate   = $vm.Config.Template
        NumCpus      = $numCpus
        CurrentCpuPct = $currentCpuPct
        MaxCpuPct    = $maxCpuPct
        AvgCpuPct    = $avgCpuPct
        CpuUsedMhz   = $qs.OverallCpuUsage
        MemUsedMB    = $qs.GuestMemoryUsage
        Host         = $hostName
        Cluster      = $clusterName
        FolderPath   = $folderPath
    }
}

Write-Host "  Found $($vmResults.Count) VM(s) after filters" -ForegroundColor White

# Build combined results (unified schema) for optional single CSV export
$combinedResults = @()
foreach ($h in $hostResults) {
    $combinedResults += [PSCustomObject]@{
        Type            = 'Host'
        Name            = $h.HostName
        Cluster         = $h.Cluster
        Host            = $h.HostName
        CpuUsedMhz      = $h.CpuUsedMhz
        CpuTotalMhz     = $h.CpuTotalMhz
        CpuUsagePct     = $h.CpuUsagePct
        MemUsedMB       = $h.MemUsedMB
        MemTotalMB      = $h.MemTotalMB
        MemUsagePct     = $h.MemUsagePct
        PowerState      = $null
        IsTemplate      = $null
        FolderPath      = $null
        InMaintenance   = $h.InMaintenance
        ConnectionState = $h.ConnectionState
    }
}
foreach ($v in $vmResults) {
    $combinedResults += [PSCustomObject]@{
        Type            = 'VM'
        Name            = $v.VMName
        Cluster         = $v.Cluster
        Host            = $v.Host
        NumCpus         = $v.NumCpus
        CurrentCpuPct   = $v.CurrentCpuPct
        MaxCpuPct       = $v.MaxCpuPct
        AvgCpuPct       = $v.AvgCpuPct
        CpuUsedMhz      = $v.CpuUsedMhz
        CpuTotalMhz     = $null
        CpuUsagePct     = $null
        MemUsedMB       = $v.MemUsedMB
        MemTotalMB      = $null
        MemUsagePct     = $null
        PowerState      = $v.PowerState
        IsTemplate      = $v.IsTemplate
        FolderPath      = $v.FolderPath
        InMaintenance   = $null
        ConnectionState = $null
    }
}

# Output
Write-Host "\n========================================" -ForegroundColor Green
Write-Host "Infrastructure Utilization" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($OutputFile) {
    try {
        $absoluteOutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
        $combinedResults | Export-Csv -Path $absoluteOutFile -NoTypeInformation -Encoding UTF8
        Write-Host "\nResults exported to single CSV: $absoluteOutFile" -ForegroundColor Green
    } catch {
        Write-Error "Failed to export single CSV file: $_"
    }
}
elseif ($OutputFolder) {
    try {
        $absoluteOutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
        if (-not (Test-Path -LiteralPath $absoluteOutDir)) { New-Item -ItemType Directory -Path $absoluteOutDir | Out-Null }

        if ($SingleCsv) {
            $combinedCsv = Join-Path $absoluteOutDir 'InfraUtilization.csv'
            $combinedResults | Export-Csv -Path $combinedCsv -NoTypeInformation -Encoding UTF8
            Write-Host "\nResults exported to single CSV:" -ForegroundColor Green
            Write-Host "  Combined: $combinedCsv" -ForegroundColor Green
        }
        else {
            $hostCsv = Join-Path $absoluteOutDir 'HostUtilization.csv'
            $vmCsv   = Join-Path $absoluteOutDir 'VMUtilization.csv'

            $hostResults | Export-Csv -Path $hostCsv -NoTypeInformation -Encoding UTF8
            $vmResults   | Export-Csv -Path $vmCsv -NoTypeInformation -Encoding UTF8

            Write-Host "\nResults exported to:" -ForegroundColor Green
            Write-Host "  Hosts: $hostCsv" -ForegroundColor Green
            Write-Host "  VMs  : $vmCsv" -ForegroundColor Green
        }
    } catch {
        Write-Error "Failed to export CSV files: $_"
    }
}
else {
    # Console summaries
    Write-Host "\nHosts:" -ForegroundColor Cyan
    $hostResults | Sort-Object Cluster, HostName | Format-Table -AutoSize HostName, Cluster, CpuUsagePct, MemUsagePct, InMaintenance

    Write-Host "\nVMs (with folders):" -ForegroundColor Cyan
    if ($IncludeStats) {
        $vmResults | Sort-Object Cluster, Host, VMName | Format-Table -AutoSize VMName, NumCpus, CurrentCpuPct, MaxCpuPct, AvgCpuPct, PowerState, Cluster, Host, FolderPath
    }
    else {
        $vmResults | Sort-Object Cluster, Host, VMName | Format-Table -AutoSize VMName, NumCpus, CpuUsedMhz, MemUsedMB, PowerState, Cluster, Host, FolderPath
    }
}

# Summary statistics
Write-Host "\n========================================" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Hosts: $($hostResults.Count)" -ForegroundColor White
Write-Host "  VMs  : $($vmResults.Count)" -ForegroundColor White
$vmPoweredOn = ($vmResults | Where-Object { $_.PowerState -eq 'poweredOn' }).Count
$vmPoweredOff = ($vmResults | Where-Object { $_.PowerState -ne 'poweredOn' }).Count
Write-Host "  Powered On VMs : $vmPoweredOn" -ForegroundColor White
Write-Host "  Powered Off VMs: $vmPoweredOff" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
