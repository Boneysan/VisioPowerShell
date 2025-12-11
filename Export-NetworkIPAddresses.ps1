<#
.SYNOPSIS
    Exports VMware network port groups with associated VM IP addresses to CSV.

.DESCRIPTION
    This script collects information about all powered-on VMs and their network configurations,
    then exports a detailed CSV report showing which VMs are connected to which networks,
    along with IP addresses, DHCP status, and VM specifications.
    
    The script analyzes network adapters and matches them with guest OS network information
    to provide comprehensive network mapping. It filters out IPv6 and link-local addresses,
    focusing on IPv4 network assignments.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER OutputFile
    Optional. Path and filename for the output CSV file. Default: "network-ip-addresses.csv" in current directory.
    Supports both relative and absolute paths.

.EXAMPLE
    .\Export-NetworkIPAddresses.ps1
    Uses existing vCenter connection and exports to network-ip-addresses.csv in current directory.

.EXAMPLE
    .\Export-NetworkIPAddresses.ps1 -vCenter "vcenter.example.com"
    Connects to specified vCenter and exports network information.

.EXAMPLE
    .\Export-NetworkIPAddresses.ps1 -OutputFile "C:\Reports\network-report.csv"
    Exports to a specific file location.

.EXAMPLE
    .\Export-NetworkIPAddresses.ps1 -vCenter "vcenter.example.com" -OutputFile "my-networks.csv"
    Connects to vCenter and exports to custom filename.

.OUTPUTS
    CSV file with the following columns:
    - NetworkName: Port group or DVS port group name
    - VMName: Virtual machine name
    - AdapterName: Network adapter identifier (e.g., "Network adapter 1")
    - IPAddress: IPv4 address (or "No IP" if not assigned)
    - DHCPEnabled: Yes/No/Unknown (requires VMware Tools)
    - MACAddress: Network adapter MAC address
    - PowerState: VM power state (PoweredOn/PoweredOff/Suspended)
    - NumCpu: Number of CPUs assigned to VM
    - MemoryGB: RAM allocated to VM in GB

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter and VM guest information
    - VMware Tools must be installed and running on VMs for:
      * IP address detection
      * DHCP status detection
      * Accurate network adapter matching
    
    Limitations:
    - Only includes powered-on VMs
    - IPv6 addresses are filtered out
    - Link-local addresses (169.254.x.x) are excluded
    - DHCP status shows "Unknown" if VMware Tools is not running
    - If a VM has multiple IPs on one adapter, separate rows are created for each IP
    
    Performance:
    - Typically processes 100 VMs in 10-30 seconds depending on network latency
    
    Output Location:
    - The script displays the full absolute path where the CSV is saved
    - Default is current directory where script is executed
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "network-ip-addresses.csv"
)

# Connect to vCenter if specified
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

Write-Host "Collecting VM and network data..." -ForegroundColor Cyan

# Get all VMs
$allVMs = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
Write-Host "  Found $($allVMs.Count) powered-on VMs" -ForegroundColor White

# Get all network adapters
$allAdapters = Get-NetworkAdapter -VM $allVMs
Write-Host "  Found $($allAdapters.Count) network adapters" -ForegroundColor White

# Build network-to-IP mapping
Write-Host "Analyzing network assignments..." -ForegroundColor Cyan

$results = @()

foreach ($adapter in $allAdapters) {
    $vm = $allVMs | Where-Object { $_.Id -eq $adapter.Parent.Id }
    
    if ($vm) {
        # Get IP addresses for this VM
        $ipAddresses = $vm.Guest.IPAddress | Where-Object { 
            $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and 
            $_ -notmatch '^169\.254\.' 
        }
        
        # Get DHCP status from guest NIC info
        $dhcpEnabled = "Unknown"
        try {
            if ($vm.Guest.Nics) {
                $guestNic = $vm.Guest.Nics | Where-Object { $_.MacAddress -eq $adapter.MacAddress }
                if ($guestNic) {
                    # Check if any IP config uses DHCP
                    if ($guestNic.IpConfig -and $guestNic.IpConfig.Count -gt 0) {
                        $hasDhcp = $false
                        foreach ($ipConfig in $guestNic.IpConfig) {
                            if ($ipConfig.Dhcp -and $ipConfig.Dhcp.Ipv4 -and $ipConfig.Dhcp.Ipv4.Enable) {
                                $hasDhcp = $true
                                break
                            }
                        }
                        $dhcpEnabled = if ($hasDhcp) { "Yes" } else { "No" }
                    }
                }
            }
        }
        catch {
            $dhcpEnabled = "Unknown"
        }
        
        # Create entry for each IP (or one entry if no IP)
        if ($ipAddresses) {
            foreach ($ip in $ipAddresses) {
                $results += [PSCustomObject]@{
                    NetworkName = $adapter.NetworkName
                    VMName = $vm.Name
                    AdapterName = $adapter.Name
                    IPAddress = $ip
                    DHCPEnabled = $dhcpEnabled
                    MACAddress = $adapter.MacAddress
                    PowerState = $vm.PowerState
                    NumCpu = $vm.NumCpu
                    MemoryGB = [math]::Round($vm.MemoryGB, 1)
                }
            }
        }
        else {
            # No IP address found
            $results += [PSCustomObject]@{
                NetworkName = $adapter.NetworkName
                VMName = $vm.Name
                AdapterName = $adapter.Name
                IPAddress = "No IP"
                DHCPEnabled = $dhcpEnabled
                MACAddress = $adapter.MacAddress
                PowerState = $vm.PowerState
                NumCpu = $vm.NumCpu
                MemoryGB = [math]::Round($vm.MemoryGB, 1)
            }
        }
    }
}

# Sort by network name, then IP address
$results = $results | Sort-Object NetworkName, IPAddress

# Export to CSV
$absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
$results | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Export complete!" -ForegroundColor Green
Write-Host "  Total entries: $($results.Count)" -ForegroundColor White
Write-Host "  Unique networks: $(($results | Select-Object -Unique NetworkName).Count)" -ForegroundColor White
Write-Host "  File saved to: $absolutePath" -ForegroundColor Green
Write-Host ""

# Display summary by network
Write-Host "Network Summary:" -ForegroundColor Cyan
$networkSummary = $results | Group-Object NetworkName | Sort-Object Name
foreach ($network in $networkSummary) {
    $ipCount = ($network.Group | Where-Object { $_.IPAddress -ne "No IP" }).Count
    Write-Host "  $($network.Name): $($network.Count) adapters, $ipCount with IPs" -ForegroundColor White
}
