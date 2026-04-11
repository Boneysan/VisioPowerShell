<#
.SYNOPSIS
    Reports the running state and startup policy of services on ESXi hosts.

.DESCRIPTION
    Enumerates all (or filtered) services on each ESXi host in the target cluster.
    Reports the service key, label, running state, startup policy, and whether the
    service is required. Useful for validating standard service configurations and
    detecting unexpected running services (e.g., SSH left enabled).

.PARAMETER ClusterName
    Optional. Cluster to inspect. If omitted, checks all connected hosts.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the host service status report as CSV.

.PARAMETER ServiceName
    Optional. Filter output to a specific service key (e.g., 'TSM-SSH', 'ntpd').

.EXAMPLE
    .\Get-HostServiceStatus.ps1 -ClusterName "Production" -OutputFile "host-services.csv"
    Exports all service states for all hosts in the Production cluster.

.EXAMPLE
    .\Get-HostServiceStatus.ps1 -ServiceName "TSM-SSH" -OutputFile "ssh-status.csv"
    Exports only SSH service status across all hosts.

.OUTPUTS
    CSV with columns: HostName, ClusterName, ServiceKey, ServiceLabel,
    Running, Policy, Required, Uninstallable

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi host service configuration

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
    [string]$ServiceName
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

Write-Host "Querying service status from $($hosts.Count) host(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vmhost in ($hosts | Sort-Object Name)) {
    $clusterObj  = $vmhost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    try {
        $services = Get-VMHostService -VMHost $vmhost -ErrorAction Stop

        foreach ($svc in $services) {
            if ($ServiceName -and $svc.Key -ne $ServiceName) { continue }

            $results.Add([PSCustomObject]@{
                HostName     = $vmhost.Name
                ClusterName  = $clusterLabel
                ServiceKey   = $svc.Key
                ServiceLabel = $svc.Label
                Running      = $svc.Running
                Policy       = $svc.Policy
                Required     = $svc.Required
                Uninstallable= $svc.Uninstallable
            })
        }
    }
    catch {
        Write-Warning "Could not query services on $($vmhost.Name): $_"
    }

    Write-Progress -Activity "Querying host services" -Status $vmhost.Name -PercentComplete (($hosts.IndexOf($vmhost) + 1) / $hosts.Count * 100)
}

Write-Progress -Activity "Querying host services" -Completed

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host "Exported $($results.Count) service records to: $OutputFile" -ForegroundColor Cyan

$running      = ($results | Where-Object { $_.Running -eq $true }).Count
$unexpectedUp = ($results | Where-Object { $_.Running -eq $true -and $_.Policy -eq 'off' }).Count

Write-Host "`n=== Host Service Status Summary ===" -ForegroundColor Cyan
Write-Host "  Hosts             : $($hosts.Count)" -ForegroundColor White
Write-Host "  Total Services    : $($results.Count)" -ForegroundColor White
Write-Host "  Running Services  : $running" -ForegroundColor White
Write-Host "  Running w/Policy=Off: $unexpectedUp" -ForegroundColor $(if ($unexpectedUp -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output            : $OutputFile" -ForegroundColor White
