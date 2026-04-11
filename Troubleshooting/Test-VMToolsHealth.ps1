<#
.SYNOPSIS
    Audits VMware Tools health across all VMs — version, running status, and upgrade needs.

.DESCRIPTION
    Checks VMware Tools installation status, running status, version currency, and upgrade
    policy for every VM in scope. Identifies VMs where Tools is not installed, not running,
    outdated, blacklisted, or otherwise in a non-optimal state. Useful for ensuring guest
    OS visibility and manageability across a cyber range.

.PARAMETER ClusterName
    Optional. Restrict audit to VMs in this cluster.

.PARAMETER FolderName
    Optional. Restrict audit to VMs in this vSphere folder.

.PARAMETER IncludePoweredOff
    Optional switch. Also evaluate powered-off VMs. Note: powered-off VMs will always show
    ToolsRunningStatus = guestToolsNotRunning, which is expected behaviour.

.PARAMETER vCenter
    Optional. vCenter Server to connect to. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Test-VMToolsHealth.ps1 -ClusterName "IQT-Alpha" -OutputFile "tools-health.csv"

.EXAMPLE
    .\Test-VMToolsHealth.ps1 -FolderName "IR-Dev" -IncludePoweredOff

.OUTPUTS
    CSV: VMName, Cluster, VMHost, HostESXiVersion, PowerState, ToolsStatus,
         ToolsRunningStatus, ToolsVersion, ToolsVersionStatus, UpgradePolicy,
         Assessment, Recommendation

.NOTES
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$FolderName,

    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# --- Connection ---
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
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter."
        exit 1
    }
}

# --- Get VMs ---
if ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $vms = Get-VM -Location $cluster
}
elseif ($FolderName) {
    $folder = Get-Folder -Name $FolderName -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $folder) { Write-Error "Folder '$FolderName' not found."; exit 1 }
    $vms = Get-VM -Location $folder
}
else {
    $vms = Get-VM
}

if (-not $IncludePoweredOff) {
    $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
}

$vmList = @($vms)
Write-Host "`n=== VMware Tools Health Audit ===" -ForegroundColor Cyan
Write-Host "  Scope    : $(if ($ClusterName) { $ClusterName } elseif ($FolderName) { $FolderName } else { 'All VMs' })" -ForegroundColor White
Write-Host "  VM Count : $($vmList.Count)" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$vmCount = 0

foreach ($vm in $vmList | Sort-Object Name) {
    $vmCount++
    Write-Host "  [$vmCount/$($vmList.Count)] $($vm.Name)..." -ForegroundColor Gray

    try {
        # ExtensionData.Guest is populated by default in Get-VM; null guard for never-booted VMs
        $guestInfo    = $vm.ExtensionData.Guest
        $toolsConfig  = if ($vm.ExtensionData.Config) { $vm.ExtensionData.Config.Tools } else { $null }

        $toolsStatus        = if ($guestInfo) { $guestInfo.ToolsStatus.ToString()        } else { 'toolsNotInstalled' }
        $toolsRunning       = if ($guestInfo) { $guestInfo.ToolsRunningStatus.ToString() } else { 'guestToolsNotRunning' }
        $toolsVersion       = if ($guestInfo) { $guestInfo.ToolsVersion                 } else { '0' }
        $toolsVersionStatus = if ($guestInfo) { $guestInfo.ToolsVersionStatus.ToString() } else { 'guestToolsNotInstalled' }
        $upgradePolicy      = if ($toolsConfig) { $toolsConfig.ToolsUpgradePolicy        } else { 'unknown' }
        $hostEsxiVersion    = $vm.VMHost.Version

        # --- Classify assessment ---
        $assessment     = 'OK'
        $recommendation = 'No action required'

        if ($toolsStatus -eq 'toolsNotInstalled' -or $toolsVersionStatus -eq 'guestToolsNotInstalled') {
            $assessment     = 'NOT_INSTALLED'
            $recommendation = 'Install VMware Tools on this VM'
        }
        elseif ($toolsVersionStatus -eq 'guestToolsBlacklisted') {
            $assessment     = 'BLACKLISTED'
            $recommendation = 'Upgrade immediately — this Tools version is blacklisted by VMware'
        }
        elseif ($toolsStatus -eq 'toolsOld' -or
                $toolsVersionStatus -eq 'guestToolsNeedUpgrade' -or
                $toolsVersionStatus -eq 'guestToolsTooOld' -or
                $toolsVersionStatus -eq 'guestToolsSupportedOld') {
            $assessment     = 'OUTDATED'
            $recommendation = 'Upgrade VMware Tools to current version'
        }
        elseif ($toolsVersionStatus -eq 'guestToolsTooNew') {
            $assessment     = 'TOO_NEW'
            $recommendation = 'Tools version newer than ESXi host supports — verify compatibility'
        }
        elseif ($toolsStatus -eq 'toolsUnmanaged' -or $toolsVersionStatus -eq 'guestToolsUnmanaged') {
            $assessment     = 'UNMANAGED'
            $recommendation = 'Open-VM-Tools or third-party Tools detected — manual update management required'
        }
        elseif ($vm.PowerState -eq 'PoweredOn' -and $toolsRunning -eq 'guestToolsNotRunning') {
            $assessment     = 'NOT_RUNNING'
            $recommendation = 'Tools installed but not running — check guest OS or restart Tools service'
        }

        $results.Add([PSCustomObject]@{
            VMName              = $vm.Name
            Cluster             = $vm.VMHost.Parent.Name
            VMHost              = $vm.VMHost.Name
            HostESXiVersion     = $hostEsxiVersion
            PowerState          = $vm.PowerState.ToString()
            ToolsStatus         = $toolsStatus
            ToolsRunningStatus  = $toolsRunning
            ToolsVersion        = $toolsVersion
            ToolsVersionStatus  = $toolsVersionStatus
            UpgradePolicy       = $upgradePolicy
            Assessment          = $assessment
            Recommendation      = $recommendation
        })

        if ($assessment -ne 'OK') {
            $color = switch ($assessment) {
                'NOT_INSTALLED' { 'Red'     }
                'BLACKLISTED'   { 'Red'     }
                'OUTDATED'      { 'Yellow'  }
                'NOT_RUNNING'   { 'Yellow'  }
                'TOO_NEW'       { 'Magenta' }
                'UNMANAGED'     { 'DarkGray'}
                default         { 'White'   }
            }
            Write-Host "    [$assessment] v$toolsVersion  $toolsVersionStatus" -ForegroundColor $color
        }
    }
    catch {
        Write-Warning "  Could not assess $($vm.Name): $_"
        $results.Add([PSCustomObject]@{
            VMName = $vm.Name; Cluster = ''; VMHost = ''; HostESXiVersion = ''
            PowerState = $vm.PowerState.ToString(); ToolsStatus = 'ERROR'
            ToolsRunningStatus = ''; ToolsVersion = ''; ToolsVersionStatus = ''
            UpgradePolicy = ''; Assessment = 'ERROR'; Recommendation = $_.Exception.Message
        })
    }
}

# --- Summary ---
$ok           = ($results | Where-Object { $_.Assessment -eq 'OK'           }).Count
$notInstalled = ($results | Where-Object { $_.Assessment -eq 'NOT_INSTALLED'}).Count
$outdated     = ($results | Where-Object { $_.Assessment -eq 'OUTDATED'     }).Count
$notRunning   = ($results | Where-Object { $_.Assessment -eq 'NOT_RUNNING'  }).Count
$blacklisted  = ($results | Where-Object { $_.Assessment -eq 'BLACKLISTED'  }).Count
$unmanaged    = ($results | Where-Object { $_.Assessment -eq 'UNMANAGED'    }).Count
$tooNew       = ($results | Where-Object { $_.Assessment -eq 'TOO_NEW'      }).Count

Write-Host "`n--- Tools Health Summary ---" -ForegroundColor Cyan
Write-Host "  Total Checked : $($results.Count)" -ForegroundColor White
Write-Host "  OK            : $ok"               -ForegroundColor Green
Write-Host "  Not Installed : $notInstalled"     -ForegroundColor $(if ($notInstalled -gt 0) { 'Red'     } else { 'White' })
Write-Host "  Outdated      : $outdated"         -ForegroundColor $(if ($outdated     -gt 0) { 'Yellow'  } else { 'White' })
Write-Host "  Not Running   : $notRunning"       -ForegroundColor $(if ($notRunning   -gt 0) { 'Yellow'  } else { 'White' })
Write-Host "  Blacklisted   : $blacklisted"      -ForegroundColor $(if ($blacklisted  -gt 0) { 'Red'     } else { 'White' })
Write-Host "  Unmanaged     : $unmanaged"        -ForegroundColor $(if ($unmanaged    -gt 0) { 'DarkGray'} else { 'White' })
Write-Host "  Too New       : $tooNew"           -ForegroundColor $(if ($tooNew       -gt 0) { 'Magenta' } else { 'White' })

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}
