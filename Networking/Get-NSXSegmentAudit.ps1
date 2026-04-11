<#
.SYNOPSIS
    Inventories NSX-T segments, transport zones, connected VMs, and DFW rules via REST API.

.DESCRIPTION
    Connects to NSX Manager using REST API to enumerate segments, transport zones,
    connected logical ports (VMs), and distributed firewall (DFW) rule sections.
    Exports findings to separate CSVs for each data domain.

.PARAMETER NSXManager
    Required. Hostname or IP of the NSX Manager node.

.PARAMETER Credential
    Required. PSCredential for NSX Manager authentication.

.PARAMETER TransportZone
    Optional. Filter segments to a specific transport zone display name.

.PARAMETER OutputFile
    Required. Base path for CSV output files.

.EXAMPLE
    $cred = Get-Credential
    .\Get-NSXSegmentAudit.ps1 -NSXManager "nsxmgr.example.com" -Credential $cred -OutputFile "nsx-audit.csv"
    Inventories all NSX-T segments and DFW rules.

.EXAMPLE
    $cred = Get-Credential
    .\Get-NSXSegmentAudit.ps1 -NSXManager "nsxmgr.example.com" -Credential $cred -TransportZone "Overlay-TZ" -OutputFile "overlay.csv"
    Reports only segments in the Overlay transport zone.

.OUTPUTS
    - OutputFile              : Segment inventory
    - <base>-transportzones.csv : Transport zone summary
    - <base>-dfw.csv          : DFW rule summary
    - <base>-vms.csv          : Connected VM list

.NOTES
    Requires:
    - Network access to NSX Manager on port 443
    - NSX Manager API credentials (read-only auditor role is sufficient)
    - PowerShell 5.1 or later

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$NSXManager,

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$TransportZone,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
)

# Disable certificate validation for self-signed NSX certs (lab/dev environments)
# In production, remove this block and use trusted certificates
Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint svcPoint, X509Certificate cert, WebRequest req, int certProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCerts]::new()
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

$baseUrl = "https://$NSXManager/api/v1"
$encodedCred = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
$headers = @{
    Authorization  = "Basic $encodedCred"
    'Content-Type' = 'application/json'
    Accept         = 'application/json'
}

function Invoke-NSXRequest {
    param([string]$Uri)
    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET -ErrorAction Stop
        return $response
    }
    catch {
        Write-Warning "NSX API request failed for $Uri : $_"
        return $null
    }
}

$basePath  = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$ext       = [System.IO.Path]::GetExtension($OutputFile)
$dir       = [System.IO.Path]::GetDirectoryName($OutputFile)
if (-not $dir) { $dir = '.' }
$tzFile    = Join-Path $dir ($basePath + '-transportzones' + $ext)
$dfwFile   = Join-Path $dir ($basePath + '-dfw' + $ext)
$vmFile    = Join-Path $dir ($basePath + '-vms' + $ext)

Write-Host "Connecting to NSX Manager: $NSXManager..." -ForegroundColor Cyan

# Transport Zones
Write-Host "  Collecting transport zones..." -ForegroundColor White
$tzResponse = Invoke-NSXRequest -Uri "$baseUrl/transport-zones?page_size=500"
$tzList     = if ($tzResponse) { $tzResponse.results } else { @() }

$tzResults = foreach ($tz in $tzList) {
    [PSCustomObject]@{
        DisplayName    = $tz.display_name
        Type           = $tz.transport_type
        HostSwitchName = $tz.host_switch_name
        Id             = $tz.id
        SegmentCount   = 0  # Will update below
    }
}
$tzResults | Export-Csv -Path $tzFile -NoTypeInformation

# Segments (logical switches)
Write-Host "  Collecting segments..." -ForegroundColor White
$segResponse = Invoke-NSXRequest -Uri "$baseUrl/logical-switches?page_size=1000"
$segments    = if ($segResponse) { $segResponse.results } else { @() }

if ($TransportZone) {
    $tzFilter = $tzList | Where-Object { $_.display_name -eq $TransportZone }
    if ($tzFilter) {
        $segments = $segments | Where-Object { $_.transport_zone_id -eq $tzFilter.id }
    }
}

$segResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmResults  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($seg in $segments) {
    $tzName = ($tzList | Where-Object { $_.id -eq $seg.transport_zone_id } | Select-Object -First 1).display_name
    $vni    = $seg.vni

    # Get logical ports for this segment
    $lportsResp = Invoke-NSXRequest -Uri "$baseUrl/logical-ports?logical_switch_id=$($seg.id)&page_size=500"
    $lports     = if ($lportsResp) { $lportsResp.results } else { @() }

    $segResults.Add([PSCustomObject]@{
        SegmentName    = $seg.display_name
        TransportZone  = $tzName
        VNI            = $vni
        AdminState     = $seg.admin_state
        ReplicationMode= $seg.replication_mode
        ConnectedPorts = @($lports).Count
        Id             = $seg.id
    })

    foreach ($port in $lports) {
        $vmResults.Add([PSCustomObject]@{
            SegmentName  = $seg.display_name
            PortName     = $port.display_name
            AdminState   = $port.admin_state
            Attachment   = if ($port.attachment) { $port.attachment.attachment_type } else { 'None' }
            AttachmentId = if ($port.attachment) { $port.attachment.id } else { 'N/A' }
        })
    }
}

$segResults | Export-Csv -Path $OutputFile -NoTypeInformation
$vmResults  | Export-Csv -Path $vmFile      -NoTypeInformation

# DFW rules
Write-Host "  Collecting distributed firewall rules..." -ForegroundColor White
$dfwResp    = Invoke-NSXRequest -Uri "$baseUrl/firewall/sections?page_size=500"
$dfwSections= if ($dfwResp) { $dfwResp.results } else { @() }
$dfwResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($section in $dfwSections) {
    $rulesResp = Invoke-NSXRequest -Uri "$baseUrl/firewall/sections/$($section.id)/rules?page_size=1000"
    $rules     = if ($rulesResp) { $rulesResp.results } else { @() }
    foreach ($rule in $rules) {
        $dfwResults.Add([PSCustomObject]@{
            SectionName = $section.display_name
            SectionType = $section.section_type
            RuleName    = $rule.display_name
            Action      = $rule.action
            Direction   = $rule.direction
            Protocol    = $rule.ip_protocol
            Disabled    = $rule.disabled
            RuleId      = $rule.id
        })
    }
}
$dfwResults | Export-Csv -Path $dfwFile -NoTypeInformation

Write-Host "`n=== NSX Segment Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Transport Zones : $($tzList.Count)" -ForegroundColor White
Write-Host "  Segments        : $($segResults.Count)" -ForegroundColor White
Write-Host "  Logical Ports   : $($vmResults.Count)" -ForegroundColor White
Write-Host "  DFW Rules       : $($dfwResults.Count)" -ForegroundColor White
Write-Host "  Segments output : $OutputFile" -ForegroundColor White
Write-Host "  Transport Zones : $tzFile" -ForegroundColor White
Write-Host "  DFW output      : $dfwFile" -ForegroundColor White
Write-Host "  VM ports output : $vmFile" -ForegroundColor White
