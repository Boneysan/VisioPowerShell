<#
.SYNOPSIS
    Creates a Visio diagram of VMware vSphere infrastructure.

.DESCRIPTION
    This script generates a Microsoft Visio (.vsd) diagram showing the hierarchy of VMware infrastructure including
    Virtual Centers, Clusters, ESX Hosts, and Virtual Machines. The diagram uses Cisco shapes for visual representation
    and automatically arranges objects in a hierarchical layout.

.PARAMETER VIServer
    The VMware vCenter Server or ESX Host to connect to. If not specified, prompts for input.

.PARAMETER Cluster
    Optional. Specific cluster to diagram. If not specified, all clusters are included.

.EXAMPLE
    .\vDiagram.ps1 -VIServer "vcenter.example.com"
    Creates a Visio diagram of the entire vCenter infrastructure.

.EXAMPLE
    .\vDiagram.ps1 -VIServer "vcenter.example.com" -Cluster "Production"
    Creates a Visio diagram of only the Production cluster.

.NOTES
    Requires:
    - Microsoft Visio installed on the local machine
    - VMware PowerCLI module
    - My-VI-Shapes.vss stencil file in the same directory
    
    Output: My_vDrawing.vsd in user's Documents folder
#>

Param ([string]$VIServer, [string]$Cluster)

# Set up the save path for the resulting Visio document
$SaveFile = [system.Environment]::GetFolderPath('MyDocuments') + "\My_vDrawing.vsd"

# Prompt for vCenter/ESXi host if not provided via parameter
if (-not $VIServer) { $VIServer = Read-Host "Please enter a Virtual Center name or ESX Host to diagram:" }

# Define the stencil file name
$shpFile = "\My-VI-Shapes.vss"

# Helper function to connect two Visio objects using a connector
function connect-visioobject ($firstObj, $secondObj)
{
    # Drop a connector tool object onto the page
	$shpConn = $pagObj.Drop($pagObj.Application.ConnectorToolDataObject, 0, 0)

	# Connect the beginning of the connector to the 'From' shape
	[void]$shpConn.CellsU("BeginX").GlueTo($firstObj.CellsU("PinX"))
	
	# Connect the end of the connector to the 'To' shape
	[void]$shpConn.CellsU("EndX").GlueTo($secondObj.CellsU("PinX"))
}

# Helper function to add a Visio shape to the page
function add-visioobject ($mastObj, $item)
{
 		Write-Host "Adding $item"
		# Drop the selected master shape on the active page at current x, y coordinates
  		$shpObj = $pagObj.Drop($mastObj, $x, $y)
		# Set the text label for the shape
  		$shpObj.Text = $item
		# Return the shape object for further operations (like connecting)
		return $shpObj
 }

# Connect to the VI Server first (before opening Visio)
Write-Host "Connecting to $VIServer"
$VIServerName = $VIServer
try {
    # Establish connection to vCenter/Host
    $VIServer = Connect-VIServer $VIServer -ErrorAction Stop
} catch {
    Write-Error "Failed to connect to vCenter '$VIServerName': $_"
    exit 1
}

# Initialize Visio application and create a new document
Write-Host "Initializing Visio application..."
$AppVisio = New-Object -ComObject Visio.Application
$docsObj = $AppVisio.Documents
$DocObj = $docsObj.Add("Basic Diagram.vst")

# Set the active page to the first page of the new document
$pagsObj = $AppVisio.ActiveDocument.Pages
$pagObj = $pagsObj.Item(1)

# Load the custom VMware stencils and get references to specific master shapes
$stnPath = [system.Environment]::GetFolderPath('MyDocuments') + "\My Shapes"
$stnObj = $AppVisio.Documents.Add($stnPath + $shpFile)
$VCObj = $stnObj.Masters.Item("Virtual Center Management Console")
$HostObj = $stnObj.Masters.Item("ESX Host")
$MSObj = $stnObj.Masters.Item("Microsoft Server")
$LXObj = $stnObj.Masters.Item("Linux Server")
$OtherObj =  $stnObj.Masters.Item("Other Server")
$CluShp = $stnObj.Masters.Item("Cluster")

# Main Diagramming Logic - Phase 1: Check if clusters exist in the environment
If ($Null -ne (Get-Cluster)){

    # Determine which clusters to diagram
	if (-not $Cluster) {
        $DrawItems = Get-Cluster
    } else {
        $DrawItems = (Get-Cluster $Cluster)
    }
	
	$x = 0
	$VCLocation = $DrawItems | Get-VMHost
	$y = $VCLocation.Length * 1.50 / 2
	
    # Place the central vCenter/Host object
	$VCObject = add-visioobject $VCObj $VIServerName

	$x = 1.50
	$y = 1.50

    # Iterate through each cluster to build the hierarchy
	ForEach ($clusterObj in $DrawItems)
	{
        # Add Cluster shape and connect it to vCenter
		$CluVisObj = add-visioobject $CluShp $clusterObj
		connect-visioobject $VCObject $CluVisObj

		$x=3.00
        # Iterate through hosts in the current cluster
		ForEach ($VMHost in (Get-Cluster $clusterObj | Get-VMHost))
		{
            # Add Host shape and connect it to the Cluster
			$Object1 = add-visioobject $HostObj $VMHost
			connect-visioobject $CluVisObj $Object1
            
            # Iterate through VMs on the current host
			ForEach ($VM in (Get-vmhost $VMHost | get-vm))
			{		
				$x += 1.50
                # Select appropriate VM icon based on Guest OS
				If ($Null -eq $vm.Guest.OSFullName)
				{
					$Object2 = add-visioobject $OtherObj $VM
				}
				Else
				{
					If ($vm.Guest.OSFullName.contains("Microsoft") -eq $True)
					{
						$Object2 = add-visioobject $MSObj $VM
					}
					else
					{
						$Object2 = add-visioobject $LXObj $VM
					}
				}	
                # Connect the VM to its host or the previous VM in the chain
				connect-visioobject $Object1 $Object2
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
    # Main Diagramming Logic - Phase 2: Handle environments without clusters (direct ESXi management)
	$DrawItems = Get-VMHost
	
	$x = 0
	$y = $DrawItems.Length * 1.50 / 2
	
    # Place the central vCenter/Host object
	$VCObject = add-visioobject $VCObj $VIServerName

	$x = 1.50
	$y = 1.50

    # Iterate through standalone hosts
	ForEach ($VMHost in $DrawItems)
	{
        # Add Host shape and connect it to the central object
		$Object1 = add-visioobject $HostObj $VMHost
		connect-visioobject $VCObject $Object1
        
        # Iterate through VMs on the standalone host
		ForEach ($VM in (Get-vmhost $VMHost | get-vm))
		{		
			$x += 1.50
            # Select appropriate VM icon based on Guest OS
			If ($Null -eq $vm.Guest.OSFullName)
			{
				$Object2 = add-visioobject $OtherObj $VM
			}
			Else
			{
				If ($vm.Guest.OSFullName.contains("Microsoft") -eq $True)
				{
					$Object2 = add-visioobject $MSObj $VM
				}
				else
				{
					$Object2 = add-visioobject $LXObj $VM
				}
			}	
            # Connect the VM to its host
			connect-visioobject $Object1 $Object2
			$Object1 = $Object2
		}
		$x = 1.50
		$y += 1.50
	}
$x = 1.50
}

# Finalize the drawing
Write-Host "Finalizing diagram layout..."
# Resize to fit page
$pagObj.ResizeToFitContents()

# Save the diagram to the specified file path
$DocObj.SaveAs("$Savefile")

# Final output and cleanup
Write-Output "Document saved as $savefile"
# Disconnect from vCenter
Disconnect-VIServer -Server $VIServer -Confirm:$false