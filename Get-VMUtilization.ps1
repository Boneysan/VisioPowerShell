<#
.SYNOPSIS
    Retrieves VM resource utilization statistics for VMs in a specified folder.

.DESCRIPTION
    This script collects CPU, Memory, Disk, and Network utilization metrics for all VMs
    within a specified folder over a configurable time period. It provides average, maximum,
    and minimum values for each metric, helping identify resource usage patterns and potential
    performance issues.
    
    The script uses vCenter historical statistics and can analyze data from the past hour
    up to several days, depending on vCenter statistics collection settings.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER FolderPath
    Required. The path to the VM folder to analyze. Use forward slashes for nested folders.
    Examples: "Production", "Development/WebServers", "VDI/Users"
    
    Note: This is the folder name as shown in vCenter, not the full inventory path.

.PARAMETER Hours
    Optional. Number of hours to look back for statistics. Default: 1 hour.
    Valid range: 0.25 (15 minutes) to 720 (30 days, depending on vCenter stats settings).

.PARAMETER IntervalMinutes
    Optional. Statistics collection interval in minutes. Default: 5 minutes.
    Smaller intervals provide more granular data but may take longer to retrieve.

.PARAMETER OutputFile
    Optional. Path to export results as CSV. If not specified, displays results in console.

.PARAMETER IncludePoweredOff
    Optional. Include powered-off VMs in the results. Default: Only powered-on VMs.

.EXAMPLE
    .\Get-VMUtilization.ps1 -FolderPath "Production"
    Shows utilization for all VMs in the Production folder over the last hour.

.EXAMPLE
    .\Get-VMUtilization.ps1 -FolderPath "Development/WebServers" -Hours 24
    Shows 24-hour utilization for VMs in Development/WebServers folder.

.EXAMPLE
    .\Get-VMUtilization.ps1 -vCenter "vcenter.example.com" -FolderPath "VDI" -Hours 4 -OutputFile "vdi-stats.csv"
    Connects to vCenter, analyzes 4 hours of VDI VM stats, exports to CSV.

.EXAMPLE
    .\Get-VMUtilization.ps1 -FolderPath "Production" -IntervalMinutes 1 -Hours 0.5
    Shows 30 minutes of stats with 1-minute intervals for detailed analysis.

.OUTPUTS
    Console output or CSV file with the following columns:
    - VMName: Virtual machine name
    - Folder: VM folder location
    - PowerState: Current power state
    - AvgCPU_Percent: Average CPU usage percentage
    - MaxCPU_Percent: Peak CPU usage percentage
    - AvgMemory_Percent: Average memory usage percentage
    - MaxMemory_Percent: Peak memory usage percentage
    - AvgMemory_MB: Average active memory in MB
    - AvgDiskRead_KBps: Average disk read throughput
    - AvgDiskWrite_KBps: Average disk write throughput
    - AvgNetworkRx_KBps: Average network receive throughput
    - AvgNetworkTx_KBps: Average network transmit throughput
    - NumCPU: Number of CPUs
    - MemoryGB: Total configured RAM
    - DataPoints: Number of statistics samples collected

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter and VM statistics
    - vCenter must have statistics collection enabled at the desired interval
    
    Statistics Intervals:
    - Real-time (20 seconds): Up to 1 hour of data
    - Level 1 (5 minutes): Up to 1 day of data
    - Level 2 (30 minutes): Up to 1 week of data
    - Level 3 (2 hours): Up to 1 month of data
    - Level 4 (1 day): Up to 1 year of data
    
    Performance:
    - Retrieval time depends on number of VMs, time range, and interval
    - Typically 1-5 seconds per VM for 1 hour of data
    - Use larger intervals for faster results with large time ranges
    
    Limitations:
    - Historical data availability depends on vCenter statistics settings
    - Very old data may not be available if vCenter retention is limited
    - Powered-off VMs have no statistics unless -IncludePoweredOff is used
    
    Metrics Explained:
    - CPU %: Percentage of total CPU resources used (0-100 per vCPU)
    - Memory %: Percentage of configured memory actively used
    - Disk KBps: Kilobytes per second read/write
    - Network KBps: Kilobytes per second received/transmitted
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(0.25, 720)]
    [double]$Hours = 1,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet(1, 5, 15, 30, 60, 120)]
    [int]$IntervalMinutes = 5,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff
)

# Connect to vCenter if specified
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

Write-Host "Looking for folder: $FolderPath..." -ForegroundColor Cyan

# Find the folder
$folder = Get-Folder -Name $FolderPath -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'VM' }

if (-not $folder) {
    Write-Error "Folder '$FolderPath' not found. Please check the folder name and try again."
    Write-Host "`nAvailable VM folders:" -ForegroundColor Yellow
    Get-Folder -Type VM | Select-Object Name, Parent | Format-Table -AutoSize
    exit 1
}

if ($folder -is [array]) {
    Write-Warning "Multiple folders found with name '$FolderPath'. Using first match: $($folder[0].Name) in $($folder[0].Parent.Name)"
    $folder = $folder[0]
}

Write-Host "Found folder: $($folder.Name)" -ForegroundColor Green

# Get VMs from the folder
Write-Host "Retrieving VMs from folder..." -ForegroundColor Cyan
$vms = Get-VM -Location $folder

if (-not $IncludePoweredOff) {
    $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
}

if ($vms.Count -eq 0) {
    Write-Error "No VMs found in folder '$FolderPath'"
    exit 1
}

Write-Host "  Found $($vms.Count) VM(s)" -ForegroundColor White

# Calculate time range
$endTime = Get-Date
$startTime = $endTime.AddHours(-$Hours)

Write-Host "`nCollecting statistics from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))..." -ForegroundColor Cyan
Write-Host "  Interval: $IntervalMinutes minute(s)" -ForegroundColor White

# Define statistics to collect
$statTypes = @(
    'cpu.usage.average',           # CPU usage %
    'mem.usage.average',           # Memory usage %
    'mem.active.average',          # Active memory KB
    'disk.read.average',           # Disk read KB/s
    'disk.write.average',          # Disk write KB/s
    'net.received.average',        # Network received KB/s
    'net.transmitted.average'      # Network transmitted KB/s
)

$results = @()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  Processing [$vmCount/$($vms.Count)]: $($vm.Name)..." -ForegroundColor White
    
    try {
        # Get statistics for this VM
        $stats = Get-Stat -Entity $vm -Stat $statTypes -Start $startTime -Finish $endTime -IntervalMins $IntervalMinutes -ErrorAction Stop
        
        if ($stats) {
            # Calculate averages and maximums for each metric
            $cpuStats = $stats | Where-Object { $_.MetricId -eq 'cpu.usage.average' }
            $memUsageStats = $stats | Where-Object { $_.MetricId -eq 'mem.usage.average' }
            $memActiveStats = $stats | Where-Object { $_.MetricId -eq 'mem.active.average' }
            $diskReadStats = $stats | Where-Object { $_.MetricId -eq 'disk.read.average' }
            $diskWriteStats = $stats | Where-Object { $_.MetricId -eq 'disk.write.average' }
            $netRxStats = $stats | Where-Object { $_.MetricId -eq 'net.received.average' }
            $netTxStats = $stats | Where-Object { $_.MetricId -eq 'net.transmitted.average' }
            
            $results += [PSCustomObject]@{
                VMName = $vm.Name
                Folder = $folder.Name
                PowerState = $vm.PowerState
                NumCPU = $vm.NumCpu
                MemoryGB = $vm.MemoryGB
                AvgCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                MinCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Minimum).Minimum, 2) } else { 0 }
                AvgMemory_Percent = if ($memUsageStats) { [math]::Round(($memUsageStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxMemory_Percent = if ($memUsageStats) { [math]::Round(($memUsageStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                AvgMemory_MB = if ($memActiveStats) { [math]::Round(($memActiveStats | Measure-Object -Property Value -Average).Average / 1024, 0) } else { 0 }
                AvgDiskRead_KBps = if ($diskReadStats) { [math]::Round(($diskReadStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxDiskRead_KBps = if ($diskReadStats) { [math]::Round(($diskReadStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                AvgDiskWrite_KBps = if ($diskWriteStats) { [math]::Round(($diskWriteStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxDiskWrite_KBps = if ($diskWriteStats) { [math]::Round(($diskWriteStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                AvgNetworkRx_KBps = if ($netRxStats) { [math]::Round(($netRxStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxNetworkRx_KBps = if ($netRxStats) { [math]::Round(($netRxStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                AvgNetworkTx_KBps = if ($netTxStats) { [math]::Round(($netTxStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                MaxNetworkTx_KBps = if ($netTxStats) { [math]::Round(($netTxStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                DataPoints = $cpuStats.Count
            }
        }
        else {
            Write-Warning "    No statistics available for $($vm.Name)"
            $results += [PSCustomObject]@{
                VMName = $vm.Name
                Folder = $folder.Name
                PowerState = $vm.PowerState
                NumCPU = $vm.NumCpu
                MemoryGB = $vm.MemoryGB
                AvgCPU_Percent = 0
                MaxCPU_Percent = 0
                MinCPU_Percent = 0
                AvgMemory_Percent = 0
                MaxMemory_Percent = 0
                AvgMemory_MB = 0
                AvgDiskRead_KBps = 0
                MaxDiskRead_KBps = 0
                AvgDiskWrite_KBps = 0
                MaxDiskWrite_KBps = 0
                AvgNetworkRx_KBps = 0
                MaxNetworkRx_KBps = 0
                AvgNetworkTx_KBps = 0
                MaxNetworkTx_KBps = 0
                DataPoints = 0
            }
        }
    }
    catch {
        Write-Warning "    Error collecting stats for $($vm.Name): $_"
    }
}

# Sort by average CPU usage descending
$results = $results | Sort-Object AvgCPU_Percent -Descending

# Output results
Write-Host "`nUtilization Summary:" -ForegroundColor Green
Write-Host "===================" -ForegroundColor Green

if ($OutputFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $results | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $absolutePath" -ForegroundColor Green
    
    # Display summary statistics
    Write-Host "`nTop 10 VMs by CPU Usage:" -ForegroundColor Cyan
    $results | Select-Object VMName, AvgCPU_Percent, MaxCPU_Percent, AvgMemory_Percent, NumCPU, MemoryGB -First 10 | Format-Table -AutoSize
}
else {
    $results | Format-Table -AutoSize
}

# Display aggregate statistics
Write-Host "`nAggregate Statistics:" -ForegroundColor Cyan
Write-Host "  Total VMs analyzed: $($results.Count)" -ForegroundColor White
Write-Host "  Average CPU across all VMs: $([math]::Round(($results | Measure-Object -Property AvgCPU_Percent -Average).Average, 2))%" -ForegroundColor White
Write-Host "  Average Memory across all VMs: $([math]::Round(($results | Measure-Object -Property AvgMemory_Percent -Average).Average, 2))%" -ForegroundColor White
Write-Host "  Peak CPU usage: $([math]::Round(($results | Measure-Object -Property MaxCPU_Percent -Maximum).Maximum, 2))% ($($results | Sort-Object MaxCPU_Percent -Descending | Select-Object -First 1 -ExpandProperty VMName))" -ForegroundColor White
Write-Host "  Peak Memory usage: $([math]::Round(($results | Measure-Object -Property MaxMemory_Percent -Maximum).Maximum, 2))% ($($results | Sort-Object MaxMemory_Percent -Descending | Select-Object -First 1 -ExpandProperty VMName))" -ForegroundColor White

# Identify potential issues
Write-Host "`nPotential Issues:" -ForegroundColor Yellow
$highCPU = $results | Where-Object { $_.AvgCPU_Percent -gt 80 }
$highMem = $results | Where-Object { $_.AvgMemory_Percent -gt 90 }
$noData = $results | Where-Object { $_.DataPoints -eq 0 }

if ($highCPU) {
    Write-Host "  High CPU (>80% avg): $($highCPU.Count) VM(s)" -ForegroundColor Red
    $highCPU | Select-Object VMName, AvgCPU_Percent, MaxCPU_Percent | Format-Table -AutoSize
}

if ($highMem) {
    Write-Host "  High Memory (>90% avg): $($highMem.Count) VM(s)" -ForegroundColor Red
    $highMem | Select-Object VMName, AvgMemory_Percent, MaxMemory_Percent | Format-Table -AutoSize
}

if ($noData) {
    Write-Host "  No statistics available: $($noData.Count) VM(s)" -ForegroundColor Yellow
    Write-Host "    (These VMs may have been powered off or have insufficient statistics collection)" -ForegroundColor Gray
}

if (-not $highCPU -and -not $highMem) {
    Write-Host "  No critical resource issues detected." -ForegroundColor Green
}
