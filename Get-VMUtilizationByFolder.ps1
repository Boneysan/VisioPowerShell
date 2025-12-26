<#
.SYNOPSIS
    Retrieves VM resource utilization statistics for all VMs grouped by folder.

.DESCRIPTION
    This script collects actual CPU, Memory, Disk, and Network performance statistics
    using Get-Stat for all VMs across all folders in vCenter. Results are organized
    by folder with individual VM metrics and folder-level aggregates.
    
    Unlike event-based approaches, this uses vCenter's performance statistics to
    provide real utilization data including averages, maximums, and minimums.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER Hours
    Optional. Number of hours to look back for statistics. Default: 1 hour.
    Valid range: 0.25 (15 minutes) to 720 (30 days, depending on vCenter stats settings).

.PARAMETER IncludePoweredOff
    Optional. Include powered-off VMs in the results. Default: Only powered-on VMs.

.PARAMETER OutputFile
    Optional. Path to export detailed results as CSV. If not specified, displays results in console.

.PARAMETER FolderSummaryFile
    Optional. Path to export folder-level summary as CSV.

.PARAMETER ExcludeTemplates
    Optional. Exclude template VMs from statistics collection. Default: Include templates.

.EXAMPLE
    .\Get-VMUtilizationByFolder.ps1
    Shows utilization for all VMs grouped by folder over the last hour.

.EXAMPLE
    .\Get-VMUtilizationByFolder.ps1 -Hours 24 -OutputFile "vm-stats.csv"
    Collects 24 hours of stats and exports to CSV.

.EXAMPLE
    .\Get-VMUtilizationByFolder.ps1 -vCenter "vcenter.example.com" -Hours 4 -FolderSummaryFile "folder-summary.csv"
    Connects to vCenter, analyzes 4 hours, and exports folder summaries.

.EXAMPLE
    .\Get-VMUtilizationByFolder.ps1 -ExcludeTemplates -IncludePoweredOff
    Shows stats for all VMs (including powered off) but excludes templates.

.OUTPUTS
    Console output or CSV file with VM-level statistics:
    - VMName: Virtual machine name
    - Folder: VM folder location
    - FolderPath: Full folder path
    - PowerState: Current power state
    - IsTemplate: Whether the VM is a template
    - AvgCPU_Percent: Average CPU usage percentage
    - MaxCPU_Percent: Peak CPU usage percentage
    - MinCPU_Percent: Minimum CPU usage percentage
    - AvgMemory_Percent: Average memory usage percentage
    - MaxMemory_Percent: Peak memory usage percentage
    - MinMemory_Percent: Minimum memory usage percentage
    - AvgDiskRead_KBps: Average disk read throughput
    - AvgDiskWrite_KBps: Average disk write throughput
    - MaxDiskRead_KBps: Peak disk read throughput
    - MaxDiskWrite_KBps: Peak disk write throughput
    - AvgNetworkRx_KBps: Average network receive throughput
    - AvgNetworkTx_KBps: Average network transmit throughput
    - MaxNetworkRx_KBps: Peak network receive throughput
    - MaxNetworkTx_KBps: Peak network transmit throughput
    - NumCPU: Number of virtual CPUs
    - MemoryGB: Total configured RAM
    - DataPoints: Number of statistics samples collected

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter and VM statistics
    - vCenter must have statistics collection enabled
    
    Performance Metrics:
    - cpu.usage.average: CPU usage as percentage
    - mem.usage.average: Memory usage as percentage  
    - disk.read.average: Disk read rate in KBps
    - disk.write.average: Disk write rate in KBps
    - net.received.average: Network receive rate in KBps
    - net.transmitted.average: Network transmit rate in KBps
    
    Statistics Intervals:
    - Real-time (20 seconds): Up to 1 hour of data
    - Level 1 (5 minutes): Up to 1 day of data
    - Level 2 (30 minutes): Up to 1 week of data
    - Level 3 (2 hours): Up to 1 month of data
    - Level 4 (1 day): Up to 1 year of data
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(0.25, 720)]
    [double]$Hours = 1,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile,
    
    [Parameter(Mandatory=$false)]
    [string]$FolderSummaryFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$ExcludeTemplates
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

# Calculate time range
$endTime = Get-Date
$startTime = $endTime.AddHours(-$Hours)

Write-Host "`nCollecting statistics from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))..." -ForegroundColor Cyan

# Get all VM folders
Write-Host "Retrieving VM folders..." -ForegroundColor Cyan
$folders = Get-Folder -Type VM | Sort-Object Name

Write-Host "  Found $($folders.Count) VM folder(s)" -ForegroundColor White

# Define stat types to collect
$statTypes = @(
    'cpu.usage.average',
    'mem.usage.average',
    'disk.read.average',
    'disk.write.average',
    'net.received.average',
    'net.transmitted.average'
)

$allResults = @()
$folderSummaries = @()
$totalVMs = 0
$processedVMs = 0

foreach ($folder in $folders) {
    Write-Host "`nProcessing folder: $($folder.Name)" -ForegroundColor Cyan
    
    # Get VMs in this folder (non-recursive)
    $vms = Get-VM -Location $folder -ErrorAction SilentlyContinue
    
    # Apply filters
    if (-not $IncludePoweredOff) {
        $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
    }
    
    if ($ExcludeTemplates) {
        $vms = $vms | Where-Object { -not $_.ExtensionData.Config.Template }
    }
    
    if ($vms.Count -eq 0) {
        Write-Host "  No VMs found in this folder (after applying filters)" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  Found $($vms.Count) VM(s)" -ForegroundColor White
    $totalVMs += $vms.Count
    
    # Build folder path
    $folderPath = $folder.Name
    $parent = $folder.Parent
    while ($parent -and $parent.Name -ne 'vm') {
        $folderPath = "$($parent.Name)/$folderPath"
        $parent = $parent.Parent
    }
    
    $folderResults = @()
    
    foreach ($vm in $vms) {
        $processedVMs++
        Write-Host "  [$processedVMs/$totalVMs] Processing: $($vm.Name)..." -ForegroundColor White
        
        try {
            # Only collect stats for powered-on VMs
            if ($vm.PowerState -eq 'PoweredOn') {
                # Get statistics for this VM
                $stats = Get-Stat -Entity $vm -Stat $statTypes -Start $startTime -Finish $endTime -ErrorAction Stop
                
                if ($stats) {
                    # Group stats by metric type and calculate aggregates
                    $cpuStats = $stats | Where-Object { $_.MetricId -eq 'cpu.usage.average' }
                    $memStats = $stats | Where-Object { $_.MetricId -eq 'mem.usage.average' }
                    $diskReadStats = $stats | Where-Object { $_.MetricId -eq 'disk.read.average' }
                    $diskWriteStats = $stats | Where-Object { $_.MetricId -eq 'disk.write.average' }
                    $netRxStats = $stats | Where-Object { $_.MetricId -eq 'net.received.average' }
                    $netTxStats = $stats | Where-Object { $_.MetricId -eq 'net.transmitted.average' }
                    
                    $result = [PSCustomObject]@{
                        VMName = $vm.Name
                        Folder = $folder.Name
                        FolderPath = $folderPath
                        PowerState = $vm.PowerState
                        IsTemplate = $vm.ExtensionData.Config.Template
                        NumCPU = $vm.NumCpu
                        MemoryGB = $vm.MemoryGB
                        AvgCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        MinCPU_Percent = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Minimum).Minimum, 2) } else { 0 }
                        AvgMemory_Percent = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxMemory_Percent = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        MinMemory_Percent = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Minimum).Minimum, 2) } else { 0 }
                        AvgDiskRead_KBps = if ($diskReadStats) { [math]::Round(($diskReadStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxDiskRead_KBps = if ($diskReadStats) { [math]::Round(($diskReadStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        AvgDiskWrite_KBps = if ($diskWriteStats) { [math]::Round(($diskWriteStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxDiskWrite_KBps = if ($diskWriteStats) { [math]::Round(($diskWriteStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        AvgNetworkRx_KBps = if ($netRxStats) { [math]::Round(($netRxStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxNetworkRx_KBps = if ($netRxStats) { [math]::Round(($netRxStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        AvgNetworkTx_KBps = if ($netTxStats) { [math]::Round(($netTxStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
                        MaxNetworkTx_KBps = if ($netTxStats) { [math]::Round(($netTxStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
                        DataPoints = $stats.Count
                    }
                    
                    Write-Host "    CPU: $($result.AvgCPU_Percent)% avg, Mem: $($result.AvgMemory_Percent)% avg" -ForegroundColor Green
                }
                else {
                    Write-Host "    No statistics available" -ForegroundColor Yellow
                    $result = [PSCustomObject]@{
                        VMName = $vm.Name
                        Folder = $folder.Name
                        FolderPath = $folderPath
                        PowerState = $vm.PowerState
                        IsTemplate = $vm.ExtensionData.Config.Template
                        NumCPU = $vm.NumCpu
                        MemoryGB = $vm.MemoryGB
                        AvgCPU_Percent = 0
                        MaxCPU_Percent = 0
                        MinCPU_Percent = 0
                        AvgMemory_Percent = 0
                        MaxMemory_Percent = 0
                        MinMemory_Percent = 0
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
            else {
                # Powered off VM
                Write-Host "    VM is powered off - no statistics" -ForegroundColor Gray
                $result = [PSCustomObject]@{
                    VMName = $vm.Name
                    Folder = $folder.Name
                    FolderPath = $folderPath
                    PowerState = $vm.PowerState
                    IsTemplate = $vm.ExtensionData.Config.Template
                    NumCPU = $vm.NumCpu
                    MemoryGB = $vm.MemoryGB
                    AvgCPU_Percent = 0
                    MaxCPU_Percent = 0
                    MinCPU_Percent = 0
                    AvgMemory_Percent = 0
                    MaxMemory_Percent = 0
                    MinMemory_Percent = 0
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
            
            $folderResults += $result
            $allResults += $result
        }
        catch {
            Write-Warning "    Error collecting stats for $($vm.Name): $_"
        }
    }
    
    # Calculate folder-level summary
    if ($folderResults.Count -gt 0) {
        $poweredOnVMs = $folderResults | Where-Object { $_.PowerState -eq 'PoweredOn' }
        
        $folderSummary = [PSCustomObject]@{
            Folder = $folder.Name
            FolderPath = $folderPath
            TotalVMs = $folderResults.Count
            PoweredOnVMs = $poweredOnVMs.Count
            PoweredOffVMs = ($folderResults | Where-Object { $_.PowerState -ne 'PoweredOn' }).Count
            Templates = ($folderResults | Where-Object { $_.IsTemplate }).Count
            TotalCPUs = ($folderResults | Measure-Object -Property NumCPU -Sum).Sum
            TotalMemoryGB = [math]::Round(($folderResults | Measure-Object -Property MemoryGB -Sum).Sum, 2)
            AvgCPU_Percent = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgCPU_Percent -Average).Average, 2) } else { 0 }
            MaxCPU_Percent = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property MaxCPU_Percent -Maximum).Maximum, 2) } else { 0 }
            AvgMemory_Percent = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgMemory_Percent -Average).Average, 2) } else { 0 }
            MaxMemory_Percent = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property MaxMemory_Percent -Maximum).Maximum, 2) } else { 0 }
            TotalDiskRead_KBps = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgDiskRead_KBps -Sum).Sum, 2) } else { 0 }
            TotalDiskWrite_KBps = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgDiskWrite_KBps -Sum).Sum, 2) } else { 0 }
            TotalNetworkRx_KBps = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgNetworkRx_KBps -Sum).Sum, 2) } else { 0 }
            TotalNetworkTx_KBps = if ($poweredOnVMs) { [math]::Round(($poweredOnVMs | Measure-Object -Property AvgNetworkTx_KBps -Sum).Sum, 2) } else { 0 }
        }
        
        $folderSummaries += $folderSummary
    }
}

# Output results
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "VM Utilization Summary" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Export detailed results
if ($OutputFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $allResults | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "`nDetailed VM results exported to: $absolutePath" -ForegroundColor Green
}

# Export folder summaries
if ($FolderSummaryFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FolderSummaryFile)
    $folderSummaries | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "Folder summaries exported to: $absolutePath" -ForegroundColor Green
}

# Display folder summaries
Write-Host "`nFolder-Level Summary:" -ForegroundColor Cyan
$folderSummaries | Format-Table Folder, TotalVMs, PoweredOnVMs, AvgCPU_Percent, AvgMemory_Percent, TotalMemoryGB -AutoSize

# Display top consumers
Write-Host "`nTop 10 CPU Consumers:" -ForegroundColor Cyan
$allResults | Where-Object { $_.PowerState -eq 'PoweredOn' } | 
    Sort-Object AvgCPU_Percent -Descending | 
    Select-Object VMName, Folder, AvgCPU_Percent, MaxCPU_Percent -First 10 | 
    Format-Table -AutoSize

Write-Host "`nTop 10 Memory Consumers:" -ForegroundColor Cyan
$allResults | Where-Object { $_.PowerState -eq 'PoweredOn' } | 
    Sort-Object AvgMemory_Percent -Descending | 
    Select-Object VMName, Folder, AvgMemory_Percent, MaxMemory_Percent, MemoryGB -First 10 | 
    Format-Table -AutoSize

Write-Host "`nTop 10 Network Consumers:" -ForegroundColor Cyan
$allResults | Where-Object { $_.PowerState -eq 'PoweredOn' } | 
    Sort-Object { $_.AvgNetworkRx_KBps + $_.AvgNetworkTx_KBps } -Descending | 
    Select-Object VMName, Folder, AvgNetworkRx_KBps, AvgNetworkTx_KBps -First 10 | 
    Format-Table -AutoSize

# Overall statistics
Write-Host "`nOverall Statistics:" -ForegroundColor Cyan
$totalPoweredOn = ($allResults | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
$totalPoweredOff = ($allResults | Where-Object { $_.PowerState -ne 'PoweredOn' }).Count

Write-Host "  Total VMs processed: $($allResults.Count)" -ForegroundColor White
Write-Host "  Powered On: $totalPoweredOn" -ForegroundColor White
Write-Host "  Powered Off: $totalPoweredOff" -ForegroundColor White
Write-Host "  Total Folders: $($folderSummaries.Count)" -ForegroundColor White
Write-Host "  Time period: $Hours hour(s)" -ForegroundColor White
