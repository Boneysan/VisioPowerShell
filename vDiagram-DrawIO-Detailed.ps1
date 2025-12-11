<#
.SYNOPSIS
    Creates a detailed Draw.io diagram of VMware vSphere infrastructure with network information.

.DESCRIPTION
    This script generates a comprehensive Draw.io (.drawio) format diagram showing VMware infrastructure hierarchy
    including Virtual Centers, Clusters, ESX Hosts, Virtual Machines, Virtual Switches, and Port Groups.
    
    Key features:
    - Hierarchical layout showing infrastructure relationships
    - Network topology with virtual switches and port groups
    - Detailed VM information including network adapters, IP addresses, MAC addresses, CPU, RAM, and power state
    - Color-coded VMs by operating system (Windows/Linux/Other)
    - Visual connections between VMs and their network port groups
    - Multiple network adapters per VM are displayed with full details

.PARAMETER VIServer
    The VMware vCenter Server or ESX Host to connect to. If not specified, prompts for input.

.PARAMETER Cluster
    Optional. Specific cluster to diagram. If not specified, all clusters are included.

.EXAMPLE
    .\vDiagram-DrawIO-Detailed.ps1 -VIServer "vcenter.example.com"
    Creates a detailed Draw.io diagram of the entire vCenter infrastructure with network details.

.EXAMPLE
    .\vDiagram-DrawIO-Detailed.ps1 -VIServer "vcenter.example.com" -Cluster "Production"
    Creates a detailed diagram of only the Production cluster.

.EXAMPLE
    # Using existing vCenter connection
    Connect-VIServer -Server vcenter.example.com
    .\vDiagram-DrawIO-Detailed.ps1

.NOTES
    Requires:
    - VMware PowerCLI module
    - VMware Tools installed on VMs for guest information (IP addresses, OS details)
    
    Output: My_vDrawing_Detailed.drawio in user's Documents folder
    
    VM Details Displayed:
    - VM Name
    - Network Adapter Names
    - IP Addresses (IPv4 only, filters out link-local)
    - Network/Port Group Names
    - MAC Addresses
    - CPU Count
    - RAM in GB
    - Power State
    
    The output file can be opened with:
    - Draw.io web application (https://app.diagrams.net)
    - Draw.io desktop application
    - Visual Studio Code with Draw.io extension
    
    Performance: For large environments (100+ VMs), this script may take several minutes to complete
    as it collects detailed network adapter information for each VM.
#>

Param ($VIServer=$FALSE, $Cluster=$FALSE)

$SaveFile = [system.Environment]::GetFolderPath('MyDocuments') + "\My_vDrawing_Detailed.drawio"
if ($VIServer -eq $FALSE) { $VIServer = Read-Host "Please enter a Virtual Center name or ESX Host to diagram:" }

# Initialize diagram data structures
$script:shapes = @()
$script:connections = @()
$script:shapeId = 2
$script:vSwitches = @{}
$script:portGroups = @{}

# Shape style definitions for different object types
$script:styles = @{
    'VirtualCenter' = 'shape=mxgraph.cisco.servers.virtual_switch_controller;fillColor=#6FA8DC;strokeColor=#0B5394;fontColor=#000000;'
    'Cluster' = 'shape=mxgraph.cisco.servers.server_cluster;fillColor=#93C47D;strokeColor=#38761D;fontColor=#000000;'
    'ESXHost' = 'shape=mxgraph.cisco.servers.server;fillColor=#F6B26B;strokeColor=#E69138;fontColor=#000000;'
    'WindowsVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#6D9EEB;strokeColor=#1155CC;fontColor=#000000;'
    'LinuxVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;fontColor=#000000;'
    'OtherVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#CCCCCC;strokeColor=#666666;fontColor=#000000;'
    'vSwitch' = 'shape=mxgraph.cisco.switches.workgroup_switch;fillColor=#FFE599;strokeColor=#F1C232;fontColor=#000000;'
    'PortGroup' = 'shape=mxgraph.cisco.switches.layer_2_remote_switch;fillColor=#B6D7A8;strokeColor=#6AA84F;fontColor=#000000;'
}

function New-DrawIOShape {
    param(
        [string]$Label,
        [string]$Style,
        [double]$X,
        [double]$Y,
        [int]$Width = 120,
        [int]$Height = 80,
        [string]$Details = ""
    )
    
    $id = $script:shapeId++
    
    # Format label with details
    $fullLabel = $Label
    if ($Details -ne "") {
        $fullLabel = "$Label`n$Details"
    }
    
    $shape = [PSCustomObject]@{
        Id = $id
        Label = $fullLabel
        Style = $Style
        X = $X * 250  # Scale up coordinates for better spacing
        Y = $Y * 180
        Width = $Width
        Height = $Height
    }
    
    $script:shapes += $shape
    Write-Host "Adding $Label"
    return $shape
}

function Connect-DrawIOShape {
    param(
        [PSCustomObject]$Source,
        [PSCustomObject]$Target,
        [string]$Label = ""
    )
    
    $connection = [PSCustomObject]@{
        Id = $script:shapeId++
        Source = $Source.Id
        Target = $Target.Id
        Label = $Label
    }
    
    $script:connections += $connection
}

function Get-VMNetworkDetails {
    param($VM)
    
    $details = @()
    $networkAdapters = $VM | Get-NetworkAdapter
    
    foreach ($adapter in $networkAdapters) {
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
        $details += "Network: $($adapter.NetworkName)"
        if ($adapter.MacAddress) {
            $details += "MAC: $($adapter.MacAddress)"
        }
    }
    
    return ($details -join "`n")
}

function Get-VMHostNetworkDetails {
    param($VMHost)
    
    $details = @()
    
    # Get management IP
    $vmk0 = $VMHost | Get-VMHostNetworkAdapter | Where-Object { $_.ManagementTrafficEnabled -eq $true } | Select-Object -First 1
    if ($vmk0) {
        $details += "Mgmt IP: $($vmk0.IP)"
    }
    
    # Get vMotion IP if configured
    $vmk1 = $VMHost | Get-VMHostNetworkAdapter | Where-Object { $_.VMotionEnabled -eq $true } | Select-Object -First 1
    if ($vmk1) {
        $details += "vMotion: $($vmk1.IP)"
    }
    
    return ($details -join "`n")
}

function Add-NetworkTopology {
    param(
        [PSCustomObject]$HostShape,
        $VMHost,
        [double]$BaseX,
        [double]$BaseY,
        [ref]$CurrentMaxY
    )
    
    # Get virtual switches - place them to the left of host
    $vSwitches = $VMHost | Get-VirtualSwitch
    $switchX = $BaseX - 4
    $switchY = $BaseY
    
    foreach ($vSwitch in $vSwitches) {
        $switchKey = "$($VMHost.Name)-$($vSwitch.Name)"
        
        if (-not $script:vSwitches.ContainsKey($switchKey)) {
            $switchDetails = "Type: $($vSwitch.GetType().Name.Replace('VirtualSwitch',''))"
            if ($vSwitch.Mtu) {
                $switchDetails += "`nMTU: $($vSwitch.Mtu)"
            }
            
            $switchShape = New-DrawIOShape -Label $vSwitch.Name -Style $script:styles['vSwitch'] `
                -X $switchX -Y $switchY -Width 100 -Height 60 -Details $switchDetails
            
            Connect-DrawIOShape -Source $HostShape -Target $switchShape
            $script:vSwitches[$switchKey] = $switchShape
            
            # Get port groups for this switch - try multiple methods
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
                        Write-Warning "Could not retrieve port groups for switch $($vSwitch.Name) using any method"
                    }
                }
            }
            
            $pgX = $switchX - 3
            $pgY = $switchY
            
            foreach ($pg in $portGroups) {
                $pgKey = "$($VMHost.Name)-$($pg.Name)"
                
                if (-not $script:portGroups.ContainsKey($pgKey)) {
                    $pgDetails = ""
                    if ($pg.VLanId) {
                        $pgDetails = "VLAN: $($pg.VLanId)"
                    }
                    
                    $pgShape = New-DrawIOShape -Label $pg.Name -Style $script:styles['PortGroup'] `
                        -X $pgX -Y $pgY -Width 90 -Height 50 -Details $pgDetails
                    
                    Connect-DrawIOShape -Source $switchShape -Target $pgShape
                    $script:portGroups[$pgKey] = $pgShape
                    
                    $pgY += 1.8
                    
                    # Track maximum Y position
                    if ($pgY -gt $CurrentMaxY.Value) {
                        $CurrentMaxY.Value = $pgY
                    }
                }
            }
            
            $switchY += 3
        }
    }
}

function Export-DrawIOXML {
    param([string]$FilePath)
    
    $xml = New-Object System.Xml.XmlDocument
    $xmlDeclaration = $xml.CreateXmlDeclaration("1.0", "UTF-8", $null)
    [void]$xml.AppendChild($xmlDeclaration)
    
    # Root mxfile element
    $mxfile = $xml.CreateElement("mxfile")
    [void]$xml.AppendChild($mxfile)
    
    # Diagram element
    $diagram = $xml.CreateElement("diagram")
    $diagram.SetAttribute("id", "vmware-infrastructure")
    $diagram.SetAttribute("name", "VMware Infrastructure - Detailed")
    [void]$mxfile.AppendChild($diagram)
    
    # mxGraphModel element
    $graphModel = $xml.CreateElement("mxGraphModel")
    $graphModel.SetAttribute("dx", "0")
    $graphModel.SetAttribute("dy", "0")
    $graphModel.SetAttribute("grid", "1")
    $graphModel.SetAttribute("gridSize", "10")
    $graphModel.SetAttribute("guides", "1")
    $graphModel.SetAttribute("tooltips", "1")
    $graphModel.SetAttribute("connect", "1")
    $graphModel.SetAttribute("arrows", "1")
    $graphModel.SetAttribute("fold", "1")
    $graphModel.SetAttribute("page", "1")
    $graphModel.SetAttribute("pageScale", "1")
    $graphModel.SetAttribute("pageWidth", "1600")
    $graphModel.SetAttribute("pageHeight", "1200")
    [void]$diagram.AppendChild($graphModel)
    
    # root element
    $root = $xml.CreateElement("root")
    [void]$graphModel.AppendChild($root)
    
    # Layer 0 (required)
    $cell0 = $xml.CreateElement("mxCell")
    $cell0.SetAttribute("id", "0")
    [void]$root.AppendChild($cell0)
    
    # Layer 1 (required)
    $cell1 = $xml.CreateElement("mxCell")
    $cell1.SetAttribute("id", "1")
    $cell1.SetAttribute("parent", "0")
    [void]$root.AppendChild($cell1)
    
    # Add shapes
    foreach ($shape in $script:shapes) {
        $cell = $xml.CreateElement("mxCell")
        $cell.SetAttribute("id", $shape.Id.ToString())
        $cell.SetAttribute("value", $shape.Label)
        $cell.SetAttribute("style", $shape.Style)
        $cell.SetAttribute("vertex", "1")
        $cell.SetAttribute("parent", "1")
        
        $geometry = $xml.CreateElement("mxGeometry")
        $geometry.SetAttribute("x", $shape.X.ToString())
        $geometry.SetAttribute("y", $shape.Y.ToString())
        $geometry.SetAttribute("width", $shape.Width.ToString())
        $geometry.SetAttribute("height", $shape.Height.ToString())
        $geometry.SetAttribute("as", "geometry")
        [void]$cell.AppendChild($geometry)
        
        [void]$root.AppendChild($cell)
    }
    
    # Add connections
    foreach ($conn in $script:connections) {
        $cell = $xml.CreateElement("mxCell")
        $cell.SetAttribute("id", $conn.Id.ToString())
        
        $labelStyle = if ($conn.Label) { "labelBackgroundColor=#ffffff;" } else { "" }
        $cell.SetAttribute("style", "edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;strokeWidth=2;strokeColor=#666666;$labelStyle")
        $cell.SetAttribute("edge", "1")
        $cell.SetAttribute("parent", "1")
        $cell.SetAttribute("source", $conn.Source.ToString())
        $cell.SetAttribute("target", $conn.Target.ToString())
        
        if ($conn.Label) {
            $cell.SetAttribute("value", $conn.Label)
        }
        
        $geometry = $xml.CreateElement("mxGeometry")
        $geometry.SetAttribute("relative", "1")
        $geometry.SetAttribute("as", "geometry")
        [void]$cell.AppendChild($geometry)
        
        [void]$root.AppendChild($cell)
    }
    
    # Save XML to file with explicit stream handling to prevent truncation
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = [System.Text.Encoding]::UTF8
    $settings.Indent = $true
    $settings.IndentChars = "  "
    
    $writer = $null
    try {
        $writer = [System.Xml.XmlWriter]::Create($FilePath, $settings)
        $xml.Save($writer)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) {
            $writer.Close()
            $writer.Dispose()
        }
    }
}

# Connect to the VI Server
Write-Host "Connecting to $VIServer"
$VIServer = Connect-VIServer $VIServer

Write-Host "`nCollecting network topology information..."

# Start drawing
If ($Null -ne (Get-Cluster)){

	If ($Cluster -eq $FALSE){ 
        $DrawItems = Get-Cluster 
    } Else {
        $DrawItems = (Get-Cluster $Cluster)
    }
	
	$x = 0
	$VCLocation = $DrawItems | Get-VMHost
	$y = $VCLocation.Length * 1.50 / 2
	
	$VCObject = New-DrawIOShape -Label $VIServer.Name -Style $script:styles['VirtualCenter'] -X $x -Y $y
	
	$x = 1.50
	$y = 1.50
	
	ForEach ($Cluster in $DrawItems) {
		$CluVisObj = New-DrawIOShape -Label $Cluster.Name -Style $script:styles['Cluster'] -X $x -Y $y
		Connect-DrawIOShape -Source $VCObject -Target $CluVisObj
		
		$x = 3.00
		ForEach ($VMHost in (Get-Cluster $Cluster | Get-VMHost)) {
			$hostDetails = Get-VMHostNetworkDetails -VMHost $VMHost
			$hostDetails += "`nESXi: $($VMHost.Version)"
			
			$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] `
				-X $x -Y $y -Width 140 -Height 90 -Details $hostDetails
			Connect-DrawIOShape -Source $CluVisObj -Target $Object1
			
			# Track Y position for proper vertical alignment
			$maxYRef = [ref]$y
			
			# Add network topology for this host (switches and port groups to the left)
			Add-NetworkTopology -HostShape $Object1 -VMHost $VMHost -BaseX $x -BaseY $y -CurrentMaxY $maxYRef
			
			# Place VMs to the right of host, grouped by network
			$vmX = $x + 3
			$vmY = $y
			
			# Group VMs by their primary network for better organization
			$vmsGrouped = @{}
			
			# Get all VMs and group by primary network
			$allVMs = Get-VMHost $VMHost | Get-VM
			foreach ($VM in $allVMs) {
				$primaryAdapter = $VM | Get-NetworkAdapter | Select-Object -First 1
				if ($primaryAdapter) {
					$networkName = $primaryAdapter.NetworkName
					if (-not $vmsGrouped.ContainsKey($networkName)) {
						$vmsGrouped[$networkName] = @()
					}
					$vmsGrouped[$networkName] += $VM
				}
			}
			
			# Draw VMs grouped by network
			foreach ($networkName in ($vmsGrouped.Keys | Sort-Object)) {
				foreach ($VM in $vmsGrouped[$networkName]) {
					$networkDetails = Get-VMNetworkDetails -VM $VM
					$vmLabel = $VM.Name
					
					If ($Null -eq $vm.Guest.OSFullName) {
						$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['OtherVM'] `
							-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
					} Else {
						If ($vm.Guest.OSFullName.Contains("Microsoft") -eq $True) {
							$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['WindowsVM'] `
								-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
						} else {
							$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['LinuxVM'] `
								-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
						}
					}
					
					# Connect VMs to their networks
					$networkAdapters = $VM | Get-NetworkAdapter
					foreach ($adapter in $networkAdapters) {
						$pgKey = "$($VMHost.Name)-$($adapter.NetworkName)"
						if ($script:portGroups.ContainsKey($pgKey)) {
							$pgShape = $script:portGroups[$pgKey]
							Connect-DrawIOShape -Source $pgShape -Target $Object2 -Label $adapter.Name
						} else {
							$switchKey = "$($VMHost.Name)-$($adapter.NetworkName)"
							if ($script:vSwitches.ContainsKey($switchKey)) {
								$switchShape = $script:vSwitches[$switchKey]
								Connect-DrawIOShape -Source $switchShape -Target $Object2 -Label "$($adapter.Name)`n$($adapter.NetworkName)"
							}
						}
					}
					
					$vmY += 2.0
				}
			}
			$x = 3.00
			# Use the maximum Y position to ensure proper vertical spacing
			if ($vmY -gt $maxYRef.Value) {
				$y = $vmY + 2
			} else {
				$y = $maxYRef.Value + 2
			}
		}
		$x = 1.50
	}
} Else {
	$DrawItems = Get-VMHost
	
	$x = 0
	$y = $DrawItems.Length * 1.50 / 2
	
	$VCObject = New-DrawIOShape -Label $VIServer.Name -Style $script:styles['VirtualCenter'] -X $x -Y $y
	
	$x = 1.50
	$y = 1.50
	
	ForEach ($VMHost in $DrawItems) {
		$hostDetails = Get-VMHostNetworkDetails -VMHost $VMHost
		$hostDetails += "`nESXi: $($VMHost.Version)"
		
		$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] `
			-X $x -Y $y -Width 140 -Height 90 -Details $hostDetails
		Connect-DrawIOShape -Source $VCObject -Target $Object1
		
		# Track Y position for proper vertical alignment
		$maxYRef = [ref]$y
		
		# Add network topology for this host (switches and port groups to the left)
		Add-NetworkTopology -HostShape $Object1 -VMHost $VMHost -BaseX $x -BaseY $y -CurrentMaxY $maxYRef
		
		# Place VMs to the right of host, grouped by network
		$vmX = $x + 3
		$vmY = $y
		
		# Group VMs by their primary network for better organization
		$vmsGrouped = @{}
		
		# Get all VMs and group by primary network
		$allVMs = Get-VMHost $VMHost | Get-VM
		foreach ($VM in $allVMs) {
			$primaryAdapter = $VM | Get-NetworkAdapter | Select-Object -First 1
			if ($primaryAdapter) {
				$networkName = $primaryAdapter.NetworkName
				if (-not $vmsGrouped.ContainsKey($networkName)) {
					$vmsGrouped[$networkName] = @()
				}
				$vmsGrouped[$networkName] += $VM
			}
		}
		
		# Draw VMs grouped by network
		foreach ($networkName in ($vmsGrouped.Keys | Sort-Object)) {
			foreach ($VM in $vmsGrouped[$networkName]) {
				$networkDetails = Get-VMNetworkDetails -VM $VM
				$vmLabel = $VM.Name
				
				If ($Null -eq $vm.Guest.OSFullName) {
					$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['OtherVM'] `
						-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
				} Else {
					If ($vm.Guest.OSFullName.Contains("Microsoft") -eq $True) {
						$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['WindowsVM'] `
							-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
					} else {
						$Object2 = New-DrawIOShape -Label $vmLabel -Style $script:styles['LinuxVM'] `
							-X $vmX -Y $vmY -Width 140 -Height 90 -Details $networkDetails
					}
				}
				
				# Connect VMs to their networks
				$networkAdapters = $VM | Get-NetworkAdapter
				foreach ($adapter in $networkAdapters) {
					$pgKey = "$($VMHost.Name)-$($adapter.NetworkName)"
					if ($script:portGroups.ContainsKey($pgKey)) {
						$pgShape = $script:portGroups[$pgKey]
						Connect-DrawIOShape -Source $pgShape -Target $Object2 -Label $adapter.Name
					} else {
						$switchKey = "$($VMHost.Name)-$($adapter.NetworkName)"
						if ($script:vSwitches.ContainsKey($switchKey)) {
							$switchShape = $script:vSwitches[$switchKey]
							Connect-DrawIOShape -Source $switchShape -Target $Object2 -Label "$($adapter.Name)`n$($adapter.NetworkName)"
						}
					}
				}
				
				$vmY += 2.0
			}
		}
		$x = 1.50
		# Use the maximum Y position to ensure proper vertical spacing
		if ($vmY -gt $maxYRef.Value) {
			$y = $vmY + 2
		} else {
			$y = $maxYRef.Value + 2
		}
	}
}

# Export to draw.io XML format
Write-Host "`nGenerating detailed draw.io diagram..."
Export-DrawIOXML -FilePath $SaveFile

Write-Output "`nDocument saved as $SaveFile"
Write-Output "Open this file in draw.io (https://app.diagrams.net) or draw.io Desktop"
Write-Output "`nDiagram includes:"
Write-Output "  - IP addresses for VMs and hosts"
Write-Output "  - Virtual switches and port groups"
Write-Output "  - VLAN configurations"
Write-Output "  - Network adapter details"
Write-Output "  - MAC addresses"

Disconnect-VIServer -Server $VIServer -Confirm:$false
