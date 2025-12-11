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

Param ($VIServer=$FALSE, $Cluster=$FALSE)

$SaveFile = [system.Environment]::GetFolderPath('MyDocuments') + "\My_vDrawing.drawio"
if ($VIServer -eq $FALSE) { $VIServer = Read-Host "Please enter a Virtual Center name or ESX Host to diagram:" }

# Initialize diagram data structures
$script:shapes = @()
$script:connections = @()
$script:shapeId = 2

# Shape style definitions for different object types
$script:styles = @{
    'VirtualCenter' = 'shape=mxgraph.cisco.servers.virtual_switch_controller;fillColor=#6FA8DC;strokeColor=#0B5394;fontColor=#000000;'
    'Cluster' = 'shape=mxgraph.cisco.servers.server_cluster;fillColor=#93C47D;strokeColor=#38761D;fontColor=#000000;'
    'ESXHost' = 'shape=mxgraph.cisco.servers.server;fillColor=#F6B26B;strokeColor=#E69138;fontColor=#000000;'
    'WindowsVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#6D9EEB;strokeColor=#1155CC;fontColor=#000000;'
    'LinuxVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#76A5AF;strokeColor=#0B5394;fontColor=#000000;'
    'OtherVM' = 'shape=mxgraph.cisco.servers.virtual_server;fillColor=#CCCCCC;strokeColor=#666666;fontColor=#000000;'
}

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
        Label = [System.Security.SecurityElement]::Escape($Label)
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
        [PSCustomObject]$Target
    )
    
    $connection = [PSCustomObject]@{
        Id = $script:shapeId++
        Source = $Source.Id
        Target = $Target.Id
    }
    
    $script:connections += $connection
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
    $diagram.SetAttribute("name", "VMware Infrastructure")
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
    $graphModel.SetAttribute("pageWidth", "1169")
    $graphModel.SetAttribute("pageHeight", "827")
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
    
    # Save XML to file
    $xml.Save($FilePath)
}

# Connect to the VI Server
Write-Host "Connecting to $VIServer"
$VIServer = Connect-VIServer $VIServer

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
	
	ForEach ($Cluster in $DrawItems)
	{
		$CluVisObj = New-DrawIOShape -Label $Cluster.Name -Style $script:styles['Cluster'] -X $x -Y $y
		Connect-DrawIOShape -Source $VCObject -Target $CluVisObj
		
		$x = 3.00
		ForEach ($VMHost in (Get-Cluster $Cluster | Get-VMHost))
		{
			$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] -X $x -Y $y
			Connect-DrawIOShape -Source $CluVisObj -Target $Object1
			
			ForEach ($VM in (Get-VMHost $VMHost | Get-VM))
			{		
				$x += 1.50
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
	$DrawItems = Get-VMHost
	
	$x = 0
	$y = $DrawItems.Length * 1.50 / 2
	
	$VCObject = New-DrawIOShape -Label $VIServer.Name -Style $script:styles['VirtualCenter'] -X $x -Y $y
	
	$x = 1.50
	$y = 1.50
	
	ForEach ($VMHost in $DrawItems)
	{
		$Object1 = New-DrawIOShape -Label $VMHost.Name -Style $script:styles['ESXHost'] -X $x -Y $y
		Connect-DrawIOShape -Source $VCObject -Target $Object1
		
		ForEach ($VM in (Get-VMHost $VMHost | Get-VM))
		{		
			$x += 1.50
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

# Export to draw.io XML format
Write-Host "Generating draw.io diagram..."
Export-DrawIOXML -FilePath $SaveFile

Write-Output "Document saved as $SaveFile"
Write-Output "Open this file in draw.io (https://app.diagrams.net) or draw.io Desktop"

Disconnect-VIServer -Server $VIServer -Confirm:$false
