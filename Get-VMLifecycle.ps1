<#
.SYNOPSIS
    Retrieves comprehensive VM lifecycle management data for VMs in a specified folder.

.DESCRIPTION
    This script collects detailed VM inventory information useful for lifecycle management,
    including power state, resource allocation, storage usage, snapshots, creation dates,
    host/cluster assignments, guest OS details, and resource configurations.
    
    The output provides a complete dataset for VM provisioning tracking, capacity planning,
    maintenance scheduling, compliance reporting, and decommissioning decisions.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER FolderPath
    Optional. The path to the VM folder to analyze. If not specified, analyzes all VMs.
    Examples: "Production", "Development/WebServers", "VDI/Users"

.PARAMETER OutputFile
    Required. Path to export results as CSV.

.PARAMETER IncludePoweredOff
    Optional. Include powered-off VMs in the results. Default: All VMs (powered on and off).

.PARAMETER IncludeSnapshots
    Optional. Include detailed snapshot information. Default: True.

.EXAMPLE
    .\Get-VMLifecycle.ps1 -OutputFile "vm-lifecycle.csv"
    Exports lifecycle data for all VMs to CSV.

.EXAMPLE
    .\Get-VMLifecycle.ps1 -FolderPath "Production" -OutputFile "production-vms.csv"
    Exports lifecycle data for Production folder VMs.

.EXAMPLE
    .\Get-VMLifecycle.ps1 -vCenter "vcenter.example.com" -FolderPath "VDI" -OutputFile "vdi-inventory.csv" -IncludeSnapshots:$false
    Connects to vCenter, analyzes VDI VMs without snapshot details.

.OUTPUTS
    CSV file with the following columns:
    - VMName: Virtual machine name
    - PowerState: Current power state (PoweredOn/PoweredOff/Suspended)
    - Folder: VM folder location
    - Cluster: vSphere cluster name
    - Host: ESXi host running the VM
    - NumCPU: Number of virtual CPUs
    - MemoryGB: Configured RAM in GB
    - UsedSpaceGB: Current disk space used
    - ProvisionedSpaceGB: Total provisioned disk space
    - GuestOS: Guest operating system name
    - IPAddress: Primary IP address
    - AllIPAddresses: All IP addresses (comma-separated)
    - ToolsStatus: VMware Tools installation status
    - ToolsVersion: VMware Tools version
    - CreateDate: VM creation date
    - SnapshotCount: Number of snapshots
    - OldestSnapshot: Date of oldest snapshot
    - NewestSnapshot: Date of newest snapshot
    - SnapshotSizeGB: Total snapshot disk usage
    - CPUReservationMHz: CPU reservation
    - CPULimitMHz: CPU limit (-1 = unlimited)
    - MemoryReservationMB: Memory reservation
    - MemoryLimitMB: Memory limit (-1 = unlimited)
    - CPUShares: CPU share level
    - MemoryShares: Memory share level
    - Notes: VM notes/annotations

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter and VM inventory
    
    Performance:
    - Retrieval time depends on number of VMs and snapshot details
    - Typically 1-3 seconds per VM
    - Use -IncludeSnapshots:$false for faster results on large inventories
    
    Use Cases:
    - VM inventory and asset tracking
    - Capacity planning and resource optimization
    - Snapshot cleanup and storage management
    - Compliance and audit reporting
    - Decommissioning candidates (powered off, old, unused)
    - Migration planning and host balancing
    
    Author: GitHub Copilot
    Version: 1.0
    Date: December 11, 2025
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$true)]
    [string]$OutputFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff = $true,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeSnapshots = $true
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

# Get VMs based on folder path or all VMs
if ($FolderPath) {
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
    Write-Host "Retrieving VMs from folder..." -ForegroundColor Cyan
    $vms = Get-VM -Location $folder
}
else {
    Write-Host "Retrieving all VMs..." -ForegroundColor Cyan
    $vms = Get-VM
}

if (-not $IncludePoweredOff) {
    $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
}

if ($vms.Count -eq 0) {
    Write-Error "No VMs found"
    exit 1
}

Write-Host "  Found $($vms.Count) VM(s)" -ForegroundColor White
Write-Host "`nCollecting VM lifecycle data..." -ForegroundColor Cyan

$results = @()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  Processing [$vmCount/$($vms.Count)]: $($vm.Name)..." -ForegroundColor White
    
    try {
        # Get VM View for creation date
        $vmView = $vm | Get-View -Property Config.CreateDate, Config.Annotation
        
        # Get VMGuest info for OS and IP
        $vmGuest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
        
        # Get resource configuration
        $vmResourceConfig = $vm | Get-VMResourceConfiguration -ErrorAction SilentlyContinue
        
        # Get snapshot information if requested
        $snapshots = $null
        $snapshotCount = 0
        $oldestSnapshot = $null
        $newestSnapshot = $null
        $snapshotSizeGB = 0
        
        if ($IncludeSnapshots) {
            $snapshots = Get-Snapshot -VM $vm -ErrorAction SilentlyContinue
            if ($snapshots) {
                $snapshotCount = $snapshots.Count
                $oldestSnapshot = ($snapshots | Measure-Object -Property Created -Minimum).Minimum
                $newestSnapshot = ($snapshots | Measure-Object -Property Created -Maximum).Maximum
                $snapshotSizeGB = [math]::Round(($snapshots | Measure-Object -Property SizeGB -Sum).Sum, 2)
            }
        }
        
        # Get host and cluster
        $vmHost = Get-VMHost -VM $vm -ErrorAction SilentlyContinue
        $cluster = Get-Cluster -VM $vm -ErrorAction SilentlyContinue
        
        # Get all IP addresses
        $allIPs = if ($vmGuest.IPAddress) { 
            ($vmGuest.IPAddress | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' }) -join ', '
        } else { 
            'N/A' 
        }
        
        $primaryIP = if ($vmGuest.IPAddress -and $vmGuest.IPAddress.Count -gt 0) {
            ($vmGuest.IPAddress | Where-Object { $_ -match '\d+\.\d+\.\d+\.\d+' } | Select-Object -First 1)
        } else {
            'N/A'
        }
        
        # Build result object
        $results += [PSCustomObject]@{
            VMName = $vm.Name
            PowerState = $vm.PowerState
            Folder = $vm.Folder.Name
            Cluster = if ($cluster) { $cluster.Name } else { 'N/A' }
            Host = if ($vmHost) { $vmHost.Name } else { 'N/A' }
            NumCPU = $vm.NumCpu
            MemoryGB = $vm.MemoryGB
            UsedSpaceGB = [math]::Round($vm.UsedSpaceGB, 2)
            ProvisionedSpaceGB = [math]::Round($vm.ProvisionedSpaceGB, 2)
            GuestOS = if ($vmGuest.OSFullName) { $vmGuest.OSFullName } else { $vm.GuestId }
            IPAddress = $primaryIP
            AllIPAddresses = $allIPs
            ToolsStatus = if ($vmGuest) { $vmGuest.State } else { 'Unknown' }
            ToolsVersion = if ($vmGuest) { $vmGuest.ToolsVersion } else { 'Unknown' }
            CreateDate = if ($vmView.Config.CreateDate) { $vmView.Config.CreateDate } else { 'Unknown' }
            SnapshotCount = $snapshotCount
            OldestSnapshot = if ($oldestSnapshot) { $oldestSnapshot } else { 'None' }
            NewestSnapshot = if ($newestSnapshot) { $newestSnapshot } else { 'None' }
            SnapshotSizeGB = $snapshotSizeGB
            CPUReservationMHz = if ($vmResourceConfig) { $vmResourceConfig.CpuReservationMhz } else { 0 }
            CPULimitMHz = if ($vmResourceConfig) { $vmResourceConfig.CpuLimitMhz } else { -1 }
            MemoryReservationMB = if ($vmResourceConfig) { $vmResourceConfig.MemReservationMB } else { 0 }
            MemoryLimitMB = if ($vmResourceConfig) { $vmResourceConfig.MemLimitMB } else { -1 }
            CPUShares = if ($vmResourceConfig) { $vmResourceConfig.CpuSharesLevel } else { 'Normal' }
            MemoryShares = if ($vmResourceConfig) { $vmResourceConfig.MemSharesLevel } else { 'Normal' }
            Notes = if ($vmView.Config.Annotation) { $vmView.Config.Annotation } else { '' }
        }
    }
    catch {
        Write-Warning "    Error collecting data for $($vm.Name): $_"
    }
}

# Sort by VM name
$results = $results | Sort-Object VMName

# Export to CSV
$absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
$results | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8

Write-Host "`nResults exported to: $absolutePath" -ForegroundColor Green

# Display summary statistics
Write-Host "`nVM Lifecycle Summary:" -ForegroundColor Cyan
Write-Host "=====================" -ForegroundColor Cyan

$poweredOn = ($results | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
$poweredOff = ($results | Where-Object { $_.PowerState -eq 'PoweredOff' }).Count
$suspended = ($results | Where-Object { $_.PowerState -eq 'Suspended' }).Count

Write-Host "  Total VMs: $($results.Count)" -ForegroundColor White
Write-Host "  Powered On: $poweredOn" -ForegroundColor Green
Write-Host "  Powered Off: $poweredOff" -ForegroundColor Yellow
Write-Host "  Suspended: $suspended" -ForegroundColor Yellow

# Resource summary
$totalCPU = ($results | Measure-Object -Property NumCPU -Sum).Sum
$totalMemoryGB = ($results | Measure-Object -Property MemoryGB -Sum).Sum
$totalUsedGB = [math]::Round(($results | Measure-Object -Property UsedSpaceGB -Sum).Sum, 2)
$totalProvisionedGB = [math]::Round(($results | Measure-Object -Property ProvisionedSpaceGB -Sum).Sum, 2)

Write-Host "`nResource Allocation:" -ForegroundColor Cyan
Write-Host "  Total vCPUs: $totalCPU" -ForegroundColor White
Write-Host "  Total Memory: $totalMemoryGB GB" -ForegroundColor White
Write-Host "  Total Used Storage: $totalUsedGB GB" -ForegroundColor White
Write-Host "  Total Provisioned Storage: $totalProvisionedGB GB" -ForegroundColor White

# Snapshot summary
if ($IncludeSnapshots) {
    $vmsWithSnapshots = ($results | Where-Object { $_.SnapshotCount -gt 0 }).Count
    $totalSnapshots = ($results | Measure-Object -Property SnapshotCount -Sum).Sum
    $totalSnapshotSize = [math]::Round(($results | Measure-Object -Property SnapshotSizeGB -Sum).Sum, 2)
    
    Write-Host "`nSnapshot Summary:" -ForegroundColor Cyan
    Write-Host "  VMs with snapshots: $vmsWithSnapshots" -ForegroundColor White
    Write-Host "  Total snapshots: $totalSnapshots" -ForegroundColor White
    Write-Host "  Total snapshot size: $totalSnapshotSize GB" -ForegroundColor White
    
    if ($vmsWithSnapshots -gt 0) {
        Write-Host "`n  VMs with most snapshots:" -ForegroundColor Yellow
        $results | Where-Object { $_.SnapshotCount -gt 0 } | 
            Sort-Object SnapshotCount -Descending | 
            Select-Object VMName, SnapshotCount, SnapshotSizeGB, OldestSnapshot -First 5 | 
            Format-Table -AutoSize
    }
}

# Potential issues
Write-Host "`nPotential Lifecycle Issues:" -ForegroundColor Yellow

# Long-running powered off VMs
$oldPoweredOff = $results | Where-Object { 
    $_.PowerState -eq 'PoweredOff' -and 
    $_.CreateDate -ne 'Unknown' -and 
    ([DateTime]$_.CreateDate) -lt (Get-Date).AddDays(-90)
}

if ($oldPoweredOff) {
    Write-Host "  Powered off VMs older than 90 days: $($oldPoweredOff.Count) (consider decommissioning)" -ForegroundColor Red
    $oldPoweredOff | Select-Object VMName, CreateDate, Folder -First 5 | Format-Table -AutoSize
}

# VMs with old snapshots
if ($IncludeSnapshots) {
    $oldSnapshots = $results | Where-Object { 
        $_.OldestSnapshot -ne 'None' -and 
        ([DateTime]$_.OldestSnapshot) -lt (Get-Date).AddDays(-7)
    }
    
    if ($oldSnapshots) {
        Write-Host "  VMs with snapshots older than 7 days: $($oldSnapshots.Count) (review and cleanup)" -ForegroundColor Red
        $oldSnapshots | 
            Sort-Object OldestSnapshot | 
            Select-Object VMName, SnapshotCount, OldestSnapshot, SnapshotSizeGB -First 5 | 
            Format-Table -AutoSize
    }
}

# VMs with no IP address (powered on)
$noIP = $results | Where-Object { 
    $_.PowerState -eq 'PoweredOn' -and 
    $_.IPAddress -eq 'N/A'
}

if ($noIP) {
    Write-Host "  Powered on VMs with no IP address: $($noIP.Count) (check VMware Tools)" -ForegroundColor Red
    $noIP | Select-Object VMName, ToolsStatus, GuestOS -First 5 | Format-Table -AutoSize
}

# VMs with outdated tools
$outdatedTools = $results | Where-Object { 
    $_.PowerState -eq 'PoweredOn' -and 
    $_.ToolsStatus -match 'Old|NotInstalled|NotRunning'
}

if ($outdatedTools) {
    Write-Host "  VMs with outdated or missing VMware Tools: $($outdatedTools.Count)" -ForegroundColor Yellow
    $outdatedTools | Select-Object VMName, ToolsStatus, ToolsVersion -First 5 | Format-Table -AutoSize
}

if (-not $oldPoweredOff -and -not $oldSnapshots -and -not $noIP -and -not $outdatedTools) {
    Write-Host "  No critical lifecycle issues detected." -ForegroundColor Green
}

Write-Host "`nLifecycle data collection complete!" -ForegroundColor Green
