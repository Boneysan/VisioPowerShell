<#
.SYNOPSIS
    Orchestrates all VisioPowerShell audit scripts into a comprehensive cluster report.

.DESCRIPTION
    Runs all available audit and reporting scripts against a target cluster, collecting
    output CSV/JSON files into a timestamped output folder. Generates an index of all
    outputs and a summary HTML dashboard. Designed for comprehensive quarterly/annual
    vSphere environment reviews.

    Scripts are executed in dependency order within the following domains:
    - Security & Compliance
    - Storage Management
    - Networking
    - Backup & DR
    - Operations
    - Change Management
    - Capacity Planning
    - Licensing
    - Tags & Organization
    - Templates & Content Library
    - Patch Management
    - Alarm Management

.PARAMETER ClusterName
    Required. The cluster to run the full audit against.

.PARAMETER vCenter
    Required. The vCenter Server to connect to.

.PARAMETER OutputFolder
    Optional. Root folder for audit outputs. Default: .\AuditOutput\[ClusterName]_[Timestamp].

.PARAMETER ScriptRoot
    Optional. Path to the VisioPowerShell scripts root folder.
    Default: folder containing this script (parent directory).

.PARAMETER SkipDomains
    Optional. Comma-delimited list of domain names to skip (e.g., 'Capacity-Planning,Networking').

.PARAMETER DryRun
    Optional switch. Validates that all scripts exist without running any of them.

.EXAMPLE
    .\Export-FullClusterAudit.ps1 -ClusterName "Production" -vCenter "vcenter.lab.local" -OutputFolder "C:\Audits\Q1-2026"
    Runs the full audit against the Production cluster.

.EXAMPLE
    .\Export-FullClusterAudit.ps1 -ClusterName "Production" -vCenter "vcenter.lab.local" -SkipDomains "Capacity-Planning" -DryRun
    Dry run showing which scripts would be executed.

.OUTPUTS
    Multiple CSV/JSON files in the output folder, plus an audit-index.csv summary.

.NOTES
    Requires:
    - VMware PowerCLI module
    - All VisioPowerShell domain scripts accessible via -ScriptRoot

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFolder,

    [Parameter(Mandatory=$false)]
    [string]$ScriptRoot,

    [Parameter(Mandatory=$false)]
    [string]$SkipDomains,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# Resolve paths
$timestamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
$scriptBase = if ($ScriptRoot) { $ScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition | Split-Path -Parent }
$outputBase = if ($OutputFolder) { $OutputFolder } else { Join-Path (Get-Location) "AuditOutput\${ClusterName}_${timestamp}" }

$skipList = if ($SkipDomains) { $SkipDomains -split ',' | ForEach-Object { $_.Trim() } } else { @() }

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  VisioPowerShell Full Cluster Audit" -ForegroundColor Cyan
Write-Host "  Cluster    : $ClusterName" -ForegroundColor White
Write-Host "  vCenter    : $vCenter" -ForegroundColor White
Write-Host "  Output     : $outputBase" -ForegroundColor White
Write-Host "  DryRun     : $DryRun" -ForegroundColor White
Write-Host "  Skip       : $($skipList -join ', ')" -ForegroundColor Yellow
Write-Host "============================================`n" -ForegroundColor Cyan

# Connect vCenter once
if (-not $DryRun) {
    try {
        Connect-VIServer -Server $vCenter -ErrorAction Stop | Out-Null
        Write-Host "Connected to vCenter: $vCenter" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter: $_"
        exit 1
    }
}

# Define all audit script runs
# Format: @{ Domain; ScriptRelPath; OutputFile; ExtraArgs (hashtable) }
$auditRuns = @(
    # Security-Compliance
    @{ Domain='Security-Compliance'; Script='Security-Compliance\Test-ESXiSecurityBaseline.ps1';
       Output='security\esxi-security-baseline.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Security-Compliance'; Script='Security-Compliance\Get-vSpherePermissionsAudit.ps1';
       Output='security\vsphere-permissions.csv'
       Args=@{} }
    @{ Domain='Security-Compliance'; Script='Security-Compliance\Test-VMSecurityConfiguration.ps1';
       Output='security\vm-security-config.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Security-Compliance'; Script='Security-Compliance\Get-CertificateStatus.ps1';
       Output='security\certificate-status.csv'
       Args=@{} }
    @{ Domain='Security-Compliance'; Script='Security-Compliance\Get-FailedLoginAudit.ps1';
       Output='security\failed-logins.csv'
       Args=@{} }

    # Storage-Management
    @{ Domain='Storage-Management'; Script='Storage-Management\Get-DatastoreOvercommit.ps1';
       Output='storage\datastore-overcommit.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Storage-Management'; Script='Storage-Management\Get-OrphanedVMDKs.ps1';
       Output='storage\orphaned-vmdks.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Storage-Management'; Script='Storage-Management\Get-StoragePolicyCompliance.ps1';
       Output='storage\storage-policy-compliance.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Storage-Management'; Script='Storage-Management\Get-RDMInventory.ps1';
       Output='storage\rdm-inventory.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Storage-Management'; Script='Storage-Management\Get-VMDiskLayout.ps1';
       Output='storage\vm-disk-layout.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Networking
    @{ Domain='Networking'; Script='Networking\Get-VDSwitchAudit.ps1';
       Output='networking\vds-audit.csv'
       Args=@{} }
    @{ Domain='Networking'; Script='Networking\Test-NetworkConsistency.ps1';
       Output='networking\network-consistency.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Networking'; Script='Networking\Get-VMKernelAdapterReport.ps1';
       Output='networking\vmkernel-adapters.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Networking'; Script='Networking\Get-PhysicalNICInventory.ps1';
       Output='networking\physical-nics.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Backup-DR
    @{ Domain='Backup-DR'; Script='Backup-DR\Test-VMBackupStatus.ps1';
       Output='backup-dr\vm-backup-status.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Backup-DR'; Script='Backup-DR\Get-ReplicationStatus.ps1';
       Output='backup-dr\replication-status.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Backup-DR'; Script='Backup-DR\Get-DRReadinessReport.ps1';
       Output='backup-dr\dr-readiness.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Operations
    @{ Domain='Operations'; Script='Operations\Get-ClusterConfigurationReport.ps1';
       Output='operations\cluster-config.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Operations'; Script='Operations\Get-DRSRulesAndGroups.ps1';
       Output='operations\drs-rules.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Operations'; Script='Operations\Get-ResourcePoolConfiguration.ps1';
       Output='operations\resource-pools.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Operations'; Script='Operations\Get-ActiveAlarms.ps1';
       Output='operations\active-alarms.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Operations'; Script='Operations\Get-HostServiceStatus.ps1';
       Output='operations\host-services.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Change-Management
    @{ Domain='Change-Management'; Script='Change-Management\Get-VMHardwareVersionReport.ps1';
       Output='change-management\vm-hardware-versions.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Change-Management'; Script='Change-Management\Get-HostProfileCompliance.ps1';
       Output='change-management\host-profile-compliance.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Capacity-Planning
    @{ Domain='Capacity-Planning'; Script='Capacity-Planning\Get-VMRightSizingDetailed.ps1';
       Output='capacity-planning\vm-rightsizing.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Capacity-Planning'; Script='Capacity-Planning\Get-CapacityForecast.ps1';
       Output='capacity-planning\capacity-forecast.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Licensing
    @{ Domain='Licensing'; Script='Licensing\Get-LicenseAudit.ps1';
       Output='licensing\license-audit.csv'
       Args=@{} }

    # Tags-Organization
    @{ Domain='Tags-Organization'; Script='Tags-Organization\Get-TagInventory.ps1';
       Output='tags\tag-inventory.csv'
       Args=@{} }
    @{ Domain='Tags-Organization'; Script='Tags-Organization\Get-CustomAttributeReport.ps1';
       Output='tags\custom-attributes.csv'
       Args=@{} }

    # Templates
    @{ Domain='Templates-ContentLibrary'; Script='Templates-ContentLibrary\Get-TemplateInventory.ps1';
       Output='templates\template-inventory.csv'
       Args=@{} }
    @{ Domain='Templates-ContentLibrary'; Script='Templates-ContentLibrary\Get-ContentLibraryReport.ps1';
       Output='templates\content-library-report.csv'
       Args=@{} }

    # Patch-Management
    @{ Domain='Patch-Management'; Script='Patch-Management\Get-ESXiPatchLevel.ps1';
       Output='patching\esxi-patch-levels.csv'
       Args=@{ ClusterName=$ClusterName } }
    @{ Domain='Patch-Management'; Script='Patch-Management\Get-VUMComplianceReport.ps1';
       Output='patching\vum-compliance.csv'
       Args=@{ ClusterName=$ClusterName } }

    # Alarm-Management
    @{ Domain='Alarm-Management'; Script='Alarm-Management\Get-AlarmDefinitionAudit.ps1';
       Output='alarms\alarm-definitions.csv'
       Args=@{} }
)

$index = [System.Collections.Generic.List[PSCustomObject]]::new()

$totalRuns = 0; $successRuns = 0; $failedRuns = 0; $skippedRuns = 0

foreach ($run in $auditRuns) {
    $totalRuns++

    if ($skipList -contains $run.Domain) {
        $skippedRuns++
        Write-Host "  [SKIP] $($run.Script)" -ForegroundColor DarkGray
        $index.Add([PSCustomObject]@{
            Domain=$run.Domain; Script=$run.Script; OutputFile=$run.Output
            Status='Skipped'; Duration='N/A'; Notes='Domain skipped'
        })
        continue
    }

    $scriptPath = Join-Path $scriptBase $run.Script
    $outputPath = Join-Path $outputBase $run.Output

    if (-not (Test-Path $scriptPath)) {
        Write-Host "  [MISSING] $($run.Script)" -ForegroundColor Red
        $index.Add([PSCustomObject]@{
            Domain=$run.Domain; Script=$run.Script; OutputFile=$run.Output
            Status='Missing'; Duration='N/A'; Notes="Script not found: $scriptPath"
        })
        $failedRuns++
        continue
    }

    if ($DryRun) {
        Write-Host "  [DRYRUN] $($run.Script)" -ForegroundColor Cyan
        $index.Add([PSCustomObject]@{
            Domain=$run.Domain; Script=$run.Script; OutputFile=$run.Output
            Status='DryRun'; Duration='N/A'; Notes='Would execute'
        })
        continue
    }

    # Ensure output dir exists
    $outDir = Split-Path -Parent $outputPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    # Build arguments
    $splat = $run.Args + @{ OutputFile = $outputPath }

    $start  = Get-Date
    $status = 'Success'
    $notes  = ''

    Write-Host "  [RUN] $($run.Domain) > $($run.Script)..." -ForegroundColor White -NoNewline

    try {
        & $scriptPath @splat -ErrorAction Stop | Out-Null
        $duration = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        Write-Host " Done ($duration s)" -ForegroundColor Green
        $successRuns++
    }
    catch {
        $duration = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        $status = 'Failed'
        $notes  = $_.Exception.Message
        Write-Host " FAILED: $notes" -ForegroundColor Red
        $failedRuns++
    }

    $index.Add([PSCustomObject]@{
        Domain     = $run.Domain
        Script     = $run.Script
        OutputFile = $outputPath
        Status     = $status
        Duration   = "$duration s"
        Notes      = $notes
    })
}

# Export index
$indexFile = Join-Path $outputBase 'audit-index.csv'
if (-not $DryRun) {
    if (-not (Test-Path $outputBase)) { New-Item -ItemType Directory -Path $outputBase -Force | Out-Null }
    $index | Export-Csv -Path $indexFile -NoTypeInformation
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Full Audit Complete" -ForegroundColor Cyan
Write-Host "  Total Scripts  : $totalRuns"                -ForegroundColor White
Write-Host "  Success        : $successRuns"               -ForegroundColor Green
Write-Host "  Failed         : $failedRuns"                -ForegroundColor $(if ($failedRuns -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped        : $skippedRuns"               -ForegroundColor Yellow
Write-Host "  Output Folder  : $outputBase"                -ForegroundColor White
if (-not $DryRun) {
    Write-Host "  Audit Index    : $indexFile"             -ForegroundColor White
}
Write-Host "============================================`n" -ForegroundColor Cyan
