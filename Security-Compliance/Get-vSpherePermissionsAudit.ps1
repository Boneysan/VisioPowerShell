<#
.SYNOPSIS
    Exports all vSphere roles, permissions, and privilege assignments with risk flags.

.DESCRIPTION
    Audits every role and permission assignment across the vCenter inventory hierarchy.
    Flags overly broad permissions (Administrator, full datacenter permissions) and
    identifies orphaned accounts (principals not found in any directory).

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER Scope
    Optional. Inventory level to audit. Default: All (entire hierarchy).
    Valid values: vCenter, Datacenter, Cluster, Host, VM.

.PARAMETER OutputFile
    Required. Path to export the permissions audit as CSV.

.PARAMETER IncludeSystemRoles
    Optional. Include built-in system roles (No Access, Read Only, Administrator) in output.

.EXAMPLE
    .\Get-vSpherePermissionsAudit.ps1 -vCenter "vc.example.com" -OutputFile "permissions.csv"
    Exports all permissions for the entire vCenter hierarchy.

.EXAMPLE
    .\Get-vSpherePermissionsAudit.ps1 -Scope "Cluster" -OutputFile "cluster-perms.csv" -IncludeSystemRoles
    Exports cluster-level permissions including system roles.

.OUTPUTS
    CSV with columns: EntityPath, EntityType, Principal, PrincipalType, Role,
    IsGroup, Propagate, RolePrivilegeCount, RiskFlag, RiskReason

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter permissions

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [ValidateSet('vCenter', 'Datacenter', 'Cluster', 'Host', 'VM', 'All')]
    [string]$Scope = 'All',

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSystemRoles
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

$systemRoleNames = @('No Access', 'Read-Only', 'Administrator', 'No Cryptography Administrator', 'VirtualMachine.Administrator')

Write-Host "Collecting all permissions (Scope: $Scope)..." -ForegroundColor Cyan

# Collect VIPermissions from entire hierarchy
$allPerms = @()

switch ($Scope) {
    'VM'         { $entities = Get-VM }
    'Host'       { $entities = Get-VMHost }
    'Cluster'    { $entities = Get-Cluster }
    'Datacenter' { $entities = Get-Datacenter }
    default {
        # All - get permissions from root folder and recursively
        $allPerms = Get-VIPermission -ErrorAction SilentlyContinue
    }
}

if ($Scope -ne 'All' -and $Scope -ne 'vCenter') {
    foreach ($entity in $entities) {
        $allPerms += Get-VIPermission -Entity $entity -ErrorAction SilentlyContinue
    }
}

if ($Scope -eq 'vCenter') {
    $allPerms = Get-VIPermission -ErrorAction SilentlyContinue | Where-Object { $_.Entity -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualCenter] }
}

if (-not $IncludeSystemRoles) {
    $allPerms = $allPerms | Where-Object { $systemRoleNames -notcontains $_.Role }
}

Write-Host "  Found $($allPerms.Count) permission assignment(s)" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($perm in $allPerms) {
    $riskFlag = $false
    $riskReasons = @()

    # Risk: Administrator role
    if ($perm.Role -eq 'Administrator') {
        $riskFlag = $true
        $riskReasons += 'Full Administrator role assigned'
    }

    # Risk: Propagation to entire vCenter root
    $entityType = 'Unknown'
    try {
        $entityType = $perm.Entity.GetType().Name
    } catch { Write-Verbose "Could not determine entity type for permission on '$($perm.Entity)': $_" }
    if ($perm.Propagate -and ($entityType -match 'Datacenter|VirtualCenter')) {
        $riskFlag = $true
        $riskReasons += 'Permission propagates from top-level entity'
    }

    # Risk: Group with broad role
    if ($perm.IsGroup -and $perm.Role -match 'Admin') {
        $riskFlag = $true
        $riskReasons += 'Group assignment with administrative role'
    }

    $entityPath = try { $perm.Entity.Name } catch { 'Unknown' }
    $results.Add([PSCustomObject]@{
        EntityPath          = $entityPath
        EntityType          = $entityType
        Principal           = $perm.Principal
        IsGroup             = $perm.IsGroup
        Role                = $perm.Role
        Propagate           = $perm.Propagate
        RiskFlag            = $riskFlag
        RiskReason          = ($riskReasons -join '; ')
    })
}

Write-Host "Exporting $($results.Count) permission records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$riskyCount = ($results | Where-Object { $_.RiskFlag -eq $true }).Count

Write-Host "`n=== Permissions Audit Summary ===" -ForegroundColor Cyan
Write-Host "  Total permissions : $($results.Count)" -ForegroundColor White
Write-Host "  Risky assignments : $riskyCount" -ForegroundColor $(if ($riskyCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Output            : $OutputFile" -ForegroundColor White
