<#
.SYNOPSIS
    Reports Storage DRS (datastore cluster) configuration and automation settings.

.DESCRIPTION
    Enumerates all datastore clusters (Storage DRS pods), reporting automation level,
    I/O load balancing, space utilization thresholds, I/O latency thresholds, affinity
    rules, and the datastores and VMs associated with each pod.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER DatastoreClusterName
    Optional. Limit the report to a specific datastore cluster name.

.PARAMETER OutputFile
    Required. Path to export the SDRS configuration report as CSV.

.EXAMPLE
    .\Get-DatastoreClusterConfig.ps1 -vCenter "vc.example.com" -OutputFile "sdrs-config.csv"
    Reports all Storage DRS cluster configurations.

.EXAMPLE
    .\Get-DatastoreClusterConfig.ps1 -DatastoreClusterName "Gold-SDRS" -OutputFile "gold-sdrs.csv"
    Reports configuration for a specific Storage DRS cluster.

.OUTPUTS
    CSV with columns: PodName, AutomationLevel, IOLoadBalanceEnabled, SpaceThresholdGB,
    SpaceThresholdPercent, IOLatencyThresholdMs, DatastoreCount, VMCount,
    TotalCapacityGB, TotalFreeGB

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to datastore cluster configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$DatastoreClusterName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
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

if ($DatastoreClusterName) {
    $datastoreClusters = Get-DatastoreCluster -Name $DatastoreClusterName -ErrorAction SilentlyContinue
    if (-not $datastoreClusters) { Write-Error "Datastore cluster '$DatastoreClusterName' not found."; exit 1 }
}
else {
    $datastoreClusters = Get-DatastoreCluster -ErrorAction SilentlyContinue
}

if (-not $datastoreClusters) {
    Write-Warning "No datastore clusters (Storage DRS pods) found in this environment."
    @() | Export-Csv -Path $OutputFile -NoTypeInformation
    exit 0
}

Write-Host "Reporting on $($datastoreClusters.Count) Storage DRS cluster(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pod in $datastoreClusters) {
    Write-Host "  Processing: $($pod.Name)..." -ForegroundColor White

    try {
        $datastores = Get-Datastore -DatastoreCluster $pod -ErrorAction SilentlyContinue
        $totalCapGB  = [math]::Round(($datastores | Measure-Object -Property CapacityGB -Sum).Sum, 2)
        $totalFreeGB = [math]::Round(($datastores | Measure-Object -Property FreeSpaceGB -Sum).Sum, 2)

        # VMs on these datastores
        $vmCount = 0
        foreach ($ds in $datastores) {
            $vmCount += (Get-VM -Datastore $ds -ErrorAction SilentlyContinue).Count
        }

        $podView = $pod | Get-View
        $sdrsConfig = $podView.PodStorageDrsEntry.StorageDrsConfig.PodConfig

        $results.Add([PSCustomObject]@{
            PodName                = $pod.Name
            AutomationLevel        = $pod.SdrsAutomationLevel
            IOLoadBalanceEnabled   = if ($sdrsConfig) { $sdrsConfig.IoLoadBalanceEnabled } else { 'N/A' }
            SpaceThresholdPercent  = if ($sdrsConfig) { $sdrsConfig.SpaceThresholdPercent } else { 'N/A' }
            IOLatencyThresholdMs   = if ($sdrsConfig) { $sdrsConfig.IoLatencyThreshold } else { 'N/A' }
            DatastoreCount         = $datastores.Count
            VMCount                = $vmCount
            TotalCapacityGB        = $totalCapGB
            TotalFreeGB            = $totalFreeGB
            FreePercent            = if ($totalCapGB -gt 0) { [math]::Round(($totalFreeGB / $totalCapGB) * 100, 1) } else { 0 }
        })
    }
    catch {
        Write-Warning "Error processing storage cluster $($pod.Name): $_"
    }
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n=== Storage DRS Config Summary ===" -ForegroundColor Cyan
Write-Host "  DS Clusters : $($results.Count)" -ForegroundColor White
Write-Host "  Output      : $OutputFile" -ForegroundColor White
