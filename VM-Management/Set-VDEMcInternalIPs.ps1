#Requires -Version 5.1
<#
.SYNOPSIS
    Sets static IP configuration on the mc-internal NIC (eth_1) for all VDE-* client VMs in IQT-CL-DT2.

.DESCRIPTION
    Targets the guest adapter that corresponds to the VM NIC connected to the selected
    mc-internal portgroup. Verifies the current IPv4 address and default gateway on that
    adapter, then corrects them if they do not match the expected values.

    Expected configuration per terraform.tfvars (04_clients):
      eth_0 : VDE network        -> 10.99.10.<ip_start>/24  (not touched by this script)
      eth_1 : mc-internal        -> 10.20.0.<ip_start>/24   (fixed by this script)
              default gateway    -> 10.20.0.1

    IP map (conflict-free, starting at .100 to avoid Manticore infrastructure):
      Manticore reserved: .1 (GW), .10 (DNS), .11-.16/.18 (servers), .21-.25 (workstations)
      VDE-STU01..25 = 10.20.0.100..124
      VDE-INS01..10 = 10.20.0.125..134
      VDE-ENG01..03 = 10.20.0.135..137

.PARAMETER vCenter
    vCenter server address. Defaults to c1r1r12-vcsa-01.texnet1.net.

.PARAMETER EventName
    Event name suffix appended to VM names. Defaults to CLDT2.

.PARAMETER NetworkName
    vSphere network/portgroup name to target (e.g. IQT-CL-DT2). Only VMs with a NIC
    connected to this network will be processed. Supports wildcards (e.g. IQT-CL-*).
    If not provided, the script will prompt for it.

.PARAMETER OutputFile
    Optional. Path to export results as CSV.

.EXAMPLE
    .\Set-VDEMcInternalIPs.ps1
    Prompts for credentials and verifies/fixes mc-internal IP and gateway on all VDE-* VMs.

.EXAMPLE
    .\Set-VDEMcInternalIPs.ps1 -NetworkName "IQT-CL-DT2" -OutputFile "mc-internal-fix.csv"
    Only processes VMs that have a NIC connected to the IQT-CL-DT2 portgroup and
    verifies/fixes the matching guest adapter configuration.

.EXAMPLE
    .\Set-VDEMcInternalIPs.ps1 -vCenter "c1r1r12-vcsa-01.texnet1.net" -OutputFile "mc-internal-fix.csv"

.NOTES
    Requires:
    - VMware PowerCLI module
    - Active vCenter connection OR -vCenter parameter
    - VMware Tools running on target VMs
    - Guest OS credentials with local admin rights
#>

param(
    [string]$vCenter     = "c1r1r12-vcsa-01.texnet1.net",
    [string]$EventName   = "CLDT2",
    [string]$NetworkName,
    [string]$OutputFile
)

if (-not $NetworkName) {
    $NetworkName = Read-Host "Enter the vSphere network/portgroup name to target (e.g. IQT-CDO2-CL7)"
    if (-not $NetworkName) {
        Write-Error "NetworkName is required."
        exit 1
    }
}

# EventName drives the VM name suffix (e.g. VDE-STU01-1-<EventName>).
# Default to NetworkName so that -NetworkName "IQT-CDO2-CL7" automatically
# targets VMs named VDE-STU01-1-IQT-CDO2-CL7 without needing -EventName.
if (-not $PSBoundParameters.ContainsKey('EventName')) {
    $EventName = $NetworkName
}

# -- VM name -> last octet for 10.20.0.x --
# Range starts at .100 to avoid Manticore infrastructure:
#   .1=GW  .10=DNS  .11-.16/.18=servers (MAC-locked)  .21-.25=mc-workstations
$defaultGateway = '10.20.0.1'

$vmIpMap = [ordered]@{
    "VDE-STU01" = 100; "VDE-STU02" = 101; "VDE-STU03" = 102; "VDE-STU04" = 103
    "VDE-STU05" = 104; "VDE-STU06" = 105; "VDE-STU07" = 106; "VDE-STU08" = 107
    "VDE-STU09" = 108; "VDE-STU10" = 109; "VDE-STU11" = 110; "VDE-STU12" = 111
    "VDE-STU13" = 112; "VDE-STU14" = 113; "VDE-STU15" = 114; "VDE-STU16" = 115
    "VDE-STU17" = 116; "VDE-STU18" = 117; "VDE-STU19" = 118; "VDE-STU20" = 119
    "VDE-STU21" = 120; "VDE-STU22" = 121; "VDE-STU23" = 122; "VDE-STU24" = 123
    "VDE-STU25" = 124
    "VDE-INS01" = 125; "VDE-INS02" = 126; "VDE-INS03" = 127; "VDE-INS04" = 128
    "VDE-INS05" = 129; "VDE-INS06" = 130; "VDE-INS07" = 131; "VDE-INS08" = 132
    "VDE-INS09" = 133; "VDE-INS10" = 134
    "VDE-ENG01" = 135; "VDE-ENG02" = 136; "VDE-ENG03" = 137
}

# -- Connect if not already connected --
if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    Write-Host "Connecting to vCenter: $vCenter..." -ForegroundColor Cyan
    $vcCred = Get-Credential -Message "vCenter credentials for $vCenter"
    try {
        Connect-VIServer -Server $vCenter -Credential $vcCred | Out-Null
        Write-Host "Connected to $vCenter." -ForegroundColor Green
    } catch {
        Write-Error "Failed to connect to ${vCenter}: $($_.Exception.Message)"
        exit 1
    }
}

$GuestCred = Get-Credential -Message "Guest OS credentials (local admin on VDE-* VMs)"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Discover VMs on the target network that match VDE-* naming
Write-Host "Discovering VMs on network matching '*$NetworkName*'..." -ForegroundColor Cyan
$discoveredVMs = foreach ($key in $vmIpMap.Keys) {
    $vmMatches = Get-VM -Name "$key-*" -ErrorAction SilentlyContinue | Where-Object {
        $adapters = Get-NetworkAdapter -VM $_ -ErrorAction SilentlyContinue
        $adapters | Where-Object { $_.NetworkName -like "*$NetworkName*" }
    }
    foreach ($match in $vmMatches) {
        Write-Host "  Found: $($match.Name)" -ForegroundColor Gray
        $match
    }
}

if (-not $discoveredVMs) {
    Write-Warning "No VMs matching vmIpMap names (VDE-STU01, VDE-INS01, etc.) found on network '*$NetworkName*'."
    exit 0
}

Write-Host "Found $(@($discoveredVMs).Count) VM(s) on '*$NetworkName*'. Starting IP configuration..." -ForegroundColor Green

foreach ($vm in $discoveredVMs) {
    $vmName = $vm.Name

    # Extract base name (e.g. VDE-STU01 from VDE-STU01-1-IQT-CDO2-CL7)
    $baseName = $vmIpMap.Keys | Where-Object { $vmName -like "$_-*" } | Select-Object -First 1

    if (-not $baseName) {
        Write-Warning "[$vmName] No IP map entry found for this VM - skipping."
        $results.Add([PSCustomObject]@{ VM=$vmName; TargetIP="N/A"; Status="NO IP MAP"; Detail="" })
        continue
    }

    $targetIP = "10.20.0.$($vmIpMap[$baseName])"

    # Verify Tools are running
    $guest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
    $badTools = @('toolsNotInstalled','toolsNotRunning')
    if (-not $guest -or $badTools -contains $guest.ToolsStatus) {
        Write-Warning "[$vmName] VMware Tools not running - skipping."
        $results.Add([PSCustomObject]@{ VM=$vmName; TargetIP=$targetIP; Status="TOOLS NOT RUNNING"; Detail="" })
        continue
    }

    $targetNic = Get-NetworkAdapter -VM $vm -ErrorAction SilentlyContinue | Where-Object {
        $_.NetworkName -like "*$NetworkName*"
    } | Select-Object -First 1

    if (-not $targetNic) {
        Write-Warning "[$vmName] No NIC on '*$NetworkName*' found during configuration - skipping."
        $results.Add([PSCustomObject]@{ VM=$vmName; TargetIP=$targetIP; Status="NIC NOT FOUND"; Detail="No adapter on target network" })
        continue
    }

    $targetMac = ($targetNic.MacAddress -replace '[:-]', '').ToUpperInvariant()

    Write-Host "[$vmName] Verifying mc-internal NIC ($($targetNic.Name)) for $targetIP/24 with gateway $defaultGateway ..." -ForegroundColor Cyan

    # Use the vSphere NIC MAC to identify the matching guest adapter, then verify the
    # current IP and gateway before deciding whether a change is needed.
    $guestScript = @(
        "`$targetMac = '$targetMac'"
        "`$targetIP = '$targetIP'"
        "`$defaultGateway = '$defaultGateway'"
        '$adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {'
        '    ($_.MacAddress -replace ''-'','''').ToUpperInvariant() -eq $targetMac'
        '} | Select-Object -First 1'
        ''
        'if (-not $adapter) {'
        '    Write-Output ("SKIP: Target guest adapter not found for MAC " + $targetMac)'
        '    exit 0'
        '}'
        ''
        '$allIPv4 = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue'
        '$apipaIPv4 = $allIPv4 | Where-Object { $_.IPAddress -like ''169.254.*'' } | Select-Object -First 1'
        '$currentIPv4 = $allIPv4 |'
        '    Where-Object { $_.IPAddress -notlike ''169.254.*'' } | Select-Object -First 1'
        '$currentGateway = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix ''0.0.0.0/0'' -ErrorAction SilentlyContinue |'
        '    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).NextHop'
        '$reasons = New-Object ''System.Collections.Generic.List[string]'''
        ''
        'if ($apipaIPv4) {'
        '    $reasons.Add("APIPA detected") | Out-Null'
        '}'
        ''
        'if ($currentIPv4) {'
        '    if ($currentIPv4.IPAddress -ne $targetIP) {'
        '        $reasons.Add("Wrong IP detected (" + $currentIPv4.IPAddress + ")") | Out-Null'
        '    }'
        '} elseif (-not $apipaIPv4) {'
        '    $reasons.Add("No IPv4 detected") | Out-Null'
        '}'
        ''
        'if ($currentGateway -ne $defaultGateway) {'
        '    if ([string]::IsNullOrWhiteSpace($currentGateway)) {'
        '        $reasons.Add("Missing gateway detected") | Out-Null'
        '    } else {'
        '        $reasons.Add("Wrong gateway detected (" + $currentGateway + ")") | Out-Null'
        '    }'
        '}'
        ''
        'if ($reasons.Count -eq 0) {'
        '    Write-Output ("SKIP: Already correct - " + $adapter.Name + " -> " + $targetIP + "/24 gw " + $defaultGateway)'
        '    exit 0'
        '}'
        ''
        'Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |'
        '    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue'
        'Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix ''0.0.0.0/0'' -ErrorAction SilentlyContinue |'
        '    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue'
        ''
        'Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue'
        ''
        'New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $targetIP -PrefixLength 24 -DefaultGateway $defaultGateway -ErrorAction Stop | Out-Null'
        ''
        'Write-Output ("OK: " + $adapter.Name + " [" + ($reasons -join ''; '') + "] -> " + $targetIP + "/24 gw " + $defaultGateway)'
    ) -join "`n"

    try {
        $result = Invoke-VMScript -VM $vm -ScriptText $guestScript -GuestCredential $GuestCred -ScriptType Powershell -ErrorAction Stop
        $detail = $result.ScriptOutput.Trim()
        $status = if ($detail -like 'OK:*') { 'SUCCESS' } else { 'SKIPPED' }
        $color  = if ($status -eq 'SUCCESS') { 'Green' } else { 'DarkYellow' }
        Write-Host "[$vmName] $detail" -ForegroundColor $color
        $results.Add([PSCustomObject]@{ VM=$vmName; TargetIP=$targetIP; Status=$status; Detail=$detail })
    } catch {
        $msg = $_.Exception.Message
        Write-Warning "[$vmName] Failed: $msg"
        $results.Add([PSCustomObject]@{ VM=$vmName; TargetIP=$targetIP; Status="ERROR"; Detail=$msg })
    }
}

# -- Summary --
Write-Host "`n=== mc-internal IP Fix Summary ===" -ForegroundColor Cyan
if ($results.Count -eq 0) {
    Write-Warning "No VMs were processed. Check that NetworkName '$NetworkName' matches a portgroup and that VM names like 'VDE-STU01-1-$EventName' exist in vCenter."
} else {
    $results | Group-Object Status | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation:($PSVersionTable.PSVersion.Major -lt 6)
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
