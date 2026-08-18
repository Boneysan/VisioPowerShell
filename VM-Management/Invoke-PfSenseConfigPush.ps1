<#
.SYNOPSIS
    Pushes pfSense XML configuration files to router VMs via SSH/SCP.

.DESCRIPTION
    Reads a pfSense push plan (JSON) produced by a Terraform workspace and stages
    router configuration XML files to each pfSense router via SCP. Optionally applies
    the configuration and reboots each router after staging.

    The plan JSON is produced by the CCH 02_routers Terraform module:
        terraform -chdir=02_routers output -json pfsense_push_plan > pfsense-push-plan.json

    Each entry in the plan must contain:
        vm_name            - Display name of the router VM
        mgmt_ipv4          - Management IP address of the pfSense router
        config_upload_path - Local path to the XML config file to push

.PARAMETER PlanPath
    Required. Path to the pfSense push plan JSON file.

.PARAMETER SshUser
    Optional. SSH username to connect to pfSense routers. Defaults to 'admin'.

.PARAMETER RemoteStageDir
    Optional. Directory on the pfSense router to stage the config file. Defaults to '/tmp'.

.PARAMETER GeneratePlan
    Optional switch. Runs 'terraform output -json pfsense_push_plan' to regenerate the
    plan file from the current Terraform state before pushing. Requires terraform in PATH
    and must be run from the Terraform workspace directory.

.PARAMETER ApplyAfterStage
    Optional switch. After staging, backs up the existing config.xml, replaces it with
    the staged file, and reboots the router. Requires SSH shell access on the pfSense host.
    If this fails in your environment, stage only and restore via the pfSense WebGUI.

.PARAMETER DryRun
    Optional switch. Reports what would happen without making any changes.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Invoke-PfSenseConfigPush.ps1 -PlanPath ".\pfsense-push-plan.json" -DryRun
    Preview which routers would receive config pushes without making changes.

.EXAMPLE
    .\Invoke-PfSenseConfigPush.ps1 -PlanPath ".\pfsense-push-plan.json"
    Stage config XML files to all pfSense routers listed in the plan.

.EXAMPLE
    .\Invoke-PfSenseConfigPush.ps1 -PlanPath ".\pfsense-push-plan.json" -ApplyAfterStage
    Stage and apply config on each router, then reboot.

.EXAMPLE
    .\Invoke-PfSenseConfigPush.ps1 -PlanPath ".\pfsense-push-plan.json" -OutputFile "push-log.csv"
    Stage configs and export per-router results to CSV.

.OUTPUTS
    CSV with columns: RouterKey, VMName, MgmtIP, ConfigFile, StageStatus, ApplyStatus, Detail, Timestamp

.NOTES
    Requires:
    - ssh and scp in PATH (OpenSSH or equivalent)
    - SSH access to each pfSense router management IP
    - terraform in PATH if using -GeneratePlan

    How to use:
      Get-Help .\Invoke-PfSenseConfigPush.ps1 -Full
      Get-Help .\Invoke-PfSenseConfigPush.ps1 -Examples

    Author:  Mike Zomer
    Version: 1.0
    Date:    June 25, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$PlanPath,

    [Parameter(Mandatory=$false)]
    [string]$SshUser = 'admin',

    [Parameter(Mandatory=$false)]
    [string]$RemoteStageDir = '/tmp',

    [Parameter(Mandatory=$false)]
    [switch]$GeneratePlan,

    [Parameter(Mandatory=$false)]
    [switch]$ApplyAfterStage,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# --- Preflight checks ---
function Assert-CommandExists {
    param([Parameter(Mandatory=$true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$Name' was not found in PATH."
        exit 1
    }
}

Assert-CommandExists -Name 'ssh'
Assert-CommandExists -Name 'scp'

if ($GeneratePlan) {
    Assert-CommandExists -Name 'terraform'
}

# --- Generate plan (optional) ---
if ($GeneratePlan) {
    Write-Host "Generating pfSense push plan from Terraform output..." -ForegroundColor Cyan
    terraform output -json pfsense_push_plan | Out-File -FilePath $PlanPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        Write-Error "terraform output failed."
        exit 1
    }
    Write-Host "Plan written to: $PlanPath" -ForegroundColor Green
}

# --- Load plan ---
if (-not (Test-Path -LiteralPath $PlanPath)) {
    Write-Error "Plan file not found: $PlanPath"
    exit 1
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if (-not $plan) {
    Write-Error "Plan file is empty or invalid: $PlanPath"
    exit 1
}

$routerCount = ($plan.PSObject.Properties | Measure-Object).Count

Write-Host "`n=== pfSense Config Push (SSH/SCP) ===" -ForegroundColor Cyan
Write-Host "  Plan File         : $PlanPath ($routerCount routers)" -ForegroundColor White
Write-Host "  SSH User          : $SshUser" -ForegroundColor White
Write-Host "  Remote Stage Dir  : $RemoteStageDir" -ForegroundColor White
Write-Host "  Apply After Stage : $ApplyAfterStage" -ForegroundColor White
Write-Host "  DryRun            : $DryRun`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param(
        [string]$RouterKey,
        [string]$VMName,
        [string]$MgmtIP,
        [string]$ConfigFile,
        [string]$StageStatus,
        [string]$ApplyStatus,
        [string]$Detail
    )
    $entry = [PSCustomObject]@{
        RouterKey   = $RouterKey
        VMName      = $VMName
        MgmtIP      = $MgmtIP
        ConfigFile  = $ConfigFile
        StageStatus = $StageStatus
        ApplyStatus = $ApplyStatus
        Detail      = $Detail
        Timestamp   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($StageStatus) {
        'SUCCESS' { 'Green'  }
        'SKIPPED' { 'Yellow' }
        'ERROR'   { 'Red'    }
        'DRYRUN'  { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host "  [$StageStatus] $RouterKey ($VMName) : $Detail" -ForegroundColor $color
}

# --- Push configs ---
foreach ($entry in $plan.PSObject.Properties | Sort-Object Name) {
    $routerKey = $entry.Name
    $target    = $entry.Value

    $ip      = [string]$target.mgmt_ipv4
    $xmlPath = [string]$target.config_upload_path
    $vmName  = [string]$target.vm_name

    if ([string]::IsNullOrWhiteSpace($ip)) {
        Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP '' `
            -ConfigFile $xmlPath -StageStatus 'ERROR' -ApplyStatus 'N/A' `
            -Detail "Missing mgmt_ipv4 in plan"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($xmlPath)) {
        Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP $ip `
            -ConfigFile '' -StageStatus 'ERROR' -ApplyStatus 'N/A' `
            -Detail "Missing config_upload_path in plan"
        continue
    }

    if (-not (Test-Path -LiteralPath $xmlPath)) {
        Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP $ip `
            -ConfigFile $xmlPath -StageStatus 'ERROR' -ApplyStatus 'N/A' `
            -Detail "Config XML not found: $xmlPath"
        continue
    }

    $xmlLeaf    = Split-Path -Path $xmlPath -Leaf
    $remotePath = "$RemoteStageDir/$xmlLeaf"
    $sshTarget  = "$SshUser@$ip"

    if ($DryRun) {
        $applyNote = if ($ApplyAfterStage) { ', then apply and reboot' } else { '' }
        Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP $ip `
            -ConfigFile $xmlLeaf -StageStatus 'DRYRUN' `
            -ApplyStatus $(if ($ApplyAfterStage) { 'DRYRUN' } else { 'N/A' }) `
            -Detail "Would SCP $xmlLeaf to ${sshTarget}:${remotePath}$applyNote"
        continue
    }

    # Stage via SCP
    scp -o StrictHostKeyChecking=accept-new "$xmlPath" "${sshTarget}:${remotePath}"
    if ($LASTEXITCODE -ne 0) {
        Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP $ip `
            -ConfigFile $xmlLeaf -StageStatus 'ERROR' -ApplyStatus 'N/A' `
            -Detail "SCP failed (exit code $LASTEXITCODE)"
        continue
    }

    $applyStatus = 'N/A'
    $detail      = "Staged to ${sshTarget}:${remotePath}"

    # Apply and reboot (optional)
    if ($ApplyAfterStage) {
        $applyCmd = "cp /cf/conf/config.xml /cf/conf/config.xml.pre-restore; cp $remotePath /cf/conf/config.xml; reboot"
        ssh "$sshTarget" "$applyCmd"
        if ($LASTEXITCODE -eq 0) {
            $applyStatus = 'SUCCESS'
            $detail      += '; applied and rebooting'
        } else {
            $applyStatus = 'ERROR'
            $detail      += "; apply failed (exit code $LASTEXITCODE)"
        }
    }

    Add-Result -RouterKey $routerKey -VMName $vmName -MgmtIP $ip `
        -ConfigFile $xmlLeaf -StageStatus 'SUCCESS' -ApplyStatus $applyStatus -Detail $detail
}

# --- Summary ---
$success     = ($results | Where-Object { $_.StageStatus -eq 'SUCCESS' }).Count
$errors      = ($results | Where-Object { $_.StageStatus -eq 'ERROR'   }).Count
$dryrunCount = ($results | Where-Object { $_.StageStatus -eq 'DRYRUN'  }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total Routers : $routerCount" -ForegroundColor White
if ($DryRun) {
    Write-Host "  Would push    : $dryrunCount" -ForegroundColor Cyan
} else {
    Write-Host "  Success       : $success" -ForegroundColor Green
    Write-Host "  Errors        : $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'White' })
    if (-not $ApplyAfterStage) {
        Write-Host "`n  Configs staged only. Restore via pfSense WebGUI or rerun with -ApplyAfterStage." -ForegroundColor Yellow
    }
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
