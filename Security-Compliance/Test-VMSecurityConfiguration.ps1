<#
.SYNOPSIS
    Audits VM-level security settings for compliance.

.DESCRIPTION
    Checks every VM in a cluster (or a specific VM) against security best practices:
    isolation tools settings (copy/paste/drag-and-drop), remote display limits,
    encryption status, device presence, logging configuration, and annotation
    secrets.

.PARAMETER ClusterName
    Optional. Cluster to audit. If not specified, audits all VMs.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export audit results as CSV.

.PARAMETER VMName
    Optional. Audit only the specified VM name.

.EXAMPLE
    .\Test-VMSecurityConfiguration.ps1 -ClusterName "Production" -OutputFile "vm-security.csv"
    Audits all VMs in the Production cluster.

.EXAMPLE
    .\Test-VMSecurityConfiguration.ps1 -vCenter "vc.example.com" -VMName "WebServer01" -OutputFile "vm-sec.csv"
    Audits a single VM.

.OUTPUTS
    CSV with columns: VMName, CheckName, Category, CurrentValue, RecommendedValue, Status, Note

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to VM configurations

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
    [string]$VMName
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

if ($VMName) {
    $vms = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vms) { Write-Error "VM '$VMName' not found."; exit 1 }
}
elseif ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster
}
else {
    $vms = Get-VM
}

Write-Host "Auditing security configuration for $($vms.Count) VM(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Checks: advancedconfig key, recommended value, severity, description
$advChecks = @(
    @{ Key='isolation.tools.copy.disable';    Expected='true';  Category='Isolation'; Severity='High';   Note='Prevent guest-to-host clipboard copy' }
    @{ Key='isolation.tools.paste.disable';   Expected='true';  Category='Isolation'; Severity='High';   Note='Prevent host-to-guest clipboard paste' }
    @{ Key='isolation.tools.dnd.disable';     Expected='true';  Category='Isolation'; Severity='Medium'; Note='Prevent drag-and-drop between guest and console' }
    @{ Key='isolation.tools.setGUIOptions.enable'; Expected='false'; Category='Isolation'; Severity='Medium'; Note='Prevent guest from modifying console options' }
    @{ Key='RemoteDisplay.maxConnections';    Expected='1';     Category='RemoteAccess'; Severity='Medium'; Note='Limit simultaneous remote console connections' }
    @{ Key='tools.setInfo.sizeLimit';         Expected='1048576'; Category='Integrity'; Severity='Low'; Note='Limit size of guest info data written to VMX' }
    @{ Key='log.keepOld';                     Expected='10';    Category='Logging'; Severity='Low'; Note='Retain at least 10 previous log files' }
    @{ Key='log.rotateSize';                  Expected='2048000'; Category='Logging'; Severity='Low'; Note='Rotate logs at 2 MB to prevent runaway log growth' }
    @{ Key='isolation.tools.diskShrink.disable'; Expected='true'; Category='Isolation'; Severity='Medium'; Note='Prevent guest disk shrink operations' }
    @{ Key='isolation.tools.diskWiper.disable';  Expected='true'; Category='Isolation'; Severity='Medium'; Note='Prevent guest disk wiper operations' }
)

$vmCount = 0
foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name)..." -ForegroundColor White

    try {
        $vmConfig   = $vm | Get-View -Property Config
        $advConfig  = $vmConfig.Config.ExtraConfig
        $advHash    = @{}
        foreach ($item in $advConfig) { $advHash[$item.Key] = $item.Value }

        # Advanced config checks
        foreach ($check in $advChecks) {
            $current = $advHash[$check.Key]
            $status  = if ($null -eq $current -or $current -eq '') { 'MISSING' }
                       elseif ($current -eq $check.Expected) { 'PASS' } else { 'FAIL' }

            $results.Add([PSCustomObject]@{
                VMName           = $vm.Name
                Category         = $check.Category
                CheckName        = $check.Key
                Severity         = $check.Severity
                CurrentValue     = if ($null -eq $current) { '(not set)' } else { $current }
                RecommendedValue = $check.Expected
                Status           = $status
                Note             = $check.Note
            })
        }

        # --- Encryption Status ---
        $encryptionState = if ($vmConfig.Config.KeyId) { 'Encrypted' } else { 'Not Encrypted' }
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Encryption'
            CheckName        = 'VM Encryption at Rest'
            Severity         = 'High'
            CurrentValue     = $encryptionState
            RecommendedValue = 'Encrypted (if sensitive data)'
            Status           = if ($encryptionState -eq 'Encrypted') { 'PASS' } else { 'INFO' }
            Note             = 'Enable VM encryption for VMs holding sensitive data'
        })

        # --- vTPM ---
        $vtpm = $vmConfig.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualTPM' }
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Security Hardware'
            CheckName        = 'vTPM Present'
            Severity         = 'Medium'
            CurrentValue     = ($null -ne $vtpm)
            RecommendedValue = 'True (for Windows 11 / modern OS)'
            Status           = 'INFO'
            Note             = 'Add vTPM for VMs requiring Secure Boot attestation'
        })

        # --- Floppy Device ---
        $floppy = $vmConfig.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualFloppy' }
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Devices'
            CheckName        = 'Floppy Drive Present'
            Severity         = 'Low'
            CurrentValue     = ($null -ne $floppy)
            RecommendedValue = 'False'
            Status           = if ($null -eq $floppy) { 'PASS' } else { 'FAIL' }
            Note             = 'Remove unused floppy devices to reduce attack surface'
        })

        # --- Serial/Parallel Ports ---
        $serial   = $vmConfig.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualSerialPort' }
        $parallel = $vmConfig.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualParallelPort' }
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Devices'
            CheckName        = 'Serial/Parallel Ports Present'
            Severity         = 'Low'
            CurrentValue     = "Serial=$($null -ne $serial) Parallel=$($null -ne $parallel)"
            RecommendedValue = 'False / False'
            Status           = if ($null -eq $serial -and $null -eq $parallel) { 'PASS' } else { 'FAIL' }
            Note             = 'Remove unused serial/parallel ports'
        })

        # --- Sensitive data in annotation ---
        $annotation = $vmConfig.Config.Annotation
        $secretRegex = '(?i)(password|passwd|secret|token|credential|api.?key)\s*[:=]'
        $hasSecret = $annotation -match $secretRegex
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Sensitive Data'
            CheckName        = 'Credentials in Annotation'
            Severity         = 'Critical'
            CurrentValue     = if ($hasSecret) { 'Potential credential detected' } else { 'Clean' }
            RecommendedValue = 'No credentials in annotations'
            Status           = if ($hasSecret) { 'FAIL' } else { 'PASS' }
            Note             = 'Never store passwords or secrets in VM annotations'
        })

        # --- Independent Non-Persistent Disks ---
        $nonPersistentDisks = $vmConfig.Config.Hardware.Device | Where-Object {
            $_ -is [VMware.Vim.VirtualDisk] -and $_.Backing.DiskMode -eq 'independent_nonpersistent'
        }
        $results.Add([PSCustomObject]@{
            VMName           = $vm.Name
            Category         = 'Storage'
            CheckName        = 'Independent Non-Persistent Disks'
            Severity         = 'Medium'
            CurrentValue     = ($null -ne $nonPersistentDisks -and @($nonPersistentDisks).Count -gt 0)
            RecommendedValue = 'False'
            Status           = if ($null -eq $nonPersistentDisks -or @($nonPersistentDisks).Count -eq 0) { 'PASS' } else { 'WARN' }
            Note             = 'Independent non-persistent disks prevent CBT and can complicate backups'
        })
    }
    catch {
        Write-Warning "Error auditing VM $($vm.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) findings to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$pass = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count

Write-Host "`n=== VM Security Audit Summary ===" -ForegroundColor Cyan
Write-Host "  VMs audited : $($vms.Count)" -ForegroundColor White
Write-Host "  PASS        : $pass" -ForegroundColor Green
Write-Host "  FAIL        : $fail" -ForegroundColor Red
Write-Host "  Output      : $OutputFile" -ForegroundColor White
