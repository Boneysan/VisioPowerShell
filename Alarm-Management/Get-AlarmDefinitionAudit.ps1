<#
.SYNOPSIS
    Audits all alarm definitions in vCenter for configuration, triggers, and actions.

.DESCRIPTION
    Enumerates all alarm definitions (both default and custom) defined at the vCenter,
    datacenter, cluster, and host levels. Reports alarm name, target entity type,
    trigger expressions, configured actions (email, SNMP, script), enabled state,
    and whether the alarm has been acknowledged/global. Helps identify misconfigured
    or disabled alarms that may leave gaps in monitoring coverage.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Path to export the alarm definition audit as CSV.

.PARAMETER IncludeDisabled
    Optional switch. Include disabled alarm definitions in the report.

.PARAMETER EntityType
    Optional. Filter to alarms for a specific entity type (e.g., VirtualMachine, HostSystem).

.EXAMPLE
    .\Get-AlarmDefinitionAudit.ps1 -OutputFile "alarm-definitions.csv"
    Exports all enabled alarm definitions.

.EXAMPLE
    .\Get-AlarmDefinitionAudit.ps1 -IncludeDisabled -EntityType HostSystem -OutputFile "host-alarms.csv"
    Exports all host alarms including disabled ones.

.OUTPUTS
    CSV with columns: AlarmName, Description, EntityType, Enabled, ActionCount,
    EmailActions, SnmpActions, ScriptActions, TriggerSummary, DefinedAt

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to alarm definitions

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
    [switch]$IncludeDisabled,

    [Parameter(Mandatory=$false)]
    [string]$EntityType
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

Write-Host "Enumerating alarm definitions..." -ForegroundColor Cyan

$si         = Get-View ServiceInstance
$alarmMgr   = Get-View $si.Content.AlarmManager
$rootFolder = Get-View $si.Content.RootFolder

$alarmMoRefs = $alarmMgr.GetAlarm($rootFolder.MoRef)
Write-Host "  Found $($alarmMoRefs.Count) alarm definitions" -ForegroundColor Yellow

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($alarmRef in $alarmMoRefs) {
    try {
        $alarm = Get-View -Id $alarmRef -Property Info

        $info = $alarm.Info
        $enabled = -not $info.Enabled.Equals($false)

        if (-not $IncludeDisabled -and -not $enabled) { continue }
        if ($EntityType -and $info.Expression.PSObject.Properties['EntityType'] -and $info.Expression.EntityType -ne $EntityType) { continue }

        # Count actions by type
        $emailActions  = 0
        $snmpActions   = 0
        $scriptActions = 0
        $actionCount   = 0

        if ($info.Action -and $info.Action.PSObject.Properties['ActionSpec']) {
            foreach ($actionSpec in $info.Action.ActionSpec) {
                $actionCount++
                $actionType = $actionSpec.Action.GetType().Name
                if ($actionType -match 'SendEmailAction')   { $emailActions++ }
                if ($actionType -match 'SendSNMPAction')    { $snmpActions++  }
                if ($actionType -match 'RunScriptAction')   { $scriptActions++ }
            }
        }

        # Target entity type
        $targetEntityType = 'Any'
        if ($info.Expression -and $info.Expression.PSObject.Properties['EntityType']) {
            $targetEntityType = $info.Expression.EntityType
        }

        # Trigger summary: first expression detail
        $triggerSummary = 'N/A'
        if ($info.Expression) {
            $exprType = $info.Expression.GetType().Name
            if ($exprType -match 'AndAlarmExpression' -or $exprType -match 'OrAlarmExpression') {
                $expCount = if ($info.Expression.Expression) { $info.Expression.Expression.Count } else { 0 }
                $triggerSummary = "$exprType ($expCount sub-expressions)"
            }
            else {
                $triggerSummary = $exprType
            }
        }

        # Where it's defined
        $definedAt = 'vCenter'
        if ($info.Spec -and $info.Spec.PSObject.Properties['Entity']) {
            $entity = Get-View -Id $info.Spec.Entity -Property Name -ErrorAction SilentlyContinue
            if ($entity) { $definedAt = "$($info.Spec.Entity.Type): $($entity.Name)" }
        }
        if ($alarm.MoRef.Value -like 'alarm-default*') { $definedAt = 'Default (VMware)' }

        $results.Add([PSCustomObject]@{
            AlarmName     = $info.Name
            Description   = $info.Description
            EntityType    = $targetEntityType
            Enabled       = $enabled
            ActionCount   = $actionCount
            EmailActions  = $emailActions
            SnmpActions   = $snmpActions
            ScriptActions = $scriptActions
            TriggerSummary= $triggerSummary
            DefinedAt     = $definedAt
            AlarmMoRef    = $alarmRef.Value
        })
    }
    catch {
        # Skip inaccessible alarm definitions
    }
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$results | Export-Csv -Path $OutputFile -NoTypeInformation

$enabled   = ($results | Where-Object { $_.Enabled -eq $true  }).Count
$disabled  = ($results | Where-Object { $_.Enabled -eq $false }).Count
$noActions = ($results | Where-Object { $_.Enabled -eq $true -and $_.ActionCount -eq 0 }).Count

Write-Host "`n=== Alarm Definition Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Total Definitions  : $($results.Count)"  -ForegroundColor White
Write-Host "  Enabled            : $enabled"             -ForegroundColor Green
Write-Host "  Disabled           : $disabled"            -ForegroundColor $(if ($disabled -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Enabled/No Actions : $noActions"           -ForegroundColor $(if ($noActions -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Output             : $OutputFile"          -ForegroundColor White
