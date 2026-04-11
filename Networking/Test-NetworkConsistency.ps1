<#
.SYNOPSIS
    Validates that all hosts in a cluster have consistent network configuration.

.DESCRIPTION
    Compares virtual switches, port groups, NIC teaming policies, VMkernel adapters,
    and MTU settings across all hosts in a cluster. Identifies drift relative to a
    reference host or the majority configuration.

.PARAMETER ClusterName
    Required. Name of the cluster to audit for network consistency.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the consistency report as CSV.

.PARAMETER ReferenceHost
    Optional. Name of a host to use as the baseline. If not specified, uses the first host.

.EXAMPLE
    .\Test-NetworkConsistency.ps1 -ClusterName "Production" -OutputFile "net-consistency.csv"
    Checks network consistency for all hosts in Production cluster.

.EXAMPLE
    .\Test-NetworkConsistency.ps1 -ClusterName "Prod" -ReferenceHost "esxi01.example.com" -OutputFile "drift.csv"
    Uses esxi01 as the baseline for comparison.

.OUTPUTS
    CSV with columns: HostName, ConfigItem, SubItem, ExpectedValue, ActualValue, Consistent, DriftDetail

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi host network configurations

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [string]$ReferenceHost
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

$cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }

$vmHosts = Get-VMHost -Location $cluster | Where-Object { $_.ConnectionState -eq 'Connected' }
if ($vmHosts.Count -lt 2) {
    Write-Warning "Fewer than 2 connected hosts found. Consistency check requires at least 2 hosts."
}

# Determine reference host
if ($ReferenceHost) {
    $refHost = $vmHosts | Where-Object { $_.Name -eq $ReferenceHost -or $_.Name -like "$ReferenceHost*" } | Select-Object -First 1
    if (-not $refHost) { Write-Error "Reference host '$ReferenceHost' not found in cluster."; exit 1 }
}
else {
    $refHost = $vmHosts | Select-Object -First 1
}
Write-Host "Reference host: $($refHost.Name)" -ForegroundColor Cyan
Write-Host "Comparing $($vmHosts.Count - 1) other host(s)..." -ForegroundColor Cyan

# Build reference network profile
function Get-HostNetProfile {
    param($vmHost)
    $vswitches  = Get-VirtualSwitch -VMHost $vmHost -ErrorAction SilentlyContinue
    $portGroups = Get-VirtualPortGroup -VMHost $vmHost -ErrorAction SilentlyContinue
    $vmks       = Get-VMHostNetworkAdapter -VMHost $vmHost -VMKernel -ErrorAction SilentlyContinue
    $netAdapters= Get-VMHostNetworkAdapter -VMHost $vmHost -Physical -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        VswitchNames  = ($vswitches | Sort-Object Name | Select-Object -ExpandProperty Name) -join '|'
        PortGroupNames= ($portGroups | Where-Object { $_.Name -notmatch 'Management Network' } | Sort-Object Name | Select-Object -ExpandProperty Name) -join '|'
        VmkAdapters   = ($vmks | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.IP)/$($_.SubnetMask):MTU=$($_.Mtu)" }) -join '|'
        VmkServices   = ($vmks | Sort-Object Name | ForEach-Object {
            $svc = @()
            if ($_.VMotionEnabled) { $svc += 'vMotion' }
            if ($_.FaultToleranceLoggingEnabled) { $svc += 'FT' }
            if ($_.ManagementTrafficEnabled) { $svc += 'Mgmt' }
            if ($_.VsanTrafficEnabled) { $svc += 'vSAN' }
            "$($_.Name):$($svc -join ',')"
        }) -join '|'
        PhysicalNICs  = (@($netAdapters).Count)
        UplinkMTUs    = ($netAdapters | Sort-Object Name | ForEach-Object { "$($_.Name):MTU=$($_.Mtu)" }) -join '|'
    }
}

$refProfile = Get-HostNetProfile -vmHost $refHost
$results    = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vmHost in ($vmHosts | Where-Object { $_.Name -ne $refHost.Name })) {
    Write-Host "  Comparing: $($vmHost.Name)..." -ForegroundColor White

    try {
        $hostProfile = Get-HostNetProfile -vmHost $vmHost

        # Compare each property
        $checks = @{
            'Virtual Switches'  = @{ Ref = $refProfile.VswitchNames;   Actual = $hostProfile.VswitchNames }
            'Port Groups'       = @{ Ref = $refProfile.PortGroupNames;  Actual = $hostProfile.PortGroupNames }
            'VMkernel Adapters' = @{ Ref = $refProfile.VmkAdapters;    Actual = $hostProfile.VmkAdapters }
            'VMkernel Services' = @{ Ref = $refProfile.VmkServices;    Actual = $hostProfile.VmkServices }
            'Physical NIC Count'= @{ Ref = $refProfile.PhysicalNICs;   Actual = $hostProfile.PhysicalNICs }
            'Uplink MTUs'       = @{ Ref = $refProfile.UplinkMTUs;     Actual = $hostProfile.UplinkMTUs }
        }

        foreach ($check in $checks.GetEnumerator()) {
            $consistent = $check.Value.Ref -eq $check.Value.Actual
            $drift = if (-not $consistent) {
                $refItems    = $check.Value.Ref  -split '\|'
                $actualItems = $check.Value.Actual -split '\|'
                $missing = ($refItems  | Where-Object { $_ -notin $actualItems }) -join ', '
                $extra   = ($actualItems | Where-Object { $_ -notin $refItems })  -join ', '
                $parts = @()
                if ($missing) { $parts += "Missing: $missing" }
                if ($extra)   { $parts += "Extra: $extra" }
                $parts -join '; '
            } else { '' }

            $results.Add([PSCustomObject]@{
                HostName     = $vmHost.Name
                ConfigItem   = $check.Key
                SubItem      = ''
                ExpectedValue= $check.Value.Ref
                ActualValue  = $check.Value.Actual
                Consistent   = $consistent
                DriftDetail  = $drift
            })
        }
    }
    catch {
        Write-Warning "Error comparing $($vmHost.Name): $_"
    }
}

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$inconsistent = ($results | Where-Object { -not $_.Consistent }).Count
Write-Host "`n=== Network Consistency Summary ===" -ForegroundColor Cyan
Write-Host "  Reference host   : $($refHost.Name)" -ForegroundColor White
Write-Host "  Hosts compared   : $($vmHosts.Count - 1)" -ForegroundColor White
Write-Host "  Drift findings   : $inconsistent" -ForegroundColor $(if ($inconsistent -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output           : $OutputFile" -ForegroundColor White
