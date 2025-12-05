Param ($VIServer=$FALSE, $Cluster=$FALSE)

$SaveFile = [system.Environment]::GetFolderPath('MyDocuments') + "\My_vDrawing_Detailed.drawio"
if ($VIServer -eq $FALSE) { $VIServer = Read-Host "Please enter a Virtual Center name or ESX Host to diagram:" }

# Initialize diagram data structures
$script:shapes = @()
$script:connections = @()
$script:shapeId = 1
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
        Label = [System.Security.SecurityElement]::Escape($fullLabel)
        Style = $Style
        X = $X * 150  # Scale up coordinates
        Y = $Y * 100
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
        Label = [System.Security.SecurityElement]::Escape($Label)
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
        [double]$BaseY
    )
    
    # Get virtual switches
    $vSwitches = $VMHost | Get-VirtualSwitch
    $switchX = $BaseX - 3
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
            
            # Get port groups for this switch
            $portGroups = $VMHost | Get-VirtualPortGroup | Where-Object { $_.VirtualSwitchName -eq $vSwitch.Name }
            $pgX = $switchX - 2
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
                    
                    $pgY += 1.2
                }
            }
            
            $switchY += 2
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
    
    # Save XML to file
    $xml.Save($FilePath)
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
			
			# Add network topology for this host
			Add-NetworkTopology -HostShape $Object1 -VMHost $VMHost -BaseX $x -BaseY $y
			
			$vmX = $x + 2
			$vmY = $y
			
			ForEach ($VM in (Get-VMHost $VMHost | Get-VM)) {		
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
				
				# Get the network adapters and connect to appropriate port groups
				$networkAdapters = $VM | Get-NetworkAdapter
				foreach ($adapter in $networkAdapters) {
					$pgKey = "$($VMHost.Name)-$($adapter.NetworkName)"
					if ($script:portGroups.ContainsKey($pgKey)) {
						$pgShape = $script:portGroups[$pgKey]
						Connect-DrawIOShape -Source $pgShape -Target $Object2 -Label $adapter.Name
					}
				}
				
				$vmY += 1.5
			}
			$x = 3.00
			$y += 4
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
		
		# Add network topology for this host
		Add-NetworkTopology -HostShape $Object1 -VMHost $VMHost -BaseX $x -BaseY $y
		
		$vmX = $x + 2
		$vmY = $y
		
		ForEach ($VM in (Get-VMHost $VMHost | Get-VM)) {		
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
			
			# Get the network adapters and connect to appropriate port groups
			$networkAdapters = $VM | Get-NetworkAdapter
			foreach ($adapter in $networkAdapters) {
				$pgKey = "$($VMHost.Name)-$($adapter.NetworkName)"
				if ($script:portGroups.ContainsKey($pgKey)) {
					$pgShape = $script:portGroups[$pgKey]
					Connect-DrawIOShape -Source $pgShape -Target $Object2 -Label $adapter.Name
				}
			}
			
			$vmY += 1.5
		}
		$x = 1.50
		$y += 4
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
