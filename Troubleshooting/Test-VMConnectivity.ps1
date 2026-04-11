<#
.SYNOPSIS
    Tests network reachability to VMs in a vSphere folder via ICMP ping and TCP port checks.

.DESCRIPTION
    Enumerates all VMs in the specified folder, resolves their guest IP addresses from
    VMware Tools, and tests ICMP reachability plus any specified TCP ports from the machine
    running this script (typically a jump host). Useful for quickly verifying that a cyber
    range network is up and reachable after deployment or exercise reset.

.PARAMETER Folder
    Required. The vSphere folder path containing the target VMs (e.g. "CyberRange\Exercise01").

.PARAMETER Ports
    Optional. Array of TCP ports to test on each VM (e.g. 22, 3389, 80, 443).
    If omitted, only ICMP ping is performed.

.PARAMETER TimeoutMs
    Optional. TCP connection timeout in milliseconds. Default: 1000.

.PARAMETER IncludeSubfolders
    Optional switch. Also test VMs in subfolders of the target folder.

.PARAMETER SkipPoweredOff
    Optional switch. Skip VMs that are not powered on.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER OutputFile
    Optional. Path to export the results as CSV.

.EXAMPLE
    .\Test-VMConnectivity.ps1 -Folder "CyberRange\Exercise01" -Ports 22,3389
    Ping all VMs in Exercise01 and test SSH and RDP ports.

.EXAMPLE
    .\Test-VMConnectivity.ps1 -Folder "CyberRange\Exercise01" -Ports 80,443,22 -SkipPoweredOff -OutputFile "connectivity.csv"
    Test web and SSH ports for powered-on VMs only, export to CSV.

.OUTPUTS
    CSV with columns: VMName, GuestOS, PowerState, IPAddress, PingResult, Port_<N> (one per tested port), OverallStatus

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools running in guest VMs (for IP address resolution)
    - Network connectivity from the machine running this script to the VMs

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Folder,

    [Parameter(Mandatory=$false)]
    [int[]]$Ports = @(),

    [Parameter(Mandatory=$false)]
    [int]$TimeoutMs = 1000,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSubfolders,

    [Parameter(Mandatory=$false)]
    [switch]$SkipPoweredOff,

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

# --- Resolve folder ---
$targetFolder = Get-Folder -Name ($Folder -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'VM' } | Select-Object -First 1

if (-not $targetFolder) { Write-Error "Folder '$Folder' not found."; exit 1 }

$vms = if ($IncludeSubfolders) {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue
} else {
    Get-VM -Location $targetFolder -ErrorAction SilentlyContinue |
        Where-Object { $_.FolderId -eq $targetFolder.Id }
}

if (-not $vms) { Write-Warning "No VMs found in folder '$Folder'."; exit 0 }

if ($SkipPoweredOff) { $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' } }

Write-Host "`n=== VM Connectivity Test ===" -ForegroundColor Cyan
Write-Host "  Folder    : $Folder ($($vms.Count) VMs)" -ForegroundColor White
Write-Host "  Ports     : $(if ($Ports.Count -gt 0) { $Ports -join ', ' } else { 'ICMP only' })" -ForegroundColor White
Write-Host "  Timeout   : ${TimeoutMs}ms`n" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vm in $vms | Sort-Object Name) {
    $ipAddress = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1

    $row = [ordered]@{
        VMName        = $vm.Name
        GuestOS       = $vm.Guest.OSFullName
        PowerState    = $vm.PowerState
        IPAddress     = if ($ipAddress) { $ipAddress } else { '(unknown)' }
        PingResult    = 'N/A'
        OverallStatus = 'N/A'
    }

    if (-not $ipAddress) {
        $row['OverallStatus'] = 'NO_IP'
        foreach ($port in $Ports) { $row["Port_$port"] = 'NO_IP' }
        $results.Add([PSCustomObject]$row)
        Write-Host "  [NO_IP]   $($vm.Name) - No IP address from VMware Tools" -ForegroundColor Yellow
        continue
    }

    # ICMP ping
    $ping = Test-Connection -ComputerName $ipAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
    $row['PingResult'] = if ($ping) { 'OK' } else { 'FAIL' }

    # TCP port tests
    $portStatuses = @{}
    foreach ($port in $Ports) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connect = $tcp.BeginConnect($ipAddress, $port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            $isOpen = $false
            if ($wait) {
                try { $tcp.EndConnect($connect); $isOpen = $true } catch {}
            }
            $tcp.Close()
            $portStatuses[$port] = if ($isOpen) { 'OPEN' } else { 'CLOSED' }
        }
        catch {
            $portStatuses[$port] = 'ERROR'
        }
        $row["Port_$port"] = $portStatuses[$port]
    }

    # Overall status
    $allPortsOk = ($Ports.Count -eq 0) -or ($portStatuses.Values | Where-Object { $_ -ne 'OPEN' }).Count -eq 0
    $row['OverallStatus'] = if ($ping -and $allPortsOk) { 'OK' } elseif ($ping) { 'PARTIAL' } else { 'UNREACHABLE' }

    $results.Add([PSCustomObject]$row)

    $color  = switch ($row['OverallStatus']) { 'OK' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }
    $portStr = if ($Ports.Count -gt 0) {
        ' | ' + (($Ports | ForEach-Object { "${_}:$($portStatuses[$_])" }) -join ' ')
    } else { '' }
    Write-Host "  [$($row['OverallStatus'])]  $($vm.Name) ($ipAddress) | PING:$($row['PingResult'])$portStr" -ForegroundColor $color
}

# --- Summary ---
$ok          = ($results | Where-Object { $_.OverallStatus -eq 'OK'          }).Count
$partial     = ($results | Where-Object { $_.OverallStatus -eq 'PARTIAL'     }).Count
$unreachable = ($results | Where-Object { $_.OverallStatus -eq 'UNREACHABLE' }).Count
$noIp        = ($results | Where-Object { $_.OverallStatus -eq 'NO_IP'       }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Total VMs   : $($results.Count)" -ForegroundColor White
Write-Host "  OK          : $ok"          -ForegroundColor Green
Write-Host "  Partial     : $partial"     -ForegroundColor Yellow
Write-Host "  Unreachable : $unreachable" -ForegroundColor $(if ($unreachable -gt 0) { 'Red'    } else { 'White' })
Write-Host "  No IP       : $noIp"        -ForegroundColor $(if ($noIp        -gt 0) { 'Yellow' } else { 'White' })

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation
    Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
}
elseif ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
}
