<#
.SYNOPSIS
    Analyzes host utilization and provides VM placement recommendations.

.DESCRIPTION
    This script collects detailed ESXi host utilization metrics including CPU, memory, 
    storage, and VM counts. It analyzes resource distribution across hosts and provides 
    recommendations for optimal VM placement and load balancing.
    
    The output helps identify overutilized hosts, suggests VM migration targets, and 
    enables data-driven decisions for capacity planning and workload distribution.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER Cluster
    Optional. The cluster name to analyze. If not specified, analyzes all clusters.

.PARAMETER OutputFile
    Optional. Path to export results as CSV. If not specified, displays results only.

.PARAMETER ShowRecommendations
    Optional. Display VM placement recommendations. Default: True.

.PARAMETER CPUThreshold
    Optional. CPU utilization percentage threshold for identifying overutilized hosts. Default: 80.

.PARAMETER MemoryThreshold
    Optional. Memory utilization percentage threshold for identifying overutilized hosts. Default: 80.

.PARAMETER TopVMs
    Optional. Number of top resource-consuming VMs to show per host. Default: 5.

.EXAMPLE
    .\Get-VMHostUtilization.ps1
    Displays utilization for all hosts with recommendations.

.EXAMPLE
    .\Get-VMHostUtilization.ps1 -Cluster "Production" -OutputFile "host-util.csv"
    Analyzes Production cluster and exports to CSV.

.EXAMPLE
    .\Get-VMHostUtilization.ps1 -Cluster "Production" -CPUThreshold 70 -MemoryThreshold 75
    Uses custom thresholds for identifying overutilized hosts.

.OUTPUTS
    Console display with:
    - Host utilization summary (CPU, Memory, Storage, VM count)
    - Overutilized hosts identification
    - Top resource-consuming VMs per host
    - VM placement recommendations
    
    Optional CSV output with columns:
    - HostName, Cluster, ConnectionState, PowerState
    - CPUUsageMhz, CPUTotalMhz, CPUUsagePercent
    - MemoryUsageGB, MemoryTotalGB, MemoryUsagePercent
    - VMCount, PoweredOnVMs, PoweredOffVMs
    - Status (Normal/High CPU/High Memory/Overutilized)

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter and host inventory
    
    Performance:
    - Retrieval time depends on number of hosts and VMs
    - Real-time stats collection may take 10-30 seconds per host
    
    Use Cases:
    - Load balancing and VM placement decisions
    - Capacity planning and resource optimization
    - Identifying migration candidates for maintenance
    - DRS effectiveness analysis
    - Pre-maintenance host evacuation planning
    
    Author: GitHub Copilot
    Version: 1.0
    Date: December 16, 2025
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [string]$Cluster,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowRecommendations = $true,
    
    [Parameter(Mandatory=$false)]
    [int]$CPUThreshold = 80,
    
    [Parameter(Mandatory=$false)]
    [int]$MemoryThreshold = 80,
    
    [Parameter(Mandatory=$false)]
    [int]$TopVMs = 5
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

# Get hosts based on cluster or all hosts
if ($Cluster) {
    Write-Host "Looking for cluster: $Cluster..." -ForegroundColor Cyan
    
    $clusterObj = Get-Cluster -Name $Cluster -ErrorAction SilentlyContinue
    
    if (-not $clusterObj) {
        Write-Error "Cluster '$Cluster' not found. Please check the cluster name and try again."
        Write-Host "`nAvailable clusters:" -ForegroundColor Yellow
        Get-Cluster | Select-Object Name | Format-Table -AutoSize
        exit 1
    }
    
    Write-Host "Found cluster: $($clusterObj.Name)" -ForegroundColor Green
    Write-Host "Retrieving hosts from cluster..." -ForegroundColor Cyan
    $vmHosts = Get-VMHost -Location $clusterObj | Where-Object { $_.ConnectionState -eq 'Connected' }
}
else {
    Write-Host "Retrieving all connected hosts..." -ForegroundColor Cyan
    $vmHosts = Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' }
}

if ($vmHosts.Count -eq 0) {
    Write-Error "No connected hosts found"
    exit 1
}

Write-Host "  Found $($vmHosts.Count) connected host(s)" -ForegroundColor White
Write-Host "`nCollecting host utilization data..." -ForegroundColor Cyan

$results = @()
$hostCount = 0

foreach ($vmHost in $vmHosts) {
    $hostCount++
    Write-Host "  Processing [$hostCount/$($vmHosts.Count)]: $($vmHost.Name)..." -ForegroundColor White
    
    try {
        # Get VMs on this host
        $vms = Get-VM -Location $vmHost -ErrorAction SilentlyContinue
        $poweredOnVMs = ($vms | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
        $poweredOffVMs = ($vms | Where-Object { $_.PowerState -eq 'PoweredOff' }).Count
        
        # Calculate percentages
        $cpuUsagePercent = if ($vmHost.CpuTotalMhz -gt 0) { 
            [math]::Round(($vmHost.CpuUsageMhz / $vmHost.CpuTotalMhz) * 100, 2) 
        } else { 0 }
        
        $memoryUsagePercent = if ($vmHost.MemoryTotalGB -gt 0) { 
            [math]::Round(($vmHost.MemoryUsageGB / $vmHost.MemoryTotalGB) * 100, 2) 
        } else { 0 }
        
        # Determine status
        $status = "Normal"
        if ($cpuUsagePercent -ge $CPUThreshold -and $memoryUsagePercent -ge $MemoryThreshold) {
            $status = "Overutilized"
        } elseif ($cpuUsagePercent -ge $CPUThreshold) {
            $status = "High CPU"
        } elseif ($memoryUsagePercent -ge $MemoryThreshold) {
            $status = "High Memory"
        }
        
        # Get cluster info
        $hostCluster = Get-Cluster -VMHost $vmHost -ErrorAction SilentlyContinue
        
        # Build result object
        $results += [PSCustomObject]@{
            HostName = $vmHost.Name
            Cluster = if ($hostCluster) { $hostCluster.Name } else { 'N/A' }
            ConnectionState = $vmHost.ConnectionState
            PowerState = $vmHost.PowerState
            CPUUsageMhz = $vmHost.CpuUsageMhz
            CPUTotalMhz = $vmHost.CpuTotalMhz
            CPUUsagePercent = $cpuUsagePercent
            MemoryUsageGB = [math]::Round($vmHost.MemoryUsageGB, 2)
            MemoryTotalGB = [math]::Round($vmHost.MemoryTotalGB, 2)
            MemoryUsagePercent = $memoryUsagePercent
            VMCount = $vms.Count
            PoweredOnVMs = $poweredOnVMs
            PoweredOffVMs = $poweredOffVMs
            Status = $status
            VMs = $vms  # Store VM objects for recommendations
        }
    }
    catch {
        Write-Warning "    Error collecting data for $($vmHost.Name): $_"
    }
}

# Sort by utilization
$results = $results | Sort-Object CPUUsagePercent -Descending

# Export to CSV if requested
if ($OutputFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $results | Select-Object -Property * -ExcludeProperty VMs | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $absolutePath" -ForegroundColor Green
}

# Display host utilization summary
Write-Host "`n╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                      HOST UTILIZATION SUMMARY                              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$results | Format-Table -AutoSize -Property `
    @{Name="Host";Expression={$_.HostName};Width=25}, `
    @{Name="Cluster";Expression={$_.Cluster};Width=15}, `
    @{Name="CPU %";Expression={$_.CPUUsagePercent};Width=8}, `
    @{Name="Mem %";Expression={$_.MemoryUsagePercent};Width=8}, `
    @{Name="VMs";Expression={$_.PoweredOnVMs};Width=5}, `
    @{Name="Status";Expression={$_.Status};Width=15}

# Overall statistics
Write-Host "`n╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                         CLUSTER STATISTICS                                 ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$totalHosts = $results.Count
$normalHosts = ($results | Where-Object { $_.Status -eq 'Normal' }).Count
$highCPUHosts = ($results | Where-Object { $_.Status -eq 'High CPU' }).Count
$highMemHosts = ($results | Where-Object { $_.Status -eq 'High Memory' }).Count
$overutilizedHosts = ($results | Where-Object { $_.Status -eq 'Overutilized' }).Count

$avgCPU = [math]::Round(($results | Measure-Object -Property CPUUsagePercent -Average).Average, 2)
$avgMemory = [math]::Round(($results | Measure-Object -Property MemoryUsagePercent -Average).Average, 2)
$totalVMs = ($results | Measure-Object -Property PoweredOnVMs -Sum).Sum

Write-Host "  Total Hosts: $totalHosts" -ForegroundColor White
Write-Host "  Normal: $normalHosts" -ForegroundColor Green
Write-Host "  High CPU: $highCPUHosts" -ForegroundColor Yellow
Write-Host "  High Memory: $highMemHosts" -ForegroundColor Yellow
Write-Host "  Overutilized: $overutilizedHosts" -ForegroundColor Red
Write-Host ""
Write-Host "  Average CPU Usage: $avgCPU%" -ForegroundColor White
Write-Host "  Average Memory Usage: $avgMemory%" -ForegroundColor White
Write-Host "  Total Powered-On VMs: $totalVMs" -ForegroundColor White

# Identify problematic hosts
$problematicHosts = $results | Where-Object { $_.Status -ne 'Normal' }

if ($problematicHosts) {
    Write-Host "`n╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║                    HOSTS REQUIRING ATTENTION                               ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    
    foreach ($vmHostInfo in $problematicHosts) {
        Write-Host "`n  Host: $($vmHostInfo.HostName)" -ForegroundColor White
        Write-Host "    Status: $($vmHostInfo.Status)" -ForegroundColor $(if ($vmHostInfo.Status -eq 'Overutilized') { 'Red' } else { 'Yellow' })
        Write-Host "    CPU: $($vmHostInfo.CPUUsagePercent)% ($($vmHostInfo.CPUUsageMhz) / $($vmHostInfo.CPUTotalMhz) MHz)" -ForegroundColor White
        Write-Host "    Memory: $($vmHostInfo.MemoryUsagePercent)% ($($vmHostInfo.MemoryUsageGB) / $($vmHostInfo.MemoryTotalGB) GB)" -ForegroundColor White
        Write-Host "    Powered-On VMs: $($vmHostInfo.PoweredOnVMs)" -ForegroundColor White
        
        # Show top resource-consuming VMs
        if ($vmHostInfo.VMs -and $vmHostInfo.VMs.Count -gt 0) {
            $topVMs = $vmHostInfo.VMs | Where-Object { $_.PowerState -eq 'PoweredOn' } | 
                Sort-Object @{Expression={$_.NumCpu * $_.MemoryGB}; Descending=$true} | 
                Select-Object -First $TopVMs
            
            if ($topVMs) {
                Write-Host "    Top Resource-Consuming VMs:" -ForegroundColor Cyan
                foreach ($vm in $topVMs) {
                    Write-Host "      - $($vm.Name): $($vm.NumCpu) vCPU, $($vm.MemoryGB) GB RAM" -ForegroundColor Gray
                }
            }
        }
    }
}
else {
    Write-Host "`n✓ All hosts are operating within normal thresholds" -ForegroundColor Green
}

# Show recommendations
if ($ShowRecommendations) {
    Write-Host "`n╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                     VM PLACEMENT RECOMMENDATIONS                           ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    $overloadedHosts = $results | Where-Object { $_.Status -eq 'Overutilized' -or $_.Status -eq 'High CPU' -or $_.Status -eq 'High Memory' }
    $underloadedHosts = $results | Where-Object { $_.CPUUsagePercent -lt 50 -and $_.MemoryUsagePercent -lt 50 } | Sort-Object CPUUsagePercent
    
    if ($overloadedHosts -and $underloadedHosts) {
        Write-Host "`nRecommended VM Migrations for Load Balancing:" -ForegroundColor Yellow
        Write-Host "=" * 80 -ForegroundColor Gray
        
        foreach ($overloadedHost in $overloadedHosts) {
            $sourceHost = $overloadedHost.HostName
            $targetHost = $underloadedHosts[0].HostName
            
            # Get candidate VMs (smaller VMs are easier to move)
            $candidateVMs = $overloadedHost.VMs | Where-Object { $_.PowerState -eq 'PoweredOn' } | 
                Sort-Object @{Expression={$_.NumCpu * $_.MemoryGB}} | 
                Select-Object -First 3
            
            if ($candidateVMs) {
                Write-Host "`n  From: $sourceHost (CPU: $($overloadedHost.CPUUsagePercent)%, Mem: $($overloadedHost.MemoryUsagePercent)%)" -ForegroundColor Red
                Write-Host "  To:   $targetHost (CPU: $($underloadedHosts[0].CPUUsagePercent)%, Mem: $($underloadedHosts[0].MemoryUsagePercent)%)" -ForegroundColor Green
                Write-Host "  Candidate VMs to migrate:" -ForegroundColor Cyan
                
                foreach ($vm in $candidateVMs) {
                    Write-Host "    • $($vm.Name) - $($vm.NumCpu) vCPU, $($vm.MemoryGB) GB RAM" -ForegroundColor White
                    Write-Host "      PowerCLI Command: Move-VM -VM '$($vm.Name)' -Destination (Get-VMHost '$targetHost')" -ForegroundColor Gray
                }
            }
        }
        
        Write-Host "`n" -NoNewline
        Write-Host "NOTE: " -ForegroundColor Yellow -NoNewline
        Write-Host "Review DRS rules and VM dependencies before migrating. Use vMotion for live migration." -ForegroundColor White
    }
    elseif ($overloadedHosts -and -not $underloadedHosts) {
        Write-Host "`n⚠ All hosts are heavily loaded. Consider:" -ForegroundColor Yellow
        Write-Host "  • Adding more hosts to the cluster" -ForegroundColor White
        Write-Host "  • Reviewing VM resource allocations" -ForegroundColor White
        Write-Host "  • Identifying and decommissioning unused VMs" -ForegroundColor White
        Write-Host "  • Checking for CPU/Memory reservations that may be too high" -ForegroundColor White
    }
    else {
        Write-Host "`n✓ Host utilization is well-balanced. No immediate action required." -ForegroundColor Green
        
        # Show least utilized hosts for new VM placement
        $leastLoaded = $results | Sort-Object CPUUsagePercent | Select-Object -First 3
        Write-Host "`nBest hosts for new VM placement:" -ForegroundColor Cyan
        foreach ($vmHostInfo in $leastLoaded) {
            Write-Host "  • $($vmHostInfo.HostName): CPU $($vmHostInfo.CPUUsagePercent)%, Memory $($vmHostInfo.MemoryUsagePercent)%, VMs: $($vmHostInfo.PoweredOnVMs)" -ForegroundColor White
        }
    }
}

Write-Host "`n╔════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    Analysis Complete!                                      ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
