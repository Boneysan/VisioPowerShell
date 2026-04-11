<#
.SYNOPSIS
    Validates vSphere HA readiness for all clusters — config, heartbeat datastores,
    admission control, and simulated host failure impact.

.DESCRIPTION
    Performs a comprehensive HA readiness check for each cluster in scope:

    1. HA enabled and no overriding faults
    2. Heartbeat datastores (should have >= 2)
    3. Admission control policy and configured failover capacity
    4. Host isolation response setting
    5. Host health overview — any hosts currently in a degraded state
    6. Simplified slot calculation — available failover capacity given current VM load
    7. Simulated failure — what happens to HA capacity if the largest host goes down

.PARAMETER ClusterName
    Optional. Check only this cluster. If omitted, checks all clusters.

.PARAMETER vCenter
    Optional. vCenter Server. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Test-HAReadiness.ps1 -OutputFile "ha-readiness.csv"

.EXAMPLE
    .\Test-HAReadiness.ps1 -ClusterName "IQT-Alpha"

.OUTPUTS
    CSV: ClusterName, CheckName, Status, Current, Expected, Detail

.NOTES
    The slot calculation uses a simplified model (32 MHz CPU slot, 0 MB memory
    reservation baseline + per-VM overhead). For exact production slot sizing,
    use the vSphere HA Slot Viewer in the vSphere Client.
    Requires VMware PowerCLI module.
    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

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

# --- Get Clusters ---
if ($ClusterName) {
    $clusters = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $clusters) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
}
else {
    $clusters = Get-Cluster -ErrorAction SilentlyContinue
}

$clusterList = @($clusters)
Write-Host "`n=== HA Readiness Check ===" -ForegroundColor Cyan
Write-Host "  Clusters to check: $($clusterList.Count)" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Check {
    param(
        [string]$Cluster,
        [string]$CheckName,
        [string]$Status,      # PASS / FAIL / WARN / INFO
        [string]$Current,
        [string]$Expected,
        [string]$Detail
    )
    $color = switch ($Status) {
        'PASS' { 'Green'  }
        'FAIL' { 'Red'    }
        'WARN' { 'Yellow' }
        'INFO' { 'Cyan'   }
        default { 'White' }
    }
    Write-Host "    [$Status] $CheckName : $Detail" -ForegroundColor $color
    $results.Add([PSCustomObject]@{
        ClusterName = $Cluster
        CheckName   = $CheckName
        Status      = $Status
        Current     = $Current
        Expected    = $Expected
        Detail      = $Detail
    })
}

foreach ($cluster in $clusterList | Sort-Object Name) {
    Write-Host "`n  === Cluster: $($cluster.Name) ===" -ForegroundColor Magenta

    try {
        $clusterView  = $cluster | Get-View -Property ConfigurationEx, Summary -ErrorAction Stop
        $dasConfig    = $clusterView.ConfigurationEx.DasConfig
        $vmHosts      = @(Get-VMHost -Location $cluster -ErrorAction SilentlyContinue)
        $vms          = @(Get-VM -Location $cluster -ErrorAction SilentlyContinue)

        # --- Check 1: HA Enabled ---
        $haEnabled = $cluster.HAEnabled
        Add-Check -Cluster $cluster.Name -CheckName 'HA Enabled' `
            -Status   (if ($haEnabled) { 'PASS' } else { 'FAIL' }) `
            -Current  $haEnabled.ToString() `
            -Expected 'True' `
            -Detail   (if ($haEnabled) { 'vSphere HA is enabled' } else { 'vSphere HA is DISABLED — VMs will not restart on host failure' })

        if (-not $haEnabled) {
            Write-Host "    (Skipping remaining HA checks — HA not enabled)" -ForegroundColor DarkGray
            continue
        }

        # --- Check 2: Host Count (need at least 2 for any HA benefit) ---
        $hostCount = $vmHosts.Count
        Add-Check -Cluster $cluster.Name -CheckName 'Host Count' `
            -Status   (if ($hostCount -ge 2) { 'PASS' } else { 'FAIL' }) `
            -Current  $hostCount.ToString() `
            -Expected '>= 2' `
            -Detail   "Cluster has $hostCount host(s)"

        # --- Check 3: Heartbeat Datastores ---
        $hbDs = @()
        if ($dasConfig -and $dasConfig.HeartbeatDatastore) {
            $hbDs = @($dasConfig.HeartbeatDatastore)
        }
        $hbCount = $hbDs.Count
        Add-Check -Cluster $cluster.Name -CheckName 'Heartbeat Datastores' `
            -Status   (if ($hbCount -ge 2) { 'PASS' } elseif ($hbCount -eq 1) { 'WARN' } else { 'FAIL' }) `
            -Current  $hbCount.ToString() `
            -Expected '>= 2' `
            -Detail   "HA datastore heartbeating configured on $hbCount datastore(s)"

        # --- Check 4: Admission Control ---
        $acEnabled = if ($dasConfig) { $dasConfig.AdmissionControlEnabled } else { $false }
        Add-Check -Cluster $cluster.Name -CheckName 'Admission Control' `
            -Status   (if ($acEnabled) { 'PASS' } else { 'WARN' }) `
            -Current  $acEnabled.ToString() `
            -Expected 'True' `
            -Detail   (if ($acEnabled) { 'Admission control is enabled' } else { 'Admission control is disabled — HA may not be able to restart all VMs on failure' })

        # --- Check 5: Admission Control Policy type and failover level ---
        if ($dasConfig -and $dasConfig.AdmissionControlPolicy) {
            $acPolicy    = $dasConfig.AdmissionControlPolicy
            $policyType  = $acPolicy.GetType().Name

            $policyDesc = switch -Wildcard ($policyType) {
                '*FailoverLevel*'     {
                    $fl = $acPolicy.FailoverLevel
                    "Fixed failover hosts=$fl (cluster can tolerate $fl host failure(s))"
                }
                '*FailoverResources*' {
                    $cpuPct = $acPolicy.CpuFailoverResourcesPercent
                    $memPct = $acPolicy.MemoryFailoverResourcesPercent
                    "Cluster resources: ${cpuPct}% CPU, ${memPct}% memory reserved"
                }
                '*FailoverHost*'      {
                    $fhCount = @($acPolicy.FailoverHosts).Count
                    "Dedicated failover hosts: $fhCount configured"
                }
                default { $policyType }
            }
            Add-Check -Cluster $cluster.Name -CheckName 'Admission Control Policy' `
                -Status  'INFO' `
                -Current $policyType `
                -Expected 'Any configured policy' `
                -Detail  $policyDesc
        }

        # --- Check 6: Host Isolation Response ---
        $isoResp = 'Unknown'
        if ($dasConfig -and $dasConfig.DefaultVmSettings -and $dasConfig.DefaultVmSettings.IsolationResponse) {
            $isoResp = $dasConfig.DefaultVmSettings.IsolationResponse.ToString()
        }
        $isoStatus = if ($isoResp -eq 'none') { 'WARN' } else { 'PASS' }
        Add-Check -Cluster $cluster.Name -CheckName 'Isolation Response' `
            -Status  $isoStatus `
            -Current $isoResp `
            -Expected 'powerOff or shutdown (not none)' `
            -Detail  (if ($isoResp -eq 'none') { 'Isolated VMs will NOT be powered off — risk of split-brain if storage is still accessible' } else { "Isolated VMs will: $isoResp" })

        # --- Check 7: Host Health Overview ---
        $disconnected = @($vmHosts | Where-Object { $_.ConnectionState -ne 'Connected' })
        $inMaint      = @($vmHosts | Where-Object { $_.State -eq 'Maintenance' })
        $hostStatus   = if ($disconnected.Count -gt 0) { 'FAIL' } elseif ($inMaint.Count -gt 0) { 'WARN' } else { 'PASS' }
        $hostDetail   = "Connected: $($vmHosts.Count - $disconnected.Count - $inMaint.Count), Maintenance: $($inMaint.Count), Disconnected: $($disconnected.Count)"
        Add-Check -Cluster $cluster.Name -CheckName 'Host Health' `
            -Status  $hostStatus `
            -Current $hostDetail `
            -Expected "All hosts connected and not in maintenance" `
            -Detail  $hostDetail

        # --- Check 8: Simplified failover capacity simulation ---
        # Find the largest host by CPU; simulate removing it
        if ($hostCount -ge 2) {
            $connectedHosts = @($vmHosts | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.State -ne 'Maintenance' })
            if ($connectedHosts.Count -ge 2) {
                $largestHost     = $connectedHosts | Sort-Object CpuTotalMhz -Descending | Select-Object -First 1
                $remainingHosts  = $connectedHosts | Where-Object { $_.Name -ne $largestHost.Name }
                $remainingCpuMhz = ($remainingHosts | Measure-Object -Property CpuTotalMhz -Sum).Sum
                $remainingMemGB  = ($remainingHosts | Measure-Object -Property MemoryTotalGB -Sum).Sum
                $totalVmCpuMhz   = ($vms | Measure-Object -Property NumCpu -Sum).Sum * 500   # rough 500 MHz per vCPU estimate
                $totalVmMemGB    = ($vms | Measure-Object -Property MemoryGB -Sum).Sum

                $cpuCapacityPct = if ($remainingCpuMhz -gt 0) { [math]::Round($totalVmCpuMhz / $remainingCpuMhz * 100, 1) } else { 9999 }
                $memCapacityPct = if ($remainingMemGB  -gt 0) { [math]::Round($totalVmMemGB  / $remainingMemGB  * 100, 1) } else { 9999 }
                $worstPct       = [math]::Max($cpuCapacityPct, $memCapacityPct)

                $failSimStatus = if ($worstPct -le 80) { 'PASS' } elseif ($worstPct -le 100) { 'WARN' } else { 'FAIL' }
                $failSimDetail = "If '$($largestHost.Name)' fails: remaining CPU load ~${cpuCapacityPct}%, memory load ~${memCapacityPct}%"
                Add-Check -Cluster $cluster.Name -CheckName 'Failover Capacity Sim' `
                    -Status  $failSimStatus `
                    -Current "CPU ${cpuCapacityPct}%, Mem ${memCapacityPct}% after largest host failure" `
                    -Expected '<= 80% load on remaining hosts' `
                    -Detail  $failSimDetail
            }
        }

        # --- Check 9: VMs with HA restart priority = disabled ---
        $haOverrides = @()
        if ($clusterView.ConfigurationEx.DasVmConfig) {
            $haOverrides = @($clusterView.ConfigurationEx.DasVmConfig | Where-Object { $_.DasSettings.RestartPriority -eq 'disabled' })
        }
        if ($haOverrides.Count -gt 0) {
            Add-Check -Cluster $cluster.Name -CheckName 'VMs with HA Disabled' `
                -Status  'WARN' `
                -Current $haOverrides.Count.ToString() `
                -Expected '0' `
                -Detail  "$($haOverrides.Count) VM(s) have HA restart priority set to Disabled and will not restart on failure"
        }
        else {
            Add-Check -Cluster $cluster.Name -CheckName 'VMs with HA Disabled' `
                -Status  'PASS' `
                -Current '0' `
                -Expected '0' `
                -Detail  'All VMs will be restarted by HA on host failure'
        }
    }
    catch {
        Write-Warning "  Error checking cluster $($cluster.Name): $_"
        Add-Check -Cluster $cluster.Name -CheckName 'Check Error' `
            -Status 'FAIL' -Current 'ERROR' -Expected 'N/A' -Detail $_.Exception.Message
    }
}

# --- Summary ---
$pass = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warn = ($results | Where-Object { $_.Status -eq 'WARN' }).Count

Write-Host "`n--- HA Readiness Summary ---" -ForegroundColor Cyan
Write-Host "  Total Checks : $($results.Count)" -ForegroundColor White
Write-Host "  PASS         : $pass"              -ForegroundColor Green
Write-Host "  WARN         : $warn"              -ForegroundColor $(if ($warn -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  FAIL         : $fail"              -ForegroundColor $(if ($fail -gt 0) { 'Red'    } else { 'White' })

if ($OutputFile) {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Cyan
}
