<#
.SYNOPSIS
    Validates that all VMs have recent successful backups using CBT and custom attributes.

.DESCRIPTION
    Reports CBT (Changed Block Tracking) status per VM and checks a configurable
    custom attribute (set by backup software like Veeam, Avamar, or similar) to
    determine when the last backup occurred. VMs exceeding the -MaxBackupAgeDays
    threshold are flagged as Warning or Critical.

.PARAMETER ClusterName
    Optional. Scope the check to a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER MaxBackupAgeDays
    Optional. Maximum acceptable backup age in days. Default: 1.

.PARAMETER BackupAttributeName
    Optional. Custom attribute name set by the backup tool. Default: 'LastBackupDate'.

.PARAMETER OutputFile
    Required. Path to export the backup status report as CSV.

.EXAMPLE
    .\Test-VMBackupStatus.ps1 -ClusterName "Production" -OutputFile "backup-status.csv"
    Checks backup status for all Production VMs.

.EXAMPLE
    .\Test-VMBackupStatus.ps1 -BackupAttributeName "Veeam_LastBackup" -MaxBackupAgeDays 2 -OutputFile "backup-check.csv"
    Uses a Veeam-specific custom attribute with a 2-day threshold.

.OUTPUTS
    CSV with columns: VMName, Cluster, PowerState, CBTEnabled, LastBackupDate,
    BackupAgeDays, Status

.NOTES
    Requires:
    - VMware PowerCLI module
    - Custom attribute set by backup software, or CBT as a proxy indicator

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
    [int]$MaxBackupAgeDays = 1,

    [Parameter(Mandatory=$false)]
    [string]$BackupAttributeName = 'LastBackupDate',

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

if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster
}
else {
    $vms = Get-VM
}

Write-Host "Checking backup status for $($vms.Count) VM(s)..." -ForegroundColor Cyan
Write-Host "  Max backup age  : $MaxBackupAgeDays day(s)" -ForegroundColor White
Write-Host "  Attribute name  : $BackupAttributeName" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0

foreach ($vm in $vms) {
    $vmCount++
    Write-Host "  [$vmCount/$($vms.Count)] $($vm.Name)..." -ForegroundColor White

    try {
        $vmView    = $vm | Get-View -Property Config.ChangeTrackingEnabled, Summary.Config.Name
        $cbtEnabled= $vmView.Config.ChangeTrackingEnabled

        # Check custom attribute for last backup date
        $lastBackupDate = $null
        $backupAgeDays  = $null
        try {
            $attrValue = ($vm | Get-Annotation -CustomAttribute $BackupAttributeName -ErrorAction SilentlyContinue).Value
            if ($attrValue -and $attrValue -ne '') {
                $lastBackupDate = [datetime]::Parse($attrValue)
                $backupAgeDays  = [math]::Round(((Get-Date) - $lastBackupDate).TotalDays, 1)
            }
        } catch {}

        # Determine status
        $status = 'Unknown'
        if ($null -ne $backupAgeDays) {
            if ($backupAgeDays -le $MaxBackupAgeDays) { $status = 'OK' }
            elseif ($backupAgeDays -le $MaxBackupAgeDays * 2) { $status = 'Warning' }
            else { $status = 'Critical' }
        }
        elseif (-not $cbtEnabled -and $vm.PowerState -eq 'PoweredOn') {
            $status = 'CBT Disabled'
        }

        # Get cluster name
        $vmCluster = try { (Get-Cluster -VM $vm -ErrorAction SilentlyContinue).Name } catch { 'N/A' }

        $results.Add([PSCustomObject]@{
            VMName         = $vm.Name
            Cluster        = $vmCluster
            PowerState     = $vm.PowerState
            CBTEnabled     = $cbtEnabled
            LastBackupDate = if ($lastBackupDate) { $lastBackupDate.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Not found' }
            BackupAgeDays  = if ($null -ne $backupAgeDays) { $backupAgeDays } else { 'N/A' }
            Status         = $status
        })
    }
    catch {
        Write-Warning "Error checking $($vm.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$ok       = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$warn     = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$critical = ($results | Where-Object { $_.Status -eq 'Critical' }).Count
$unknown  = ($results | Where-Object { $_.Status -in 'Unknown', 'CBT Disabled', 'Not found' }).Count

Write-Host "`n=== Backup Status Summary ===" -ForegroundColor Cyan
Write-Host "  VMs checked   : $($results.Count)" -ForegroundColor White
Write-Host "  OK            : $ok"       -ForegroundColor Green
Write-Host "  Warning       : $warn"     -ForegroundColor Yellow
Write-Host "  Critical      : $critical" -ForegroundColor Red
Write-Host "  Unknown       : $unknown"  -ForegroundColor Gray
Write-Host "  Output        : $OutputFile" -ForegroundColor White
