<#
.SYNOPSIS
    Tests network connectivity between VMs across different subnets in a cyber range.

.DESCRIPTION
    Automatically discovers all unique subnets among VMs in a folder, selects a probe
    VM from each subnet, and tests ICMP + TCP reachability between every subnet pair.
    Produces a subnet-to-subnet connectivity matrix that instantly reveals which
    network segments can or cannot communicate.

    Designed for cyber range environments where multiple network segments (e.g. 10.20.0.0/24,
    10.30.0.0/24, 172.16.0.0/24) must communicate through routers/firewalls. Quickly
    identifies broken routing, missing firewall rules, or VLAN isolation problems.

.PARAMETER Folder
    Required. vSphere folder containing the cyber range VMs.

.PARAMETER Ports
    Optional. TCP ports to test between subnets. Default: 22 (SSH).

.PARAMETER GuestCredential
    Required. PSCredential for guest OS authentication (needed for Invoke-VMScript on probes).

.PARAMETER GuestOS
    Optional. Guest OS type for Invoke-VMScript. Default: Linux.

.PARAMETER IncludeSubfolders
    Optional switch. Include VMs in subfolders.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Optional. Path to export the connectivity matrix as CSV.

.EXAMPLE
    .\Test-CrossSubnetConnectivity.ps1 -Folder "CyberRange\Exercise01" -GuestCredential (Get-Credential)
    Auto-discover subnets and test ICMP + SSH between all subnet pairs.

.EXAMPLE
    .\Test-CrossSubnetConnectivity.ps1 -Folder "CyberRange\Exercise01" -Ports 22,5044,5601 -GuestCredential (Get-Credential) -OutputFile "subnet-matrix.csv"
    Test SSH, Logstash, and Kibana ports between all subnets.

.OUTPUTS
    CSV with columns: SourceSubnet, SourceProbeVM, SourceIP, TargetSubnet, TargetProbeVM, TargetIP, Test, Result, LatencyMs, Detail

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running on probe VMs
    - Guest credentials for probe VMs

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [int[]]$Ports = @(22),

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Linux', 'Windows')]
    [string]$GuestOS = 'Linux',

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

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

# --- Resolve folder and VMs ---
$targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }

$allVMs = if ($IncludeSubfolders) {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
} else {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
        Where-Object { $_.FolderId -eq $targetFolder.Id }
}

$allVMs = $allVMs | Where-Object { $_.PowerState -eq 'PoweredOn' }
if (-not $allVMs) { Write-Warning "No powered-on VMs found in folder '$Folder'."; exit 0 }

# --- Discover subnets and select probes ---
Write-Host "`n=== Cross-Subnet Connectivity Test ===" -ForegroundColor Cyan
Write-Host "  Folder : $Folder ($($allVMs.Count) powered-on VMs)" -ForegroundColor White

$vmInfo = foreach ($vm in $allVMs) {
    $ip = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    if ($ip -and $ip -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') {
        [PSCustomObject]@{
            VM     = $vm
            Name   = $vm.Name
            IP     = $ip
            Subnet = "$($Matches[1]).0/24"
        }
    }
}

if (-not $vmInfo) { Write-Warning "No VMs with IPv4 addresses found."; exit 0 }

$subnets = $vmInfo | Group-Object Subnet | Sort-Object Name
Write-Host "  Subnets discovered: $($subnets.Count)`n" -ForegroundColor White

foreach ($s in $subnets) {
    $members = $s.Group | ForEach-Object { $_.Name }
    Write-Host "    $($s.Name) : $($members -join ', ')" -ForegroundColor Gray
}

# Select one probe VM per subnet (prefer first VM alphabetically)
$probes = foreach ($s in $subnets) {
    $probe = $s.Group | Sort-Object Name | Select-Object -First 1
    [PSCustomObject]@{
        Subnet = $s.Name
        VM     = $probe.VM
        Name   = $probe.Name
        IP     = $probe.IP
    }
}

Write-Host "`n  Selected probes:" -ForegroundColor White
foreach ($p in $probes) {
    Write-Host "    $($p.Subnet) -> $($p.Name) ($($p.IP))" -ForegroundColor Cyan
}

Write-Host "`n  Testing ports: $($Ports -join ', ')" -ForegroundColor White
Write-Host "  Running tests...`n" -ForegroundColor Gray

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$scriptType = if ($GuestOS -eq 'Linux') { 'Bash' } else { 'PowerShell' }

function Add-ConnResult {
    param([string]$SrcSubnet, [string]$SrcVM, [string]$SrcIP, [string]$TgtSubnet,
          [string]$TgtVM, [string]$TgtIP, [string]$Test, [string]$Result, [int]$LatencyMs, [string]$Detail)
    $entry = [PSCustomObject]@{
        SourceSubnet  = $SrcSubnet
        SourceProbeVM = $SrcVM
        SourceIP      = $SrcIP
        TargetSubnet  = $TgtSubnet
        TargetProbeVM = $TgtVM
        TargetIP      = $TgtIP
        Test          = $Test
        Result        = $Result
        LatencyMs     = $LatencyMs
        Detail        = $Detail
    }
    $results.Add($entry)
    $color = switch ($Result) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host "    $($SrcSubnet.PadRight(18)) -> $($TgtSubnet.PadRight(18)) [$Test] $Result" -ForegroundColor $color
}

# For every source-target subnet pair
foreach ($srcProbe in $probes) {
    foreach ($tgtProbe in $probes) {
        $isSameSubnet = ($srcProbe.Subnet -eq $tgtProbe.Subnet)
        $label = if ($isSameSubnet) { '(same subnet)' } else { '' }

        Write-Host "  $($srcProbe.Name) ($($srcProbe.Subnet)) -> $($tgtProbe.Name) ($($tgtProbe.Subnet)) $label" -ForegroundColor White

        # ICMP Ping
        if ($GuestOS -eq 'Linux') {
            $pingScript = "ping -c 2 -W 3 $($tgtProbe.IP) >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'"
        }
        else {
            $pingScript = "if (Test-Connection -ComputerName '$($tgtProbe.IP)' -Count 2 -Quiet) { 'OK' } else { 'FAIL' }"
        }

        try {
            $r = Invoke-VMScript -VM $srcProbe.VM -ScriptText $pingScript -ScriptType $scriptType `
                -GuestCredential $GuestCredential -ErrorAction Stop
            $pingResult = if ($r.ScriptOutput.Trim() -match 'OK') { 'OK' } else { 'FAIL' }
        }
        catch {
            $pingResult = 'ERROR'
        }

        Add-ConnResult -SrcSubnet $srcProbe.Subnet -SrcVM $srcProbe.Name -SrcIP $srcProbe.IP `
            -TgtSubnet $tgtProbe.Subnet -TgtVM $tgtProbe.Name -TgtIP $tgtProbe.IP `
            -Test 'ICMP' -Result $pingResult -LatencyMs 0 -Detail ''

        # TCP port tests
        foreach ($port in $Ports) {
            if ($GuestOS -eq 'Linux') {
                $tcpScript = "timeout 3 bash -c 'echo > /dev/tcp/$($tgtProbe.IP)/$port' 2>&1 && echo 'OK' || echo 'FAIL'"
            }
            else {
                $tcpScript = @"
`$tcp = New-Object System.Net.Sockets.TcpClient
try { `$tcp.ConnectAsync('$($tgtProbe.IP)', $port).Wait(3000); if (`$tcp.Connected) { 'OK' } else { 'FAIL' } } catch { 'FAIL' } finally { `$tcp.Close() }
"@
            }

            try {
                $r = Invoke-VMScript -VM $srcProbe.VM -ScriptText $tcpScript -ScriptType $scriptType `
                    -GuestCredential $GuestCredential -ErrorAction Stop
                $tcpResult = if ($r.ScriptOutput.Trim() -match 'OK') { 'OK' } else { 'FAIL' }
            }
            catch {
                $tcpResult = 'ERROR'
            }

            Add-ConnResult -SrcSubnet $srcProbe.Subnet -SrcVM $srcProbe.Name -SrcIP $srcProbe.IP `
                -TgtSubnet $tgtProbe.Subnet -TgtVM $tgtProbe.Name -TgtIP $tgtProbe.IP `
                -Test "TCP:$port" -Result $tcpResult -LatencyMs 0 -Detail ''
        }
    }
}

# --- Connectivity Matrix ---
Write-Host "`n--- Subnet-to-Subnet Connectivity Matrix ---`n" -ForegroundColor Cyan

$tests = @('ICMP') + ($Ports | ForEach-Object { "TCP:$_" })

foreach ($test in $tests) {
    Write-Host "  [$test]" -ForegroundColor White
    $header = '  ' + 'From \ To'.PadRight(20)
    foreach ($tgt in $probes) { $header += $tgt.Subnet.PadRight(20) }
    Write-Host $header -ForegroundColor Gray

    foreach ($src in $probes) {
        $line = "  $($src.Subnet)".PadRight(22)
        foreach ($tgt in $probes) {
            $entry = $results | Where-Object {
                $_.SourceSubnet -eq $src.Subnet -and $_.TargetSubnet -eq $tgt.Subnet -and $_.Test -eq $test
            } | Select-Object -First 1

            $val = if ($entry) { $entry.Result } else { '?' }
            $line += $val.PadRight(20)
        }
        Write-Host $line -ForegroundColor White
    }
    Write-Host ""
}

# --- Cross-Subnet Issues ---
$crossFails = $results | Where-Object { $_.Result -eq 'FAIL' -and $_.SourceSubnet -ne $_.TargetSubnet }
$sameFails  = $results | Where-Object { $_.Result -eq 'FAIL' -and $_.SourceSubnet -eq $_.TargetSubnet }

if ($crossFails.Count -gt 0 -and $sameFails.Count -eq 0) {
    Write-Host "  ** Cross-subnet failures detected (in-subnet OK) **" -ForegroundColor Red
    $failedTests = $crossFails | Group-Object Test
    foreach ($ft in $failedTests) {
        $pairs = $ft.Group | ForEach-Object { "$($_.SourceSubnet) -> $($_.TargetSubnet)" }
        Write-Host "    $($ft.Name): $($pairs -join '; ')" -ForegroundColor Red
    }
    Write-Host "`n  This matches the classic pattern where services work in-subnet but not cross-subnet." -ForegroundColor Yellow
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Run Get-VMNetworkDiagnostics.ps1 on the target VM to check service binding & guest firewall" -ForegroundColor Gray
    Write-Host "    2. Check pfSense/router rules for the failing ports" -ForegroundColor Gray
    Write-Host "    3. Check NSX distributed firewall" -ForegroundColor Gray
}

if ($sameFails.Count -gt 0) {
    Write-Host "  ** In-subnet failures detected — possible service/VM issue, not routing **" -ForegroundColor Red
}

# --- Summary ---
$ok   = ($results | Where-Object { $_.Result -eq 'OK'   }).Count
$fail = ($results | Where-Object { $_.Result -eq 'FAIL' }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total tests : $($results.Count)" -ForegroundColor White
Write-Host "  OK          : $ok"   -ForegroundColor Green
Write-Host "  FAIL        : $fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'White' })

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
