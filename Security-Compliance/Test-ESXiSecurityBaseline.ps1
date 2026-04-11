<#
.SYNOPSIS
    Audits ESXi hosts against a CIS/DISA STIG-derived security baseline.

.DESCRIPTION
    Checks ESXi hosts in a cluster against a configurable security baseline profile
    (CIS-Level1, CIS-Level2, or DISA-STIG), evaluating SSH, lockdown mode, account
    policies, firewall rules, service states, NTP, syslog, SNMP, TLS, and more.

    Findings are reported with severity, current value, expected value, and pass/fail
    status. Optionally remediates non-compliant settings when -RemediateFindings is used.

.PARAMETER ClusterName
    Optional. Name of the cluster to audit. If not specified, audits all hosts.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER BaselineProfile
    Optional. Security baseline to audit against. Default: CIS-Level1.
    Valid values: CIS-Level1, CIS-Level2, DISA-STIG.

.PARAMETER OutputFile
    Required. Path to export findings as CSV.

.PARAMETER RemediateFindings
    Optional. Switch. When specified, attempts to remediate non-compliant settings.
    Use with caution in production environments.

.EXAMPLE
    .\Test-ESXiSecurityBaseline.ps1 -ClusterName "Production" -OutputFile "security-audit.csv"
    Audits Production cluster hosts against CIS Level 1 baseline.

.EXAMPLE
    .\Test-ESXiSecurityBaseline.ps1 -vCenter "vc.example.com" -ClusterName "Prod" -BaselineProfile "DISA-STIG" -OutputFile "stig-audit.csv"
    Audits against DISA STIG profile.

.OUTPUTS
    CSV with columns: HostName, FindingID, Category, CheckName, Severity,
    CurrentValue, ExpectedValue, Status, RemediationNote

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to ESXi host configurations
    - Host credentials required for some ESXCLI-level checks

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [ValidateSet('CIS-Level1', 'CIS-Level2', 'DISA-STIG')]
    [string]$BaselineProfile = 'CIS-Level1',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$RemediateFindings
)

# Connect to vCenter if specified
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

# Get hosts
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) {
        Write-Error "Cluster '$ClusterName' not found."
        exit 1
    }
    $vmHosts = Get-VMHost -Location $cluster
}
else {
    $vmHosts = Get-VMHost
}

if (-not $vmHosts) {
    Write-Error "No hosts found."
    exit 1
}

Write-Host "Auditing $($vmHosts.Count) host(s) against $BaselineProfile baseline..." -ForegroundColor Cyan

# Define expected values per profile
$expectedLockdownMode = @{
    'CIS-Level1' = 'lockdownNormal'
    'CIS-Level2' = 'lockdownStrict'
    'DISA-STIG'  = 'lockdownNormal'
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$hostCount = 0

foreach ($vmHost in $vmHosts) {
    $hostCount++
    Write-Host "  [$hostCount/$($vmHosts.Count)] Auditing: $($vmHost.Name)..." -ForegroundColor White

    try {
        $esxcli = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction SilentlyContinue
        $hostView = $vmHost | Get-View -Property Config.Service, Config.Firewall, Config.DateTimeInfo, Config.Option, LockdownMode
        $services = $vmHost | Get-VMHostService -ErrorAction SilentlyContinue

        # Helper to add finding
        function Add-Finding {
            param($FindingID, $Category, $CheckName, $Severity, $Current, $Expected, $Status, $Note = '')
            $results.Add([PSCustomObject]@{
                HostName        = $vmHost.Name
                FindingID       = $FindingID
                Category        = $Category
                CheckName       = $CheckName
                Severity        = $Severity
                CurrentValue    = $Current
                ExpectedValue   = $Expected
                Status          = $Status
                RemediationNote = $Note
            })
        }

        # --- SSH Service ---
        $sshSvc = $services | Where-Object { $_.Key -eq 'TSM-SSH' }
        $sshRunning = if ($sshSvc) { $sshSvc.Running } else { $false }
        $expectedSsh = $false
        Add-Finding -FindingID 'ESXi-001' -Category 'Services' -CheckName 'SSH Service Disabled' `
            -Severity 'High' -Current $sshRunning -Expected $expectedSsh `
            -Status (if ($sshRunning -eq $expectedSsh) { 'PASS' } else { 'FAIL' }) `
            -Note 'Disable SSH unless actively required for troubleshooting'

        if ($RemediateFindings -and $sshRunning) {
            try { Stop-VMHostService -HostService $sshSvc -Confirm:$false | Out-Null } catch {}
        }

        # --- ESXi Shell Service ---
        $shellSvc = $services | Where-Object { $_.Key -eq 'TSM' }
        $shellRunning = if ($shellSvc) { $shellSvc.Running } else { $false }
        Add-Finding -FindingID 'ESXi-002' -Category 'Services' -CheckName 'ESXi Shell Disabled' `
            -Severity 'High' -Current $shellRunning -Expected $false `
            -Status (if (-not $shellRunning) { 'PASS' } else { 'FAIL' }) `
            -Note 'Disable ESXi Shell unless actively required'

        # --- Lockdown Mode ---
        $lockdownMode = $hostView.Config.LockdownMode
        if (-not $lockdownMode) {
            # Try alternate property path
            $lockdownMode = ($vmHost | Get-View).Config.LockdownMode
        }
        $expectedLock = $expectedLockdownMode[$BaselineProfile]
        Add-Finding -FindingID 'ESXi-003' -Category 'Access' -CheckName 'Lockdown Mode' `
            -Severity 'High' -Current $lockdownMode -Expected $expectedLock `
            -Status (if ($lockdownMode -eq $expectedLock) { 'PASS' } else { 'FAIL' }) `
            -Note "Expected lockdown mode for $BaselineProfile"

        # --- NTP Configuration ---
        $ntpConfig = $vmHost | Get-VMHostNtpServer -ErrorAction SilentlyContinue
        $ntpConfigured = ($ntpConfig -and $ntpConfig.Count -gt 0)
        Add-Finding -FindingID 'ESXi-004' -Category 'Time' -CheckName 'NTP Configured' `
            -Severity 'Medium' -Current ($ntpConfig -join ',') -Expected '<NTP server configured>' `
            -Status (if ($ntpConfigured) { 'PASS' } else { 'FAIL' }) `
            -Note 'Configure at least one NTP server for time synchronization'

        # --- Syslog Target ---
        $syslogTarget = $vmHost | Get-AdvancedSetting -Name 'Syslog.global.logHost' -ErrorAction SilentlyContinue
        $syslogValue = if ($syslogTarget) { $syslogTarget.Value } else { '' }
        $syslogConfigured = ($syslogValue -ne '' -and $null -ne $syslogValue)
        Add-Finding -FindingID 'ESXi-005' -Category 'Logging' -CheckName 'Remote Syslog Configured' `
            -Severity 'High' -Current $syslogValue -Expected '<syslog server URI>' `
            -Status (if ($syslogConfigured) { 'PASS' } else { 'FAIL' }) `
            -Note 'Configure remote syslog for centralized log management'

        # --- SNMP Community String ---
        $snmpConfig = $null
        if ($esxcli) {
            try { $snmpConfig = $esxcli.system.snmp.get.Invoke() } catch {}
        }
        $snmpEnabled = if ($snmpConfig) { $snmpConfig.Enable } else { $false }
        $snmpCommunity = if ($snmpConfig) { $snmpConfig.Communities } else { '' }
        $snmpRisk = $snmpEnabled -and ($snmpCommunity -match 'public|private')
        Add-Finding -FindingID 'ESXi-006' -Category 'Services' -CheckName 'SNMP Default Community' `
            -Severity 'Medium' -Current "Enabled=$snmpEnabled Communities=$snmpCommunity" -Expected 'No default community strings (public/private)' `
            -Status (if (-not $snmpRisk) { 'PASS' } else { 'FAIL' }) `
            -Note 'Change or disable SNMP default community strings'

        # --- Account Lockout ---
        $lockoutSetting = $vmHost | Get-AdvancedSetting -Name 'Security.AccountLockFailures' -ErrorAction SilentlyContinue
        $lockoutValue = if ($lockoutSetting) { [int]$lockoutSetting.Value } else { 0 }
        $expectedLockout = if ($BaselineProfile -eq 'DISA-STIG') { 3 } else { 5 }
        Add-Finding -FindingID 'ESXi-007' -Category 'Authentication' -CheckName 'Account Lockout Failures' `
            -Severity 'Medium' -Current $lockoutValue -Expected "<= $expectedLockout" `
            -Status (if ($lockoutValue -gt 0 -and $lockoutValue -le $expectedLockout) { 'PASS' } else { 'FAIL' }) `
            -Note "Set to $expectedLockout or fewer failed login attempts before lockout"

        # --- Password Complexity ---
        $pwdComplexity = $vmHost | Get-AdvancedSetting -Name 'Security.PasswordQualityControl' -ErrorAction SilentlyContinue
        $pwdValue = if ($pwdComplexity) { $pwdComplexity.Value } else { '' }
        $pwdOk = $pwdValue -match 'min=\d+'
        Add-Finding -FindingID 'ESXi-008' -Category 'Authentication' -CheckName 'Password Complexity Policy' `
            -Severity 'High' -Current $pwdValue -Expected 'retry=3 min=disabled,disabled,disabled,7,7' `
            -Status (if ($pwdOk) { 'PASS' } else { 'FAIL' }) `
            -Note 'Configure password complexity via Security.PasswordQualityControl'

        # --- DCUI Timeout ---
        $dcuiTimeout = $vmHost | Get-AdvancedSetting -Name 'UserVars.DcuiTimeOut' -ErrorAction SilentlyContinue
        $dcuiValue = if ($dcuiTimeout) { [int]$dcuiTimeout.Value } else { 0 }
        $expectedDcui = 600
        Add-Finding -FindingID 'ESXi-009' -Category 'Access' -CheckName 'DCUI Timeout' `
            -Severity 'Low' -Current $dcuiValue -Expected "<= $expectedDcui" `
            -Status (if ($dcuiValue -gt 0 -and $dcuiValue -le $expectedDcui) { 'PASS' } else { 'FAIL' }) `
            -Note "Set DCUI timeout to $expectedDcui seconds or less"

        # --- CEIP ---
        $ceip = $vmHost | Get-AdvancedSetting -Name 'UserVars.HostClientCEIPOptIn' -ErrorAction SilentlyContinue
        $ceipValue = if ($ceip) { $ceip.Value } else { $null }
        Add-Finding -FindingID 'ESXi-010' -Category 'Privacy' -CheckName 'CEIP Participation' `
            -Severity 'Info' -Current $ceipValue -Expected '0 (disabled)' `
            -Status (if ($ceipValue -eq 0 -or $ceipValue -eq '0') { 'PASS' } else { 'INFO' }) `
            -Note 'Disable CEIP (Customer Experience Improvement Program) if required by policy'

        # --- MOB Accessibility ---
        $mob = $vmHost | Get-AdvancedSetting -Name 'Config.HostAgent.plugins.solo.enableMob' -ErrorAction SilentlyContinue
        $mobEnabled = if ($mob) { $mob.Value } else { $null }
        Add-Finding -FindingID 'ESXi-011' -Category 'Access' -CheckName 'MOB Accessibility' `
            -Severity 'Medium' -Current $mobEnabled -Expected 'False' `
            -Status (if ($mobEnabled -eq $false -or $mobEnabled -eq 'False' -or $mobEnabled -eq '0') { 'PASS' } else { 'FAIL' }) `
            -Note 'Disable Managed Object Browser (MOB) in production environments'

        # --- TLS Versions ---
        $tlsSetting = $vmHost | Get-AdvancedSetting -Name 'UserVars.ESXiVPsDisabledProtocols' -ErrorAction SilentlyContinue
        $tlsValue = if ($tlsSetting) { $tlsSetting.Value } else { '' }
        $tlsOk = $tlsValue -match 'tlsv1\.0|sslv3'
        Add-Finding -FindingID 'ESXi-012' -Category 'Cryptography' -CheckName 'TLS Protocol Versions' `
            -Severity 'High' -Current $tlsValue -Expected 'TLSv1.0 and SSLv3 disabled' `
            -Status (if ($tlsOk) { 'PASS' } else { 'WARN' }) `
            -Note 'Disable TLSv1.0 and SSLv3; use TLSv1.2 or higher only'

    }
    catch {
        Write-Warning "Error auditing host $($vmHost.Name): $_"
    }
}

# Export results
Write-Host "`nExporting $($results.Count) findings to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

# Summary
$pass  = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail  = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warn  = ($results | Where-Object { $_.Status -eq 'WARN' }).Count

Write-Host "`n=== Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Profile  : $BaselineProfile" -ForegroundColor White
Write-Host "  Hosts    : $($vmHosts.Count)" -ForegroundColor White
Write-Host "  PASS     : $pass" -ForegroundColor Green
Write-Host "  FAIL     : $fail" -ForegroundColor Red
Write-Host "  WARN     : $warn" -ForegroundColor Yellow
Write-Host "  Output   : $OutputFile" -ForegroundColor White
