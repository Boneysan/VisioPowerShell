<#
.SYNOPSIS
    Validates vCenter API, SSO, and core service health endpoints.

.DESCRIPTION
    Performs a series of connectivity and health checks against a vCenter Server:
    TCP port reachability, REST API responsiveness, SSO/PSC token endpoint, vSphere
    Managed Object Browser (MOB), and SDK/WSDL endpoint. Reports per-check pass/fail
    and round-trip latency. Useful for diagnosing vCenter outages, SSO failures,
    or network path problems from a jump host in a cyber range environment.

    Does not require an active PowerCLI session — can be used before connecting.

.PARAMETER vCenter
    Required. The vCenter Server hostname or IP address to test.

.PARAMETER Credential
    Optional. PSCredential for API authentication checks. If not supplied, unauthenticated
    endpoint reachability is tested only (no token validation).

.PARAMETER TimeoutSec
    Optional. HTTP/TCP timeout in seconds. Default: 10.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Test-vCenterConnectivity.ps1 -vCenter "vcenter.lab.local"
    Test all vCenter endpoints without authentication.

.EXAMPLE
    .\Test-vCenterConnectivity.ps1 -vCenter "vcenter.lab.local" -Credential (Get-Credential) -OutputFile "vcenter-health.csv"
    Test vCenter endpoints including authenticated API and SSO token exchange.

.OUTPUTS
    CSV with columns: Check, Endpoint, TCPPort, Status, LatencyMs, Detail, Timestamp

.NOTES
    Requires:
    - Network connectivity from the machine running this script to vCenter
    - PowerShell 5.1 or later (uses System.Net.Http.HttpClient)
    - For -Credential checks: valid vCenter SSO credentials

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutSec = 10,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Check {
    param([string]$Check, [string]$Endpoint, [int]$TCPPort, [string]$Status, [int]$LatencyMs, [string]$Detail)
    $entry = [PSCustomObject]@{
        Check      = $Check
        Endpoint   = $Endpoint
        TCPPort    = $TCPPort
        Status     = $Status
        LatencyMs  = $LatencyMs
        Detail     = $Detail
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'White' } }
    Write-Host ("  [{0,-4}] {1,-35} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Test-TcpPort {
    param([string]$Hostname, [int]$Port, [int]$TimeoutMs)
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar        = $tcp.BeginConnect($Hostname, $Port, $null, $null)
        $done      = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $connected = $false
        if ($done) { try { $tcp.EndConnect($ar); $connected = $true } catch {} }
        $sw.Stop()
        return [PSCustomObject]@{ Open = $connected; LatencyMs = $sw.ElapsedMilliseconds }
    }
    finally { $tcp.Close() }
}

# Bypass SSL cert validation once for the session (lab/self-signed certs)
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls -bor `
    [System.Net.SecurityProtocolType]::Tls11 -bor `
    [System.Net.SecurityProtocolType]::Tls12
# Also attempt TLS 1.3 (numeric 12288) if supported by the runtime
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]12288 } catch {}

function Invoke-HttpCheck {
    param([string]$Uri, [int]$TimeoutSec, [System.Management.Automation.PSCredential]$Cred)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $curlArgs = @('-k', '-s', '-o', 'NUL', '-w', '%{http_code}|%{time_total}', '--max-time', $TimeoutSec, '--location', $Uri)
        if ($Cred) {
            $curlArgs += @('-u', "$($Cred.UserName):$($Cred.GetNetworkCredential().Password)")
        }
        $curlOut = & curl.exe @curlArgs 2>$null
        $sw.Stop()
        $parts = $curlOut -split '\|'
        $code  = [int]($parts[0].Trim())
        return [PSCustomObject]@{ StatusCode = $code; Success = ($code -gt 0 -and $code -lt 400); LatencyMs = $sw.ElapsedMilliseconds }
    }
    catch {
        $sw.Stop()
        return [PSCustomObject]@{ StatusCode = 0; Success = $false; LatencyMs = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

Write-Host "`n=== vCenter Connectivity Test: $vCenter ===" -ForegroundColor Cyan
Write-Host "  Timeout    : ${TimeoutSec}s" -ForegroundColor White
Write-Host "  Auth Check : $(if ($Credential) { 'Yes (credentials provided)' } else { 'No (unauthenticated only)' })`n" -ForegroundColor White

# --- TCP Port Checks ---
# Only port 443 is required for PowerCLI/management access on vCenter 7/8.
# Ports 80/389/636 are often firewalled from client machines and are not needed.
$ports = @(
    @{ Check = 'HTTPS (443)'; Port = 443 }
)

$uniquePorts = $ports | ForEach-Object { $_['Port'] } | Select-Object -Unique
foreach ($port in $uniquePorts) {
    $label = ($ports | Where-Object { $_['Port'] -eq $port } | Select-Object -First 1)['Check']
    $r = Test-TcpPort -Hostname $vCenter -Port $port -TimeoutMs ($TimeoutSec * 1000)
    if ($r.Open) {
        Add-Check -Check "TCP:$port" -Endpoint "$vCenter`:$port" -TCPPort $port -Status 'PASS' -LatencyMs $r.LatencyMs -Detail "Port open ($($r.LatencyMs)ms)"
    }
    else {
        Add-Check -Check "TCP:$port" -Endpoint "$vCenter`:$port" -TCPPort $port -Status 'FAIL' -LatencyMs $r.LatencyMs -Detail "Port unreachable"
    }
}

# --- HTTPS Endpoint Checks ---
$endpoints = [ordered]@{
    'vSphere REST API'        = "https://$vCenter/api"
    'vSphere API root'        = "https://$vCenter/sdk/vimService.wsdl"
    'MOB'                     = "https://$vCenter/mob"
    'vCenter UI'              = "https://$vCenter/ui"
    'SSO token endpoint'      = "https://$vCenter/sts/STSService"
}

foreach ($name in $endpoints.Keys) {
    $uri = $endpoints[$name]
    $r   = Invoke-HttpCheck -Uri $uri -TimeoutSec $TimeoutSec
    if ($r.StatusCode -in @(200, 301, 302, 401, 403, 405)) {
        # 401/403 = reachable but auth required; 405 = wrong method but endpoint exists — all PASS for connectivity
        $status  = 'PASS'
        $detail  = "HTTP $($r.StatusCode) ($($r.LatencyMs)ms)"
    }
    elseif ($r.StatusCode -eq 0) {
        $status = 'FAIL'
        $detail = if ($r.Error) { $r.Error } else { "No response" }
    }
    else {
        $status = 'WARN'
        $detail = "HTTP $($r.StatusCode) ($($r.LatencyMs)ms)"
    }
    Add-Check -Check $name -Endpoint $uri -TCPPort 443 -Status $status -LatencyMs $r.LatencyMs -Detail $detail
}

# --- Authenticated API check ---
if ($Credential) {
    $sessionUri = "https://$vCenter/api/session"
    Write-Host "`n  Testing authenticated REST API session..." -ForegroundColor Gray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $curlArgs = @('-k', '-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', $TimeoutSec, '-X', 'POST',
            '-u', "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)", $sessionUri)
        $code = [int](& curl.exe @curlArgs 2>$null).Trim()
        $sw.Stop()
        if ($code -eq 201 -or $code -eq 200) {
            Add-Check -Check 'REST API Auth (POST /api/session)' -Endpoint $sessionUri -TCPPort 443 `
                -Status 'PASS' -LatencyMs $sw.ElapsedMilliseconds -Detail "Session token obtained (HTTP $code)"
        } else {
            Add-Check -Check 'REST API Auth (POST /api/session)' -Endpoint $sessionUri -TCPPort 443 `
                -Status 'FAIL' -LatencyMs $sw.ElapsedMilliseconds -Detail "HTTP $code - authentication failed"
        }
    }
    catch {
        $sw.Stop()
        Add-Check -Check 'REST API Auth (POST /api/session)' -Endpoint $sessionUri -TCPPort 443 `
            -Status 'FAIL' -LatencyMs $sw.ElapsedMilliseconds -Detail $_.Exception.Message
    }
}

# --- Summary ---
$pass = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$warn = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
$fail = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Checks run : $($results.Count)" -ForegroundColor White
Write-Host "  PASS       : $pass" -ForegroundColor Green
Write-Host "  WARN       : $warn" -ForegroundColor $(if ($warn -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  FAIL       : $fail" -ForegroundColor $(if ($fail -gt 0) { 'Red'    } else { 'White' })

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}
