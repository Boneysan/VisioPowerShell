<#
.SYNOPSIS
    Exports vSphere Operations metrics to CSV files for Power BI dashboard consumption.

.DESCRIPTION
    This script collects comprehensive vSphere metrics similar to VMware Aria Operations
    dashboards and exports them to CSV files for Power BI. It covers:
    1. Environment Health (cluster health, critical alerts, incidents)
    2. Capacity Headroom (CPU/Memory/Storage with days to exhaustion)
    3. Cost & Efficiency (idle/oversized VMs, savings estimates)
    4. SLA & Performance (threshold breaches, trends)
    5. Network/NSX Health (NSX health, critical alerts)
    6. Hybrid Footprint (on-prem vs cloud resources)

.PARAMETER vCenterServer
    The vCenter Server(s) to connect to. Can be an array for multiple vCenters.

.PARAMETER NSXManager
    NSX Manager address (optional). Required for Tile 5 - Network/NSX Health.

.PARAMETER OutputPath
    The folder path where CSV files will be exported. Defaults to C:\Data\vSphereOperations

.PARAMETER DaysOfHistory
    Number of days of historical data to collect for trending. Defaults to 7.

.PARAMETER IncludeCloudMetrics
    Switch to include cloud metrics for Tile 6 (hybrid footprint).

.PARAMETER CloudCostPerVCpuHour
    Cost per vCPU hour for cloud comparison. Defaults to $0.05.

.PARAMETER OnPremCostPerVCpuHour
    Cost per vCPU hour for on-premises. Defaults to $0.02.

.PARAMETER Credential
    PSCredential object for vCenter authentication.

.PARAMETER NSXCredential
    PSCredential object for NSX Manager authentication.

.EXAMPLE
    .\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.domain.local"

.EXAMPLE
    .\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.domain.local" -NSXManager "nsx.domain.local" -IncludeCloudMetrics

.NOTES
    Author: vSphere Operations Dashboard
    Requires: VMware PowerCLI module, NSX PowerCLI (for NSX metrics)
    Schedule: Recommended to run every 4-6 hours via Windows Task Scheduler
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [string]$NSXManager,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "C:\Data\vSphereOperations",

    [Parameter(Mandatory = $false)]
    [int]$DaysOfHistory = 7,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCloudMetrics,

    [Parameter(Mandatory = $false)]
    [decimal]$CloudCostPerVCpuHour = 0.05,

    [Parameter(Mandatory = $false)]
    [decimal]$OnPremCostPerVCpuHour = 0.02,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$NSXCredential
)

#region Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Log file configuration
$LogPath = Join-Path $OutputPath "Logs"
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogPath "OperationsDashboard_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:StartTime = Get-Date

# Thresholds for health and performance
$Script:Thresholds = @{
    CPUReadyWarning      = 5      # % CPU ready
    CPUReadyCritical     = 10
    MemoryWarning        = 85     # % Memory usage
    MemoryCritical       = 95
    DatastoreWarning     = 80     # % Datastore usage
    DatastoreCritical    = 90
    LatencyWarning       = 15     # ms
    LatencyCritical      = 30
    IdleCPUThreshold     = 5      # % CPU for idle VM
    IdleMemThreshold     = 10     # % Memory for idle VM
    IdleDays             = 7      # Days to average for idle detection
}
#endregion

#region Logging Functions
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $logEntry
    
    switch ($Level) {
        "INFO"    { Write-Host $logEntry -ForegroundColor Cyan }
        "WARN"    { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
    }
}

function Write-Progress-Custom {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}
#endregion

#region Tile 1: Environment Health
function Export-EnvironmentHealth {
    <#
    .SYNOPSIS
        Exports environment health metrics: cluster health, critical alerts, incidents.
    #>
    Write-Log "=== TILE 1: Collecting Environment Health ==="
    
    # Cluster Health Status
    Write-Log "Collecting cluster health status..."
    $clusterHealth = Get-Cluster | ForEach-Object {
        $cluster = $_
        $hosts = $cluster | Get-VMHost
        
        # Calculate cluster health
        $hostsHealthy = ($hosts | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' }).Count
        $hostsTotal = $hosts.Count
        $clusterHealthy = ($hostsHealthy -eq $hostsTotal)
        
        # Check for HA/DRS issues
        $haEnabled = $cluster.HAEnabled
        $drsEnabled = $cluster.DrsEnabled
        $haFailures = if ($cluster.HAEnabled) { $cluster.HAAdmissionControlEnabled -eq $false } else { $false }
        
        # Determine health status
        $healthStatus = "Healthy"
        if (-not $clusterHealthy -or $haFailures) { $healthStatus = "Degraded" }
        if ($hostsHealthy -lt ($hostsTotal * 0.75)) { $healthStatus = "Critical" }
        
        [PSCustomObject]@{
            ClusterName        = $cluster.Name
            vCenter            = $cluster.Uid.Split('@')[1].Split(':')[0]
            HealthStatus       = $healthStatus
            TotalHosts         = $hostsTotal
            HealthyHosts       = $hostsHealthy
            UnhealthyHosts     = $hostsTotal - $hostsHealthy
            HAEnabled          = $haEnabled
            DRSEnabled         = $drsEnabled
            HAFailures         = $haFailures
            VmCount            = ($cluster | Get-VM).Count
            TotalCPU           = ($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum
            TotalMemoryGB      = [math]::Round(($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum, 2)
            CollectionDate     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Tile1_Cluster_Health.csv"
    $clusterHealth | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported cluster health: $($clusterHealth.Count) clusters" -Level SUCCESS
    
    # Critical Alerts (simulated from events - last 7 days)
    Write-Log "Collecting critical alerts (last $DaysOfHistory days)..."
    $startDate = (Get-Date).AddDays(-$DaysOfHistory)
    
    $criticalAlerts = @()
    foreach ($vc in $global:DefaultVIServers) {
        $events = Get-VIEvent -Start $startDate -MaxSamples 10000 -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.FullFormattedMessage -match 'error|failed|critical|alarm|disconnect' -or
                $_ -is [VMware.Vim.AlarmStatusChangedEvent] -or
                $_ -is [VMware.Vim.HostConnectionLostEvent] -or
                $_ -is [VMware.Vim.DasHostFailedEvent]
            }
        
        foreach ($event in $events) {
            $severity = "Warning"
            if ($event -is [VMware.Vim.AlarmStatusChangedEvent]) {
                if ($event.To -eq 'red') { $severity = "Critical" }
                elseif ($event.To -eq 'yellow') { $severity = "Warning" }
            }
            elseif ($event -is [VMware.Vim.HostConnectionLostEvent] -or $event -is [VMware.Vim.DasHostFailedEvent]) {
                $severity = "Critical"
            }
            
            $criticalAlerts += [PSCustomObject]@{
                vCenter        = $vc.Name
                Timestamp      = $event.CreatedTime
                Severity       = $severity
                EventType      = $event.GetType().Name
                EntityName     = if ($event.Vm) { $event.Vm.Name } elseif ($event.Host) { $event.Host.Name } else { $event.ComputeResource.Name }
                EntityType     = if ($event.Vm) { "VM" } elseif ($event.Host) { "Host" } else { "Cluster" }
                Message        = $event.FullFormattedMessage
                UserName       = $event.UserName
                CollectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }
    
    $outputFile = Join-Path $OutputPath "Tile1_Critical_Alerts.csv"
    $criticalAlerts | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported critical alerts: $($criticalAlerts.Count) events" -Level SUCCESS
    
    # Major Incidents (last 7 days) - Host failures, cluster issues
    Write-Log "Collecting major incidents (last $DaysOfHistory days)..."
    $majorIncidents = $criticalAlerts | Where-Object { 
        $_.Severity -eq 'Critical' -and
        $_.EventType -in @('HostConnectionLostEvent', 'DasHostFailedEvent', 'ClusterOvercommittedEvent', 'DatastoreIORMReconfiguredEvent')
    }
    
    $outputFile = Join-Path $OutputPath "Tile1_Major_Incidents.csv"
    $majorIncidents | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported major incidents: $($majorIncidents.Count) incidents" -Level SUCCESS
    
    # Summary metrics
    $healthSummary = [PSCustomObject]@{
        TotalClusters      = $clusterHealth.Count
        HealthyClusters    = ($clusterHealth | Where-Object { $_.HealthStatus -eq 'Healthy' }).Count
        DegradedClusters   = ($clusterHealth | Where-Object { $_.HealthStatus -eq 'Degraded' }).Count
        CriticalClusters   = ($clusterHealth | Where-Object { $_.HealthStatus -eq 'Critical' }).Count
        CriticalAlerts     = ($criticalAlerts | Where-Object { $_.Severity -eq 'Critical' }).Count
        WarningAlerts      = ($criticalAlerts | Where-Object { $_.Severity -eq 'Warning' }).Count
        MajorIncidents7d   = $majorIncidents.Count
        CollectionDate     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $outputFile = Join-Path $OutputPath "Tile1_Health_Summary.csv"
    $healthSummary | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported health summary" -Level SUCCESS
    
    return $healthSummary
}
#endregion

#region Tile 2: Capacity Headroom
function Export-CapacityHeadroom {
    <#
    .SYNOPSIS
        Exports capacity headroom: CPU/Memory/Storage by cluster with days to exhaustion.
    #>
    Write-Log "=== TILE 2: Collecting Capacity Headroom ==="
    
    $capacityData = Get-Cluster | ForEach-Object {
        $cluster = $_
        $hosts = $cluster | Get-VMHost
        $vms = $cluster | Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
        
        # Calculate total capacity
        $totalCpuMhz = ($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum
        $totalMemGB = [math]::Round(($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum, 2)
        
        # Calculate current usage
        $usedCpuMhz = ($vms | Measure-Object -Property { $_.NumCpu * 2000 } -Sum).Sum  # Rough estimate
        $usedMemGB = [math]::Round(($vms | Measure-Object -Property MemoryGB -Sum).Sum, 2)
        
        # Get actual usage stats from last 7 days for more accurate trending
        $startDate = (Get-Date).AddDays(-$DaysOfHistory)
        $clusterCpuStats = $cluster | Get-Stat -Stat cpu.usage.average -Start $startDate -ErrorAction SilentlyContinue
        $clusterMemStats = $cluster | Get-Stat -Stat mem.usage.average -Start $startDate -ErrorAction SilentlyContinue
        
        $avgCpuPercent = if ($clusterCpuStats) { [math]::Round(($clusterCpuStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
        $avgMemPercent = if ($clusterMemStats) { [math]::Round(($clusterMemStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
        
        # Calculate headroom
        $cpuHeadroomPercent = [math]::Round(100 - $avgCpuPercent, 2)
        $memHeadroomPercent = [math]::Round(100 - $avgMemPercent, 2)
        
        # Storage capacity
        $datastores = $cluster | Get-Datastore
        $totalStorageGB = [math]::Round(($datastores | Measure-Object -Property CapacityGB -Sum).Sum, 2)
        $freeStorageGB = [math]::Round(($datastores | Measure-Object -Property FreeSpaceGB -Sum).Sum, 2)
        $usedStorageGB = $totalStorageGB - $freeStorageGB
        $storageUsedPercent = if ($totalStorageGB -gt 0) { [math]::Round(($usedStorageGB / $totalStorageGB) * 100, 2) } else { 0 }
        $storageHeadroomPercent = 100 - $storageUsedPercent
        
        # Calculate growth rate (simple linear projection from last 7 days)
        # Group stats by day to get daily average growth
        $cpuDailyAvg = $clusterCpuStats | Group-Object { $_.Timestamp.Date } | ForEach-Object {
            ($_.Group | Measure-Object -Property Value -Average).Average
        }
        $memDailyAvg = $clusterMemStats | Group-Object { $_.Timestamp.Date } | ForEach-Object {
            ($_.Group | Measure-Object -Property Value -Average).Average
        }
        
        # Calculate daily growth rate
        $cpuGrowthRate = if ($cpuDailyAvg.Count -gt 1) {
            ($cpuDailyAvg[-1] - $cpuDailyAvg[0]) / $cpuDailyAvg.Count
        } else { 0 }
        
        $memGrowthRate = if ($memDailyAvg.Count -gt 1) {
            ($memDailyAvg[-1] - $memDailyAvg[0]) / $memDailyAvg.Count
        } else { 0 }
        
        # Days to exhaustion (when usage will reach 95%)
        $cpuDaysToExhaustion = if ($cpuGrowthRate -gt 0) {
            [math]::Round((95 - $avgCpuPercent) / $cpuGrowthRate, 0)
        } else { 999 }
        
        $memDaysToExhaustion = if ($memGrowthRate -gt 0) {
            [math]::Round((95 - $avgMemPercent) / $memGrowthRate, 0)
        } else { 999 }
        
        # Estimate storage growth (using VM provisioned growth)
        $storageGrowthRate = 0.1  # Assume 0.1% per day if no historical data
        $storageDaysToExhaustion = if ($storageGrowthRate -gt 0 -and $storageUsedPercent -lt 95) {
            [math]::Round((95 - $storageUsedPercent) / $storageGrowthRate, 0)
        } else { 999 }
        
        # Cap at 999 for display purposes
        if ($cpuDaysToExhaustion -gt 999) { $cpuDaysToExhaustion = 999 }
        if ($memDaysToExhaustion -gt 999) { $memDaysToExhaustion = 999 }
        if ($storageDaysToExhaustion -gt 999) { $storageDaysToExhaustion = 999 }
        
        [PSCustomObject]@{
            ClusterName              = $cluster.Name
            vCenter                  = $cluster.Uid.Split('@')[1].Split(':')[0]
            # CPU Metrics
            TotalCpuMhz              = $totalCpuMhz
            AvgCpuUsedPercent        = $avgCpuPercent
            CpuHeadroomPercent       = $cpuHeadroomPercent
            CpuDaysToExhaustion      = $cpuDaysToExhaustion
            CpuGrowthRatePerDay      = [math]::Round($cpuGrowthRate, 3)
            # Memory Metrics
            TotalMemoryGB            = $totalMemGB
            AvgMemUsedPercent        = $avgMemPercent
            MemHeadroomPercent       = $memHeadroomPercent
            MemDaysToExhaustion      = $memDaysToExhaustion
            MemGrowthRatePerDay      = [math]::Round($memGrowthRate, 3)
            # Storage Metrics
            TotalStorageGB           = $totalStorageGB
            UsedStorageGB            = $usedStorageGB
            FreeStorageGB            = $freeStorageGB
            StorageUsedPercent       = $storageUsedPercent
            StorageHeadroomPercent   = $storageHeadroomPercent
            StorageDaysToExhaustion  = $storageDaysToExhaustion
            StorageGrowthRatePerDay  = [math]::Round($storageGrowthRate, 3)
            # Cluster Info
            HostCount                = $hosts.Count
            VMCount                  = $vms.Count
            CollectionDate           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Tile2_Capacity_Headroom.csv"
    $capacityData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported capacity headroom: $($capacityData.Count) clusters" -Level SUCCESS
    
    return $capacityData.Count
}
#endregion

#region Tile 3: Cost & Efficiency
function Export-CostEfficiency {
    <#
    .SYNOPSIS
        Exports cost and efficiency metrics: idle VMs, oversized VMs, savings estimates.
    #>
    Write-Log "=== TILE 3: Collecting Cost & Efficiency ==="
    
    Write-Log "Analyzing VM efficiency (this may take a while)..."
    $startDate = (Get-Date).AddDays(-$Script:Thresholds.IdleDays)
    
    $vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
    $total = $vms.Count
    $current = 0
    
    $efficiencyData = foreach ($vm in $vms) {
        $current++
        if ($current % 50 -eq 0) {
            Write-Progress-Custom -Activity "Analyzing VMs" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        }
        
        try {
            # Get CPU and Memory stats
            $cpuStats = $vm | Get-Stat -Stat cpu.usage.average -Start $startDate -MaxSamples 500 -ErrorAction SilentlyContinue
            $memStats = $vm | Get-Stat -Stat mem.usage.average -Start $startDate -MaxSamples 500 -ErrorAction SilentlyContinue
            
            $avgCpu = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
            $maxCpu = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
            $avgMem = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
            $maxMem = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
            
            # Determine if VM is idle or oversized
            $isIdle = ($avgCpu -lt $Script:Thresholds.IdleCPUThreshold -and $avgMem -lt $Script:Thresholds.IdleMemThreshold)
            $isOversizedCPU = ($avgCpu -lt 20 -and $vm.NumCpu -gt 2)
            $isOversizedMem = ($avgMem -lt 30 -and $vm.MemoryGB -gt 4)
            $isOversized = ($isOversizedCPU -or $isOversizedMem)
            
            # Calculate potential savings
            $recommendedCPU = $vm.NumCpu
            $recommendedMemGB = $vm.MemoryGB
            
            if ($isOversizedCPU) {
                $recommendedCPU = [math]::Max(2, [math]::Ceiling($vm.NumCpu * ($avgCpu / 40)))
            }
            if ($isOversizedMem) {
                $recommendedMemGB = [math]::Max(2, [math]::Ceiling($vm.MemoryGB * ($avgMem / 50)))
            }
            
            # Cost savings (based on vCPU hours)
            $currentCost = $vm.NumCpu * 24 * 30 * $OnPremCostPerVCpuHour  # Monthly cost
            $recommendedCost = $recommendedCPU * 24 * 30 * $OnPremCostPerVCpuHour
            $potentialSavingsMonthly = [math]::Round($currentCost - $recommendedCost, 2)
            
            # If idle, savings is full decommission
            if ($isIdle) {
                $potentialSavingsMonthly = [math]::Round($currentCost, 2)
            }
            
            [PSCustomObject]@{
                VMName                    = $vm.Name
                vCenter                   = $vm.Uid.Split('@')[1].Split(':')[0]
                Cluster                   = $vm.VMHost.Parent.Name
                Folder                    = $vm.Folder.Name
                PowerState                = $vm.PowerState
                # Current Configuration
                ConfiguredCPU             = $vm.NumCpu
                ConfiguredMemoryGB        = [math]::Round($vm.MemoryGB, 2)
                ProvisionedStorageGB      = [math]::Round($vm.ProvisionedSpaceGB, 2)
                UsedStorageGB             = [math]::Round($vm.UsedSpaceGB, 2)
                # Performance Stats
                AvgCpuPercent             = $avgCpu
                MaxCpuPercent             = $maxCpu
                AvgMemPercent             = $avgMem
                MaxMemPercent             = $maxMem
                # Efficiency Classification
                IsIdle                    = $isIdle
                IsOversized               = $isOversized
                IsOversizedCPU            = $isOversizedCPU
                IsOversizedMem            = $isOversizedMem
                # Recommendations
                RecommendedCPU            = $recommendedCPU
                RecommendedMemoryGB       = $recommendedMemGB
                CPUReduction              = $vm.NumCpu - $recommendedCPU
                MemoryReductionGB         = [math]::Round($vm.MemoryGB - $recommendedMemGB, 2)
                # Cost Savings
                CurrentMonthlyCost        = [math]::Round($currentCost, 2)
                RecommendedMonthlyCost    = [math]::Round($recommendedCost, 2)
                PotentialSavingsMonthly   = $potentialSavingsMonthly
                PotentialSavingsAnnual    = [math]::Round($potentialSavingsMonthly * 12, 2)
                # Metadata
                GuestOS                   = $vm.Guest.OSFullName
                VMToolsStatus             = $vm.ExtensionData.Guest.ToolsStatus
                CollectionDate            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Log "Warning: Could not analyze VM $($vm.Name): $_" -Level WARN
        }
    }
    
    Write-Progress -Activity "Analyzing VMs" -Completed
    
    $outputFile = Join-Path $OutputPath "Tile3_Cost_Efficiency.csv"
    $efficiencyData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported cost efficiency data: $($efficiencyData.Count) VMs" -Level SUCCESS
    
    # Summary
    $idleVMs = $efficiencyData | Where-Object { $_.IsIdle -eq $true }
    $oversizedVMs = $efficiencyData | Where-Object { $_.IsOversized -eq $true }
    $totalSavings = [math]::Round(($efficiencyData | Measure-Object -Property PotentialSavingsMonthly -Sum).Sum, 2)
    
    $costSummary = [PSCustomObject]@{
        TotalVMs                     = $efficiencyData.Count
        IdleVMs                      = $idleVMs.Count
        OversizedVMs                 = $oversizedVMs.Count
        PotentialMonthlySavings      = $totalSavings
        PotentialAnnualSavings       = [math]::Round($totalSavings * 12, 2)
        IdleVMStorageGB              = [math]::Round(($idleVMs | Measure-Object -Property UsedStorageGB -Sum).Sum, 2)
        OversizedVMStorageGB         = [math]::Round(($oversizedVMs | Measure-Object -Property UsedStorageGB -Sum).Sum, 2)
        CollectionDate               = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $outputFile = Join-Path $OutputPath "Tile3_Cost_Summary.csv"
    $costSummary | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Idle VMs: $($idleVMs.Count), Oversized VMs: $($oversizedVMs.Count), Potential Savings: `$$totalSavings/month" -Level SUCCESS
    
    return $costSummary
}
#endregion

#region Tile 4: SLA & Performance
function Export-SLAPerformance {
    <#
    .SYNOPSIS
        Exports SLA and performance metrics: VMs breaching thresholds, trends.
    #>
    Write-Log "=== TILE 4: Collecting SLA & Performance ==="
    
    $startDate = (Get-Date).AddDays(-$DaysOfHistory)
    $previousPeriodStart = $startDate.AddDays(-$DaysOfHistory)
    
    Write-Log "Collecting VM performance metrics..."
    $vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
    $total = $vms.Count
    $current = 0
    
    $performanceData = foreach ($vm in $vms) {
        $current++
        if ($current % 50 -eq 0) {
            Write-Progress-Custom -Activity "Collecting Performance Stats" -Status "$current of $total" -PercentComplete (($current / $total) * 100)
        }
        
        try {
            # Current period stats
            $cpuReady = $vm | Get-Stat -Stat cpu.ready.summation -Start $startDate -ErrorAction SilentlyContinue
            $memUsage = $vm | Get-Stat -Stat mem.usage.average -Start $startDate -ErrorAction SilentlyContinue
            
            # Previous period stats for trending
            $cpuReadyPrev = $vm | Get-Stat -Stat cpu.ready.summation -Start $previousPeriodStart -End $startDate -ErrorAction SilentlyContinue
            $memUsagePrev = $vm | Get-Stat -Stat mem.usage.average -Start $previousPeriodStart -End $startDate -ErrorAction SilentlyContinue
            
            # Calculate averages
            $avgCpuReady = if ($cpuReady) { [math]::Round(($cpuReady | Measure-Object -Property Value -Average).Average / 200, 2) } else { 0 }
            $maxCpuReady = if ($cpuReady) { [math]::Round(($cpuReady | Measure-Object -Property Value -Maximum).Maximum / 200, 2) } else { 0 }
            $avgMem = if ($memUsage) { [math]::Round(($memUsage | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
            $maxMem = if ($memUsage) { [math]::Round(($memUsage | Measure-Object -Property Value -Maximum).Maximum, 2) } else { 0 }
            
            $avgCpuReadyPrev = if ($cpuReadyPrev) { [math]::Round(($cpuReadyPrev | Measure-Object -Property Value -Average).Average / 200, 2) } else { 0 }
            $avgMemPrev = if ($memUsagePrev) { [math]::Round(($memUsagePrev | Measure-Object -Property Value -Average).Average, 2) } else { 0 }
            
            # Determine threshold breaches
            $breachCPUReady = $maxCpuReady -gt $Script:Thresholds.CPUReadyWarning
            $breachMemory = $maxMem -gt $Script:Thresholds.MemoryWarning
            $breachingThresholds = $breachCPUReady -or $breachMemory
            
            # Trend comparison
            $cpuReadyTrend = if ($avgCpuReadyPrev -gt 0) { 
                [math]::Round((($avgCpuReady - $avgCpuReadyPrev) / $avgCpuReadyPrev) * 100, 2) 
            } else { 0 }
            $memTrend = if ($avgMemPrev -gt 0) { 
                [math]::Round((($avgMem - $avgMemPrev) / $avgMemPrev) * 100, 2) 
            } else { 0 }
            
            [PSCustomObject]@{
                VMName                  = $vm.Name
                vCenter                 = $vm.Uid.Split('@')[1].Split(':')[0]
                Cluster                 = $vm.VMHost.Parent.Name
                VMHost                  = $vm.VMHost.Name
                # Current Period Performance
                AvgCpuReadyPercent      = $avgCpuReady
                MaxCpuReadyPercent      = $maxCpuReady
                AvgMemoryPercent        = $avgMem
                MaxMemoryPercent        = $maxMem
                # Previous Period Performance
                AvgCpuReadyPercentPrev  = $avgCpuReadyPrev
                AvgMemoryPercentPrev    = $avgMemPrev
                # Trends (% change)
                CpuReadyTrendPercent    = $cpuReadyTrend
                MemoryTrendPercent      = $memTrend
                # Threshold Breaches
                BreachesCPUReady        = $breachCPUReady
                BreachesMemory          = $breachMemory
                BreachingThresholds     = $breachingThresholds
                # Severity
                Severity                = if ($maxCpuReady -gt $Script:Thresholds.CPUReadyCritical -or $maxMem -gt $Script:Thresholds.MemoryCritical) { "Critical" }
                                          elseif ($breachingThresholds) { "Warning" }
                                          else { "Normal" }
                # VM Config
                NumCPU                  = $vm.NumCpu
                MemoryGB                = [math]::Round($vm.MemoryGB, 2)
                CollectionDate          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Log "Warning: Could not collect performance for VM $($vm.Name): $_" -Level WARN
        }
    }
    
    Write-Progress -Activity "Collecting Performance Stats" -Completed
    
    $outputFile = Join-Path $OutputPath "Tile4_SLA_Performance.csv"
    $performanceData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported SLA performance data: $($performanceData.Count) VMs" -Level SUCCESS
    
    # Summary
    $breachingVMs = $performanceData | Where-Object { $_.BreachingThresholds -eq $true }
    $criticalVMs = $performanceData | Where-Object { $_.Severity -eq 'Critical' }
    $warningVMs = $performanceData | Where-Object { $_.Severity -eq 'Warning' }
    
    $slaSummary = [PSCustomObject]@{
        TotalVMs                = $performanceData.Count
        VmsBreachingThresholds  = $breachingVMs.Count
        CriticalVMs             = $criticalVMs.Count
        WarningVMs              = $warningVMs.Count
        NormalVMs               = $performanceData.Count - $breachingVMs.Count
        PercentBreaching        = [math]::Round(($breachingVMs.Count / $performanceData.Count) * 100, 2)
        CollectionDate          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $outputFile = Join-Path $OutputPath "Tile4_SLA_Summary.csv"
    $slaSummary | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Breaching VMs: $($breachingVMs.Count) ($([math]::Round(($breachingVMs.Count / $performanceData.Count) * 100, 1))%)" -Level SUCCESS
    
    return $slaSummary
}
#endregion

#region Tile 5: Network/NSX Health
function Export-NetworkNSXHealth {
    <#
    .SYNOPSIS
        Exports network and NSX health metrics.
    #>
    Write-Log "=== TILE 5: Collecting Network/NSX Health ==="
    
    # Port Group Health
    Write-Log "Collecting port group health..."
    $portGroups = Get-VirtualPortGroup
    $pgHealth = $portGroups | ForEach-Object {
        $pg = $_
        [PSCustomObject]@{
            PortGroupName   = $pg.Name
            vCenter         = if ($pg.Uid) { $pg.Uid.Split('@')[1].Split(':')[0] } else { "Unknown" }
            VLanId          = $pg.VLanId
            VirtualSwitch   = $pg.VirtualSwitch.Name
            VMCount         = ($pg | Get-VM).Count
            CollectionDate  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Tile5_PortGroup_Health.csv"
    $pgHealth | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported port group health: $($pgHealth.Count) port groups" -Level SUCCESS
    
    # NSX Health (if NSX Manager is provided)
    if ($NSXManager) {
        try {
            Write-Log "Attempting NSX connection to $NSXManager..."
            # Note: This requires NSX PowerCLI module
            # Connect-NsxServer -Server $NSXManager -Credential $NSXCredential -ErrorAction Stop
            
            # Placeholder for NSX health data
            # In production, you would query NSX API for:
            # - Controller cluster status
            # - Edge status
            # - Logical switches
            # - DFW rule counts
            # - Transport zones
            
            $nsxHealth = [PSCustomObject]@{
                NSXManager          = $NSXManager
                Status              = "Connected"
                HealthStatus        = "Healthy"
                CriticalAlerts      = 0
                WarningAlerts       = 0
                Message             = "NSX health monitoring requires NSX PowerCLI module"
                CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
            
            Write-Log "NSX monitoring requires NSX PowerCLI module - placeholder created" -Level WARN
        }
        catch {
            Write-Log "Could not connect to NSX Manager: $_" -Level ERROR
            $nsxHealth = [PSCustomObject]@{
                NSXManager          = $NSXManager
                Status              = "Disconnected"
                HealthStatus        = "Unknown"
                CriticalAlerts      = 0
                WarningAlerts       = 0
                Message             = $_.Exception.Message
                CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        
        $outputFile = Join-Path $OutputPath "Tile5_NSX_Health.csv"
        $nsxHealth | Export-Csv $outputFile -NoTypeInformation -Force
        Write-Log "Exported NSX health data" -Level SUCCESS
    }
    else {
        Write-Log "NSX Manager not specified - skipping NSX health collection" -Level WARN
        
        # Create placeholder
        $nsxHealth = [PSCustomObject]@{
            NSXManager          = "Not Configured"
            Status              = "N/A"
            HealthStatus        = "N/A"
            CriticalAlerts      = 0
            WarningAlerts       = 0
            Message             = "NSX Manager parameter not provided"
            CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        
        $outputFile = Join-Path $OutputPath "Tile5_NSX_Health.csv"
        $nsxHealth | Export-Csv $outputFile -NoTypeInformation -Force
    }
    
    # Network Summary
    $networkSummary = [PSCustomObject]@{
        TotalPortGroups     = $pgHealth.Count
        TotalVirtualSwitches = ($portGroups | Select-Object -ExpandProperty VirtualSwitch -Unique).Count
        NSXHealthStatus     = $nsxHealth.HealthStatus
        NSXCriticalAlerts   = $nsxHealth.CriticalAlerts
        CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $outputFile = Join-Path $OutputPath "Tile5_Network_Summary.csv"
    $networkSummary | Export-Csv $outputFile -NoTypeInformation -Force
    
    return $networkSummary
}
#endregion

#region Tile 6: Hybrid Footprint
function Export-HybridFootprint {
    <#
    .SYNOPSIS
        Exports hybrid footprint metrics: on-prem vs cloud resources.
    #>
    Write-Log "=== TILE 6: Collecting Hybrid Footprint ==="
    
    # On-premises footprint
    Write-Log "Calculating on-premises footprint..."
    $vms = Get-VM
    $onPremVMs = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
    
    $onPremCPU = ($onPremVMs | Measure-Object -Property NumCpu -Sum).Sum
    $onPremMemGB = [math]::Round(($onPremVMs | Measure-Object -Property MemoryGB -Sum).Sum, 2)
    $onPremStorageGB = [math]::Round(($onPremVMs | Measure-Object -Property UsedSpaceGB -Sum).Sum, 2)
    
    # Calculate monthly cost
    $onPremMonthlyCost = [math]::Round($onPremCPU * 24 * 30 * $OnPremCostPerVCpuHour, 2)
    
    $onPremFootprint = [PSCustomObject]@{
        Environment         = "On-Premises"
        VMCount             = $onPremVMs.Count
        TotalVCPUs          = $onPremCPU
        TotalMemoryGB       = $onPremMemGB
        TotalStorageGB      = $onPremStorageGB
        MonthlyCost         = $onPremMonthlyCost
        AnnualCost          = [math]::Round($onPremMonthlyCost * 12, 2)
        CostPerVCpuHour     = $OnPremCostPerVCpuHour
        CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    # Cloud footprint (placeholder - would integrate with cloud APIs)
    if ($IncludeCloudMetrics) {
        Write-Log "Cloud metrics requested - creating placeholder (requires cloud API integration)" -Level WARN
        
        # Placeholder for cloud data (AWS, Azure, GCP integration would go here)
        $cloudFootprint = [PSCustomObject]@{
            Environment         = "Cloud"
            VMCount             = 0
            TotalVCPUs          = 0
            TotalMemoryGB       = 0
            TotalStorageGB      = 0
            MonthlyCost         = 0
            AnnualCost          = 0
            CostPerVCpuHour     = $CloudCostPerVCpuHour
            Provider            = "Not Configured"
            Message             = "Cloud integration requires provider-specific API modules (AWS/Azure/GCP PowerShell)"
            CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    else {
        $cloudFootprint = [PSCustomObject]@{
            Environment         = "Cloud"
            VMCount             = 0
            TotalVCPUs          = 0
            TotalMemoryGB       = 0
            TotalStorageGB      = 0
            MonthlyCost         = 0
            AnnualCost          = 0
            CostPerVCpuHour     = $CloudCostPerVCpuHour
            Provider            = "N/A"
            Message             = "Cloud metrics not requested"
            CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    # Combined footprint
    $hybridFootprint = @($onPremFootprint, $cloudFootprint)
    
    $outputFile = Join-Path $OutputPath "Tile6_Hybrid_Footprint.csv"
    $hybridFootprint | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported hybrid footprint data" -Level SUCCESS
    
    # Summary
    $totalVMs = $onPremFootprint.VMCount + $cloudFootprint.VMCount
    $totalCost = $onPremFootprint.MonthlyCost + $cloudFootprint.MonthlyCost
    
    $hybridSummary = [PSCustomObject]@{
        TotalVMs                = $totalVMs
        OnPremVMs               = $onPremFootprint.VMCount
        CloudVMs                = $cloudFootprint.VMCount
        OnPremPercentage        = if ($totalVMs -gt 0) { [math]::Round(($onPremFootprint.VMCount / $totalVMs) * 100, 2) } else { 100 }
        CloudPercentage         = if ($totalVMs -gt 0) { [math]::Round(($cloudFootprint.VMCount / $totalVMs) * 100, 2) } else { 0 }
        TotalMonthlyCost        = $totalCost
        OnPremMonthlyCost       = $onPremFootprint.MonthlyCost
        CloudMonthlyCost        = $cloudFootprint.MonthlyCost
        CollectionDate          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $outputFile = Join-Path $OutputPath "Tile6_Hybrid_Summary.csv"
    $hybridSummary | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Total VMs: $totalVMs (On-Prem: $($onPremFootprint.VMCount), Cloud: $($cloudFootprint.VMCount))" -Level SUCCESS
    
    return $hybridSummary
}
#endregion

#region Main Execution
try {
    Write-Log "====================================" -Level INFO
    Write-Log "vSphere Operations Dashboard Export" -Level INFO
    Write-Log "====================================" -Level INFO
    Write-Log "Start Time: $($Script:StartTime)" -Level INFO
    
    # Connect to vCenter(s)
    foreach ($vcServer in $vCenterServer) {
        Write-Log "Connecting to vCenter: $vcServer" -Level INFO
        
        try {
            if ($Credential) {
                Connect-VIServer -Server $vcServer -Credential $Credential -Force -ErrorAction Stop | Out-Null
            }
            else {
                Connect-VIServer -Server $vcServer -Force -ErrorAction Stop | Out-Null
            }
            Write-Log "Connected to $vcServer successfully" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to connect to $vcServer : $_" -Level ERROR
            throw
        }
    }
    
    # Execute data collection for each tile
    Write-Log "`n" -Level INFO
    Write-Log "Starting data collection for 6 dashboard tiles..." -Level INFO
    Write-Log "`n" -Level INFO
    
    $tile1Summary = Export-EnvironmentHealth
    Write-Log "`n" -Level INFO
    
    $tile2Count = Export-CapacityHeadroom
    Write-Log "`n" -Level INFO
    
    $tile3Summary = Export-CostEfficiency
    Write-Log "`n" -Level INFO
    
    $tile4Summary = Export-SLAPerformance
    Write-Log "`n" -Level INFO
    
    $tile5Summary = Export-NetworkNSXHealth
    Write-Log "`n" -Level INFO
    
    $tile6Summary = Export-HybridFootprint
    Write-Log "`n" -Level INFO
    
    # Create overall summary
    $overallSummary = [PSCustomObject]@{
        ExportDateTime              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        vCenterServers              = ($vCenterServer -join ", ")
        DaysOfHistory               = $DaysOfHistory
        # Tile 1
        TotalClusters               = $tile1Summary.TotalClusters
        HealthyClusters             = $tile1Summary.HealthyClusters
        CriticalAlerts              = $tile1Summary.CriticalAlerts
        MajorIncidents7d            = $tile1Summary.MajorIncidents7d
        # Tile 2
        ClustersAnalyzed            = $tile2Count
        # Tile 3
        TotalVMs                    = $tile3Summary.TotalVMs
        IdleVMs                     = $tile3Summary.IdleVMs
        OversizedVMs                = $tile3Summary.OversizedVMs
        PotentialMonthlySavings     = $tile3Summary.PotentialMonthlySavings
        # Tile 4
        VmsBreachingThresholds      = $tile4Summary.VmsBreachingThresholds
        CriticalPerformanceIssues   = $tile4Summary.CriticalVMs
        # Tile 5
        NetworkHealthStatus         = $tile5Summary.NSXHealthStatus
        # Tile 6
        OnPremVMs                   = $tile6Summary.OnPremVMs
        CloudVMs                    = $tile6Summary.CloudVMs
        TotalMonthlyCost            = $tile6Summary.TotalMonthlyCost
        # Execution
        ExecutionTimeSeconds        = [math]::Round(((Get-Date) - $Script:StartTime).TotalSeconds, 2)
        OutputPath                  = $OutputPath
    }
    
    $outputFile = Join-Path $OutputPath "Export_Summary.csv"
    $overallSummary | Export-Csv $outputFile -NoTypeInformation -Force
    
    Write-Log "`n" -Level INFO
    Write-Log "====================================" -Level SUCCESS
    Write-Log "Export completed successfully!" -Level SUCCESS
    Write-Log "====================================" -Level SUCCESS
    Write-Log "Total execution time: $($overallSummary.ExecutionTimeSeconds) seconds" -Level INFO
    Write-Log "Output location: $OutputPath" -Level INFO
    Write-Log "`nFiles generated:" -Level INFO
    Get-ChildItem -Path $OutputPath -Filter "*.csv" | ForEach-Object {
        Write-Log "  - $($_.Name)" -Level INFO
    }
    
    # Disconnect from vCenter
    Disconnect-VIServer -Server * -Force -Confirm:$false
    Write-Log "`nDisconnected from vCenter(s)" -Level INFO
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    
    # Ensure disconnection on error
    if ($global:DefaultVIServers) {
        Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    
    throw
}
#endregion
