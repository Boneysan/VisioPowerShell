<#
.SYNOPSIS
    Runs comprehensive network diagnostics on a VM to identify service reachability issues.

.DESCRIPTION
    Performs deep inspection of a VM's network stack from both the vSphere side and the
    guest OS side. This is the script you run on the suspect VM itself when services are
    unreachable cross-subnet but ping/SSH work fine (the classic Elastic/Logstash ticket).

    Checks performed:
    - vSphere side: port group, VLAN, security policy, MAC address, connected state
    - Guest side (via Invoke-VMScript): IP config, listening ports, guest firewall rules,
      routing table, and service binding addresses

    Outputs a diagnostic report highlighting the most likely root cause.

.PARAMETER VMName
    Required. Name of the VM to diagnose.

.PARAMETER Ports
    Optional. Array of specific TCP ports to check binding/firewall status for.
    If not specified, reports all listening ports.

.PARAMETER GuestCredential
    Optional. PSCredential for guest OS authentication (required for guest-side checks).
    If omitted, only vSphere-side checks are performed.

.PARAMETER GuestOS
    Optional. Guest OS type. Default: Linux. Valid values: Linux, Windows.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Optional. Path to export the diagnostic report as CSV.

.EXAMPLE
    .\Get-VMNetworkDiagnostics.ps1 -VMName "elastic01" -Ports 5044,5045,5601,22 -GuestCredential (Get-Credential)
    Full diagnostic of elastic01 checking Logstash/Kibana/SSH ports from vSphere and guest.

.EXAMPLE
    .\Get-VMNetworkDiagnostics.ps1 -VMName "elastic01"
    vSphere-side only diagnostics (no guest credentials provided).

.OUTPUTS
    CSV with columns: Category, Check, Status, Detail, Recommendation

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running on the target VM (for guest-side checks)
    - Guest credentials (for guest-side checks via Invoke-VMScript)

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [int[]]$Ports,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Linux', 'Windows')]
    [string]$GuestOS = 'Linux',

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

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Error "VM '$VMName' not found."; exit 1 }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Diag {
    param([string]$Category, [string]$Check, [string]$Status, [string]$Detail, [string]$Recommendation = '')
    $entry = [PSCustomObject]@{
        Category       = $Category
        Check          = $Check
        Status         = $Status
        Detail         = $Detail
        Recommendation = $Recommendation
    }
    $results.Add($entry)
    $color = switch ($Status) { 'OK' { 'Green' } 'WARNING' { 'Yellow' } 'ISSUE' { 'Red' } 'INFO' { 'Cyan' } default { 'White' } }
    $marker = switch ($Status) { 'OK' { '[OK]   ' } 'WARNING' { '[WARN] ' } 'ISSUE' { '[ISSUE]' } default { '[INFO] ' } }
    Write-Host "  $marker $Category / $Check" -ForegroundColor $color
    Write-Host "         $Detail" -ForegroundColor Gray
    if ($Recommendation) { Write-Host "         -> $Recommendation" -ForegroundColor Yellow }
}

Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host "  Network Diagnostics: $VMName" -ForegroundColor Cyan
Write-Host "====================================`n" -ForegroundColor Cyan

# ============================================================
# SECTION 1: vSphere-Side Checks
# ============================================================

Write-Host "--- vSphere Side ---`n" -ForegroundColor White

# 1a. VM Power State & Tools
$toolsStatus  = $vm.ExtensionData.Guest.ToolsStatus
$toolsRunning = $vm.ExtensionData.Guest.ToolsRunningStatus

Add-Diag -Category 'VM State' -Check 'Power State' `
    -Status $(if ($vm.PowerState -eq 'PoweredOn') { 'OK' } else { 'ISSUE' }) `
    -Detail "Power: $($vm.PowerState)"

Add-Diag -Category 'VM State' -Check 'VMware Tools' `
    -Status $(if ($toolsStatus -eq 'toolsOk') { 'OK' } elseif ($toolsStatus -eq 'toolsOld') { 'WARNING' } else { 'ISSUE' }) `
    -Detail "Status: $toolsStatus | Running: $toolsRunning" `
    -Recommendation $(if ($toolsStatus -ne 'toolsOk') { 'Install/update VMware Tools for full guest diagnostics' } else { '' })

# 1b. Network Adapter Analysis
$nics = Get-NetworkAdapter -VM $vm -ErrorAction SilentlyContinue
foreach ($nic in $nics) {
    $connected = $nic.ConnectionState.Connected
    $startConnected = $nic.ConnectionState.StartConnected

    Add-Diag -Category 'NIC' -Check "$($nic.Name) Connection" `
        -Status $(if ($connected) { 'OK' } else { 'ISSUE' }) `
        -Detail "Connected: $connected | StartConnected: $startConnected | Type: $($nic.Type) | MAC: $($nic.MacAddress)" `
        -Recommendation $(if (-not $connected) { 'NIC is disconnected -- connect it in VM settings' } else { '' })

    # Port group / network details
    $pgName = $nic.NetworkName
    Add-Diag -Category 'NIC' -Check "$($nic.Name) Port Group" `
        -Status 'INFO' -Detail "Network: $pgName"

    # Try to get VDS port group details
    $vdpg = Get-VDPortgroup -Name $pgName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vdpg) {
        $vlanConfig = $vdpg.VlanConfiguration
        $vlanStr = if ($vlanConfig) { $vlanConfig.ToString() } else { 'None/Trunk' }

        Add-Diag -Category 'Port Group' -Check "VLAN ($pgName)" `
            -Status 'INFO' -Detail "VLAN: $vlanStr"

        # Security policy
        $secPolicy = $vdpg | Get-VDSecurityPolicy -ErrorAction SilentlyContinue
        if ($secPolicy) {
            $issues = @()
            if ($secPolicy.AllowPromiscuous)   { $issues += 'Promiscuous=ON' }
            if ($secPolicy.ForgedTransmits)    { $issues += 'ForgedTransmits=ON' }
            if ($secPolicy.MacChanges)         { $issues += 'MACChanges=ON' }

            $secDetail = "Promiscuous: $($secPolicy.AllowPromiscuous) | ForgedTransmits: $($secPolicy.ForgedTransmits) | MACChanges: $($secPolicy.MacChanges)"
            Add-Diag -Category 'Port Group' -Check "Security Policy ($pgName)" `
                -Status $(if ($issues.Count -eq 0) { 'OK' } else { 'WARNING' }) `
                -Detail $secDetail `
                -Recommendation $(if ($issues.Count -gt 0) { "Non-default security settings: $($issues -join ', ')" } else { '' })
        }
    }
    else {
        # Standard vSwitch
        $vmhost = Get-VMHost -Id $vm.VMHostId
        $vswitch = $vmhost | Get-VirtualSwitch -ErrorAction SilentlyContinue |
            Where-Object { ($_ | Get-VirtualPortGroup -ErrorAction SilentlyContinue).Name -contains $pgName }
        if ($vswitch) {
            $stdPg = $vswitch | Get-VirtualPortGroup -Name $pgName -ErrorAction SilentlyContinue
            if ($stdPg) {
                Add-Diag -Category 'Port Group' -Check "VLAN ($pgName)" `
                    -Status 'INFO' -Detail "VlanId: $($stdPg.VLanId) | vSwitch: $($vswitch.Name)"

                $secPolicy = $stdPg | Get-SecurityPolicy -ErrorAction SilentlyContinue
                if ($secPolicy) {
                    $secDetail = "Promiscuous: $($secPolicy.AllowPromiscuous) | ForgedTransmits: $($secPolicy.ForgedTransmits) | MACChanges: $($secPolicy.MacChanges)"
                    Add-Diag -Category 'Port Group' -Check "Security Policy ($pgName)" `
                        -Status 'INFO' -Detail $secDetail
                }
            }
        }
    }
}

# 1c. Guest IP addresses from vSphere
$guestIPs = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
Add-Diag -Category 'Guest IPs (vSphere)' -Check 'IP Addresses' `
    -Status $(if ($guestIPs) { 'OK' } else { 'WARNING' }) `
    -Detail $(if ($guestIPs) { $guestIPs -join ', ' } else { 'No IPv4 addresses reported by VMware Tools' }) `
    -Recommendation $(if (-not $guestIPs) { 'Check if VMware Tools is running and NIC has DHCP/static IP' } else { '' })

# ============================================================
# SECTION 2: Guest-Side Checks (requires credentials)
# ============================================================

if ($GuestCredential) {
    Write-Host "`n--- Guest Side (via Invoke-VMScript) ---`n" -ForegroundColor White

    $scriptType = if ($GuestOS -eq 'Linux') { 'Bash' } else { 'PowerShell' }

    # Helper to run in-guest commands
    function Invoke-GuestCommand {
        param([string]$ScriptText, [string]$Description)
        try {
            $r = Invoke-VMScript -VM $vm -ScriptText $ScriptText -ScriptType $scriptType `
                -GuestCredential $GuestCredential -ErrorAction Stop
            return $r.ScriptOutput.Trim()
        }
        catch {
            Write-Warning "  Guest command failed ($Description): $_"
            return $null
        }
    }

    # 2a. IP Configuration
    if ($GuestOS -eq 'Linux') {
        $ipOutput = Invoke-GuestCommand -ScriptText 'ip -4 addr show 2>/dev/null || ifconfig 2>/dev/null' -Description 'IP config'
    }
    else {
        $ipOutput = Invoke-GuestCommand -ScriptText 'Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize | Out-String' -Description 'IP config'
    }
    if ($ipOutput) {
        Add-Diag -Category 'Guest' -Check 'IP Configuration' -Status 'INFO' -Detail ($ipOutput -replace "`n", " | ")
    }

    # 2b. Routing table
    if ($GuestOS -eq 'Linux') {
        $routeOutput = Invoke-GuestCommand -ScriptText 'ip route show 2>/dev/null || route -n 2>/dev/null' -Description 'Routing'
    }
    else {
        $routeOutput = Invoke-GuestCommand -ScriptText 'Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -ne "255.255.255.255/32" } | Format-Table DestinationPrefix, NextHop, InterfaceAlias -AutoSize | Out-String' -Description 'Routing'
    }
    if ($routeOutput) {
        # Check for default route
        $hasDefault = $routeOutput -match 'default|0\.0\.0\.0'
        Add-Diag -Category 'Guest' -Check 'Routing Table' `
            -Status $(if ($hasDefault) { 'OK' } else { 'WARNING' }) `
            -Detail ($routeOutput -replace "`n", " | ") `
            -Recommendation $(if (-not $hasDefault) { 'No default route detected -- VMs outside this subnet cannot reach these services' } else { '' })
    }

    # 2c. Listening ports -- THE KEY CHECK
    if ($GuestOS -eq 'Linux') {
        $listenOutput = Invoke-GuestCommand -ScriptText 'ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null' -Description 'Listening ports'
    }
    else {
        $listenOutput = Invoke-GuestCommand -ScriptText 'Get-NetTCPConnection -State Listen | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize | Out-String' -Description 'Listening ports'
    }

    if ($listenOutput) {
        Add-Diag -Category 'Guest' -Check 'All Listening Ports' -Status 'INFO' -Detail ($listenOutput -replace "`n", " | ")

        # Check each specified port for binding address
        if ($Ports) {
            foreach ($port in $Ports) {
                # Look for the port in the output
                $portLines = ($listenOutput -split "`n") | Where-Object { $_ -match "\b$port\b" }
                if ($portLines) {
                    # Check if bound to 0.0.0.0 (good), 127.0.0.1 (bad), or specific IP
                    $bindingIssue = $false
                    $bindAddress  = '(unknown)'
                    foreach ($line in $portLines) {
                        if ($line -match '127\.0\.0\.1[:\s]+' + $port) {
                            $bindingIssue = $true
                            $bindAddress = '127.0.0.1 (LOCALHOST ONLY)'
                        }
                        elseif ($line -match '0\.0\.0\.0[:\s*]+' + $port -or $line -match '\*[:\s]+' + $port -or $line -match ':::\s*' + $port) {
                            $bindAddress = '0.0.0.0 (all interfaces)'
                        }
                        elseif ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})[:\s]+' + $port) {
                            $bindAddress = "$($Matches[1]) (specific IP)"
                            # Specific IP binding -- cross-subnet should still work unless it's a loopback
                        }
                    }

                    if ($bindingIssue) {
                        Add-Diag -Category 'Service Binding' -Check "Port $port" `
                            -Status 'ISSUE' `
                            -Detail "Port $port is bound to $bindAddress -- ONLY accessible from localhost!" `
                            -Recommendation "Reconfigure the service to bind to 0.0.0.0 or the VM's primary IP. For Logstash: set host => '0.0.0.0' in the input config. For Kibana: set server.host: '0.0.0.0' in kibana.yml"
                    }
                    else {
                        Add-Diag -Category 'Service Binding' -Check "Port $port" `
                            -Status 'OK' -Detail "Port $port bound to $bindAddress"
                    }
                }
                else {
                    Add-Diag -Category 'Service Binding' -Check "Port $port" `
                        -Status 'ISSUE' -Detail "Port $port is NOT listening on this VM" `
                        -Recommendation "Service is not running or not configured. Check service status (systemctl status <service>)"
                }
            }
        }
    }

    # 2d. Guest Firewall (iptables / firewalld / Windows Firewall)
    if ($GuestOS -eq 'Linux') {
        # Check iptables INPUT chain
        $fwOutput = Invoke-GuestCommand -ScriptText 'iptables -L INPUT -n --line-numbers 2>/dev/null; echo "---FIREWALLD---"; firewall-cmd --list-all 2>/dev/null || echo "firewalld not active"' -Description 'Firewall'

        if ($fwOutput) {
            Add-Diag -Category 'Guest Firewall' -Check 'iptables/firewalld' -Status 'INFO' -Detail ($fwOutput -replace "`n", " | ")

            # Check if specific ports are allowed
            if ($Ports) {
                foreach ($port in $Ports) {
                    $allowed = $fwOutput -match "dpt:$port\s+.*ACCEPT" -or $fwOutput -match "port.*$port.*accept" -or
                               $fwOutput -match "ports:\s*.*\b$port\b"
                    $dropped = $fwOutput -match "dpt:$port\s+.*DROP|REJECT" -or $fwOutput -match "policy\s+DROP"

                    if ($dropped -and -not $allowed) {
                        Add-Diag -Category 'Guest Firewall' -Check "Port $port Rule" `
                            -Status 'ISSUE' -Detail "Port $port appears to be blocked by guest firewall" `
                            -Recommendation "Add firewall rule: firewall-cmd --add-port=$port/tcp --permanent; firewall-cmd --reload"
                    }
                    elseif ($allowed) {
                        Add-Diag -Category 'Guest Firewall' -Check "Port $port Rule" `
                            -Status 'OK' -Detail "Port $port found in firewall allow rules"
                    }
                    else {
                        Add-Diag -Category 'Guest Firewall' -Check "Port $port Rule" `
                            -Status 'WARNING' -Detail "Could not confirm port $port rule -- check manually if default policy is DROP" `
                            -Recommendation "Verify: iptables -L INPUT -n | grep $port"
                    }
                }
            }
        }
    }
    else {
        $fwOutput = Invoke-GuestCommand -ScriptText 'Get-NetFirewallProfile | Format-Table Name, Enabled, DefaultInboundAction -AutoSize | Out-String' -Description 'Firewall profiles'
        if ($fwOutput) {
            Add-Diag -Category 'Guest Firewall' -Check 'Windows Firewall Profiles' -Status 'INFO' -Detail ($fwOutput -replace "`n", " | ")
        }

        if ($Ports) {
            $portFilter = $Ports -join ','
            $fwRules = Invoke-GuestCommand -ScriptText "Get-NetFirewallPortFilter | Where-Object { `$_.LocalPort -in @($portFilter) } | Get-NetFirewallRule | Format-Table DisplayName, Enabled, Direction, Action -AutoSize | Out-String" -Description 'Firewall port rules'
            if ($fwRules) {
                Add-Diag -Category 'Guest Firewall' -Check 'Port-Specific Rules' -Status 'INFO' -Detail ($fwRules -replace "`n", " | ")
            }
        }
    }
}
else {
    Write-Host "`n  Skipping guest-side checks (-GuestCredential not provided)" -ForegroundColor Yellow
    Write-Host "  To diagnose service binding / guest firewall issues, re-run with -GuestCredential`n" -ForegroundColor Yellow
}

# ============================================================
# SECTION 3: Diagnosis Summary
# ============================================================

$issues = $results | Where-Object { $_.Status -eq 'ISSUE' }
$warnings = $results | Where-Object { $_.Status -eq 'WARNING' }

Write-Host "`n====================================" -ForegroundColor Cyan
Write-Host "  Diagnosis Summary" -ForegroundColor Cyan
Write-Host "====================================`n" -ForegroundColor Cyan

Write-Host "  Checks performed : $($results.Count)" -ForegroundColor White
Write-Host "  Issues found     : $($issues.Count)" -ForegroundColor $(if ($issues.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warnings         : $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'White' })

if ($issues.Count -gt 0) {
    Write-Host "`n  ** Issues requiring attention: **" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "    - $($issue.Category) / $($issue.Check): $($issue.Detail)" -ForegroundColor Red
        if ($issue.Recommendation) {
            Write-Host "      FIX: $($issue.Recommendation)" -ForegroundColor Yellow
        }
    }
}

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "`n  No obvious issues found from vSphere/guest checks." -ForegroundColor Green
    Write-Host "  If services are still unreachable cross-subnet, check:" -ForegroundColor Yellow
    Write-Host "    1. NSX Distributed Firewall rules (not visible from guest)" -ForegroundColor Yellow
    Write-Host "    2. Physical switch/router ACLs" -ForegroundColor Yellow
    Write-Host "    3. pfSense rules for these specific ports" -ForegroundColor Yellow
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nDiagnostics exported to: $OutputFile" -ForegroundColor Green
}
