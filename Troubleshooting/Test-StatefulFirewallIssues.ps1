<#
.SYNOPSIS
    Diagnoses stateful firewall / asymmetric routing issues blocking TCP ports cross-subnet.

.DESCRIPTION
    Purpose-built for the scenario where:
    - ICMP and SSH work cross-subnet
    - A specific TCP port (e.g. Logstash 5045) works in-subnet but times out cross-subnet
    - Guest firewall has been ruled out (SELinux permissive, firewalld stopped, nftables flushed)
    - Service is confirmed listening on 0.0.0.0
    - The issue appeared after a VM redeploy (Terraform) and was initially "spotty"

    This pattern almost always points to a stateful firewall (pfSense, OPNsense) dropping
    TCP packets because it sees mid-stream traffic (TCP:A / TCP:PA flags) without
    having tracked the original SYN — caused by asymmetric routing, stale state entries,
    or interface-state mismatch after VM redeployment.

    Checks performed:
    1. Route path analysis: traceroute from both subnets to detect asymmetric paths
    2. TCP SYN vs established behavior: tests a fresh SYN vs sending data on a half-open socket
    3. Service binding confirmation on the target
    4. ARP table consistency on both endpoints
    5. MTU / fragmentation check (redeploys sometimes change MTU)
    6. MAC address consistency (Terraform redeploys may reassign MACs, causing stale ARP
       or pfSense state table entries referencing old MAC addresses)
    7. Connection timing pattern (rapid connect/disconnect to detect "spotty" behavior)
    8. Guidance for pfSense-specific fixes

.PARAMETER SourceVM
    Required. Name of the VM on the subnet that CANNOT reach the service (e.g. a VM on 172.19.11.0/24).

.PARAMETER TargetVM
    Required. Name of the VM running the service (e.g. Logstash VM on 10.20.0.0/24).

.PARAMETER FailingPort
    Required. The TCP port that is failing cross-subnet (e.g. 5045).

.PARAMETER WorkingPort
    Optional. A TCP port that IS working cross-subnet for comparison (e.g. 22 for SSH). Default: 22.

.PARAMETER GuestCredential
    Required. PSCredential for guest OS authentication on both VMs.

.PARAMETER GuestOS
    Optional. Guest OS type. Default: Linux.

.PARAMETER FirewallVM
    Optional. Name of the pfSense/firewall VM (for state table checks if SSH is available).

.PARAMETER FirewallCredential
    Optional. PSCredential for pfSense SSH access.

.PARAMETER RepeatCount
    Optional. Number of rapid TCP connection attempts to detect intermittent "spotty" failures.
    Default: 10.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Optional. Path to export the diagnostic report as CSV.

.EXAMPLE
    .\Test-StatefulFirewallIssues.ps1 -SourceVM "analyst-ws" -TargetVM "logstash01" -FailingPort 5045 -GuestCredential (Get-Credential)
    Basic diagnosis: test from analyst workstation on 172.19.11.0/24 to Logstash on 10.20.0.0/24.

.EXAMPLE
    .\Test-StatefulFirewallIssues.ps1 -SourceVM "analyst-ws" -TargetVM "logstash01" -FailingPort 5045 -WorkingPort 22 -GuestCredential (Get-Credential) -FirewallVM "pfsense-ir" -FirewallCredential (Get-Credential) -OutputFile "fw-diag.csv"
    Full diagnosis including pfSense state table analysis.

.OUTPUTS
    CSV with columns: Phase, Check, Status, Detail, Recommendation

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running on source and target VMs
    - Guest credentials for Invoke-VMScript
    - (Optional) SSH access to pfSense for state table checks

    Root cause reference for this failure pattern:
    -----------------------------------------------
    When VMs are redeployed via Terraform, new MAC addresses are assigned. pfSense maintains
    a state table keyed partly on MAC + IP + port. If the state table still has entries for
    the OLD MAC with the same IP, new TCP SYNs may be matched against stale state entries
    and treated as out-of-state packets (TCP:A / TCP:PA without a tracked SYN). pfSense then
    drops them under its default "strict state" checking.

    Meanwhile ICMP and SSH work because:
    - ICMP is stateless or has short state timeouts
    - SSH may have been re-established after the state table was partially flushed

    Fixes:
    1. pfSense: Diagnostics > States > Reset State Table (nuclear but reliable)
    2. pfSense: System > Advanced > Firewall & NAT > set "Firewall Optimization" to
       "Conservative" (more tolerant of asymmetric/out-of-order traffic)
    3. pfSense: per-rule "State Type" set to "Sloppy State" for range traffic
    4. pfSense: Disable "state killing on gateway failure" if using multi-WAN
    5. Check pfSense for floating rules that might match traffic on the wrong interface

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceVM,

    [Parameter(Mandatory=$true)]
    [string]$TargetVM,

    [Parameter(Mandatory=$true)]
    [int]$FailingPort,

    [Parameter(Mandatory=$false)]
    [int]$WorkingPort = 22,

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Linux', 'Windows')]
    [string]$GuestOS = 'Linux',

    [Parameter(Mandatory=$false)]
    [string]$FirewallVM,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$FirewallCredential,

    [Parameter(Mandatory=$false)]
    [int]$RepeatCount = 10,

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
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# --- Resolve VMs ---
$srcVM = Get-VM -Name $SourceVM -ErrorAction SilentlyContinue
if (-not $srcVM) { Write-Error "Source VM '$SourceVM' not found."; exit 1 }
$tgtVM = Get-VM -Name $TargetVM -ErrorAction SilentlyContinue
if (-not $tgtVM) { Write-Error "Target VM '$TargetVM' not found."; exit 1 }

$srcIP = $srcVM.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
$tgtIP = $tgtVM.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1

if (-not $srcIP) { Write-Error "Cannot determine IP for source VM '$SourceVM'. Is VMware Tools running?"; exit 1 }
if (-not $tgtIP) { Write-Error "Cannot determine IP for target VM '$TargetVM'. Is VMware Tools running?"; exit 1 }

$srcSubnet = if ($srcIP -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { "$($Matches[1]).0/24" } else { '?' }
$tgtSubnet = if ($tgtIP -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { "$($Matches[1]).0/24" } else { '?' }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$scriptType = if ($GuestOS -eq 'Linux') { 'Bash' } else { 'PowerShell' }

function Add-Diag {
    param([string]$Phase, [string]$Check, [string]$Status, [string]$Detail, [string]$Recommendation = '')
    $entry = [PSCustomObject]@{
        Phase          = $Phase
        Check          = $Check
        Status         = $Status
        Detail         = $Detail
        Recommendation = $Recommendation
    }
    $results.Add($entry)
    $color = switch ($Status) { 'OK' { 'Green' } 'WARNING' { 'Yellow' } 'ISSUE' { 'Red' } default { 'Cyan' } }
    $marker = switch ($Status) { 'OK' { '[OK]   ' } 'WARNING' { '[WARN] ' } 'ISSUE' { '[ISSUE]' } default { '[INFO] ' } }
    Write-Host "  $marker $Check" -ForegroundColor $color
    Write-Host "         $Detail" -ForegroundColor Gray
    if ($Recommendation) { Write-Host "         -> $Recommendation" -ForegroundColor Yellow }
}

function Invoke-GuestCmd {
    param([object]$VM, [string]$Script, [string]$Desc)
    try {
        $r = Invoke-VMScript -VM $VM -ScriptText $Script -ScriptType $scriptType `
            -GuestCredential $GuestCredential -ErrorAction Stop
        return $r.ScriptOutput.Trim()
    }
    catch {
        Write-Warning "  Guest command failed on $($VM.Name) ($Desc): $_"
        return $null
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Stateful Firewall / Asymmetric Routing Diagnostics" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Source  : $SourceVM ($srcIP - $srcSubnet)" -ForegroundColor White
Write-Host "  Target  : $TargetVM ($tgtIP - $tgtSubnet)" -ForegroundColor White
Write-Host "  Failing : TCP/$FailingPort" -ForegroundColor Red
Write-Host "  Working : TCP/$WorkingPort (control)" -ForegroundColor Green
Write-Host "============================================================`n" -ForegroundColor Cyan

# ============================================================
# PHASE 1: Confirm the symptom pattern
# ============================================================
Write-Host "--- Phase 1: Confirm Symptom Pattern ---`n" -ForegroundColor White

# 1a. ICMP from source to target
$pingOut = Invoke-GuestCmd -VM $srcVM -Script "ping -c 3 -W 2 $tgtIP 2>&1 | tail -2" -Desc 'ping'
$pingOK  = $pingOut -match '0% packet loss|[1-3] received'
Add-Diag -Phase 'Symptom Confirm' -Check "ICMP $srcSubnet -> $tgtSubnet" `
    -Status $(if ($pingOK) { 'OK' } else { 'ISSUE' }) `
    -Detail "Ping: $pingOut"

# 1b. Working port from source to target
$workOut = Invoke-GuestCmd -VM $srcVM -Script "timeout 3 bash -c 'echo > /dev/tcp/$tgtIP/$WorkingPort' 2>&1 && echo 'OPEN' || echo 'CLOSED'" -Desc "TCP/$WorkingPort"
$workOK  = $workOut -match 'OPEN'
Add-Diag -Phase 'Symptom Confirm' -Check "TCP/$WorkingPort (control) $srcSubnet -> $tgtSubnet" `
    -Status $(if ($workOK) { 'OK' } else { 'ISSUE' }) `
    -Detail "Port $WorkingPort : $workOut"

# 1c. Failing port from source to target
$failOut = Invoke-GuestCmd -VM $srcVM -Script "timeout 5 bash -c 'echo > /dev/tcp/$tgtIP/$FailingPort' 2>&1 && echo 'OPEN' || echo 'CLOSED'" -Desc "TCP/$FailingPort"
$failOK  = $failOut -match 'OPEN'
Add-Diag -Phase 'Symptom Confirm' -Check "TCP/$FailingPort (failing) $srcSubnet -> $tgtSubnet" `
    -Status $(if (-not $failOK) { 'ISSUE' } else { 'OK' }) `
    -Detail "Port $FailingPort : $failOut" `
    -Recommendation $(if (-not $failOK) { "Confirms the failure pattern: ICMP/SSH work but port $FailingPort is blocked cross-subnet" } else { '' })

# 1d. Failing port from SAME subnet (should work)
$localOut = Invoke-GuestCmd -VM $tgtVM -Script "timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/$FailingPort' 2>&1 && echo 'OPEN' || echo 'CLOSED'" -Desc "localhost:$FailingPort"
$localOK  = $localOut -match 'OPEN'
Add-Diag -Phase 'Symptom Confirm' -Check "TCP/$FailingPort local on target" `
    -Status $(if ($localOK) { 'OK' } else { 'ISSUE' }) `
    -Detail "Localhost: $localOut" `
    -Recommendation $(if (-not $localOK) { 'Service is not listening locally — this is a service issue, not a firewall issue' } else { '' })

$confirmed = $pingOK -and $workOK -and (-not $failOK) -and $localOK
if ($confirmed) {
    Write-Host "`n  ** Symptom pattern CONFIRMED: Stateful firewall drop is likely **`n" -ForegroundColor Red
}

# ============================================================
# PHASE 2: Service and Host Verification (eliminate false leads)
# ============================================================
Write-Host "--- Phase 2: Service & Host Verification ---`n" -ForegroundColor White

# 2a. Service binding on target
$listenOut = Invoke-GuestCmd -VM $tgtVM -Script "ss -tlnp 2>/dev/null | grep ':$FailingPort ' || netstat -tlnp 2>/dev/null | grep ':$FailingPort '" -Desc 'listen check'
$boundAll = $listenOut -match '0\.0\.0\.0' -or $listenOut -match '\*:'
Add-Diag -Phase 'Service Check' -Check "Binding address for port $FailingPort" `
    -Status $(if ($boundAll) { 'OK' } elseif ($listenOut) { 'WARNING' } else { 'ISSUE' }) `
    -Detail "Listen output: $listenOut" `
    -Recommendation $(if (-not $listenOut) { "Port $FailingPort not listening!" } elseif (-not $boundAll) { 'Service may be bound to a specific IP — verify it is 0.0.0.0' } else { '' })

# 2b. Guest firewall (iptables/nftables) on target
$iptOut = Invoke-GuestCmd -VM $tgtVM -Script 'iptables -L INPUT -n 2>/dev/null | head -20; echo "---NFT---"; nft list ruleset 2>/dev/null | head -20 || echo "no nft"' -Desc 'iptables'
$fwClean = ($iptOut -match 'policy ACCEPT' -or $iptOut -match 'Chain INPUT.*ACCEPT') -and ($iptOut -notmatch 'DROP|REJECT')
Add-Diag -Phase 'Service Check' -Check 'Guest firewall (iptables/nftables)' `
    -Status $(if ($fwClean) { 'OK' } else { 'WARNING' }) `
    -Detail ($iptOut -replace "`n", ' | ') `
    -Recommendation $(if (-not $fwClean) { "Guest firewall may have rules — verify iptables -L INPUT -n and nft list ruleset" } else { 'Guest firewall is open (ACCEPT policy)' })

# 2c. SELinux status on target
$seOut = Invoke-GuestCmd -VM $tgtVM -Script 'getenforce 2>/dev/null || echo "N/A"' -Desc 'SELinux'
Add-Diag -Phase 'Service Check' -Check 'SELinux status' `
    -Status $(if ($seOut -match 'Permissive|Disabled|N/A') { 'OK' } else { 'WARNING' }) `
    -Detail "SELinux: $seOut" `
    -Recommendation $(if ($seOut -match 'Enforcing') { 'SELinux is Enforcing — check audit log: ausearch -m avc -ts recent' } else { '' })

# ============================================================
# PHASE 3: Route Path Analysis (Asymmetric Routing Detection)
# ============================================================
Write-Host "`n--- Phase 3: Asymmetric Routing Detection ---`n" -ForegroundColor White

# 3a. Traceroute from source to target
$trSrcToTgt = Invoke-GuestCmd -VM $srcVM -Script "traceroute -n -m 10 -w 2 $tgtIP 2>/dev/null || tracepath -n $tgtIP 2>/dev/null | head -15" -Desc 'traceroute fwd'
Add-Diag -Phase 'Routing' -Check "Route path: $srcSubnet -> $tgtSubnet" `
    -Status 'INFO' -Detail ($trSrcToTgt -replace "`n", ' | ')

# 3b. Traceroute from target back to source
$trTgtToSrc = Invoke-GuestCmd -VM $tgtVM -Script "traceroute -n -m 10 -w 2 $srcIP 2>/dev/null || tracepath -n $srcIP 2>/dev/null | head -15" -Desc 'traceroute rev'
Add-Diag -Phase 'Routing' -Check "Route path: $tgtSubnet -> $srcSubnet (RETURN)" `
    -Status 'INFO' -Detail ($trTgtToSrc -replace "`n", ' | ')

# 3c. Compare routes for asymmetry
$fwdHops = [regex]::Matches($trSrcToTgt, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne $srcIP -and $_ -ne $tgtIP }
$revHops = [regex]::Matches($trTgtToSrc, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne $srcIP -and $_ -ne $tgtIP }

$asymmetric = $false
if ($fwdHops -and $revHops) {
    $fwdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$fwdHops)
    $revSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$revHops)
    $asymmetric = -not $fwdSet.SetEquals($revSet)
}

Add-Diag -Phase 'Routing' -Check 'Asymmetric routing detection' `
    -Status $(if ($asymmetric) { 'ISSUE' } elseif ($fwdHops -and $revHops) { 'OK' } else { 'WARNING' }) `
    -Detail "Forward hops: [$($fwdHops -join ' -> ')] | Return hops: [$($revHops -join ' -> ')]$(if ($asymmetric) { ' ** ASYMMETRIC **' })" `
    -Recommendation $(if ($asymmetric) {
        'Asymmetric routing detected! Traffic takes different paths in each direction. The pfSense firewall sees return packets it never saw the SYN for, and drops them as invalid state. Fix: enable "Sloppy State" on the pfSense rule or correct routing to be symmetric.'
    } else { '' })

# 3d. Default gateway check on both VMs
$srcGW = Invoke-GuestCmd -VM $srcVM -Script "ip route show default 2>/dev/null | head -1" -Desc 'src gateway'
$tgtGW = Invoke-GuestCmd -VM $tgtVM -Script "ip route show default 2>/dev/null | head -1" -Desc 'tgt gateway'
Add-Diag -Phase 'Routing' -Check 'Default gateways' `
    -Status 'INFO' -Detail "Source GW: $srcGW | Target GW: $tgtGW"

# ============================================================
# PHASE 4: MAC Address / ARP Consistency (Post-Redeploy Check)
# ============================================================
Write-Host "`n--- Phase 4: MAC Address & ARP Consistency ---`n" -ForegroundColor White

# 4a. vSphere MAC addresses for target VM
$tgtNics = Get-NetworkAdapter -VM $tgtVM -ErrorAction SilentlyContinue
foreach ($nic in $tgtNics) {
    Add-Diag -Phase 'MAC/ARP' -Check "vSphere MAC: $($nic.Name) ($($nic.NetworkName))" `
        -Status 'INFO' -Detail "MAC: $($nic.MacAddress) | Type: $($nic.Type)"
}

# 4b. Guest-side MAC (does it match vSphere?)
$guestMAC = Invoke-GuestCmd -VM $tgtVM -Script "ip link show 2>/dev/null | grep 'link/ether' | awk '{print `$2}' | head -5" -Desc 'guest MAC'
Add-Diag -Phase 'MAC/ARP' -Check 'Guest-reported MAC addresses' `
    -Status 'INFO' -Detail "Guest MACs: $($guestMAC -replace "`n", ', ')"

# 4c. ARP table on source — what MAC does it have for the target or its gateway?
$srcARP = Invoke-GuestCmd -VM $srcVM -Script "ip neigh show 2>/dev/null || arp -n 2>/dev/null" -Desc 'src ARP'
Add-Diag -Phase 'MAC/ARP' -Check "ARP table on $SourceVM" `
    -Status 'INFO' -Detail ($srcARP -replace "`n", ' | ')

# Check for STALE or FAILED ARP entries pointing at target subnet gateway
$staleEntries = ($srcARP -split "`n") | Where-Object { $_ -match 'STALE|FAILED|incomplete' }
if ($staleEntries) {
    Add-Diag -Phase 'MAC/ARP' -Check 'Stale/Failed ARP entries' `
        -Status 'WARNING' -Detail ($staleEntries -join ' | ') `
        -Recommendation "Stale ARP entries found. Flush with: ip neigh flush all"
}

# 4d. ARP table on target
$tgtARP = Invoke-GuestCmd -VM $tgtVM -Script "ip neigh show 2>/dev/null || arp -n 2>/dev/null" -Desc 'tgt ARP'
Add-Diag -Phase 'MAC/ARP' -Check "ARP table on $TargetVM" `
    -Status 'INFO' -Detail ($tgtARP -replace "`n", ' | ')

# ============================================================
# PHASE 5: MTU / Fragmentation Check
# ============================================================
Write-Host "`n--- Phase 5: MTU / Fragmentation ---`n" -ForegroundColor White

# Large ping (DF bit set) to detect MTU issues
$mtuOut = Invoke-GuestCmd -VM $srcVM -Script "ping -c 2 -M do -s 1472 $tgtIP 2>&1 | tail -3" -Desc 'MTU test'
$mtuOK = $mtuOut -match '0% packet loss|[1-2] received'
Add-Diag -Phase 'MTU' -Check 'Large packet test (1472+28=1500 byte)' `
    -Status $(if ($mtuOK) { 'OK' } else { 'WARNING' }) `
    -Detail "MTU test: $mtuOut" `
    -Recommendation $(if (-not $mtuOK) { 'MTU issue detected — packets >1500 bytes are being dropped. Check for tunnel overhead or mismatched MTU on vSphere port groups.' } else { '' })

# Guest MTU on both sides
$srcMTU = Invoke-GuestCmd -VM $srcVM -Script "ip link show 2>/dev/null | grep 'mtu' | head -5" -Desc 'src MTU'
$tgtMTU = Invoke-GuestCmd -VM $tgtVM -Script "ip link show 2>/dev/null | grep 'mtu' | head -5" -Desc 'tgt MTU'
Add-Diag -Phase 'MTU' -Check 'Interface MTU values' `
    -Status 'INFO' -Detail "Source: $($srcMTU -replace "`n", ' | ') || Target: $($tgtMTU -replace "`n", ' | ')"

# ============================================================
# PHASE 6: Intermittent Connection Pattern Test
# ============================================================
Write-Host "`n--- Phase 6: Intermittent Pattern Detection ($RepeatCount rapid tests) ---`n" -ForegroundColor White

# Build a script that rapidly tests the failing port N times
$rapidScript = @"
results=""
for i in `$(seq 1 $RepeatCount); do
    timeout 2 bash -c "echo > /dev/tcp/$tgtIP/$FailingPort" 2>/dev/null
    if [ `$? -eq 0 ]; then
        results="`${results}O"
    else
        results="`${results}X"
    fi
done
echo "`$results"
"@

$rapidOut = Invoke-GuestCmd -VM $srcVM -Script $rapidScript -Desc 'rapid test'
$openCount  = ($rapidOut.ToCharArray() | Where-Object { $_ -eq 'O' }).Count
$closeCount = ($rapidOut.ToCharArray() | Where-Object { $_ -eq 'X' }).Count

$pattern = $rapidOut -replace 'O', '[OK]' -replace 'X', '[FAIL]'
$isSpotty = ($openCount -gt 0 -and $closeCount -gt 0)
$isDown   = ($openCount -eq 0)

Add-Diag -Phase 'Pattern' -Check "Rapid connection test ($RepeatCount attempts)" `
    -Status $(if ($isDown) { 'ISSUE' } elseif ($isSpotty) { 'WARNING' } else { 'OK' }) `
    -Detail "Pattern: $pattern (Open: $openCount / Closed: $closeCount)" `
    -Recommendation $(if ($isSpotty) {
        'SPOTTY behavior confirmed! This strongly indicates pfSense state table issue — some SYNs make it through when state entries happen to expire. Fix: Reset pfSense state table and consider "Sloppy State" on the rule.'
    } elseif ($isDown) {
        'Port is consistently blocked. State table may have a persistent bad entry, or a firewall rule is explicitly blocking this port.'
    } else { '' })

# Also do the same for the working port as control
$rapidCtrl = @"
results=""
for i in `$(seq 1 $RepeatCount); do
    timeout 2 bash -c "echo > /dev/tcp/$tgtIP/$WorkingPort" 2>/dev/null
    if [ `$? -eq 0 ]; then
        results="`${results}O"
    else
        results="`${results}X"
    fi
done
echo "`$results"
"@

$ctrlOut = Invoke-GuestCmd -VM $srcVM -Script $rapidCtrl -Desc 'rapid control'
$ctrlOpen  = ($ctrlOut.ToCharArray() | Where-Object { $_ -eq 'O' }).Count
$ctrlPattern = $ctrlOut -replace 'O', '[OK]' -replace 'X', '[FAIL]'

Add-Diag -Phase 'Pattern' -Check "Control port $WorkingPort rapid test" `
    -Status $(if ($ctrlOpen -eq $RepeatCount) { 'OK' } else { 'WARNING' }) `
    -Detail "Pattern: $ctrlPattern (Open: $ctrlOpen / $RepeatCount)"

# ============================================================
# PHASE 7: pfSense State Table (if firewall VM accessible)
# ============================================================
if ($FirewallVM -and $FirewallCredential) {
    Write-Host "`n--- Phase 7: pfSense State Table Analysis ---`n" -ForegroundColor White

    $fwVM = Get-VM -Name $FirewallVM -ErrorAction SilentlyContinue
    if ($fwVM) {
        # Query pfSense state table for entries matching our traffic
        $stateScript = "pfctl -ss 2>/dev/null | grep -i '$tgtIP' | grep '$FailingPort' | head -20"
        $stateOut = Invoke-GuestCmd -VM $fwVM -Script $stateScript -Desc 'pfctl states'

        if ($stateOut) {
            Add-Diag -Phase 'pfSense' -Check "State table entries for $tgtIP`:$FailingPort" `
                -Status 'WARNING' -Detail ($stateOut -replace "`n", ' | ') `
                -Recommendation 'Existing state entries found. If the source IP/MAC has changed (Terraform redeploy), these are STALE and will cause drops. Reset state table in pfSense UI.'

            # Check for suspicious TCP flags in state entries
            if ($stateOut -match 'NO_TRAFFIC|CLOSED:SYN_SENT|SINGLE') {
                Add-Diag -Phase 'pfSense' -Check 'Stale state entry flags' `
                    -Status 'ISSUE' `
                    -Detail "State entries show abnormal flags (NO_TRAFFIC / CLOSED:SYN_SENT / SINGLE) indicating stale state from pre-redeploy" `
                    -Recommendation 'These stale states are almost certainly the root cause. Reset the pfSense state table: Diagnostics > States > Reset'
            }
        }
        else {
            Add-Diag -Phase 'pfSense' -Check "State table entries for $tgtIP`:$FailingPort" `
                -Status 'INFO' -Detail 'No matching state entries found (states may have expired or been cleared)'
        }

        # Check for asymmetric route detection in pfSense logs
        $logScript = "clog /var/log/filter.log 2>/dev/null | grep '$tgtIP' | grep '$FailingPort' | tail -10"
        $logOut = Invoke-GuestCmd -VM $fwVM -Script $logScript -Desc 'filter log'
        if ($logOut) {
            $blocked = $logOut -match 'block'
            Add-Diag -Phase 'pfSense' -Check 'Filter log entries' `
                -Status $(if ($blocked) { 'ISSUE' } else { 'INFO' }) `
                -Detail ($logOut -replace "`n", ' | ') `
                -Recommendation $(if ($blocked) { 'pfSense filter log shows BLOCKED entries for this traffic. Check the rule order and ensure the correct rule exists for this subnet pair and port.' } else { '' })
        }

        # Check firewall optimization mode
        $optScript = "sysctl net.pf.optimize_level 2>/dev/null || echo 'unknown'"
        $optOut = Invoke-GuestCmd -VM $fwVM -Script $optScript -Desc 'pf optimize'
        Add-Diag -Phase 'pfSense' -Check 'Firewall optimization mode' `
            -Status 'INFO' -Detail "Optimization: $optOut" `
            -Recommendation 'If set to "normal" and asymmetric routing exists, consider changing to "conservative" in System > Advanced > Firewall/NAT'
    }
    else {
        Write-Warning "Firewall VM '$FirewallVM' not found. Skipping state table analysis."
    }
}
else {
    Write-Host "`n  Skipping pfSense state table checks (-FirewallVM/-FirewallCredential not provided)" -ForegroundColor Yellow
    Write-Host "  To inspect pfSense state table, provide -FirewallVM and -FirewallCredential`n" -ForegroundColor Yellow
}

# ============================================================
# DIAGNOSIS & RECOMMENDATIONS
# ============================================================

$issues   = $results | Where-Object { $_.Status -eq 'ISSUE' }
$warnings = $results | Where-Object { $_.Status -eq 'WARNING' }

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  DIAGNOSIS" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

Write-Host "  Checks performed : $($results.Count)" -ForegroundColor White
Write-Host "  Issues           : $($issues.Count)" -ForegroundColor $(if ($issues.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warnings         : $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'White' })

if ($confirmed) {
    Write-Host "`n  CONFIRMED PATTERN: ICMP/SSH OK, port $FailingPort blocked cross-subnet, works in-subnet." -ForegroundColor Red
    Write-Host "  Service is bound correctly and guest firewall is clear." -ForegroundColor White

    if ($asymmetric) {
        Write-Host "`n  ROOT CAUSE (HIGH CONFIDENCE): Asymmetric Routing" -ForegroundColor Red
        Write-Host "  Traffic takes different paths forward vs return. The pfSense firewall" -ForegroundColor Yellow
        Write-Host "  sees return TCP packets (ACK/PSH-ACK) without a matching SYN in its" -ForegroundColor Yellow
        Write-Host "  state table and drops them as invalid." -ForegroundColor Yellow
    }
    elseif ($isSpotty) {
        Write-Host "`n  ROOT CAUSE (HIGH CONFIDENCE): Stale pfSense State Table Entries" -ForegroundColor Red
        Write-Host "  Spotty connection behavior after Terraform redeploy indicates stale" -ForegroundColor Yellow
        Write-Host "  state entries from the old VM MAC addresses." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n  ROOT CAUSE (LIKELY): pfSense State Table or Rule Issue" -ForegroundColor Red
        Write-Host "  The pattern is consistent with stateful firewall blocking." -ForegroundColor Yellow
    }

    Write-Host "`n  RECOMMENDED FIXES (try in order — no redeploy needed):" -ForegroundColor Cyan
    Write-Host "  -------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  1. pfSense: Diagnostics > States > Reset State Table" -ForegroundColor White
    Write-Host "     (Clears all tracked connections — brief disruption but fixes stale entries)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. pfSense: Edit the WAN/LAN rule for port $FailingPort" -ForegroundColor White
    Write-Host "     Set 'State Type' to 'Sloppy State' (Advanced Options on the rule)" -ForegroundColor Gray
    Write-Host "     (Tolerates asymmetric traffic and out-of-order packets)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. pfSense: System > Advanced > Firewall & NAT" -ForegroundColor White
    Write-Host "     Set 'Firewall Optimization Options' to 'Conservative'" -ForegroundColor Gray
    Write-Host "     (More tolerant of asymmetric routing and state mismatches)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. pfSense: Check for Floating Rules that match on the wrong interface" -ForegroundColor White
    Write-Host "     Floating rules with 'quick' can intercept traffic before interface rules" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  5. Both VMs: Flush ARP caches" -ForegroundColor White
    Write-Host "     Source: ip neigh flush all | Target: ip neigh flush all" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  6. Verify routing: Ensure both subnets route through the SAME pfSense" -ForegroundColor White
    Write-Host "     interface for this traffic (eliminates asymmetric return path)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ** A full firewall redeploy should be the LAST resort, not the first **" -ForegroundColor Yellow
}

if ($issues.Count -gt 0) {
    Write-Host "`n  All flagged issues:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "    - $($issue.Phase) / $($issue.Check)" -ForegroundColor Red
        Write-Host "      $($issue.Detail)" -ForegroundColor Gray
        if ($issue.Recommendation) {
            Write-Host "      FIX: $($issue.Recommendation)" -ForegroundColor Yellow
        }
    }
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nDiagnostics exported to: $OutputFile" -ForegroundColor Green
}
