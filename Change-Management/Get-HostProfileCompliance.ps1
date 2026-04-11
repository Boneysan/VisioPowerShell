<#
.SYNOPSIS
    Reports host profile compliance status for ESXi hosts.

.DESCRIPTION
    Checks each ESXi host in the target cluster against its attached host profile
    and reports compliance status, non-compliant settings, and last check time.
    Identifies hosts with no attached profile. Useful for drift detection and
    change management validation.

.PARAMETER ClusterName
    Optional. Cluster to scope the compliance check.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the host profile compliance report as CSV.

.PARAMETER RunComplianceCheck
    Optional switch. Forces a fresh compliance check before reporting.

.EXAMPLE
    .\Get-HostProfileCompliance.ps1 -ClusterName "Production" -OutputFile "hp-compliance.csv"
    Exports host profile compliance status for the Production cluster.

.EXAMPLE
    .\Get-HostProfileCompliance.ps1 -RunComplianceCheck -OutputFile "hp-compliance-fresh.csv"
    Triggers a fresh compliance check then exports the results.

.OUTPUTS
    CSV with columns: HostName, ClusterName, ProfileName, ComplianceStatus,
    LastCheckTime, FailureCount, FailureDetails

.NOTES
    Requires:
    - VMware PowerCLI module
    - Host profile management privileges

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
    [switch]$RunComplianceCheck
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
    $hosts = Get-VMHost -Location $cluster
}
else {
    $hosts = Get-VMHost
}

Write-Host "Checking host profile compliance for $($hosts.Count) host(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vmhost in ($hosts | Sort-Object Name)) {
    $clusterObj   = $vmhost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    try {
        $profile = Get-VMHostProfile -Entity $vmhost -ErrorAction SilentlyContinue

        if (-not $profile) {
            $results.Add([PSCustomObject]@{
                HostName         = $vmhost.Name
                ClusterName      = $clusterLabel
                ProfileName      = 'No Profile Attached'
                ComplianceStatus = 'Unknown'
                LastCheckTime    = 'N/A'
                FailureCount     = 0
                FailureDetails   = 'No host profile attached to this host'
            })
            continue
        }

        if ($RunComplianceCheck) {
            Write-Host "  Running compliance check on $($vmhost.Name)..." -ForegroundColor Yellow
            Test-VMHostProfileCompliance -VMHost $vmhost -ErrorAction SilentlyContinue | Out-Null
        }

        $compliance = Test-VMHostProfileCompliance -VMHost $vmhost -ErrorAction SilentlyContinue

        $status       = if ($compliance) { $compliance.ComplianceStatus } else { 'Unknown' }
        $lastCheck    = if ($compliance -and $compliance.CheckTime) { $compliance.CheckTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }

        $failures     = @()
        $failureCount = 0
        if ($compliance -and $compliance.InComplianceWithProfile -eq $false) {
            if ($compliance.PSObject.Properties['Failure']) {
                $failures = $compliance.Failure | ForEach-Object { "$($_.Message.Summary)" }
                $failureCount = $failures.Count
            }
        }

        $results.Add([PSCustomObject]@{
            HostName         = $vmhost.Name
            ClusterName      = $clusterLabel
            ProfileName      = $profile.Name
            ComplianceStatus = $status
            LastCheckTime    = $lastCheck
            FailureCount     = $failureCount
            FailureDetails   = if ($failures.Count -gt 0) { ($failures | Select-Object -First 5) -join ' | ' } else { 'None' }
        })
    }
    catch {
        $results.Add([PSCustomObject]@{
            HostName         = $vmhost.Name
            ClusterName      = $clusterLabel
            ProfileName      = 'Error'
            ComplianceStatus = 'Error'
            LastCheckTime    = 'N/A'
            FailureCount     = 0
            FailureDetails   = $_.Exception.Message
        })
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$compliant    = ($results | Where-Object { $_.ComplianceStatus -eq 'Compliant' }).Count
$nonCompliant = ($results | Where-Object { $_.ComplianceStatus -eq 'NonCompliant' }).Count
$noProfile    = ($results | Where-Object { $_.ProfileName -eq 'No Profile Attached' }).Count

Write-Host "`n=== Host Profile Compliance Summary ===" -ForegroundColor Cyan
Write-Host "  Total Hosts       : $($results.Count)"  -ForegroundColor White
Write-Host "  Compliant         : $compliant"          -ForegroundColor Green
Write-Host "  Non-Compliant     : $nonCompliant"       -ForegroundColor $(if ($nonCompliant -gt 0) { 'Red' } else { 'Green' })
Write-Host "  No Profile        : $noProfile"          -ForegroundColor $(if ($noProfile -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output            : $OutputFile"         -ForegroundColor White
