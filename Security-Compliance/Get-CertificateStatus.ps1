<#
.SYNOPSIS
    Reports certificate expiration for vCenter and ESXi hosts.

.DESCRIPTION
    Collects certificate information from vCenter's VECS stores and from each
    ESXi host's management interface, reporting subject, issuer, thumbprint,
    validity dates, days remaining, and a status flag when approaching expiration.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER ClusterName
    Optional. Limit ESXi host checks to a specific cluster.

.PARAMETER WarningDays
    Optional. Days remaining threshold for Warning status. Default: 60.

.PARAMETER CriticalDays
    Optional. Days remaining threshold for Critical status. Default: 30.

.PARAMETER OutputFile
    Required. Path to export certificate status as CSV.

.EXAMPLE
    .\Get-CertificateStatus.ps1 -vCenter "vc.example.com" -OutputFile "certs.csv"
    Reports all certificate expiration details.

.EXAMPLE
    .\Get-CertificateStatus.ps1 -ClusterName "Prod" -WarningDays 90 -CriticalDays 45 -OutputFile "certs.csv"
    Uses custom warning/critical thresholds.

.OUTPUTS
    CSV with columns: EntityName, EntityType, CertType, Subject, Issuer, Thumbprint,
    NotBefore, NotAfter, DaysRemaining, Status

.NOTES
    Requires:
    - VMware PowerCLI module
    - Network access to ESXi hosts on port 443

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [int]$WarningDays = 60,

    [Parameter(Mandatory=$false)]
    [int]$CriticalDays = 30,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
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

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$today = Get-Date

function Get-CertStatus {
    param([datetime]$NotAfter, [int]$WarnDays, [int]$CritDays)
    $days = ($NotAfter - (Get-Date)).Days
    if ($days -le 0)       { return 'EXPIRED' }
    elseif ($days -le $CritDays) { return 'CRITICAL' }
    elseif ($days -le $WarnDays) { return 'WARNING' }
    else                         { return 'OK' }
}

function Add-CertResult {
    param($EntityName, $EntityType, $CertType, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    if ($null -eq $Cert) { return }
    $notAfter = $Cert.NotAfter
    $daysRemaining = ($notAfter - $today).Days
    $status = Get-CertStatus -NotAfter $notAfter -WarnDays $WarningDays -CritDays $CriticalDays
    $results.Add([PSCustomObject]@{
        EntityName     = $EntityName
        EntityType     = $EntityType
        CertType       = $CertType
        Subject        = $Cert.Subject
        Issuer         = $Cert.Issuer
        Thumbprint     = $Cert.Thumbprint
        NotBefore      = $Cert.NotBefore.ToString('yyyy-MM-dd')
        NotAfter       = $notAfter.ToString('yyyy-MM-dd')
        DaysRemaining  = $daysRemaining
        Status         = $status
    })
}

# --- vCenter certificate (via TCP/HTTPS) ---
$vcServer = (Get-VIServer | Select-Object -First 1).Name
Write-Host "Checking vCenter certificate: $vcServer..." -ForegroundColor Cyan
try {
    $tcpClient = [System.Net.Sockets.TcpClient]::new($vcServer, 443)
    $sslStream = [System.Net.Security.SslStream]::new($tcpClient.GetStream(), $false, { $true })
    $sslStream.AuthenticateAsClient($vcServer)
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
    Add-CertResult -EntityName $vcServer -EntityType 'vCenter' -CertType 'HTTPS/Machine' -Cert $cert
    $sslStream.Dispose()
    $tcpClient.Dispose()
}
catch {
    Write-Warning "Could not retrieve vCenter certificate for ${vcServer}: $_"
}

# --- ESXi host certificates ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vmHosts = Get-VMHost -Location $cluster
}
else {
    $vmHosts = Get-VMHost
}

$hostCount = 0
foreach ($vmHost in $vmHosts) {
    $hostCount++
    Write-Host "  [$hostCount/$($vmHosts.Count)] Checking: $($vmHost.Name)..." -ForegroundColor White
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new($vmHost.Name, 443)
        $sslStream = [System.Net.Security.SslStream]::new($tcpClient.GetStream(), $false, { $true })
        $sslStream.AuthenticateAsClient($vmHost.Name)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
        Add-CertResult -EntityName $vmHost.Name -EntityType 'ESXi Host' -CertType 'HTTPS/Machine' -Cert $cert
        $sslStream.Dispose()
        $tcpClient.Dispose()
    }
    catch {
        Write-Warning "  Could not retrieve certificate for $($vmHost.Name): $_"
        $results.Add([PSCustomObject]@{
            EntityName    = $vmHost.Name
            EntityType    = 'ESXi Host'
            CertType      = 'HTTPS/Machine'
            Subject       = 'ERROR'
            Issuer        = 'ERROR'
            Thumbprint    = 'N/A'
            NotBefore     = 'N/A'
            NotAfter      = 'N/A'
            DaysRemaining = -1
            Status        = 'ERROR'
        })
    }
}

Write-Host "Exporting $($results.Count) certificate records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$ok       = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$warn     = ($results | Where-Object { $_.Status -eq 'WARNING' }).Count
$critical = ($results | Where-Object { $_.Status -eq 'CRITICAL' }).Count
$expired  = ($results | Where-Object { $_.Status -eq 'EXPIRED' }).Count

Write-Host "`n=== Certificate Status Summary ===" -ForegroundColor Cyan
Write-Host "  Total checked : $($results.Count)" -ForegroundColor White
Write-Host "  OK            : $ok"       -ForegroundColor Green
Write-Host "  Warning (<${WarningDays}d) : $warn"   -ForegroundColor Yellow
Write-Host "  Critical (<${CriticalDays}d): $critical" -ForegroundColor Red
Write-Host "  Expired       : $expired"  -ForegroundColor Magenta
Write-Host "  Output        : $OutputFile" -ForegroundColor White
