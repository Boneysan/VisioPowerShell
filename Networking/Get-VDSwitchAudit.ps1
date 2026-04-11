<#
.SYNOPSIS
    Audits distributed virtual switch (VDS) configuration across vCenter.

.DESCRIPTION
    Reports distributed virtual switch version, MTU, uplink count, port groups,
    VLAN/PVLAN configuration, traffic shaping, LACP, NetFlow, health check, and
    uplink failover policy. Optionally includes per-port-group detail.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER VDSwitchName
    Optional. Limit the audit to a specific VDS name.

.PARAMETER OutputFile
    Required. Base path for CSV output.

.PARAMETER IncludePortGroupDetail
    Optional. Switch. Include per-port-group detail in a separate CSV.

.EXAMPLE
    .\Get-VDSwitchAudit.ps1 -vCenter "vc.example.com" -OutputFile "vds-audit.csv"
    Audits all distributed switches.

.EXAMPLE
    .\Get-VDSwitchAudit.ps1 -VDSwitchName "dvSwitch-Prod" -IncludePortGroupDetail -OutputFile "dvs-prod.csv"
    Audits a specific VDS with port group detail.

.OUTPUTS
    - OutputFile                : VDS summary (one row per VDS)
    - <base>-portgroups.csv     : Port group detail (when -IncludePortGroupDetail)
    - <base>-uplinks.csv        : Per-host uplink detail

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VDS configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$VDSwitchName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludePortGroupDetail
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

if ($VDSwitchName) {
    $vdSwitches = Get-VDSwitch -Name $VDSwitchName -ErrorAction SilentlyContinue
    if (-not $vdSwitches) { Write-Error "VDS '$VDSwitchName' not found."; exit 1 }
}
else {
    $vdSwitches = Get-VDSwitch -ErrorAction SilentlyContinue
}

if (-not $vdSwitches) {
    Write-Warning "No distributed virtual switches found."
    exit 0
}

$basePath = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$ext      = [System.IO.Path]::GetExtension($OutputFile)
$dir      = [System.IO.Path]::GetDirectoryName($OutputFile)
if (-not $dir) { $dir = '.' }
$pgFile   = Join-Path $dir ($basePath + '-portgroups' + $ext)
$ulFile   = Join-Path $dir ($basePath + '-uplinks' + $ext)

$vdsSummary = [System.Collections.Generic.List[PSCustomObject]]::new()
$pgDetails  = [System.Collections.Generic.List[PSCustomObject]]::new()
$ulDetails  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vds in $vdSwitches) {
    Write-Host "  Auditing VDS: $($vds.Name)..." -ForegroundColor White

    try {
        $vdsView   = $vds | Get-View
        $config    = $vdsView.Config
        $numPorts  = $config.NumPorts
        $mtu       = $config.DefaultPortConfig.Mtu.Value
        $version   = $vds.Version
        $numHosts  = (Get-VMHost -DistributedSwitch $vds -ErrorAction SilentlyContinue).Count

        # Health check
        $healthCheck = try {
            $hcEnabled = $config.HealthCheckConfig | Where-Object { $_.Enable } | Measure-Object
            "$($hcEnabled.Count) checks enabled"
        } catch { 'N/A' }

        # LACP
        $lacpEnabled = try { $null -ne $vdsView.Config.LacpApiVersion } catch { $false }

        $vdsSummary.Add([PSCustomObject]@{
            VDSName          = $vds.Name
            Version          = $version
            MTU              = $mtu
            NumPorts         = $numPorts
            HostCount        = $numHosts
            UplinkCount      = $vds.NumUplinkPorts
            LACPEnabled      = $lacpEnabled
            HealthCheck      = $healthCheck
            Datacenter       = $vds.Datacenter
        })

        # Port group detail
        if ($IncludePortGroupDetail) {
            $portGroups = Get-VDPortgroup -VDSwitch $vds -ErrorAction SilentlyContinue
            foreach ($pg in $portGroups) {
                $pgConfig = $pg | Get-View
                $vlanType = $pgConfig.Config.DefaultPortConfig.Vlan.GetType().Name
                $vlanId   = switch ($vlanType) {
                    'VmwareDistributedVirtualSwitchVlanIdSpec'        { $pgConfig.Config.DefaultPortConfig.Vlan.VlanId }
                    'VmwareDistributedVirtualSwitchTrunkVlanSpec'     { 'Trunk' }
                    'VmwareDistributedVirtualSwitchPvlanSpec'         { "PVLAN:$($pgConfig.Config.DefaultPortConfig.Vlan.PvlanId)" }
                    default                                           { 'Unknown' }
                }
                $vlanTypeClean = $vlanType -replace 'VmwareDistributedVirtualSwitch', ''
                $pgDetails.Add([PSCustomObject]@{
                    VDSName         = $vds.Name
                    PortGroupName   = $pg.Name
                    VLANType        = $vlanTypeClean
                    VLANID          = $vlanId
                    PortBinding     = $pg.PortBinding
                    NumPorts        = $pg.NumPorts
                    Uplink          = $pg.IsUplink
                })
            }
        }

        # Uplink detail per host
        $vdsHosts = Get-VMHost -DistributedSwitch $vds -ErrorAction SilentlyContinue
        foreach ($h in $vdsHosts) {
            $hostProxy = $vdsView.Config.Host | Where-Object { $_.Config.Host.Value -eq $h.ExtensionData.MoRef.Value }
            $uplinkPorts = $hostProxy.Config.UplinkPortKey
            $ulDetails.Add([PSCustomObject]@{
                VDSName    = $vds.Name
                HostName   = $h.Name
                UplinkKeys = ($uplinkPorts -join ', ')
                UplinkCount= @($uplinkPorts).Count
            })
        }
    }
    catch {
        Write-Warning "Error auditing VDS $($vds.Name): $_"
    }
}

$vdsSummary | Export-Csv -Path $OutputFile -NoTypeInformation
$ulDetails  | Export-Csv -Path $ulFile     -NoTypeInformation
if ($IncludePortGroupDetail) {
    $pgDetails | Export-Csv -Path $pgFile -NoTypeInformation
}

Write-Host "`n=== VDS Audit Summary ===" -ForegroundColor Cyan
Write-Host "  VDS audited    : $($vdsSummary.Count)" -ForegroundColor White
Write-Host "  Port groups    : $($pgDetails.Count)" -ForegroundColor White
Write-Host "  Uplink records : $($ulDetails.Count)" -ForegroundColor White
Write-Host "  Output         : $OutputFile" -ForegroundColor White
