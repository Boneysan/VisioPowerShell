<#
.SYNOPSIS
    Creates a Draw.io diagram of VMware vSphere infrastructure.

.DESCRIPTION
    This script generates a Draw.io (.drawio) format diagram showing the hierarchy of VMware infrastructure including
    Virtual Centers, Clusters, ESX Hosts, and Virtual Machines. The diagram uses Cisco shapes from the mxGraph library
    and creates an XML structure compatible with Draw.io web and desktop applications.
    
    The script automatically detects VM operating systems and applies appropriate styling:
    - Windows VMs: Blue color scheme
    - Linux VMs: Teal color scheme
    - Other VMs: Gray color scheme

.PARAMETER VIServer
    The VMware vCenter Server or ESX Host to connect to. If not specified, prompts for input.

.PARAMETER Cluster
    Optional. Specific cluster to diagram. If not specified, all clusters are included.

.EXAMPLE
    .\vDiagram-DrawIO.ps1 -VIServer "vcenter.example.com"
    Creates a Draw.io diagram of the entire vCenter infrastructure.

.EXAMPLE
    .\vDiagram-DrawIO.ps1 -VIServer "vcenter.example.com" -Cluster "Production"
    Creates a Draw.io diagram of only the Production cluster.

.EXAMPLE
    # Using existing vCenter connection
    Connect-VIServer -Server vcenter.example.com
    .\vDiagram-DrawIO.ps1

.NOTES
    Requires:
    - VMware PowerCLI module
    
    Output: My_vDrawing.drawio in user's Documents folder
    
    The output file can be opened with:
    - Draw.io web application (https://app.diagrams.net)
    - Draw.io desktop application
    - Visual Studio Code with Draw.io extension
#>

Param ([string]$VIServer, [string]$Cluster)

# Set the output path for the Draw.io file
$SaveFile = [system.Environment]::GetFolderPath('MyDocuments') + "\My_vDrawing.drawio"

# Prompt for vCenter/ESXi host if not provided
if (-not $VIServer) { $VIServer = Read-Host "Please enter a Virtual Center name or ESX Host to diagram:" }

# Initialize script-level data structures to store shapes and their connections
$script:shapes = @()
$script:connections = @()
$script:shapeId = 2 # Start ID at 2 (0 and 1 are reserved for Draw.io layers)

# Define mxGraph styles for different VMware objects using Cisco-themed shapes
$script:styles = @{
    'VirtualCenter' = 'shape=mxgraph.cisco.servers.virtual_switch_controller;fillColor=#6FA8DC;strokeColor=#0B5394;fontColor=#000000;'
    'Cluster'       = 'shape=mxgraph.cisco.servers.server_cluster;fillColor=#93C47D;strokeColor=#38761D;fontColor=#000000;'
    'ESXHost'       = 'shape=mxgraph.cisco.servers.server;fillColor=#F6B26B;strokeColor=#E69138;fontColor=#000000;'
    'WindowsVM'     = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#6D9EEB;strokeColor=#1155CC;fontColor=#000000;'
    'LinuxVM'       = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;fontColor=#000000;'
    'OtherVM'       = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#CCCCCC;strokeColor=#666666;fontColor=#000000;'
}

# Helper function to create a new shape entry
function New-DrawIOShape {
    param(
        [string]$Label,
        [string]$Style,
        [double]$X,
        [double]$Y,
        [int]$Width = 120,
        [int]$Height = 60
    )
    
    $id = $script:shapeId++
    $shape = [PSCustomObject]@{
        Id = $id
        Label = [System.Security.SecurityElement]::Escape($Label) # Ensure XML safety
        Style = $Style
        X = $X * 150  # Apply horizontal scaling
        Y = $Y * 100  # Apply vertical scaling
        Width = $Width
        Height = $Height
    }
    
    $script:shapes += $shape
    Write-Host "Adding $Label"
    return $shape
}

# Helper function to create a connection between two existing shapes
function Connect-DrawIOShape {
    param(
        [PSCustomObject]$Source,
        [PSCustomObject]$Target
    )
    
    $connection = [PSCustomObject]@{
        Id = $script:shapeId++
        Source = $Source.Id
        Target = $Target.Id
    }
    
    $script:connections += $connection
}

# Function to generate the Draw.io XML file from the collected shapes and connections
function Export-DrawIOXML {
    param([string]$FilePath)
    
    # Initialize XML Document
    $xml = New-Object System.Xml.XmlDocument
    $xmlDeclaration = $xml.CreateXmlDeclaration("1.0", "UTF-8", $null)
    [void]$xml.AppendChild($xmlDeclaration)
    
    # Create the root mxfile element
    $mxfile = $xml.CreateElement("mxfile")
    [void]$xml.AppendChild($mxfile)
    
    # Create the diagram container
    $diagram = $xml.CreateElement("diagram")
    $diagram.SetAttribute("id", "vmware-infrastructure")
    $diagram.SetAttribute("name", "VMware Infrastructure")
    [void]$mxfile.AppendChild($diagram)
    
    # Configure the graph model settings
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
    $graphModel.SetAttribute("pageWidth", "1169")
    $graphModel.SetAttribute("pageHeight", "827")
    [void]$diagram.AppendChild($graphModel)
    
    # Create the root element for graph cells
    $root = $xml.CreateElement("root")
    [void]$graphModel.AppendChild($root)
    
    # Layer 0: Background layer (standard Draw.io requirement)
    $cell0 = $xml.CreateElement("mxCell")
    $cell0.SetAttribute("id", "0")
    [void]$root.AppendChild($cell0)
    
    # Layer 1: Content layer (standard Draw.io requirement)
    $cell1 = $xml.CreateElement("mxCell")
    $cell1.SetAttribute("id", "1")
    $cell1.SetAttribute("parent", "0")
    [void]$root.AppendChild($cell1)
    
    # Add all collected shapes to the XML
    foreach ($shape in $script:shapes) {
        $cell = $xml.CreateElement("mxCell")
        $cell.SetAttribute("id", $shape.Id.ToString())
        $cell.SetAttribute("value", $shape.Label)
        $cell.SetAttribute("style", $shape.Style)
        $cell.SetAttribute("vertex", "1")
        $cell.SetAttribute("parent", "1")
        
        # Define shape geometry (position and size)
        $geometry = $xml.CreateElement("mxGeometry")
        $geometry.SetAttribute("x", $shape.X.ToString())
        $geometry.SetAttribute("y", $shape.Y.ToString())
        $geometry.SetAttribute("width", $shape.Width.ToString())
        $geometry.SetAttribute("height", $shape.Height.ToString())
        $geometry.SetAttribute("as", "geometry")
        [void]$cell.AppendChild($geometry)
        
        [void]$root.AppendChild($cell)
    }
    
    # Add all collected connections (edges) to the XML
    foreach ($conn in $script:connections) {
        $cell = $xml.CreateElement("mxCell")
        $cell.SetAttribute("id", $conn.Id.ToString())
        $cell.SetAttribute("style", "edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;strokeWidth=2;strokeColor=#666666;")
        $cell.SetAttribute("edge", "1")
        $cell.SetAttribute("parent", "1")
        $cell.SetAttribute("source", $conn.Source.ToString())
        $cell.SetAttribute("target", $conn.Target.ToString())
        
        $geometry = $xml.CreateElement("mxGeometry")
        $geometry.SetAttribute("relative", "1")
        $geometry.SetAttribute("as", "geometry")
        [void]$cell.AppendChild($geometry)
        
        [void]$root.AppendChild($cell)
    }
    
    # Write the completed XML to the output file
    $xml.Save($FilePath)
}

# Connect to the vCenter/ESXi Server
Write-Host "Connecting to $VIServer"
$VIServerName = $VIServer
try {
    $VIServer = Connect-VIServer $VIServer -ErrorAction Stop
} catch {
    Write-Error "Failed to connect to vCenter '$VIServerName': $_"
    exit 1
}

# Phase 1: Diagram Logic for Cluster-based environments
If ($Null -ne (Get-Cluster)){

    # Determine clusters to include
	if (-not $Cluster) {
        $DrawItems = Get-Cluster
    } else {
        $DrawItems = (Get-Cluster $Cluster)
    }
	
	$x = 0
	$VCLocation = $DrawItems | Get-VMHost
	$y = $VCLocation.Length * 1.50 / 2
	
    # Add central vCenter shape
	$VCObject = New-DrawIOShape -Label $VIServer.Name -Style $script:styles['VirtualCenter'] -X $x -Y $y
	
	$x = 1.50
	$y = 1.50
	
    # Iterate through Clusters
	ForEach ($clusterObj in $DrawItems)
	{
		$CluVisObj = New-DrawIOShape -Label $clusterObj.Name -Style $script:styles['Cluster'] -X $x -Y $y
		Connect-DrawIOShape -Source $VCObject -Target $CluVisObj

		$x = 3.00
        # Iterate through Hosts in Cluster
		ForEach ($VMHost in (Get-Cluster $clusterObj | Get-VMHost))
		{
			$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] -X $x -Y $y
			Connect-DrawIOShape -Source $CluVisObj -Target $Object1
			
            # Iterate through VMs on Host
			ForEach ($VM in (Get-VMHost $VMHost | Get-VM))
			{		
				$x += 1.50
                # Determine VM style based on Operating System
				If ($Null -eq $vm.Guest.OSFullName)
				{
					$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['OtherVM'] -X $x -Y $y
				}
				Else
				{
					If ($vm.Guest.OSFullName.Contains("Microsoft") -eq $True)
					{
						$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['WindowsVM'] -X $x -Y $y
					}
					else
					{
						$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['LinuxVM'] -X $x -Y $y
					}
				}	
				Connect-DrawIOShape -Source $Object1 -Target $Object2
				$Object1 = $Object2
			}
			$x = 3.00
			$y += 1.50
		}
		$x = 1.50
	}
}
Else
{
    # Phase 2: Diagram Logic for standalone ESXi environments (no clusters)
	$DrawItems = Get-VMHost
	
	$x = 0
	$y = $DrawItems.Length * 1.50 / 2
	
    # Add central host management shape
	$VCObject = New-DrawIOShape -Label $VIServer.Name -Style $script:styles['VirtualCenter'] -X $x -Y $y
	
	$x = 1.50
	$y = 1.50
	
    # Iterate through Standalone Hosts
	ForEach ($VMHost in $DrawItems)
	{
		$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] -X $x -Y $y
		Connect-DrawIOShape -Source $VCObject -Target $Object1
		
        # Iterate through VMs on standalone host
		ForEach ($VM in (Get-VMHost $VMHost | Get-VM))
		{		
			$x += 1.50
            # Determine VM style based on Operating System
			If ($Null -eq $vm.Guest.OSFullName)
			{
				$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['OtherVM'] -X $x -Y $y
			}
			Else
			{
				If ($vm.Guest.OSFullName.Contains("Microsoft") -eq $True)
				{
					$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['WindowsVM'] -X $x -Y $y
				}
				else
				{
					$Object2 = New-DrawIOShape -Label $VM.Name -Style $script:styles['LinuxVM'] -X $x -Y $y
				}
			}	
			Connect-DrawIOShape -Source $Object1 -Target $Object2
			$Object1 = $Object2
		}
		$x = 1.50
		$y += 1.50
	}
	$x = 1.50
}

# Final Phase: Export the diagram to XML
Write-Host "Generating draw.io diagram..."
Export-DrawIOXML -FilePath $SaveFile

# Output final location and disconnect
Write-Output "Document saved as $SaveFile"
Write-Output "Open this file in draw.io (https://app.diagrams.net) or draw.io Desktop"

Disconnect-VIServer -Server $VIServer -Confirm:$false

