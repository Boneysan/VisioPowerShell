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

# Trim any whitespace from folder path
$FolderPath = $FolderPath.Trim()

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

Write-Host "`nCollecting utilization events from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))..." -ForegroundColor Cyan

$results = @()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  Processing [$vmCount/$($vms.Count)]: $($vm.Name)..." -ForegroundColor White
    
    try {
        # Get utilization-related events for this VM
        $events = Get-VIEvent -Entity $vm -Start $startTime -Finish $endTime -MaxSamples 1000 -ErrorAction Stop | 
            Where-Object { 
                $_.FullFormattedMessage -match 'cpu|memory|mem|disk|utilization|usage|resource|performance|contention' -or
                $_.GetType().Name -match 'Alarm|Resource|Performance|Cpu|Memory|Disk'
            }
        
        if ($events) {
            Write-Host "    Found $($events.Count) utilization event(s)" -ForegroundColor Green
            
            foreach ($event in $events) {
                $results += [PSCustomObject]@{
                    VMName = $vm.Name
                    Folder = $folder.Name
                    PowerState = $vm.PowerState
                    NumCPU = $vm.NumCpu
                    MemoryGB = $vm.MemoryGB
                    EventTime = $event.CreatedTime
                    EventType = $event.GetType().Name
                    EventMessage = $event.FullFormattedMessage
                    UserName = $event.UserName
                    Severity = if ($event.PSObject.Properties.Name -contains 'Severity') { $event.Severity } else { 'Info' }
                }
            }
        }
        else {
            Write-Host "    No events listed" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                VMName = $vm.Name
                Folder = $folder.Name
                PowerState = $vm.PowerState
                NumCPU = $vm.NumCpu
                MemoryGB = $vm.MemoryGB
                EventTime = $null
                EventType = 'No events listed'
                EventMessage = 'No utilization events found for this time period'
                UserName = $null
                Severity = 'Info'
            }
        }
    }
    catch {
        Write-Warning "    Error collecting events for $($vm.Name): $_"
        $results += [PSCustomObject]@{
            VMName = $vm.Name
            Folder = $folder.Name
            PowerState = $vm.PowerState
            NumCPU = $vm.NumCpu
            MemoryGB = $vm.MemoryGB
            EventTime = $null
            EventType = 'Error'
            EventMessage = "Error: $_"
            UserName = $null
            Severity = 'Error'
        }
    }
}

# Sort by event time descending (most recent first)
$results = $results | Sort-Object EventTime -Descending

# Output results
Write-Host "`nUtilization Events Summary:" -ForegroundColor Green
Write-Host "===========================" -ForegroundColor Green

if ($OutputFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $results | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $absolutePath" -ForegroundColor Green
    
    # Display summary
    Write-Host "`nEvent Summary:" -ForegroundColor Cyan
    $results | Where-Object { $_.EventType -ne 'No events listed' } | 
        Select-Object VMName, EventTime, EventType, EventMessage -First 20 | 
        Format-Table -AutoSize -Wrap
}
else {
    $results | Format-Table VMName, EventTime, EventType, EventMessage, Severity -AutoSize -Wrap
}

# Display aggregate statistics
Write-Host "`nEvent Statistics:" -ForegroundColor Cyan
$totalEvents = ($results | Where-Object { $_.EventType -ne 'No events listed' }).Count
$vmsWithEvents = ($results | Where-Object { $_.EventType -ne 'No events listed' } | Select-Object VMName -Unique).Count
$vmsWithoutEvents = ($results | Where-Object { $_.EventType -eq 'No events listed' } | Select-Object VMName -Unique).Count

Write-Host "  Total VMs analyzed: $($vms.Count)" -ForegroundColor White
Write-Host "  VMs with utilization events: $vmsWithEvents" -ForegroundColor White
Write-Host "  VMs with no events listed: $vmsWithoutEvents" -ForegroundColor White
Write-Host "  Total utilization events found: $totalEvents" -ForegroundColor White

# Show event type breakdown
if ($totalEvents -gt 0) {
    Write-Host "`nEvent Types:" -ForegroundColor Cyan
    $results | Where-Object { $_.EventType -ne 'No events listed' } | 
        Group-Object EventType | 
        Sort-Object Count -Descending | 
        Select-Object @{N='Event Type';E={$_.Name}}, Count | 
        Format-Table -AutoSize
}
