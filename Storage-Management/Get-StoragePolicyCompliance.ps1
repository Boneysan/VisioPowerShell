<#
.SYNOPSIS
    Audits VM storage policy (SPBM) assignments and compliance status.

.DESCRIPTION
    Iterates all VMs and their associated virtual disks to report the assigned
    storage policy and whether each disk is currently compliant with that policy.
    Non-compliant disks are flagged with their last compliance check timestamp.

.PARAMETER ClusterName
    Optional. Scope the audit to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER PolicyName
    Optional. Filter results to a specific storage policy name.

.PARAMETER OutputFile
    Required. Path to export the policy compliance report as CSV.

.PARAMETER IncludeNonCompliant
    Optional. Switch. When set, only include non-compliant disks in the report.

.EXAMPLE
    .\Get-StoragePolicyCompliance.ps1 -ClusterName "Production" -OutputFile "spbm.csv"
    Reports all VM disk policy compliance in the Production cluster.

.EXAMPLE
    .\Get-StoragePolicyCompliance.ps1 -PolicyName "Gold" -IncludeNonCompliant -OutputFile "gold-violations.csv"
    Shows only non-compliant disks for the Gold storage policy.

.OUTPUTS
    CSV with columns: VMName, DiskLabel, Datastore, PolicyName, ComplianceStatus, LastCheckTime

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to SPBM and VM configurations

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$PolicyName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeNonCompliant
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
    $vms = Get-VM -Location $cluster
}
else {
    $vms = Get-VM
}

Write-Host "Checking storage policy compliance for $($vms.Count) VM(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name)..." -ForegroundColor White

    try {
        $spbmEntities = Get-SpbmEntityConfiguration -VM $vm -ErrorAction SilentlyContinue
        if (-not $spbmEntities) { continue }

        foreach ($entity in $spbmEntities) {
            $policyNameActual = if ($entity.StoragePolicy) { $entity.StoragePolicy.Name } else { '(none)' }
            if ($PolicyName -and $policyNameActual -ne $PolicyName) { continue }

            $compliance = $entity.ComplianceStatus
            if ($IncludeNonCompliant -and $compliance -eq 'compliant') { continue }

            # Determine disk label / entity name
            $diskLabel = if ($entity.Entity -is [VMware.VimAutomation.ViCore.Types.V1.VM.VM]) {
                'VM Home'
            } else {
                try { $entity.Entity.Name } catch { 'Unknown' }
            }

            # Datastore name
            $dsName = try {
                if ($entity.Entity -is [VMware.VimAutomation.Storage.Types.V1.Spbm.SpbmHardDiskEntityConfiguration]) {
                    $entity.Entity.HardDisk.Filename -replace '^\[(.+?)\].*', '$1'
                } else { 'N/A' }
            } catch { 'N/A' }

            $results.Add([PSCustomObject]@{
                VMName           = $vm.Name
                DiskLabel        = $diskLabel
                Datastore        = $dsName
                PolicyName       = $policyNameActual
                ComplianceStatus = $compliance
                LastCheckTime    = if ($entity.ComplianceTaskLastRunTime) { $entity.ComplianceTaskLastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
            })
        }
    }
    catch {
        Write-Warning "Error checking SPBM for $($vm.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$nonCompliant = ($results | Where-Object { $_.ComplianceStatus -ne 'compliant' }).Count

Write-Host "`n=== Storage Policy Compliance Summary ===" -ForegroundColor Cyan
Write-Host "  VMs checked       : $($vms.Count)" -ForegroundColor White
Write-Host "  Records exported  : $($results.Count)" -ForegroundColor White
Write-Host "  Non-compliant     : $nonCompliant" -ForegroundColor $(if ($nonCompliant -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output            : $OutputFile" -ForegroundColor White
