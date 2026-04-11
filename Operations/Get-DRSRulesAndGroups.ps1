<#
.SYNOPSIS
    Exports all DRS rules and DRS groups with member lists and status.

.DESCRIPTION
    Collects every DRS rule (VM-to-VM affinity, VM-to-VM anti-affinity, VM-to-host)
    and DRS group (VM groups, host groups) for the specified cluster. Reports rule
    type, enabled status, mandatory flag, and member VM/host names.

.PARAMETER ClusterName
    Optional. Cluster to report. If not specified, reports all clusters.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Required. Base path for CSV output (two CSVs will be created).

.EXAMPLE
    .\Get-DRSRulesAndGroups.ps1 -ClusterName "Production" -OutputFile "drs-rules.csv"
    Exports DRS rules for the Production cluster.

.OUTPUTS
    - OutputFile               : DRS rules (name, type, VMs, enabled, mandatory)
    - <base>-groups.csv        : DRS groups (name, type, members)

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to cluster DRS configuration

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
    $clusters = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $clusters) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
}
else {
    $clusters = Get-Cluster
}

$basePath   = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$ext        = [System.IO.Path]::GetExtension($OutputFile)
$dir        = [System.IO.Path]::GetDirectoryName($OutputFile)
if (-not $dir) { $dir = '.' }
$groupsFile = Join-Path $dir ($basePath + '-groups' + $ext)

$ruleResults  = [System.Collections.Generic.List[PSCustomObject]]::new()
$groupResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($cluster in $clusters) {
    Write-Host "  Processing: $($cluster.Name)..." -ForegroundColor White

    try {
        $clusterView = $cluster | Get-View -Property ConfigurationEx
        $cfgEx       = $clusterView.ConfigurationEx

        # Build VM and Host lookup (MoRef -> Name)
        $vmLookup = @{}
        Get-VM -Location $cluster | ForEach-Object { $vmLookup[$_.ExtensionData.MoRef.Value] = $_.Name }
        $hostLookup = @{}
        Get-VMHost -Location $cluster | ForEach-Object { $hostLookup[$_.ExtensionData.MoRef.Value] = $_.Name }

        # DRS Rules
        foreach ($rule in $cfgEx.Rule) {
            $ruleType = $rule.GetType().Name
            $vmNames  = @()
            $hostNames = @()

            if ($rule -is [VMware.Vim.ClusterAffinityRuleSpec] -or
                $rule -is [VMware.Vim.ClusterAntiAffinityRuleSpec]) {
                $vmNames = @($rule.Vm | ForEach-Object { if ($vmLookup[$_.Value]) { $vmLookup[$_.Value] } else { $_.Value } })
            }
            elseif ($rule -is [VMware.Vim.ClusterVmHostRuleInfo]) {
                # VM group + host group rule
                $ruleType = 'VmHostAffinity'
                $vmNames  = @($rule.VmGroupName)
                $hostNames= @($rule.AffineHostGroupName, $rule.AntiAffineHostGroupName) | Where-Object { $_ }
            }

            $ruleResults.Add([PSCustomObject]@{
                ClusterName = $cluster.Name
                RuleName    = $rule.Name
                RuleType    = $ruleType
                Enabled     = $rule.Enabled
                Mandatory   = if ($rule.PSObject.Properties['Mandatory']) { $rule.Mandatory } else { 'N/A' }
                VMs         = $vmNames -join ', '
                HostGroups  = $hostNames -join ', '
            })
        }

        # DRS Groups
        foreach ($group in $cfgEx.Group) {
            $groupType = $group.GetType().Name
            $members   = @()

            if ($group -is [VMware.Vim.ClusterVmGroup]) {
                $members = @($group.Vm | ForEach-Object { if ($vmLookup[$_.Value]) { $vmLookup[$_.Value] } else { $_.Value } })
            }
            elseif ($group -is [VMware.Vim.ClusterHostGroup]) {
                $members = @($group.Host | ForEach-Object { if ($hostLookup[$_.Value]) { $hostLookup[$_.Value] } else { $_.Value } })
            }

            $groupTypeClean = $groupType -replace 'Cluster', ''
            $groupResults.Add([PSCustomObject]@{
                ClusterName = $cluster.Name
                GroupName   = $group.Name
                GroupType   = $groupTypeClean
                MemberCount = $members.Count
                Members     = $members -join ', '
            })
        }
    }
    catch {
        Write-Warning "Error processing cluster $($cluster.Name): $_"
    }
}

$ruleResults  | Export-Csv -Path $OutputFile  -NoTypeInformation
$groupResults | Export-Csv -Path $groupsFile  -NoTypeInformation

Write-Host "`n=== DRS Rules and Groups Summary ===" -ForegroundColor Cyan
Write-Host "  Clusters  : $($clusters.Count)" -ForegroundColor White
Write-Host "  Rules     : $($ruleResults.Count)" -ForegroundColor White
Write-Host "  Groups    : $($groupResults.Count)" -ForegroundColor White
Write-Host "  Rules out : $OutputFile" -ForegroundColor White
Write-Host "  Groups out: $groupsFile" -ForegroundColor White
