<#
.SYNOPSIS
    Tests service port reachability to target VMs from multiple source VMs across subnets.

.DESCRIPTION
    Designed for diagnosing the classic "services work in-subnet but not cross-subnet"
    problem in cyber range environments (e.g. Elastic/Logstash ports reachable from the
    same /24 but unreachable from other networks, while ICMP/SSH still work).

    Takes a list of target VMs/IPs and service ports, and optionally a list of source
    VMs (probes) at different network positions. For each source-target-port combination,
    runs a TCP connect test via VMware Tools Invoke-VMScript. Also tests from the local
    machine as a baseline. Reports a matrix of reachability results.

    This lets you quickly determine:
    - Is the service listening at all? (test from same subnet)
    - Is it a cross-subnet issue? (compare in-subnet vs out-of-subnet results)
    - Is it port-specific? (SSH works but app port doesn't)

.PARAMETER TargetVMs
    Required. Array of VM names or IPs to test service ports against.

.PARAMETER Ports
    Required. Array of TCP ports to test on each target (e.g. 5044, 5045, 5601, 22, 443).

.PARAMETER SourceVMs
    Optional. Array of VM names to use as test probes (via Invoke-VMScript).
    These should be VMs on different subnets to test cross-subnet reachability.
    If omitted, tests are run only from the local machine.

.PARAMETER GuestCredential
    Optional. PSCredential for guest OS authentication when using -SourceVMs
    (required for Invoke-VMScript).

.PARAMETER GuestOS
    Optional. Guest OS type for Invoke-VMScript. Default: Linux.
    Valid values: Linux, Windows.

.PARAMETER TestFromLocal
    Optional switch (default: $true). Also test from the machine running this script.

.PARAMETER TimeoutSec
    Optional. TCP connection timeout in seconds per test. Default: 3.

.PARAMETER Folder
    Optional. vSphere folder name. If specified, targets ALL VMs in the folder
    and tests the specified ports against each. Overrides -TargetVMs.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER OutputFile
    Optional. Path to export the full results matrix as CSV.

.EXAMPLE
    .\Test-ServicePortReachability.ps1 -TargetVMs "elastic01","logstash01","kibana01" -Ports 5044,5045,5601,22 -OutputFile "port-matrix.csv"
    Test Elastic stack ports from the local machine.

.EXAMPLE
    .\Test-ServicePortReachability.ps1 -TargetVMs "elastic01" -Ports 5044,5601,22 -SourceVMs "probe-same-subnet","probe-diff-subnet" -GuestCredential (Get-Credential) -OutputFile "cross-subnet.csv"
    Full cross-subnet matrix: test from local + two probe VMs on different networks.

.OUTPUTS
    CSV with columns: SourceVM, SourceIP, SourceSubnet, TargetVM, TargetIP, Port, TCPResult, LatencyMs, Detail, Timestamp

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running on source probe VMs (for Invoke-VMScript)
    - Guest credentials for source probe VMs (for Invoke-VMScript)
    - Network access from probe VMs to target VMs

    Troubleshooting tips when this script reveals cross-subnet port failures:
    1. Check if service is bound to 0.0.0.0 vs a specific IP (netstat/ss on the VM)
    2. Check guest firewall (iptables -L / firewall-cmd --list-all)
    3. Check vSphere distributed firewall / NSX rules
    4. Check port group security policy (promiscuous mode, forged transmits)
    5. Check pfSense/router ACLs for the specific ports

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$TargetVMs,

    [Parameter(Mandatory=$true)]
    [int[]]$Ports,

    [Parameter(Mandatory=$false)]
    [string[]]$SourceVMs,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Linux', 'Windows')]
    [string]$GuestOS = 'Linux',

    [Parameter(Mandatory=$false)]
    [switch]$TestFromLocal = $true,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutSec = 3,

    [Parameter(Mandatory=$false)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

if (-not $TargetVMs -and -not $Folder) {
    Write-Error "Specify either -TargetVMs or -Folder."
    exit 1
}

if ($SourceVMs -and -not $GuestCredential) {
    Write-Error "-GuestCredential is required when using -SourceVMs (needed for Invoke-VMScript)."
    exit 1
}

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

# --- Resolve targets ---
if ($Folder) {
    $targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1
    if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }
    $targetVMObjects = Get-VM -Location $targetFolder -ErrorAction SilentlyContinue | Where-Object { $_.PowerState -eq 'PoweredOn' }
}
else {
    $targetVMObjects = foreach ($name in $TargetVMs) {
        $vmObj = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vmObj) {
            Write-Warning "Target VM '$name' not found in vCenter — will try as raw IP/hostname."
            [PSCustomObject]@{ Name = $name; IsRawIP = $true; IP = $name }
        }
        else { $vmObj }
    }
}

# Build target list with IPs
$targets = foreach ($t in $targetVMObjects) {
    if ($t.PSObject.Properties['IsRawIP'] -and $t.IsRawIP) {
        [PSCustomObject]@{ Name = $t.Name; IP = $t.IP }
    }
    else {
        $ip = $t.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        [PSCustomObject]@{ Name = $t.Name; IP = if ($ip) { $ip } else { '(unknown)' } }
    }
}

Write-Host "`n=== Service Port Reachability Test ===" -ForegroundColor Cyan
Write-Host "  Targets    : $($targets.Count) VMs" -ForegroundColor White
Write-Host "  Ports      : $($Ports -join ', ')" -ForegroundColor White
Write-Host "  Sources    : $(if ($SourceVMs) { ($SourceVMs -join ', ') + ' + local' } else { 'local machine only' })" -ForegroundColor White
Write-Host "  Timeout    : ${TimeoutSec}s`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-TestResult {
    param([string]$Source, [string]$SourceIP, [string]$SourceSubnet, [string]$TargetVM,
          [string]$TargetIP, [int]$Port, [string]$TCPResult, [int]$LatencyMs, [string]$Detail)
    $entry = [PSCustomObject]@{
        SourceVM      = $Source
        SourceIP      = $SourceIP
        SourceSubnet  = $SourceSubnet
        TargetVM      = $TargetVM
        TargetIP      = $TargetIP
        Port          = $Port
        TCPResult     = $TCPResult
        LatencyMs     = $LatencyMs
        Detail        = $Detail
        Timestamp     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $results.Add($entry)
    $color = switch ($TCPResult) { 'OPEN' { 'Green' } 'CLOSED' { 'Red' } 'TIMEOUT' { 'Yellow' } default { 'Gray' } }
    Write-Host "    $($Source.PadRight(20)) -> $($TargetVM.PadRight(15)) :$($Port.ToString().PadRight(6)) [$TCPResult] $Detail" -ForegroundColor $color
}

function Get-SubnetFromIP {
    param([string]$IP)
    if ($IP -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { return "$($Matches[1]).0/24" }
    return '(unknown)'
}

# --- Test from local machine ---
if ($TestFromLocal) {
    Write-Host "  Testing from: LOCAL ($env:COMPUTERNAME)" -ForegroundColor Cyan
    foreach ($target in $targets) {
        if ($target.IP -eq '(unknown)') {
            foreach ($port in $Ports) {
                Add-TestResult -Source 'LOCAL' -SourceIP '(self)' -SourceSubnet '(local)' `
                    -TargetVM $target.Name -TargetIP '(unknown)' -Port $port `
                    -TCPResult 'SKIP' -LatencyMs 0 -Detail "No IP address known for target"
            }
            continue
        }
        foreach ($port in $Ports) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($target.IP, $port, $null, $null)
                $done = $ar.AsyncWaitHandle.WaitOne($TimeoutSec * 1000, $false)
                $connected = $false
                if ($done) {
                    try { $tcp.EndConnect($ar); $connected = $true } catch {}
                }
                $sw.Stop()
                if ($connected) {
                    Add-TestResult -Source 'LOCAL' -SourceIP '(self)' -SourceSubnet '(local)' `
                        -TargetVM $target.Name -TargetIP $target.IP -Port $port `
                        -TCPResult 'OPEN' -LatencyMs $sw.ElapsedMilliseconds -Detail "Port open"
                }
                else {
                    Add-TestResult -Source 'LOCAL' -SourceIP '(self)' -SourceSubnet '(local)' `
                        -TargetVM $target.Name -TargetIP $target.IP -Port $port `
                        -TCPResult 'TIMEOUT' -LatencyMs $sw.ElapsedMilliseconds -Detail "Connection timed out"
                }
                $tcp.Close()
            }
            catch {
                $sw.Stop()
                Add-TestResult -Source 'LOCAL' -SourceIP '(self)' -SourceSubnet '(local)' `
                    -TargetVM $target.Name -TargetIP $target.IP -Port $port `
                    -TCPResult 'CLOSED' -LatencyMs $sw.ElapsedMilliseconds -Detail $_.Exception.Message
            }
        }
    }
}

# --- Test from source probe VMs via Invoke-VMScript ---
if ($SourceVMs) {
    foreach ($srcName in $SourceVMs) {
        $srcVM = Get-VM -Name $srcName -ErrorAction SilentlyContinue
        if (-not $srcVM) { Write-Warning "Source VM '$srcName' not found. Skipping."; continue }
        if ($srcVM.PowerState -ne 'PoweredOn') { Write-Warning "Source VM '$srcName' is not powered on. Skipping."; continue }

        $srcIP = $srcVM.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
        $srcSubnet = Get-SubnetFromIP -IP $srcIP

        Write-Host "`n  Testing from: $srcName ($srcIP - $srcSubnet)" -ForegroundColor Cyan

        foreach ($target in $targets) {
            if ($target.IP -eq '(unknown)') {
                foreach ($port in $Ports) {
                    Add-TestResult -Source $srcName -SourceIP $srcIP -SourceSubnet $srcSubnet `
                        -TargetVM $target.Name -TargetIP '(unknown)' -Port $port `
                        -TCPResult 'SKIP' -LatencyMs 0 -Detail "No IP for target"
                }
                continue
            }

            foreach ($port in $Ports) {
                # Build the in-guest test command
                if ($GuestOS -eq 'Linux') {
                    $script = "timeout $TimeoutSec bash -c 'echo > /dev/tcp/$($target.IP)/$port' 2>&1 && echo 'OPEN' || echo 'CLOSED'"
                }
                else {
                    $script = @"
`$tcp = New-Object System.Net.Sockets.TcpClient
try { `$tcp.ConnectAsync('$($target.IP)', $port).Wait($($TimeoutSec * 1000)); if (`$tcp.Connected) { 'OPEN' } else { 'CLOSED' } } catch { 'CLOSED' } finally { `$tcp.Close() }
"@
                }

                try {
                    $scriptType = if ($GuestOS -eq 'Linux') { 'Bash' } else { 'PowerShell' }
                    $result = Invoke-VMScript -VM $srcVM -ScriptText $script -ScriptType $scriptType `
                        -GuestCredential $GuestCredential -ErrorAction Stop

                    $output = $result.ScriptOutput.Trim()
                    $tcpResult = if ($output -match 'OPEN') { 'OPEN' } else { 'CLOSED' }

                    Add-TestResult -Source $srcName -SourceIP $srcIP -SourceSubnet $srcSubnet `
                        -TargetVM $target.Name -TargetIP $target.IP -Port $port `
                        -TCPResult $tcpResult -LatencyMs 0 -Detail "In-guest test: $output"
                }
                catch {
                    Add-TestResult -Source $srcName -SourceIP $srcIP -SourceSubnet $srcSubnet `
                        -TargetVM $target.Name -TargetIP $target.IP -Port $port `
                        -TCPResult 'ERROR' -LatencyMs 0 -Detail "Invoke-VMScript failed: $_"
                }
            }
        }
    }
}

# --- Results Matrix ---
Write-Host "`n--- Reachability Matrix ---" -ForegroundColor Cyan

# Build a pivot: Source x (Target:Port) => Result
$sources     = $results | Select-Object -ExpandProperty SourceVM -Unique
$targetPorts = $results | ForEach-Object { "$($_.TargetVM):$($_.Port)" } | Select-Object -Unique

Write-Host ""
$header = "  Source".PadRight(22)
foreach ($tp in $targetPorts) { $header += $tp.PadRight(22) }
Write-Host $header -ForegroundColor White
Write-Host ("  " + "-" * ($header.Length)) -ForegroundColor Gray

foreach ($src in $sources) {
    $line = "  $src".PadRight(22)
    foreach ($tp in $targetPorts) {
        $parts = $tp -split ':'
        $entry = $results | Where-Object { $_.SourceVM -eq $src -and $_.TargetVM -eq $parts[0] -and $_.Port -eq [int]$parts[1] } | Select-Object -First 1
        $val = if ($entry) { $entry.TCPResult } else { '?' }
        $color = switch ($val) { 'OPEN' { 'Green' } 'CLOSED' { 'Red' } 'TIMEOUT' { 'Yellow' } default { 'Gray' } }
        $line += $val.PadRight(22)
    }
    Write-Host $line -ForegroundColor White
}

# --- Summary ---
$open    = ($results | Where-Object { $_.TCPResult -eq 'OPEN'    }).Count
$closed  = ($results | Where-Object { $_.TCPResult -eq 'CLOSED'  }).Count
$timeout = ($results | Where-Object { $_.TCPResult -eq 'TIMEOUT' }).Count
$errors  = ($results | Where-Object { $_.TCPResult -eq 'ERROR'   }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total tests : $($results.Count)" -ForegroundColor White
Write-Host "  OPEN        : $open"    -ForegroundColor Green
Write-Host "  CLOSED      : $closed"  -ForegroundColor $(if ($closed  -gt 0) { 'Red'    } else { 'White' })
Write-Host "  TIMEOUT     : $timeout" -ForegroundColor $(if ($timeout -gt 0) { 'Yellow' } else { 'White' })
Write-Host "  ERROR       : $errors"  -ForegroundColor $(if ($errors  -gt 0) { 'Red'    } else { 'White' })

# Detect the cross-subnet pattern
$crossSubnetIssues = $results | Where-Object { $_.TCPResult -ne 'OPEN' -and $_.TCPResult -ne 'SKIP' } |
    Group-Object Port | ForEach-Object {
        $portFails = $_.Group
        $portNumber = [int]$_.Name
        $portOpens = $results | Where-Object { $_.Port -eq $portNumber -and $_.TCPResult -eq 'OPEN' }
        if ($portFails.Count -gt 0 -and $portOpens.Count -gt 0) {
            [PSCustomObject]@{ Port = $_.Name; FailCount = $portFails.Count; OpenCount = $portOpens.Count }
        }
    }

if ($crossSubnetIssues) {
    Write-Host "`n  ** Cross-subnet pattern detected **" -ForegroundColor Red
    Write-Host "  Some ports are reachable from certain sources but not others." -ForegroundColor Yellow
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    1. Service binding: Check if the service listens on 0.0.0.0 vs a specific IP" -ForegroundColor Yellow
    Write-Host "       (run 'ss -tlnp' or 'netstat -tlnp' on the target VM)" -ForegroundColor Gray
    Write-Host "    2. Guest firewall: iptables/firewalld may allow SSH but block app ports" -ForegroundColor Yellow
    Write-Host "       (run 'iptables -L -n' or 'firewall-cmd --list-all' on the target)" -ForegroundColor Gray
    Write-Host "    3. NSX/DFW: Distributed firewall rules may block specific ports cross-segment" -ForegroundColor Yellow
    Write-Host "    4. Router ACL: pfSense or upstream router may not permit these ports" -ForegroundColor Yellow
    Write-Host "    5. Port group security policy on the vSwitch" -ForegroundColor Yellow
}

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
