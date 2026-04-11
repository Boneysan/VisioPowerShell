<#
.SYNOPSIS
    Exports vSphere metrics to CSV files for Power BI dashboard consumption.

.DESCRIPTION
    This script collects comprehensive vSphere metrics using PowerCLI and exports them
    to CSV files that can be consumed by Power BI. It covers four main dashboard areas:
    1. Capacity & Waste (right-sizing, zombies, snapshots)
    2. Cluster Performance (CPU ready, memory pressure, latency)
    3. Infrastructure Hygiene (tools, hardware versions, drift)
    4. Change & Drift (VM events, DRS effectiveness)

.PARAMETER vCenterServer
    The vCenter Server to connect to. Can be an array for multiple vCenters.

.PARAMETER OutputPath
    The folder path where CSV files will be exported. Defaults to C:\Data\vSphereMetrics

.PARAMETER DaysOfStats
    Number of days of historical performance stats to collect. Defaults to 7.

.PARAMETER DaysForZombieVM
    Number of days a VM must be powered off to be considered a "zombie". Defaults to 30.

.PARAMETER Credential
    PSCredential object for vCenter authentication. If not provided, will prompt or use current session.

.EXAMPLE
    .\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter.domain.local"

.EXAMPLE
    .\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter1","vcenter2" -OutputPath "D:\PowerBI\Data" -DaysOfStats 14

.NOTES
    Author: vSphere PowerBI Integration
    Requires: VMware PowerCLI module
    Schedule: Recommended to run daily via Windows Task Scheduler
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "C:\Data\vSphereMetrics",

    [Parameter(Mandatory = $false)]
    [int]$DaysOfStats = 7,

    [Parameter(Mandatory = $false)]
    [int]$DaysForZombieVM = 30,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential
)

#region Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up web requests and large operations

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Log file configuration
$LogPath = Join-Path $OutputPath "Logs"
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogPath "vSphereExport_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:StartTime = Get-Date
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
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logEntry
    
    # Write to console with color
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

#region Data Collection Functions

function Export-VMRightSizing {
    <#
    .SYNOPSIS
        Exports VM right-sizing data for the Capacity & Waste dashboard.
    #>
    param([int]$Days)
    
    Write-Log "Collecting VM Right-Sizing data ($Days days of stats)..."
    $startDate = (Get-Date).AddDays(-$Days)
    
    $vms = Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" }
    $total = $vms.Count
    $current = 0
    
    $report = foreach ($vm in $vms) {
        $current++
        Write-Progress-Custom -Activity "Collecting VM Stats" -Status "$current of $total - $($vm.Name)" -PercentComplete (($current / $total) * 100)
        
        try {
            $cpuStats = $vm | Get-Stat -Stat cpu.usage.average -Start $startDate -MaxSamples 500 -ErrorAction SilentlyContinue
            $memStats = $vm | Get-Stat -Stat mem.usage.average -Start $startDate -MaxSamples 500 -ErrorAction SilentlyContinue
            
            # Calculate potential savings
            $avgCpu = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Average).Average, 2) } else { $null }
            $maxCpu = if ($cpuStats) { [math]::Round(($cpuStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { $null }
            $avgMem = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Average).Average, 2) } else { $null }
            $maxMem = if ($memStats) { [math]::Round(($memStats | Measure-Object -Property Value -Maximum).Maximum, 2) } else { $null }
            
            # Right-sizing recommendations
            $cpuRecommendation = "OK"
            $memRecommendation = "OK"
            
            if ($avgCpu -and $avgCpu -lt 10 -and $vm.NumCpu -gt 2) { $cpuRecommendation = "Oversized" }
            if ($avgMem -and $avgMem -lt 20 -and $vm.MemoryGB -gt 4) { $memRecommendation = "Oversized" }
            
            [PSCustomObject]@{
                VMName              = $vm.Name
                vCenter             = $vm.Uid.Split('@')[1].Split(':')[0]
                Cluster             = $vm.VMHost.Parent.Name
                VMHost              = $vm.VMHost.Name
                Folder              = $vm.Folder.Name
                ConfiguredCPU       = $vm.NumCpu
                ConfiguredMemGB     = [math]::Round($vm.MemoryGB, 2)
                ProvisionedStorageGB = [math]::Round($vm.ProvisionedSpaceGB, 2)
                UsedStorageGB       = [math]::Round($vm.UsedSpaceGB, 2)
                AvgCPUPercent       = $avgCpu
                MaxCPUPercent       = $maxCpu
                AvgMemPercent       = $avgMem
                MaxMemPercent       = $maxMem
                CPURecommendation   = $cpuRecommendation
                MemRecommendation   = $memRecommendation
                CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Log "Warning: Could not collect stats for VM $($vm.Name): $_" -Level WARN
        }
    }
    
    Write-Progress -Activity "Collecting VM Stats" -Completed
    
    $outputFile = Join-Path $OutputPath "VM_RightSizing.csv"
    $report | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($report.Count) VMs to $outputFile" -Level SUCCESS
    
    return $report.Count
}

function Export-ZombieVMs {
    <#
    .SYNOPSIS
        Exports VMs that have been powered off for extended periods.
    #>
    param([int]$DaysOff)
    
    Write-Log "Identifying Zombie VMs (powered off > $DaysOff days)..."
    
    $cutoffDate = (Get-Date).AddDays(-$DaysOff)
    
    $zombies = Get-VM | Where-Object { $_.PowerState -eq "PoweredOff" } | ForEach-Object {
        $vm = $_
        
        # Get last power off event
        $lastPowerOff = Get-VIEvent -Entity $vm -MaxSamples 1000 -ErrorAction SilentlyContinue | 
            Where-Object { $_ -is [VMware.Vim.VmPoweredOffEvent] } | 
            Select-Object -First 1
        
        $powerOffDate = if ($lastPowerOff) { $lastPowerOff.CreatedTime } else { $null }
        $isZombie = if ($powerOffDate -and $powerOffDate -lt $cutoffDate) { $true } else { $false }
        
        [PSCustomObject]@{
            VMName              = $vm.Name
            vCenter             = $vm.Uid.Split('@')[1].Split(':')[0]
            Cluster             = $vm.VMHost.Parent.Name
            Folder              = $vm.Folder.Name
            ProvisionedStorageGB = [math]::Round($vm.ProvisionedSpaceGB, 2)
            UsedStorageGB       = [math]::Round($vm.UsedSpaceGB, 2)
            LastPoweredOff      = $powerOffDate
            DaysOff             = if ($powerOffDate) { [math]::Round(((Get-Date) - $powerOffDate).TotalDays, 0) } else { "Unknown" }
            IsZombie            = $isZombie
            Notes               = $vm.Notes
            CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Zombie_VMs.csv"
    $zombies | Export-Csv $outputFile -NoTypeInformation -Force
    $zombieCount = ($zombies | Where-Object { $_.IsZombie -eq $true }).Count
    Write-Log "Exported $($zombies.Count) powered-off VMs ($zombieCount zombies) to $outputFile" -Level SUCCESS
    
    return $zombieCount
}

function Export-Snapshots {
    <#
    .SYNOPSIS
        Exports all VM snapshots with size and age information.
    #>
    Write-Log "Collecting VM Snapshots..."
    
    $snapshots = Get-VM | Get-Snapshot -ErrorAction SilentlyContinue | ForEach-Object {
        $snap = $_
        $ageInDays = [math]::Round(((Get-Date) - $snap.Created).TotalDays, 1)
        
        # Risk classification
        $risk = "Low"
        if ($ageInDays -gt 7 -and $snap.SizeGB -gt 10) { $risk = "Medium" }
        if ($ageInDays -gt 30 -or $snap.SizeGB -gt 50) { $risk = "High" }
        if ($ageInDays -gt 90 -or $snap.SizeGB -gt 100) { $risk = "Critical" }
        
        [PSCustomObject]@{
            VMName         = $snap.VM.Name
            vCenter        = $snap.VM.Uid.Split('@')[1].Split(':')[0]
            SnapshotName   = $snap.Name
            Description    = $snap.Description
            Created        = $snap.Created
            AgeInDays      = $ageInDays
            SizeGB         = [math]::Round($snap.SizeGB, 2)
            IsCurrent      = $snap.IsCurrent
            ParentSnapshot = $snap.ParentSnapshot.Name
            RiskLevel      = $risk
            CollectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Snapshots.csv"
    $snapshots | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($snapshots.Count) snapshots to $outputFile" -Level SUCCESS
    
    return $snapshots.Count
}

function Export-DatastoreCapacity {
    <#
    .SYNOPSIS
        Exports datastore capacity and free space information.
    #>
    Write-Log "Collecting Datastore Capacity..."
    
    $datastores = Get-Datastore | ForEach-Object {
        $ds = $_
        $freePercent = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 2)
        
        # Health status based on free space
        $status = "Healthy"
        if ($freePercent -lt 25) { $status = "Warning" }
        if ($freePercent -lt 15) { $status = "Critical" }
        if ($freePercent -lt 10) { $status = "Emergency" }
        
        [PSCustomObject]@{
            DatastoreName    = $ds.Name
            vCenter          = $ds.Uid.Split('@')[1].Split(':')[0]
            Datacenter       = $ds.Datacenter.Name
            Type             = $ds.Type
            CapacityGB       = [math]::Round($ds.CapacityGB, 2)
            FreeSpaceGB      = [math]::Round($ds.FreeSpaceGB, 2)
            UsedSpaceGB      = [math]::Round($ds.CapacityGB - $ds.FreeSpaceGB, 2)
            FreePercent      = $freePercent
            UsedPercent      = [math]::Round(100 - $freePercent, 2)
            Status           = $status
            VMCount          = ($ds | Get-VM).Count
            State            = $ds.State
            CollectionDate   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Datastore_Capacity.csv"
    $datastores | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($datastores.Count) datastores to $outputFile" -Level SUCCESS
    
    return $datastores.Count
}

function Export-ClusterPerformance {
    <#
    .SYNOPSIS
        Exports cluster and host performance metrics for heatmap visualization.
    #>
    param([int]$Hours = 24)
    
    Write-Log "Collecting Cluster Performance data (last $Hours hours)..."
    $startDate = (Get-Date).AddHours(-$Hours)
    
    $metrics = @(
        "cpu.ready.summation",
        "cpu.usage.average",
        "mem.usage.average",
        "mem.vmmemctl.average",
        "mem.swapused.average"
    )
    
    $hosts = Get-VMHost
    $total = $hosts.Count
    $current = 0
    
    $perfData = foreach ($vmhost in $hosts) {
        $current++
        Write-Progress-Custom -Activity "Collecting Host Performance" -Status "$current of $total - $($vmhost.Name)" -PercentComplete (($current / $total) * 100)
        
        try {
            $stats = $vmhost | Get-Stat -Stat $metrics -Start $startDate -MaxSamples 100 -ErrorAction SilentlyContinue
            
            foreach ($stat in $stats) {
                [PSCustomObject]@{
                    EntityName     = $stat.Entity.Name
                    EntityType     = "VMHost"
                    vCenter        = $vmhost.Uid.Split('@')[1].Split(':')[0]
                    Cluster        = $vmhost.Parent.Name
                    MetricId       = $stat.MetricId
                    Value          = [math]::Round($stat.Value, 2)
                    Unit           = $stat.Unit
                    Timestamp      = $stat.Timestamp
                    Hour           = $stat.Timestamp.Hour
                    CollectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
            }
        }
        catch {
            Write-Log "Warning: Could not collect stats for host $($vmhost.Name): $_" -Level WARN
        }
    }
    
    Write-Progress -Activity "Collecting Host Performance" -Completed
    
    $outputFile = Join-Path $OutputPath "Cluster_Performance.csv"
    $perfData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($perfData.Count) performance data points to $outputFile" -Level SUCCESS
    
    return $perfData.Count
}

function Export-DatastoreLatency {
    <#
    .SYNOPSIS
        Exports datastore latency metrics.
    #>
    param([int]$Hours = 24)
    
    Write-Log "Collecting Datastore Latency (last $Hours hours)..."
    $startDate = (Get-Date).AddHours(-$Hours)
    
    $metrics = @(
        "datastore.totalReadLatency.average",
        "datastore.totalWriteLatency.average",
        "datastore.read.average",
        "datastore.write.average"
    )
    
    $datastores = Get-Datastore | Where-Object { $_.State -eq "Available" }
    
    $latencyData = foreach ($ds in $datastores) {
        try {
            # Get hosts connected to this datastore
            $connectedHosts = Get-VMHost -Datastore $ds
            
            foreach ($vmhost in $connectedHosts) {
                $stats = $vmhost | Get-Stat -Stat $metrics -Start $startDate -MaxSamples 50 -ErrorAction SilentlyContinue
                
                foreach ($stat in ($stats | Where-Object { $_.Instance -eq $ds.ExtensionData.Info.Vmfs.Uuid -or $_.Instance -eq $ds.Name })) {
                    [PSCustomObject]@{
                        DatastoreName  = $ds.Name
                        VMHost         = $vmhost.Name
                        vCenter        = $ds.Uid.Split('@')[1].Split(':')[0]
                        MetricId       = $stat.MetricId
                        Value          = [math]::Round($stat.Value, 2)
                        Unit           = $stat.Unit
                        Timestamp      = $stat.Timestamp
                        CollectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
            }
        }
        catch {
            Write-Log "Warning: Could not collect latency for datastore $($ds.Name): $_" -Level WARN
        }
    }
    
    $outputFile = Join-Path $OutputPath "Datastore_Latency.csv"
    $latencyData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($latencyData.Count) latency data points to $outputFile" -Level SUCCESS
    
    return $latencyData.Count
}

function Export-InfrastructureHygiene {
    <#
    .SYNOPSIS
        Exports VM configuration data for hygiene/compliance checking.
    #>
    Write-Log "Collecting Infrastructure Hygiene data..."
    
    $hygieneData = Get-VM | ForEach-Object {
        $vm = $_
        
        # Check for mounted ISOs
        $cdDrives = $vm | Get-CDDrive
        $hasIsoMounted = ($cdDrives | Where-Object { $_.IsoPath -ne $null -and $_.ConnectionState.Connected -eq $true }).Count -gt 0
        
        # Check for connected floppies (rare but still happens)
        $floppyDrives = $vm | Get-FloppyDrive -ErrorAction SilentlyContinue
        $hasFloppyMounted = ($floppyDrives | Where-Object { $_.ConnectionState.Connected -eq $true }).Count -gt 0
        
        # Hardware version as number for sorting
        $hwVersion = [int]($vm.HardwareVersion -replace "vmx-", "")
        
        [PSCustomObject]@{
            VMName            = $vm.Name
            vCenter           = $vm.Uid.Split('@')[1].Split(':')[0]
            Cluster           = $vm.VMHost.Parent.Name
            PowerState        = $vm.PowerState
            ToolsStatus       = $vm.ExtensionData.Guest.ToolsStatus
            ToolsVersion      = $vm.ExtensionData.Guest.ToolsVersion
            ToolsRunningStatus = $vm.ExtensionData.Guest.ToolsRunningStatus
            HardwareVersion   = $vm.HardwareVersion
            HardwareVersionNum = $hwVersion
            NumCpu            = $vm.NumCpu
            CoresPerSocket    = $vm.CoresPerSocket
            MemoryGB          = [math]::Round($vm.MemoryGB, 2)
            GuestOSConfigured = $vm.GuestId
            GuestOSRunning    = $vm.Guest.OSFullName
            GuestHostname     = $vm.Guest.HostName
            IPAddresses       = ($vm.Guest.IPAddress -join "; ")
            HasIsoMounted     = $hasIsoMounted
            IsoPath           = ($cdDrives | Where-Object { $_.IsoPath } | Select-Object -ExpandProperty IsoPath -First 1)
            HasFloppyMounted  = $hasFloppyMounted
            CBTEnabled        = $vm.ExtensionData.Config.ChangeTrackingEnabled
            CpuHotAddEnabled  = $vm.ExtensionData.Config.CpuHotAddEnabled
            MemHotAddEnabled  = $vm.ExtensionData.Config.MemoryHotAddEnabled
            Annotation        = $vm.Notes
            CreateDate        = $vm.ExtensionData.Config.CreateDate
            CollectionDate    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Infrastructure_Hygiene.csv"
    $hygieneData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($hygieneData.Count) VMs to $outputFile" -Level SUCCESS
    
    return $hygieneData.Count
}

function Export-VMChangeEvents {
    <#
    .SYNOPSIS
        Exports VM creation, deletion, and reconfiguration events.
    #>
    param([int]$Days = 7)
    
    Write-Log "Collecting VM Change Events (last $Days days)..."
    $startDate = (Get-Date).AddDays(-$Days)
    
    $events = Get-VIEvent -Start $startDate -MaxSamples 10000 | 
        Where-Object { 
            $_ -is [VMware.Vim.VmCreatedEvent] -or 
            $_ -is [VMware.Vim.VmClonedEvent] -or
            $_ -is [VMware.Vim.VmDeployedEvent] -or
            $_ -is [VMware.Vim.VmRemovedEvent] -or 
            $_ -is [VMware.Vim.VmReconfiguredEvent] -or
            $_ -is [VMware.Vim.VmMigratedEvent] -or
            $_ -is [VMware.Vim.DrsVmMigratedEvent]
        } | ForEach-Object {
            $event = $_
            
            $eventType = switch ($event.GetType().Name) {
                "VmCreatedEvent"      { "VM Created" }
                "VmClonedEvent"       { "VM Cloned" }
                "VmDeployedEvent"     { "VM Deployed" }
                "VmRemovedEvent"      { "VM Removed" }
                "VmReconfiguredEvent" { "VM Reconfigured" }
                "VmMigratedEvent"     { "VM Migrated (Manual)" }
                "DrsVmMigratedEvent"  { "VM Migrated (DRS)" }
                default               { $event.GetType().Name }
            }
            
            [PSCustomObject]@{
                Timestamp           = $event.CreatedTime
                Date                = $event.CreatedTime.ToString("yyyy-MM-dd")
                Hour                = $event.CreatedTime.Hour
                VMName              = $event.Vm.Name
                EventType           = $eventType
                UserName            = $event.UserName
                Message             = $event.FullFormattedMessage
                Datacenter          = $event.Datacenter.Name
                Cluster             = $event.ComputeResource.Name
                Host                = $event.Host.Name
                CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    
    $outputFile = Join-Path $OutputPath "VM_Changes.csv"
    $events | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($events.Count) change events to $outputFile" -Level SUCCESS
    
    return $events.Count
}

function Export-DRSEffectiveness {
    <#
    .SYNOPSIS
        Exports DRS configuration and vMotion statistics.
    #>
    Write-Log "Collecting DRS Effectiveness data..."
    
    $clusters = Get-Cluster | ForEach-Object {
        $cluster = $_
        
        # Count DRS vMotions in last 24 hours
        $drsVMotions24h = (Get-VIEvent -Entity $cluster -Start (Get-Date).AddDays(-1) -MaxSamples 5000 | 
            Where-Object { $_ -is [VMware.Vim.DrsVmMigratedEvent] }).Count
        
        # Count DRS vMotions in last 7 days
        $drsVMotions7d = (Get-VIEvent -Entity $cluster -Start (Get-Date).AddDays(-7) -MaxSamples 10000 | 
            Where-Object { $_ -is [VMware.Vim.DrsVmMigratedEvent] }).Count
        
        # Get cluster resources
        $hosts = $cluster | Get-VMHost
        $vms = $cluster | Get-VM
        
        $totalCpu = ($hosts | Measure-Object -Property CpuTotalMhz -Sum).Sum
        $totalMem = ($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum
        $allocatedCpu = ($vms | Measure-Object -Property NumCpu -Sum).Sum * 1000  # Rough estimate
        $allocatedMem = ($vms | Measure-Object -Property MemoryGB -Sum).Sum
        
        [PSCustomObject]@{
            ClusterName         = $cluster.Name
            vCenter             = $cluster.Uid.Split('@')[1].Split(':')[0]
            DrsEnabled          = $cluster.DrsEnabled
            DrsMode             = $cluster.DrsMode
            DrsAutomationLevel  = $cluster.DrsAutomationLevel
            HAEnabled           = $cluster.HAEnabled
            HAAdmissionControl  = $cluster.HAAdmissionControlEnabled
            HostCount           = $hosts.Count
            VMCount             = $vms.Count
            TotalCpuMhz         = [math]::Round($totalCpu, 0)
            TotalMemoryGB       = [math]::Round($totalMem, 2)
            AllocatedMemoryGB   = [math]::Round($allocatedMem, 2)
            MemoryOvercommit    = [math]::Round(($allocatedMem / $totalMem) * 100, 2)
            DrsVMotions24h      = $drsVMotions24h
            DrsVMotions7d       = $drsVMotions7d
            AvgDrsVMotionsPerDay = [math]::Round($drsVMotions7d / 7, 1)
            CollectionDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "DRS_Effectiveness.csv"
    $clusters | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($clusters.Count) clusters to $outputFile" -Level SUCCESS
    
    return $clusters.Count
}

function Export-ClusterCapacity {
    <#
    .SYNOPSIS
        Exports cluster-level capacity metrics for vCPU:pCPU ratio tracking.
    #>
    Write-Log "Collecting Cluster Capacity data..."
    
    $clusterData = Get-Cluster | ForEach-Object {
        $cluster = $_
        $hosts = $cluster | Get-VMHost
        $vms = $cluster | Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" }
        
        $totalPCpu = ($hosts | Measure-Object -Property NumCpu -Sum).Sum
        $totalVCpu = ($vms | Measure-Object -Property NumCpu -Sum).Sum
        $ratio = if ($totalPCpu -gt 0) { [math]::Round($totalVCpu / $totalPCpu, 2) } else { 0 }
        
        # Risk level based on ratio
        $riskLevel = "Healthy"
        if ($ratio -gt 3) { $riskLevel = "Warning" }
        if ($ratio -gt 4) { $riskLevel = "High" }
        if ($ratio -gt 6) { $riskLevel = "Critical" }
        
        [PSCustomObject]@{
            ClusterName       = $cluster.Name
            vCenter           = $cluster.Uid.Split('@')[1].Split(':')[0]
            HostCount         = $hosts.Count
            PoweredOnVMCount  = $vms.Count
            TotalPCpuCores    = $totalPCpu
            TotalVCpuAllocated = $totalVCpu
            VCpuToPCpuRatio   = $ratio
            RatioRiskLevel    = $riskLevel
            TotalMemoryGB     = [math]::Round(($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum, 2)
            AllocatedMemoryGB = [math]::Round(($vms | Measure-Object -Property MemoryGB -Sum).Sum, 2)
            CollectionDate    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Cluster_Capacity.csv"
    $clusterData | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($clusterData.Count) clusters to $outputFile" -Level SUCCESS
    
    return $clusterData.Count
}

function Export-HostInventory {
    <#
    .SYNOPSIS
        Exports ESXi host inventory and configuration.
    #>
    Write-Log "Collecting Host Inventory..."
    
    $hosts = Get-VMHost | ForEach-Object {
        $vmhost = $_
        
        [PSCustomObject]@{
            HostName          = $vmhost.Name
            vCenter           = $vmhost.Uid.Split('@')[1].Split(':')[0]
            Cluster           = $vmhost.Parent.Name
            ConnectionState   = $vmhost.ConnectionState
            PowerState        = $vmhost.PowerState
            Manufacturer      = $vmhost.Manufacturer
            Model             = $vmhost.Model
            ESXiVersion       = $vmhost.Version
            ESXiBuild         = $vmhost.Build
            CpuModel          = $vmhost.ProcessorType
            CpuSockets        = $vmhost.ExtensionData.Hardware.CpuInfo.NumCpuPackages
            CpuCores          = $vmhost.NumCpu
            CpuThreads        = $vmhost.ExtensionData.Hardware.CpuInfo.NumCpuThreads
            CpuTotalMhz       = $vmhost.CpuTotalMhz
            CpuUsageMhz       = $vmhost.CpuUsageMhz
            CpuUsagePercent   = [math]::Round(($vmhost.CpuUsageMhz / $vmhost.CpuTotalMhz) * 100, 2)
            MemoryTotalGB     = [math]::Round($vmhost.MemoryTotalGB, 2)
            MemoryUsageGB     = [math]::Round($vmhost.MemoryUsageGB, 2)
            MemoryUsagePercent = [math]::Round(($vmhost.MemoryUsageGB / $vmhost.MemoryTotalGB) * 100, 2)
            VMCount           = ($vmhost | Get-VM).Count
            UptimeDays        = [math]::Round((New-TimeSpan -Seconds $vmhost.ExtensionData.Summary.QuickStats.Uptime).TotalDays, 1)
            MaintenanceMode   = $vmhost.ExtensionData.Runtime.InMaintenanceMode
            CollectionDate    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Host_Inventory.csv"
    $hosts | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($hosts.Count) hosts to $outputFile" -Level SUCCESS
    
    return $hosts.Count
}

#endregion

#region Main Execution

try {
    Write-Log "========================================" -Level INFO
    Write-Log "vSphere Metrics Export Starting" -Level INFO
    Write-Log "========================================" -Level INFO
    Write-Log "Output Path: $OutputPath"
    Write-Log "Stats History: $DaysOfStats days"
    Write-Log "Zombie Threshold: $DaysForZombieVM days"
    
    # Import PowerCLI module
    Write-Log "Loading VMware PowerCLI module..."
    if (-not (Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) {
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }
    Write-Log "PowerCLI module loaded" -Level SUCCESS
    
    # Set PowerCLI configuration
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -ParticipateInCeip $false -Confirm:$false | Out-Null
    
    # Connect to vCenter(s)
    foreach ($vc in $vCenterServer) {
        Write-Log "Connecting to vCenter: $vc..."
        
        $connectParams = @{
            Server = $vc
            ErrorAction = "Stop"
        }
        
        if ($Credential) {
            $connectParams.Credential = $Credential
        }
        
        Connect-VIServer @connectParams | Out-Null
        Write-Log "Connected to $vc" -Level SUCCESS
    }
    
    # Initialize results tracking
    $results = @{
        VMRightSizing       = 0
        ZombieVMs           = 0
        Snapshots           = 0
        DatastoreCapacity   = 0
        ClusterPerformance  = 0
        DatastoreLatency    = 0
        InfraHygiene        = 0
        VMChanges           = 0
        DRSEffectiveness    = 0
        ClusterCapacity     = 0
        HostInventory       = 0
    }
    
    # Run all collection functions
    Write-Log "----------------------------------------"
    Write-Log "Starting Data Collection..."
    Write-Log "----------------------------------------"
    
    # Dashboard 1: Capacity & Waste
    Write-Log "--- CAPACITY & WASTE DASHBOARD ---" -Level INFO
    $results.VMRightSizing = Export-VMRightSizing -Days $DaysOfStats
    $results.ZombieVMs = Export-ZombieVMs -DaysOff $DaysForZombieVM
    $results.Snapshots = Export-Snapshots
    $results.DatastoreCapacity = Export-DatastoreCapacity
    $results.ClusterCapacity = Export-ClusterCapacity
    
    # Dashboard 2: Cluster Performance
    Write-Log "--- CLUSTER PERFORMANCE DASHBOARD ---" -Level INFO
    $results.ClusterPerformance = Export-ClusterPerformance -Hours 24
    $results.DatastoreLatency = Export-DatastoreLatency -Hours 24
    
    # Dashboard 3: Infrastructure Hygiene
    Write-Log "--- INFRASTRUCTURE HYGIENE DASHBOARD ---" -Level INFO
    $results.InfraHygiene = Export-InfrastructureHygiene
    $results.HostInventory = Export-HostInventory
    
    # Dashboard 4: Change & Drift
    Write-Log "--- CHANGE & DRIFT DASHBOARD ---" -Level INFO
    $results.VMChanges = Export-VMChangeEvents -Days $DaysOfStats
    $results.DRSEffectiveness = Export-DRSEffectiveness
    
    # Generate summary
    Write-Log "----------------------------------------"
    Write-Log "Collection Complete - Summary" -Level SUCCESS
    Write-Log "----------------------------------------"
    
    $summaryData = [PSCustomObject]@{
        ExportDate          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        vCenters            = $vCenterServer -join ", "
        OutputPath          = $OutputPath
        VMsAnalyzed         = $results.VMRightSizing
        ZombieVMsFound      = $results.ZombieVMs
        SnapshotsFound      = $results.Snapshots
        DatastoresScanned   = $results.DatastoreCapacity
        PerformancePoints   = $results.ClusterPerformance
        HygieneVMs          = $results.InfraHygiene
        ChangeEvents        = $results.VMChanges
        ClustersScanned     = $results.ClusterCapacity
        HostsScanned        = $results.HostInventory
        DurationMinutes     = [math]::Round(((Get-Date) - $Script:StartTime).TotalMinutes, 2)
    }
    
    $summaryFile = Join-Path $OutputPath "Export_Summary.csv"
    $summaryData | Export-Csv $summaryFile -NoTypeInformation -Force
    
    foreach ($key in $results.Keys) {
        Write-Log "  $key : $($results[$key]) records"
    }
    
    $duration = [math]::Round(((Get-Date) - $Script:StartTime).TotalMinutes, 2)
    Write-Log "Total Duration: $duration minutes" -Level SUCCESS
    Write-Log "Log file: $LogFile"
    Write-Log "========================================" -Level INFO
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
finally {
    # Disconnect from all vCenters
    Write-Log "Disconnecting from vCenter servers..."
    Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Disconnected from all vCenter servers" -Level INFO
}

#endregion
