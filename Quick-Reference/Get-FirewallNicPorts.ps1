#Requires -Version 5.1
<#
.SYNOPSIS
    Exports NIC index, VDS port key, port group and VLAN for every range firewall.

.DESCRIPTION
    Self-contained: needs only VMware.VimAutomation.Core and a vCenter connection,
    so it is one file to carry across an airgap.

    This is the evidence that closes FW-4. pfSense inside the guest sees vmx0..vmxN
    and the Terraform declares hw_nic order separately; on all 7 devices whose
    configs we hold, the two disagree. vCenter is the only authority on which is
    right, and this is the read that settles it.

    For every VM matching -NamePattern it emits one row per virtual NIC:

      VM           the vSphere VM name
      NicIndex     ordinal from the adapter label - "Network adapter 3" -> 3.
                   Use with PCI controller and unit values to verify ordering.
      NIC          the adapter label as vCenter shows it
      ControllerKey PCI controller device key for the NIC's PCI location
      UnitNumber   PCI unit number within ControllerKey
      PortKey      the VDS port this NIC occupies
      Network      resolved port group name
      VlanId       VLAN carried by that port group
      MAC          adapter MAC address
      Connected    is the NIC connected, and does it connect at power-on
      PowerState   the VM's power state

    Read-only. Works on powered-off VMs - it reads configuration, not guest state,
    so a firewall that is shut down still reports its NIC order.

.PARAMETER NamePattern
    Regex matched against VM name in vCenter. Default '^FWALL-' catches every
    range firewall. Use '.' to dump every VM in the inventory.

.PARAMETER VMName
    Explicit VM names instead of a pattern. Use this to prove a firewall that
    *should* exist is absent - a name that matches nothing is reported as MISSING
    rather than silently skipped.

.PARAMETER VIServer
    vCenter to connect to. An existing connection is reused only when it matches
    this server.

.PARAMETER RequireAll
    With -VMName, fail after export if any requested VM name is not found.

.PARAMETER OutputFile
    CSV path. Defaults to firewall-nic-order.csv beside this script.

.PARAMETER PassThru
    Also emit the rows to the pipeline.

.EXAMPLE
    .\Get-FirewallNicPorts.ps1
    Every FWALL-* VM, written to .\firewall-nic-order.csv

.EXAMPLE
    .\Get-FirewallNicPorts.ps1 -OutputFile F:\IQT\Repo\Ranges\_inventory\live\2026-08-14\firewall-nic-order.csv

.EXAMPLE
    .\Get-FirewallNicPorts.ps1 -VMName FWALL-CL2-IQT-Alpha,FWALL-CL5-IQT-Alpha
    Only those two, and says so plainly if one does not exist.

.EXAMPLE
    .\Get-FirewallNicPorts.ps1 -VMName FWALL-CL2-IQT-Alpha -RequireAll
    Fails the verification run if the named firewall is absent.

.EXAMPLE
    .\Get-FirewallNicPorts.ps1 -PassThru | Where-Object { $_.Network -eq 'MISSING' }
    Firewalls with a NIC whose port group could not be resolved.

.OUTPUTS
    CSV (default firewall-nic-order.csv) and optional pipeline objects with:
    VM, NicIndex, NIC, ControllerKey, UnitNumber, PortKey, Network, VlanId,
    MAC, Connected, PowerState.

.NOTES
    Read-only. Requires read access to VM configuration.

    How to use:
      Get-Help .\Get-FirewallNicPorts.ps1 -Full
      Get-Help .\Get-FirewallNicPorts.ps1 -Examples

    Author:  Mike Zomer
    Version: 1.0
    Date:    August 18, 2026
#>
[CmdletBinding(DefaultParameterSetName = 'Pattern')]
param(
    [Parameter(ParameterSetName = 'Pattern')]
    [string]$NamePattern = '^FWALL-',

    [Parameter(ParameterSetName = 'Explicit', Mandatory)]
    [string[]]$VMName,

    [string]$VIServer = 'c1r1r12-vcsa-01.texnet1.net',
    [string]$OutputFile = (Join-Path $PSScriptRoot 'firewall-nic-order.csv'),
    [switch]$RequireAll,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Say($msg, $kind = 'INFO') {
    $color = switch ($kind) { 'OK' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} default {'Cyan'} }
    Write-Host ("[{0}] {1}" -f $kind.PadRight(4), $msg) -ForegroundColor $color
}

# ------------------------------------------------------------------ connect
if (-not (Get-Module -ListAvailable VMware.VimAutomation.Core)) {
    throw "PowerCLI (VMware.VimAutomation.Core) is not installed on this machine."
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop

function Test-VIServerMatch($connection, [string]$server) {
    if (-not $connection -or -not $connection.IsConnected) { return $false }
    return $connection.Name -eq $server -or $connection.ServiceUri.Host -eq $server
}

$activeConnection = @($global:DefaultVIServers | Where-Object {
    Test-VIServerMatch $_ $VIServer
} | Select-Object -First 1)

if (-not $activeConnection) {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
        -Scope Session -Confirm:$false | Out-Null
    $cred = Get-Credential -Message "vCenter credentials for $VIServer (read-only is enough)"
    $activeConnection = @(Connect-VIServer $VIServer -Credential $cred -ErrorAction Stop)
}
Say "Connected to $($activeConnection[0].Name)" 'OK'

# ------------------------------------------------- port group lookup, once
# One round trip for every port group, rather than a Get-VDPortgroup call per
# NIC. Across 13 firewalls that is ~100 calls collapsed into 2.
Say "Caching port groups..."
$pgByKey = @{}

function Get-VlanLabel($vlanSpec) {
    if (-not $vlanSpec) { return '' }
    $t = $vlanSpec.GetType().Name
    if ($t -like '*TrunkVlanSpec*') {
        return (($vlanSpec.VlanId | ForEach-Object {
            if ($_.Start -eq $_.End) { "$($_.Start)" } else { "$($_.Start)-$($_.End)" }
        }) -join ',')
    }
    if ($t -like '*PvlanSpec*') { return "pvlan $($vlanSpec.PvlanId)" }
    if ($null -ne $vlanSpec.VlanId) { return "$($vlanSpec.VlanId)" }
    return ''
}

foreach ($pg in (Get-View -ViewType DistributedVirtualPortgroup `
                          -Property Name, Key, Config.DefaultPortConfig)) {
    $pgByKey[$pg.Key] = [pscustomobject]@{
        Name = $pg.Name
        Vlan = Get-VlanLabel $pg.Config.DefaultPortConfig.Vlan
    }
}
Say "  $($pgByKey.Count) distributed port groups cached"

# ------------------------------------------------------------- select VMs
$props = @('Name', 'Config.Hardware.Device', 'Runtime.PowerState')
if ($PSCmdlet.ParameterSetName -eq 'Explicit') {
    # Anchored alternation, so vCenter filters server-side rather than dragging
    # all 1,400-odd VM views back to sort through here.
    $rx = '^(' + (($VMName | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $views = @(Get-View -ViewType VirtualMachine -Property $props -Filter @{ 'Name' = $rx })
    $found = @($views | ForEach-Object { $_.Name })
    $missingVMs = @()
    foreach ($want in $VMName) {
        if ($found -notcontains $want) {
            $missingVMs += $want
            Say "VM not found in vCenter: $want" 'WARN'
        }
    }
} else {
    $views = @(Get-View -ViewType VirtualMachine -Property $props -Filter @{ 'Name' = $NamePattern })
}

$views = @($views | Sort-Object Name)
if (-not $views.Count) { throw "No VMs matched. Pattern was '$NamePattern'." }
Say "$($views.Count) VM(s) matched" 'OK'

# ------------------------------------------------------------ walk the NICs
$rows = foreach ($v in $views) {
    $nics = @($v.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] })
    if (-not $nics.Count) { Say "  $($v.Name): no virtual NICs" 'WARN'; continue }

    foreach ($n in $nics) {
        $label = $n.DeviceInfo.Label                      # "Network adapter 3"
        $idx   = if ($label -match '(\d+)\s*$') { [int]$Matches[1] } else { $null }

        $portKey = ''; $net = 'MISSING'; $vlan = ''
        $dvs = $n.Backing -as [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]
        $std = $n.Backing -as [VMware.Vim.VirtualEthernetCardNetworkBackingInfo]
        $opq = $n.Backing -as [VMware.Vim.VirtualEthernetCardOpaqueNetworkBackingInfo]

        if ($dvs) {
            $portKey = $dvs.Port.PortKey
            $hit = $pgByKey[$dvs.Port.PortgroupKey]
            if ($hit) { $net = $hit.Name; $vlan = $hit.Vlan }
            else      { $net = "UNRESOLVED:$($dvs.Port.PortgroupKey)" }
        }
        elseif ($std) { $portKey = 'standard-switch'; $net = $std.DeviceName }
        elseif ($opq) { $portKey = 'opaque';          $net = $opq.OpaqueNetworkId }

        [pscustomobject]@{
            VM         = $v.Name
            NicIndex   = $idx
            NIC        = $label
            ControllerKey = $n.ControllerKey
            UnitNumber = $n.UnitNumber
            PortKey    = $portKey
            Network    = $net
            VlanId     = $vlan
            MAC        = $n.MacAddress
            AdapterType= $n.GetType().Name -replace '^Virtual', ''
            Connected  = $n.Connectable.Connected
            StartConn  = $n.Connectable.StartConnected
            PowerState = $v.Runtime.PowerState
        }
    }
}

$rows = @($rows | Sort-Object VM, NicIndex)

# ----------------------------------------------------------------- output
$dir = Split-Path -Parent $OutputFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$rows | Export-Csv $OutputFile -NoTypeInformation -Encoding utf8

Write-Host ""
$rows | Format-Table VM, NicIndex, ControllerKey, UnitNumber, PortKey, Network, VlanId, MAC, PowerState -AutoSize

Write-Host ""
Say "$($rows.Count) NIC rows from $($views.Count) VM(s) -> $OutputFile" 'OK'

$unresolved = @($rows | Where-Object { $_.Network -eq 'MISSING' -or $_.Network -like 'UNRESOLVED:*' })
if ($unresolved.Count) {
    Say "$($unresolved.Count) NIC(s) have no resolvable port group - check these by hand" 'WARN'
    $unresolved | ForEach-Object { Write-Host ("    {0}  {1}" -f $_.VM, $_.NIC) }
}

if ($RequireAll -and $missingVMs.Count) {
    throw "Required VM(s) were not found: $($missingVMs -join ', ')"
}

if ($PassThru) { $rows }
