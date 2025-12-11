# vDiagram-NetworkTopology.ps1
# Advanced Network Topology Visualization for VMware Infrastructure
# Generates hierarchical network maps with VLAN zones, subnet grouping, and security boundaries

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "network-topology.drawio",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("VLAN", "Subnet", "SecurityZone", "Layer2Domain")]
    [string]$GroupBy = "VLAN",
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeSwimLanes,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowIsolatedNetworks,
    
    [Parameter(Mandatory=$false)]
    [switch]$IdentifyGateways
)

# Import required modules
if (-not (Get-Module -Name VMware.PowerCLI -ListAvailable)) {
    Write-Error "VMware PowerCLI module is required. Install with: Install-Module -Name VMware.PowerCLI"
    exit 1
}

#region Helper Functions

function Get-SubnetFromIP {
    param([string]$IPAddress, [int]$CIDR = 24)
    
    if ([string]::IsNullOrEmpty($IPAddress)) { return $null }
    
    try {
        $ip = [System.Net.IPAddress]::Parse($IPAddress)
        $bytes = $ip.GetAddressBytes()
        
        # Calculate subnet based on CIDR
        $maskBytes = [byte[]]::new(4)
        $fullBytes = [Math]::Floor($CIDR / 8)
        $remainingBits = $CIDR % 8
        
        for ($i = 0; $i -lt $fullBytes; $i++) {
            $maskBytes[$i] = 255
        }
        if ($remainingBits -gt 0) {
            $maskBytes[$fullBytes] = 256 - [Math]::Pow(2, 8 - $remainingBits)
        }
        
        # Apply mask to get subnet
        $subnetBytes = @()
        for ($i = 0; $i -lt 4; $i++) {
            $subnetBytes += $bytes[$i] -band $maskBytes[$i]
        }
        
        return "$($subnetBytes[0]).$($subnetBytes[1]).$($subnetBytes[2]).$($subnetBytes[3])/$CIDR"
    }
    catch {
        return $null
    }
}

function Get-NetworkSecurityZone {
    param([string]$NetworkName, [string]$IPAddress, [int]$VlanId)
    
    # Classify networks into security zones based on naming and IP patterns
    if ($NetworkName -match "DMZ|External|Internet|INTRNET") {
        return "DMZ"
    }
    elseif ($NetworkName -match "Management|Mgmt|mc-internal|fw-mgmt") {
        return "Management"
    }
    elseif ($NetworkName -match "vMotion|vSAN|Storage|BMC") {
        return "Infrastructure"
    }
    elseif ($NetworkName -match "Production|PROD|OPS") {
        return "Production"
    }
    elseif ($NetworkName -match "Dev|Test|QA|IQT|DevTest") {
        return "Development"
    }
    elseif ($NetworkName -match "Office|OFFICE") {
        return "Corporate"
    }
    elseif ($NetworkName -match "Guest|VDE") {
        return "Guest"
    }
    else {
        return "Unclassified"
    }
}

function Get-VMNetworkDetails {
    param($VM, $NetworkAdapters)
    
    $details = @()
    $vmAdapters = $NetworkAdapters | Where-Object { $_.Parent.Name -eq $VM.Name }
    
    foreach ($adapter in $vmAdapters) {
        $ipAddress = ""
        if ($VM.Guest.IPAddress) {
            # Filter out IPv6 and link-local addresses
            $ipv4 = $VM.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^169\.254\.' }
            if ($ipv4) {
                $ipAddress = ($ipv4 | Select-Object -First 1)
            }
        }
        
        $details += "[$($adapter.Name)]"
        if ($ipAddress) {
            $details += "IP: $ipAddress"
        }
        $details += "Net: $($adapter.NetworkName)"
        if ($adapter.MacAddress) {
            $details += "MAC: $($adapter.MacAddress)"
        }
    }
    
    # Add VM details
    $vmInfo = @()
    $vmInfo += "CPU: $($VM.NumCpu)"
    $vmInfo += "RAM: $([math]::Round($VM.MemoryGB, 1))GB"
    if ($VM.PowerState) {
        $vmInfo += "State: $($VM.PowerState)"
    }
    
    $allDetails = $details + $vmInfo
    return ($allDetails -join "<br>")
}

function Analyze-NetworkTopology {
    param(
        [Parameter(Mandatory=$true)]
        [array]$VMs,
        
        [Parameter(Mandatory=$false)]
        [array]$PortGroups = @(),
        
        [Parameter(Mandatory=$true)]
        [array]$NetworkAdapters
    )
    
    Write-Host "Analyzing network topology..." -ForegroundColor Cyan
    
    # Build network topology data structure
    $topology = @{
        Networks = @{}
        VLANs = @{}
        Subnets = @{}
        SecurityZones = @{}
        GatewayVMs = @()
        IsolatedNetworks = @()
        Statistics = @{
            TotalVMs = $VMs.Count
            TotalNetworks = $PortGroups.Count
            TotalAdapters = $NetworkAdapters.Count
        }
    }
    
    # Analyze port groups and networks
    if ($null -ne $PortGroups -and $PortGroups.Count -gt 0) {
        foreach ($pg in $PortGroups) {
        $vlanId = if ($pg.VlanId) { $pg.VlanId } else { 0 }
        $networkName = $pg.Name
        $switchName = $pg.VirtualSwitchName
        
        if (-not $topology.Networks.ContainsKey($networkName)) {
            $topology.Networks[$networkName] = @{
                Name = $networkName
                VLanId = $vlanId
                Switch = $switchName
                VMs = @()
                IPAddresses = @()
                Subnets = @()
                SecurityZone = ""
                IsIsolated = $false
                Type = if ($pg.PSObject.Properties['ExtensionData']) { 
                    $pg.ExtensionData.GetType().Name 
                } else { 
                    "Unknown" 
                }
            }
        }
        
        # Group by VLAN
        if (-not $topology.VLANs.ContainsKey($vlanId)) {
            $topology.VLANs[$vlanId] = @{
                VLanId = $vlanId
                Networks = @()
                VMs = @()
            }
        }
        if ($topology.VLANs[$vlanId].Networks -notcontains $networkName) {
            $topology.VLANs[$vlanId].Networks += $networkName
        }
        }
    }
    
    # Analyze VMs and their network connections
    foreach ($vm in $VMs) {
        $vmAdapters = $NetworkAdapters | Where-Object { $_.Parent.Name -eq $vm.Name }
        $vmNetworks = @()
        $vmIPs = @()
        
        foreach ($adapter in $vmAdapters) {
            $networkName = $adapter.NetworkName
            $vmNetworks += $networkName
            
            # Get IP addresses
            $ips = $vm.Guest.IPAddress | Where-Object { 
                $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and 
                $_ -notmatch '^169\.254\.' 
            }
            
            foreach ($ip in $ips) {
                $vmIPs += $ip
                
                # Calculate subnet
                $subnet = Get-SubnetFromIP -IPAddress $ip -CIDR 24
                if ($subnet) {
                    if (-not $topology.Subnets.ContainsKey($subnet)) {
                        $topology.Subnets[$subnet] = @{
                            Subnet = $subnet
                            Networks = @()
                            VMs = @()
                            IPAddresses = @()
                        }
                    }
                    if ($topology.Subnets[$subnet].VMs -notcontains $vm.Name) {
                        $topology.Subnets[$subnet].VMs += $vm.Name
                        $topology.Subnets[$subnet].IPAddresses += $ip
                    }
                    if ($topology.Subnets[$subnet].Networks -notcontains $networkName) {
                        $topology.Subnets[$subnet].Networks += $networkName
                    }
                    
                    # Add subnet to network
                    if ($topology.Networks.ContainsKey($networkName)) {
                        if ($topology.Networks[$networkName].Subnets -notcontains $subnet) {
                            $topology.Networks[$networkName].Subnets += $subnet
                        }
                    }
                }
            }
            
            # Add VM to network (create network entry if from adapters only)
            if (-not $topology.Networks.ContainsKey($networkName)) {
                # Create network entry from adapter info
                $topology.Networks[$networkName] = @{
                    Name = $networkName
                    VLanId = 0
                    Switch = "Unknown"
                    VMs = @()
                    IPAddresses = @()
                    Subnets = @()
                    SecurityZone = ""
                    IsIsolated = $false
                    Type = "Adapter-Derived"
                }
                
                # Add to VLAN 0 group
                if (-not $topology.VLANs.ContainsKey(0)) {
                    $topology.VLANs[0] = @{
                        VLanId = 0
                        Networks = @()
                        VMs = @()
                    }
                }
                if ($topology.VLANs[0].Networks -notcontains $networkName) {
                    $topology.VLANs[0].Networks += $networkName
                }
            }
            
            if ($topology.Networks[$networkName].VMs -notcontains $vm.Name) {
                $topology.Networks[$networkName].VMs += $vm.Name
            }
            $topology.Networks[$networkName].IPAddresses += $vmIPs
            
            # Add VM to VLAN group
            $vlanId = $topology.Networks[$networkName].VLanId
            if ($topology.VLANs.ContainsKey($vlanId)) {
                if ($topology.VLANs[$vlanId].VMs -notcontains $vm.Name) {
                    $topology.VLANs[$vlanId].VMs += $vm.Name
                }
            }
        }
        
        # Identify gateway VMs (connected to multiple networks)
        if ($vmNetworks.Count -gt 1) {
            $topology.GatewayVMs += @{
                Name = $vm.Name
                Networks = $vmNetworks
                IPAddresses = $vmIPs
                AdapterCount = $vmAdapters.Count
            }
        }
    }
    
    # Classify networks by security zone
    foreach ($networkName in $topology.Networks.Keys) {
        $network = $topology.Networks[$networkName]
        $sampleIP = $network.IPAddresses | Where-Object { $_ } | Select-Object -First 1
        $zone = Get-NetworkSecurityZone -NetworkName $networkName -IPAddress $sampleIP -VlanId $network.VLanId
        $network.SecurityZone = $zone
        
        # Group by security zone
        if (-not $topology.SecurityZones.ContainsKey($zone)) {
            $topology.SecurityZones[$zone] = @{
                Zone = $zone
                Networks = @()
                VMs = @()
            }
        }
        if ($topology.SecurityZones[$zone].Networks -notcontains $networkName) {
            $topology.SecurityZones[$zone].Networks += $networkName
            $topology.SecurityZones[$zone].VMs += $network.VMs
        }
        
        # Check if network is isolated (no VMs or only 1 VM)
        if ($network.VMs.Count -le 1) {
            $network.IsIsolated = $true
            $topology.IsolatedNetworks += $networkName
        }
    }
    
    return $topology
}

#endregion

#region Draw.io XML Generation

function New-DrawIOShape {
    param(
        [int]$Id,
        [string]$Value,
        [string]$Style,
        [int]$X,
        [int]$Y,
        [int]$Width = 120,
        [int]$Height = 60,
        [string]$Parent = "1"
    )
    
    $cell = $script:xml.CreateElement("mxCell")
    $cell.SetAttribute("id", $Id)
    $cell.SetAttribute("value", $Value)
    # Add html=1 to style if not already present
    $finalStyle = if ($Style -notmatch "html=1") { "$Style;html=1" } else { $Style }
    $cell.SetAttribute("style", $finalStyle)
    $cell.SetAttribute("vertex", "1")
    $cell.SetAttribute("parent", $Parent)
    
    $geometry = $script:xml.CreateElement("mxGeometry")
    $geometry.SetAttribute("x", $X)
    $geometry.SetAttribute("y", $Y)
    $geometry.SetAttribute("width", $Width)
    $geometry.SetAttribute("height", $Height)
    $geometry.SetAttribute("as", "geometry")
    
    $cell.AppendChild($geometry) | Out-Null
    return $cell
}

function New-DrawIOContainer {
    param(
        [int]$Id,
        [string]$Value,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$FillColor = "#E1F5FE",
        [string]$StrokeColor = "#0277BD"
    )
    
    $style = "swimlane;fontStyle=1;childLayout=stackLayout;horizontal=1;startSize=30;horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=0;marginBottom=0;fillColor=$FillColor;strokeColor=$StrokeColor;fontColor=#000000;"
    return New-DrawIOShape -Id $Id -Value $Value -Style $style -X $X -Y $Y -Width $Width -Height $Height
}

function Connect-DrawIOShape {
    param([int]$Id, [int]$Source, [int]$Target, [string]$Label = "")
    
    $cell = $script:xml.CreateElement("mxCell")
    $cell.SetAttribute("id", $Id)
    $cell.SetAttribute("value", $Label)
    $cell.SetAttribute("style", "edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=#666666;")
    $cell.SetAttribute("edge", "1")
    $cell.SetAttribute("source", $Source)
    $cell.SetAttribute("target", $Target)
    $cell.SetAttribute("parent", "1")
    
    $geometry = $script:xml.CreateElement("mxGeometry")
    $geometry.SetAttribute("relative", "1")
    $geometry.SetAttribute("as", "geometry")
    $cell.AppendChild($geometry) | Out-Null
    
    return $cell
}

function Export-NetworkTopologyDiagram {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Topology,
        
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$GroupBy,
        
        [bool]$UseSwimLanes,
        
        [bool]$ShowIsolated,
        
        [bool]$HighlightGateways,
        
        [Parameter(Mandatory=$false)]
        [array]$AllVMs = @(),
        
        [Parameter(Mandatory=$false)]
        [array]$AllNetworkAdapters = @()
    )
    
    Write-Host "Generating network topology diagram..." -ForegroundColor Cyan
    
    # Create XML document
    $script:xml = New-Object System.Xml.XmlDocument
    $xmlDeclaration = $script:xml.CreateXmlDeclaration("1.0", "utf-8", $null)
    $script:xml.AppendChild($xmlDeclaration) | Out-Null
    
    # Create mxfile root
    $mxfile = $script:xml.CreateElement("mxfile")
    $script:xml.AppendChild($mxfile) | Out-Null
    
    # Create diagram
    $diagram = $script:xml.CreateElement("diagram")
    $diagram.SetAttribute("id", "network-topology")
    $diagram.SetAttribute("name", "Network Topology - $GroupBy View")
    $mxfile.AppendChild($diagram) | Out-Null
    
    # Create mxGraphModel
    $graphModel = $script:xml.CreateElement("mxGraphModel")
    $graphModel.SetAttribute("dx", "0")
    $graphModel.SetAttribute("dy", "0")
    $graphModel.SetAttribute("grid", "1")
    $graphModel.SetAttribute("gridSize", "10")
    $diagram.AppendChild($graphModel) | Out-Null
    
    # Create root
    $root = $script:xml.CreateElement("root")
    $graphModel.AppendChild($root) | Out-Null
    
    # Create base cells
    $cell0 = $script:xml.CreateElement("mxCell")
    $cell0.SetAttribute("id", "0")
    $root.AppendChild($cell0) | Out-Null
    
    $cell1 = $script:xml.CreateElement("mxCell")
    $cell1.SetAttribute("id", "1")
    $cell1.SetAttribute("parent", "0")
    $root.AppendChild($cell1) | Out-Null
    
    $currentId = 2
    $x = 50
    $y = 50
    
    # Zone colors
    $zoneColors = @{
        "DMZ" = @{Fill = "#FFCDD2"; Stroke = "#C62828"}
        "Management" = @{Fill = "#E1BEE7"; Stroke = "#6A1B9A"}
        "Infrastructure" = @{Fill = "#C5CAE9"; Stroke = "#283593"}
        "Production" = @{Fill = "#C8E6C9"; Stroke = "#2E7D32"}
        "Development" = @{Fill = "#FFF9C4"; Stroke = "#F57F17"}
        "Corporate" = @{Fill = "#BBDEFB"; Stroke = "#1565C0"}
        "Guest" = @{Fill = "#FFE0B2"; Stroke = "#E65100"}
        "Unclassified" = @{Fill = "#F5F5F5"; Stroke = "#757575"}
    }
    
    # Generate diagram based on grouping method
    switch ($GroupBy) {
        "VLAN" {
            $sortedVLANs = $Topology.VLANs.Keys | Sort-Object
            
            foreach ($vlanId in $sortedVLANs) {
                $vlan = $Topology.VLANs[$vlanId]
                if (-not $ShowIsolated -and $vlan.VMs.Count -eq 0) { continue }
                
                $vlanLabel = if ($vlanId -eq 0) { "Untagged" } else { "VLAN $vlanId" }
                $networks = $vlan.Networks
                
                if ($UseSwimLanes) {
                    # Create swim lane for VLAN
                    $containerHeight = 300 + ($networks.Count * 480)
                    $container = New-DrawIOContainer -Id $currentId -Value $vlanLabel -X $x -Y $y -Width 1200 -Height $containerHeight
                    $root.AppendChild($container) | Out-Null
                    $containerId = $currentId
                    $currentId++
                    
                    $netX = 20
                    $netY = 50
                    
                    foreach ($networkName in $networks) {
                        $network = $Topology.Networks[$networkName]
                        $vmCount = $network.VMs.Count
                        
                        # Draw network
                        $netLabel = "$networkName`nVMs: $vmCount`nSubnets: $($network.Subnets -join ', ')"
                        $netCell = New-DrawIOShape -Id $currentId -Value $netLabel -Style "shape=mxgraph.cisco.switches.layer_2_remote_switch;fillColor=#B6D7A8;strokeColor=#6AA84F;" -X $netX -Y $netY -Width 120 -Height 60 -Parent $containerId
                        $root.AppendChild($netCell) | Out-Null
                        $netId = $currentId
                        $currentId++
                        
                        # Draw VMs
                        $vmX = $netX + 200
                        $vmY = $netY
                        foreach ($vmName in $network.VMs) {
                            $vm = $allVMs | Where-Object { $_.Name -eq $vmName }
                            $vmDetails = ""
                            if ($vm) {
                                $vmDetails = Get-VMNetworkDetails -VM $vm -NetworkAdapters $allNetworkAdapters
                                $vmLabel = "$vmName`n$vmDetails"
                            } else {
                                $vmLabel = $vmName
                            }
                            $vmCell = New-DrawIOShape -Id $currentId -Value $vmLabel -Style "shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;" -X $vmX -Y $vmY -Width 200 -Height 420 -Parent $containerId
                            $root.AppendChild($vmCell) | Out-Null
                            
                            # Connect VM to network
                            $edge = Connect-DrawIOShape -Id ($currentId+1) -Source $netId -Target $currentId
                            $root.AppendChild($edge) | Out-Null
                            
                            $currentId += 2
                            $vmX += 220
                            if ($vmX -gt 1000) {
                                $vmX = $netX + 200
                                $vmY += 450
                            }
                        }
                        
                        $netY += 450
                    }
                    
                    $y += $containerHeight + 50
                }
                else {
                    # Flat layout
                    foreach ($networkName in $networks) {
                        $network = $Topology.Networks[$networkName]
                        $vmCount = $network.VMs.Count
                        
                        $netLabel = "$vlanLabel - $networkName`nVMs: $vmCount"
                        $netCell = New-DrawIOShape -Id $currentId -Value $netLabel -Style "shape=mxgraph.cisco.switches.layer_2_remote_switch;fillColor=#B6D7A8;strokeColor=#6AA84F;" -X $x -Y $y
                        $root.AppendChild($netCell) | Out-Null
                        $netId = $currentId
                        $currentId++
                        
                        $vmX = $x + 200
                        $startY = $y
                        foreach ($vmName in $network.VMs) {
                            $vm = $allVMs | Where-Object { $_.Name -eq $vmName }
                            $vmDetails = ""
                            if ($vm) {
                                $vmDetails = Get-VMNetworkDetails -VM $vm -NetworkAdapters $allNetworkAdapters
                                $vmLabel = "$vmName`n$vmDetails"
                            } else {
                                $vmLabel = $vmName
                            }
                            $vmCell = New-DrawIOShape -Id $currentId -Value $vmLabel -Style "shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;" -X $vmX -Y $y -Width 200 -Height 420
                            $root.AppendChild($vmCell) | Out-Null
                            
                            $edge = Connect-DrawIOShape -Id ($currentId+1) -Source $netId -Target $currentId
                            $root.AppendChild($edge) | Out-Null
                            
                            $currentId += 2
                            $vmX += 220
                            if ($vmX -gt 1400) {
                                $vmX = $x + 200
                                $y += 480
                            }
                        }
                        
                        $y = [Math]::Max($y, $startY) + 480
                    }
                }
            }
        }
        
        "SecurityZone" {
            $sortedZones = $Topology.SecurityZones.Keys | Sort-Object
            
            foreach ($zoneName in $sortedZones) {
                $zone = $Topology.SecurityZones[$zoneName]
                if (-not $ShowIsolated -and $zone.VMs.Count -eq 0) { continue }
                
                $colors = $zoneColors[$zoneName]
                $networks = $zone.Networks
                
                if ($UseSwimLanes) {
                    $containerHeight = 300 + ($networks.Count * 480)
                    $container = New-DrawIOContainer -Id $currentId -Value "$zoneName Zone" -X $x -Y $y -Width 1400 -Height $containerHeight -FillColor $colors.Fill -StrokeColor $colors.Stroke
                    $root.AppendChild($container) | Out-Null
                    $containerId = $currentId
                    $currentId++
                    
                    $netX = 20
                    $netY = 50
                    
                    foreach ($networkName in $networks) {
                        $network = $Topology.Networks[$networkName]
                        $vmCount = $network.VMs.Count
                        $vlanLabel = if ($network.VLanId -eq 0) { "Untagged" } else { "VLAN $($network.VLanId)" }
                        
                        $netLabel = "$networkName`n$vlanLabel`nVMs: $vmCount"
                        $netCell = New-DrawIOShape -Id $currentId -Value $netLabel -Style "shape=mxgraph.cisco.switches.layer_2_remote_switch;fillColor=#B6D7A8;strokeColor=#6AA84F;" -X $netX -Y $netY -Width 150 -Height 70 -Parent $containerId
                        $root.AppendChild($netCell) | Out-Null
                        $netId = $currentId
                        $currentId++
                        
                        $vmX = $netX + 200
                        $vmY = $netY
                        foreach ($vmName in $network.VMs) {
                            $vm = $allVMs | Where-Object { $_.Name -eq $vmName }
                            $gateway = $Topology.GatewayVMs | Where-Object { $_.Name -eq $vmName }
                            $vmStyle = if ($HighlightGateways -and $gateway) {
                                "shape=mxgraph.cisco.servers.virtual_server;fillColor=#FFD54F;strokeColor=#F57C00;"
                            } else {
                                "shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;"
                            }
                            
                            $vmDetails = ""
                            if ($vm) {
                                $vmDetails = Get-VMNetworkDetails -VM $vm -NetworkAdapters $allNetworkAdapters
                                $vmLabel = "$vmName`n$vmDetails"
                            } else {
                                $vmLabel = $vmName
                            }
                            
                            $vmCell = New-DrawIOShape -Id $currentId -Value $vmLabel -Style $vmStyle -X $vmX -Y $vmY -Width 200 -Height 420 -Parent $containerId
                            $root.AppendChild($vmCell) | Out-Null
                            
                            $edge = Connect-DrawIOShape -Id ($currentId+1) -Source $netId -Target $currentId
                            $root.AppendChild($edge) | Out-Null
                            
                            $currentId += 2
                            $vmX += 220
                            if ($vmX -gt 1200) {
                                $vmX = $netX + 200
                                $vmY += 450
                            }
                        }
                        
                        $netY = [Math]::Max($netY, $vmY) + 450
                    }
                    
                    $y += $containerHeight + 50
                }
            }
        }
        
        "Subnet" {
            $sortedSubnets = $Topology.Subnets.Keys | Sort-Object
            
            foreach ($subnet in $sortedSubnets) {
                $subnetData = $Topology.Subnets[$subnet]
                if (-not $ShowIsolated -and $subnetData.VMs.Count -eq 0) { continue }
                
                $subnetLabel = "$subnet`nVMs: $($subnetData.VMs.Count)`nNetworks: $($subnetData.Networks.Count)"
                $subnetCell = New-DrawIOShape -Id $currentId -Value $subnetLabel -Style "shape=mxgraph.cisco.routers.router;fillColor=#FFE599;strokeColor=#F1C232;" -X $x -Y $y -Width 150 -Height 70
                $root.AppendChild($subnetCell) | Out-Null
                $subnetId = $currentId
                $currentId++
                
                $vmX = $x + 200
                $startY = $y
                foreach ($vmName in $subnetData.VMs) {
                    $vm = $allVMs | Where-Object { $_.Name -eq $vmName }
                    $vmDetails = ""
                    if ($vm) {
                        $vmDetails = Get-VMNetworkDetails -VM $vm -NetworkAdapters $allNetworkAdapters
                        $vmLabel = "$vmName`n$vmDetails"
                    } else {
                        $vmLabel = $vmName
                    }
                    $vmCell = New-DrawIOShape -Id $currentId -Value $vmLabel -Style "shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;" -X $vmX -Y $y -Width 200 -Height 420
                    $root.AppendChild($vmCell) | Out-Null
                    
                    $edge = Connect-DrawIOShape -Id ($currentId+1) -Source $subnetId -Target $currentId
                    $root.AppendChild($edge) | Out-Null
                    
                    $currentId += 2
                    $vmX += 220
                    if ($vmX -gt 1400) {
                        $vmX = $x + 200
                        $y += 480
                    }
                }
                
                $y = [Math]::Max($y, $startY) + 480
            }
        }
    }
    
    # Add legend
    $legendY = $y + 50
    $legendCell = New-DrawIOShape -Id $currentId -Value "Legend" -Style "text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=top;whiteSpace=wrap;rounded=0;fontStyle=1;fontSize=14;" -X 50 -Y $legendY -Width 200 -Height 30
    $root.AppendChild($legendCell) | Out-Null
    $currentId++
    
    if ($HighlightGateways) {
        $gatewayCell = New-DrawIOShape -Id $currentId -Value "Gateway VM (Multiple Networks)" -Style "shape=mxgraph.cisco.servers.virtual_server;fillColor=#FFD54F;strokeColor=#F57C00;" -X 50 -Y ($legendY + 40) -Width 100 -Height 50
        $root.AppendChild($gatewayCell) | Out-Null
        $currentId++
    }
    
    # Save to file
    try {
        # Resolve to absolute path
        $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
        
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Encoding = [System.Text.Encoding]::UTF8
        $settings.Indent = $true
        $settings.IndentChars = "  "
        
        $writer = [System.Xml.XmlWriter]::Create($absolutePath, $settings)
        try {
            $script:xml.Save($writer)
            $writer.Flush()
        }
        finally {
            $writer.Close()
            $writer.Dispose()
        }
        
        Write-Host "Network topology diagram saved to: $absolutePath" -ForegroundColor Green
        Write-Host "Statistics:" -ForegroundColor Cyan
        Write-Host "  Total VMs: $($Topology.Statistics.TotalVMs)" -ForegroundColor White
        Write-Host "  Total Networks: $($Topology.Statistics.TotalNetworks)" -ForegroundColor White
        Write-Host "  Gateway VMs: $($Topology.GatewayVMs.Count)" -ForegroundColor White
        Write-Host "  Isolated Networks: $($Topology.IsolatedNetworks.Count)" -ForegroundColor White
        Write-Host "  VLANs: $($Topology.VLANs.Count)" -ForegroundColor White
        Write-Host "  Subnets: $($Topology.Subnets.Count)" -ForegroundColor White
        Write-Host "  Security Zones: $($Topology.SecurityZones.Count)" -ForegroundColor White
    }
    catch {
        Write-Error "Failed to save diagram: $_"
    }
}

#endregion

#region Main Execution

Write-Host "VMware Network Topology Analyzer" -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Green
Write-Host ""

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
    Write-Host "No vCenter specified. Using existing connection..." -ForegroundColor Yellow
    if (-not (Get-VIServer -ErrorAction SilentlyContinue)) {
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# Collect data
Write-Host "Collecting VM data..." -ForegroundColor Cyan
try {
    $allVMs = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
    Write-Host "  Found $($allVMs.Count) powered-on VMs" -ForegroundColor White
}
catch {
    Write-Error "Failed to collect VM data: $_"
    exit 1
}

Write-Host "Collecting network data..." -ForegroundColor Cyan
$allPortGroups = @()
$portGroupHash = @{}

# Get all VMHosts to iterate through
$allVMHosts = Get-VMHost

foreach ($VMHost in $allVMHosts) {
    # Get virtual switches
    $vSwitches = $VMHost | Get-VirtualSwitch
    
    foreach ($vSwitch in $vSwitches) {
        # Get port groups for this switch - try multiple methods (from vDiagram-DrawIO-Detailed.ps1)
        $portGroups = @()
        
        # Method 1: Standard approach
        try {
            $portGroups = $VMHost | Get-VirtualPortGroup -ErrorAction Stop | Where-Object { $_.VirtualSwitchName -eq $vSwitch.Name }
        } catch {
            # Method 2: Try getting port groups directly from the switch
            try {
                if ($vSwitch.ExtensionData.Portgroup) {
                    foreach ($pgRef in $vSwitch.ExtensionData.Portgroup) {
                        $pg = Get-View -Id $pgRef -ErrorAction Stop
                        $portGroups += [PSCustomObject]@{
                            Name = $pg.Name
                            VLanId = if ($pg.Spec.VlanId) { $pg.Spec.VlanId } else { 0 }
                            VirtualSwitchName = $vSwitch.Name
                        }
                    }
                }
            } catch {
                # Method 3: Get from VMHost network info
                try {
                    $networkSystem = Get-View $VMHost.ExtensionData.ConfigManager.NetworkSystem -ErrorAction Stop
                    foreach ($pg in $networkSystem.NetworkInfo.Portgroup) {
                        if ($pg.Vswitch -eq $vSwitch.Key) {
                            $portGroups += [PSCustomObject]@{
                                Name = $pg.Spec.Name
                                VLanId = $pg.Spec.VlanId
                                VirtualSwitchName = $vSwitch.Name
                            }
                        }
                    }
                } catch {
                    Write-Warning "Could not retrieve port groups for switch $($vSwitch.Name) on host $($VMHost.Name)"
                }
            }
        }
        
        # Add to collection (deduplicate by name)
        foreach ($pg in $portGroups) {
            if (-not $portGroupHash.ContainsKey($pg.Name)) {
                $portGroupHash[$pg.Name] = $pg
                $allPortGroups += $pg
            }
        }
    }
}

Write-Host "  Found $($allPortGroups.Count) unique port groups" -ForegroundColor White

Write-Host "Collecting network adapter data..." -ForegroundColor Cyan
try {
    $allNetworkAdapters = Get-NetworkAdapter -VM $allVMs -ErrorAction Stop
    Write-Host "  Found $($allNetworkAdapters.Count) network adapters" -ForegroundColor White
}
catch {
    Write-Error "Failed to collect network adapter data: $_"
    exit 1
}

Write-Host "" 
Write-Host "Data collection complete:" -ForegroundColor Green
Write-Host "  VMs: $($allVMs.Count)" -ForegroundColor White
Write-Host "  Port Groups: $($allPortGroups.Count)" -ForegroundColor White
Write-Host "  Network Adapters: $($allNetworkAdapters.Count)" -ForegroundColor White
Write-Host ""

# Analyze topology
if ($allVMs.Count -eq 0) {
    Write-Error "No VMs found. Cannot generate topology."
    exit 1
}

if ($allNetworkAdapters.Count -eq 0) {
    Write-Error "No network adapters found. Cannot generate topology."
    exit 1
}

Write-Host "Analyzing network topology..." -ForegroundColor Cyan
$topology = Analyze-NetworkTopology -VMs $allVMs -PortGroups $allPortGroups -NetworkAdapters $allNetworkAdapters

if ($null -eq $topology) {
    Write-Error "Topology analysis failed."
    exit 1
}

# Generate diagram
Export-NetworkTopologyDiagram `
    -Topology $topology `
    -FilePath $OutputFile `
    -GroupBy $GroupBy `
    -UseSwimLanes:$IncludeSwimLanes `
    -ShowIsolated:$ShowIsolatedNetworks `
    -HighlightGateways:$IdentifyGateways `
    -AllVMs $allVMs `
    -AllNetworkAdapters $allNetworkAdapters

Write-Host ""
Write-Host "Network topology analysis complete!" -ForegroundColor Green

#endregion
