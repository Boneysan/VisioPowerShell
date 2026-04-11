<#
.SYNOPSIS
    Reports VM hardware versions and upgrade recommendations across the environment.

.DESCRIPTION
    Inventories the virtual hardware version (VMX version) for all VMs in the
    target cluster. Compares each VM's hardware version against the maximum
    supported by its current ESXi host. Flags VMs eligible for upgrade and
    reports potential compatibility constraints (e.g., running VMs require
    scheduled upgrade via VMware Tools).

.PARAMETER ClusterName
    Optional. Cluster to scope the report. If omitted, all clusters are scanned.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the hardware version report as CSV.

.PARAMETER MinVersion
    Optional. Flag VMs below this hardware version. Default: 15 (vSphere 7.0).

.EXAMPLE
    .\Get-VMHardwareVersionReport.ps1 -ClusterName "Production" -OutputFile "hw-versions.csv"
    Exports hardware version report for Production cluster.

.EXAMPLE
    .\Get-VMHardwareVersionReport.ps1 -MinVersion 19 -OutputFile "hw-versions-all.csv"
    Reports all VMs below hardware version 19 (vSphere 8.0).

.OUTPUTS
    CSV with columns: VMName, ClusterName, HostName, CurrentVersion,
    MaxSupportedVersion, UpgradeRecommended, PowerState, UpgradeNote

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM configuration

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
    [int]$MinVersion = 15
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

Write-Host "Analyzing hardware versions for $($vms.Count) VMs..." -ForegroundColor Cyan

# Build host -> max HW version map from ESXi version
$hostHWVersionMap = @{}
Get-VMHost | ForEach-Object {
    $ver = $_.Version
    $hwMax = switch -Wildcard ($ver) {
        '8.*'   { 21 }
        '7.*'   { 19 }
        '6.7*'  { 15 }
        '6.5*'  { 14 }
        '6.0*'  { 11 }
        default { 11 }
    }
    $hostHWVersionMap[$_.Name] = $hwMax
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vm in ($vms | Sort-Object Name)) {
    $vmView = $vm | Get-View -Property Config, Summary, Runtime -ErrorAction SilentlyContinue
    if (-not $vmView) { continue }

    # Hardware version format: "vmx-XX"
    $hwVersionString = $vmView.Config.Version
    $currentVersion  = if ($hwVersionString -match 'vmx-(\d+)') { [int]$Matches[1] } else { 0 }

    $hostName    = $vm.VMHost.Name
    $maxSupported = if ($hostHWVersionMap.ContainsKey($hostName)) { $hostHWVersionMap[$hostName] } else { 0 }

    $upgradeRecommended = ($currentVersion -lt [math]::Min($maxSupported, $MinVersion))

    $upgradeNote = ''
    if ($upgradeRecommended) {
        if ($vm.PowerState -eq 'PoweredOn') {
            $upgradeNote = 'Requires VM to be shut down or schedule upgrade at next power cycle'
        }
        else {
            $upgradeNote = 'VM is powered off — can upgrade now'
        }
    }

    $clusterObj   = $vm.VMHost | Get-Cluster -ErrorAction SilentlyContinue
    $clusterLabel = if ($clusterObj) { $clusterObj.Name } else { 'Standalone' }

    $results.Add([PSCustomObject]@{
        VMName               = $vm.Name
        ClusterName          = $clusterLabel
        HostName             = $hostName
        CurrentHWVersion     = $hwVersionString
        CurrentVersionNumber = $currentVersion
        MaxSupportedVersion  = $maxSupported
        TargetMinVersion     = $MinVersion
        UpgradeRecommended   = $upgradeRecommended
        PowerState           = $vm.PowerState.ToString()
        ToolsStatus          = $vmView.Summary.Guest.ToolsStatus
        UpgradeNote          = $upgradeNote
    })
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$upgradeCount = ($results | Where-Object { $_.UpgradeRecommended -eq $true }).Count
$currentCount = ($results | Where-Object { $_.UpgradeRecommended -eq $false }).Count

Write-Host "`n=== VM Hardware Version Summary ===" -ForegroundColor Cyan
Write-Host "  Total VMs           : $($results.Count)"  -ForegroundColor White
Write-Host "  Upgrade Recommended : $upgradeCount"       -ForegroundColor $(if ($upgradeCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Current / OK        : $currentCount"       -ForegroundColor Green
Write-Host "  Target Min Version  : vmx-$MinVersion"    -ForegroundColor White
Write-Host "  Output              : $OutputFile"         -ForegroundColor White
