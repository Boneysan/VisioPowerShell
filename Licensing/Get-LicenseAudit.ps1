<#
.SYNOPSIS
    Audits vSphere license keys, editions, usage, and compliance.

.DESCRIPTION
    Enumerates all license keys assigned to the vCenter inventory. Reports the
    license edition, total capacity, used licenses, expiration date, and whether
    the environment is over-licensed or under-licensed. Highlights expired or
    soon-to-expire licenses.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the license audit report as CSV.

.PARAMETER ExpiryWarningDays
    Optional. Warn if a license expires within this many days. Default: 90.

.EXAMPLE
    .\Get-LicenseAudit.ps1 -OutputFile "license-audit.csv"
    Exports a full license audit for the connected vCenter.

.EXAMPLE
    .\Get-LicenseAudit.ps1 -vCenter "vcenter.lab.local" -ExpiryWarningDays 180 -OutputFile "licenses.csv"
    Connects to a specific vCenter and warns on 180-day expiry window.

.OUTPUTS
    CSV with columns: Edition, LicenseKey, Total, Used, Remaining, ExpirationDate,
    DaysUntilExpiry, Status, AssignedTo

.NOTES
    Requires:
    - VMware PowerCLI module
    - vCenter administrator or license management privileges

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [int]$ExpiryWarningDays = 90
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

Write-Host "Querying license information from vCenter..." -ForegroundColor Cyan

$si         = Get-View ServiceInstance
$licManager = Get-View $si.Content.LicenseManager

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($license in $licManager.Licenses) {
    $edition  = $license.Name
    $key      = $license.LicenseKey
    $total    = $license.Total
    $used     = $license.Used
    $remaining = $total - $used

    # Expiration
    $expiryDate  = 'Never'
    $daysUntil   = [int]::MaxValue
    $expiryProp  = $license.Properties | Where-Object { $_.Key -eq 'expirationDate' }
    if ($expiryProp -and $expiryProp.Value) {
        try {
            $expDate    = [datetime]$expiryProp.Value
            $expiryDate = $expDate.ToString('yyyy-MM-dd')
            $daysUntil  = ([datetime]$expDate - (Get-Date)).Days
        }
        catch { }
    }

    $status = 'OK'
    if ($daysUntil -le 0)                     { $status = 'EXPIRED'  }
    elseif ($daysUntil -le $ExpiryWarningDays) { $status = 'EXPIRING' }
    elseif ($used -gt $total)                  { $status = 'OVER-UTILIZED - COMPLIANCE RISK' }
    elseif ($remaining -gt $total * 0.5)       { $status = 'OVER-PURCHASED' }

    # Try to get assigned entity
    $assignInfo = $licManager.LicenseAssignmentManager | ForEach-Object {
        try {
            $lam = Get-View $_
            $assignments = $lam.QueryAssignedLicenses($null)
            $assignments | Where-Object { $_.AssignedLicense.LicenseKey -eq $key } | ForEach-Object { $_.EntityId }
        }
        catch { $null }
    }
    $assignedTo  = if ($assignInfo) { ($assignInfo | Select-Object -Unique) -join ', ' } else { 'N/A' }
    $formattedKey = ($key -replace '(.{5})', '$1-').TrimEnd('-')

    $results.Add([PSCustomObject]@{
        Edition          = $edition
        LicenseKey       = $formattedKey
        Total            = $total
        Used             = $used
        Remaining        = $remaining
        ExpirationDate   = $expiryDate
        DaysUntilExpiry  = if ($daysUntil -eq [int]::MaxValue) { 'Never' } else { $daysUntil }
        Status           = $status
        AssignedTo       = $assignedTo
    })
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$expired  = ($results | Where-Object { $_.Status -eq 'EXPIRED'  }).Count
$expiring = ($results | Where-Object { $_.Status -eq 'EXPIRING' }).Count
$overUsed = ($results | Where-Object { $_.Status -like 'OVER*'  }).Count

Write-Host "`n=== License Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Total License Keys : $($results.Count)"  -ForegroundColor White
Write-Host "  Expired            : $expired"             -ForegroundColor $(if ($expired -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Expiring (<$ExpiryWarningDays days)  : $expiring" -ForegroundColor $(if ($expiring -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Compliance Issues  : $overUsed"            -ForegroundColor $(if ($overUsed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output             : $OutputFile"          -ForegroundColor White
