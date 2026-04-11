<#
.SYNOPSIS
    Reports datastore overcommitment ratios and thin-provisioning risk.

.DESCRIPTION
    Compares provisioned space (thin disks counted at their maximum allocation) against
    actual datastore capacity. Identifies datastores at Warning or Critical overcommit
    thresholds and highlights the risk of thin-provisioning induced space exhaustion.

.PARAMETER ClusterName
    Optional. Cluster to scope datastores. If not specified, checks all datastores.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the overcommit report as CSV.

.PARAMETER WarningOvercommitPercent
    Optional. Overcommit ratio (%) threshold for Warning. Default: 150.

.PARAMETER CriticalOvercommitPercent
    Optional. Overcommit ratio (%) threshold for Critical. Default: 200.

.EXAMPLE
    .\Get-DatastoreOvercommit.ps1 -ClusterName "Production" -OutputFile "ds-overcommit.csv"
    Reports overcommit status for all datastores in the Production cluster.

.EXAMPLE
    .\Get-DatastoreOvercommit.ps1 -vCenter "vc.example.com" -WarningOvercommitPercent 130 -OutputFile "ds-risk.csv"
    Uses a tighter 130% warning threshold.

.OUTPUTS
    CSV with columns: DatastoreName, Type, CapacityGB, FreeSpaceGB, UsedSpaceGB,
    ProvisionedGB, OvercommitGB, OvercommitPercent, FreePercent, RiskLevel

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to datastore and VM configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$WarningOvercommitPercent = 150,

    [Parameter(Mandatory=$false)]
    [int]$CriticalOvercommitPercent = 200
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
    $datastores = Get-Datastore -RelatedObject $cluster | Where-Object { $_.Type -ne 'NFS41' -or $true }
}
else {
    $datastores = Get-Datastore
}

# De-duplicate (a datastore may appear under multiple hosts)
$datastores = $datastores | Sort-Object -Property MoRef -Unique

Write-Host "Analyzing $($datastores.Count) datastore(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$dsCount = 0

foreach ($ds in $datastores) {
    $dsCount++
    Write-Host "  [$dsCount/$($datastores.Count)] $($ds.Name)..." -ForegroundColor White

    try {
        $capacityGB    = [math]::Round($ds.CapacityGB, 2)
        $freeSpaceGB   = [math]::Round($ds.FreeSpaceGB, 2)
        $usedSpaceGB   = [math]::Round($capacityGB - $freeSpaceGB, 2)
        $freePercent   = if ($capacityGB -gt 0) { [math]::Round(($freeSpaceGB / $capacityGB) * 100, 1) } else { 0 }

        # Sum provisioned space of all VMs on this datastore
        $vms = Get-VM -Datastore $ds -ErrorAction SilentlyContinue
        $provisionedGB = 0
        foreach ($vm in $vms) {
            foreach ($hd in ($vm | Get-HardDisk -ErrorAction SilentlyContinue)) {
                $provisionedGB += $hd.CapacityGB
            }
        }
        $provisionedGB = [math]::Round($provisionedGB, 2)
        $overcommitGB  = [math]::Round($provisionedGB - $capacityGB, 2)
        $overcommitPct = if ($capacityGB -gt 0) { [math]::Round(($provisionedGB / $capacityGB) * 100, 1) } else { 0 }

        $riskLevel = 'OK'
        if ($overcommitPct -ge $CriticalOvercommitPercent) { $riskLevel = 'CRITICAL' }
        elseif ($overcommitPct -ge $WarningOvercommitPercent) { $riskLevel = 'WARNING' }
        elseif ($freePercent -lt 10) { $riskLevel = 'LOW FREE SPACE' }

        $results.Add([PSCustomObject]@{
            DatastoreName      = $ds.Name
            Type               = $ds.Type
            CapacityGB         = $capacityGB
            FreeSpaceGB        = $freeSpaceGB
            UsedSpaceGB        = $usedSpaceGB
            FreePercent        = $freePercent
            ProvisionedGB      = $provisionedGB
            OvercommitGB       = $overcommitGB
            OvercommitPercent  = $overcommitPct
            RiskLevel          = $riskLevel
        })
    }
    catch {
        Write-Warning "Error processing datastore $($ds.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$critical = ($results | Where-Object { $_.RiskLevel -eq 'CRITICAL' }).Count
$warning  = ($results | Where-Object { $_.RiskLevel -eq 'WARNING' }).Count

Write-Host "`n=== Datastore Overcommit Summary ===" -ForegroundColor Cyan
Write-Host "  Datastores checked : $($results.Count)" -ForegroundColor White
Write-Host "  CRITICAL           : $critical" -ForegroundColor Red
Write-Host "  WARNING            : $warning"  -ForegroundColor Yellow
Write-Host "  Output             : $OutputFile" -ForegroundColor White
