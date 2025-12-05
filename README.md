# VisioPowerShell - VMware Infrastructure Diagramming

Automatically generate visual diagrams of your VMware vSphere infrastructure using PowerShell.

## Overview

This repository contains PowerShell scripts that connect to VMware vCenter or ESX hosts and automatically generate network diagrams showing your virtual infrastructure hierarchy:
- Virtual Center / vCenter Server
- Clusters
- ESX Hosts
- Virtual Machines (color-coded by OS type)

## Scripts

### vDiagram.ps1 (Original - Visio)
Creates diagrams using Microsoft Visio with custom shapes.

**Requirements:**
- Microsoft Visio installed
- VMware PowerCLI module
- Custom shape file: `My-VI-Shapes.vss` (in `My Documents\My Shapes\`)

**Output:** `.vsd` file in My Documents

### vDiagram-DrawIO.ps1 (New - draw.io)
Creates diagrams in draw.io XML format - no additional software installation required!

**Requirements:**
- VMware PowerCLI module only

**Output:** `.drawio` file in My Documents (open in https://app.diagrams.net or draw.io Desktop)

### vDiagram-DrawIO-Detailed.ps1 (New - Detailed Network Diagram)
Creates comprehensive network diagrams with full topology information including IP addresses, VLANs, switches, and port groups.

**Requirements:**
- VMware PowerCLI module only

**Output:** `.drawio` file in My Documents

**Includes:**
- VM IP addresses and MAC addresses
- ESXi management and vMotion IPs
- Virtual switches (Standard and Distributed)
- Port groups with VLAN IDs
- Network adapter details
- Complete network topology connections

## Installation

### 1. Install VMware PowerCLI

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser
```

### 2. Download the Scripts

Clone this repository or download the scripts:
```powershell
git clone https://github.com/alanrenouf/VisioPowerShell.git
cd VisioPowerShell
```

### 3. Set Execution Policy (if needed)

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Usage

### Basic Usage

**For draw.io (recommended):**
```powershell
.\vDiagram-DrawIO.ps1
```

**For detailed network diagram with IP addresses and topology:**
```powershell
.\vDiagram-DrawIO-Detailed.ps1
```

**For Visio:**
```powershell
.\vDiagram.ps1
```

You will be prompted to enter your vCenter or ESX host name.

### Advanced Usage

**Specify vCenter/ESX host:**
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com"
```

**Diagram a specific cluster only:**
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com" -Cluster "Production-Cluster"
```

**Create detailed network diagram with full topology:**
```powershell
.\vDiagram-DrawIO-Detailed.ps1 -VIServer "vcenter.company.com"
```

**Diagram all clusters:**
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com" -Cluster $FALSE
```

## How It Works

1. **Connect** - Script connects to your vCenter or ESX host using PowerCLI
2. **Discover** - Queries infrastructure for clusters, hosts, and VMs
3. **Categorize** - Identifies VM operating systems (Windows, Linux, Other)
4. **Generate** - Creates shapes and connections in the diagram
5. **Save** - Exports the final diagram file

## Diagram Structure

### With Clusters
```
Virtual Center
    └─ Cluster 1
        ├─ ESX Host 1
        │   ├─ VM 1 (Windows)
        │   ├─ VM 2 (Linux)
        │   └─ VM 3 (Other)
        └─ ESX Host 2
            └─ VMs...
```

### Without Clusters (Standalone Hosts)
```
Virtual Center
    ├─ ESX Host 1
    │   ├─ VM 1
    │   └─ VM 2
    └─ ESX Host 2
        └─ VMs...
```

## Color Coding (draw.io versions)

### Basic Diagram (vDiagram-DrawIO.ps1)
- **Blue** (#6FA8DC) - Virtual Center
- **Green** (#93C47D) - Clusters
- **Orange** (#F6B26B) - ESX Hosts
- **Light Blue** (#6D9EEB) - Windows VMs
- **Teal** (#76A5AF) - Linux VMs
- **Gray** (#CCCCCC) - Unknown/Other VMs

### Detailed Diagram (vDiagram-DrawIO-Detailed.ps1)
All of the above, plus:
- **Yellow** (#FFE599) - Virtual Switches
- **Light Green** (#B6D7A8) - Port Groups/Network Segments

## Output Files

### vDiagram.ps1 (Visio)
- **Location:** `%USERPROFILE%\Documents\My_vDrawing.vsd`
- **Format:** Microsoft Visio Document
- **Open with:** Microsoft Visio

### vDiagram-DrawIO.ps1 (draw.io)
- **Location:** `%USERPROFILE%\Documents\My_vDrawing.drawio`
- **Format:** draw.io XML
- **Open with:** 
  - https://app.diagrams.net (web browser)
  - draw.io Desktop application
  - VS Code with draw.io extension

### vDiagram-DrawIO-Detailed.ps1 (draw.io - Detailed)
- **Location:** `%USERPROFILE%\Documents\My_vDrawing_Detailed.drawio`
- **Format:** draw.io XML with network topology
- **Contains:** IP addresses, virtual switches, port groups, VLANs, MAC addresses, network connections
- **Open with:** 
  - https://app.diagrams.net (web browser)
  - draw.io Desktop application
  - VS Code with draw.io extension

## Troubleshooting

### PowerCLI Not Found
```
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
```

### Certificate Warnings
```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### Connection Issues
- Verify network connectivity to vCenter/ESX host
- Check credentials have appropriate permissions
- Ensure firewall allows connections on port 443

### Visio Not Found (vDiagram.ps1 only)
- Install Microsoft Visio
- Or use `vDiagram-DrawIO.ps1` instead (no Visio required)

### Missing Shapes (vDiagram.ps1 only)
- Ensure `My-VI-Shapes.vss` is in `%USERPROFILE%\Documents\My Shapes\`
- Or use `vDiagram-DrawIO.ps1` which has built-in shapes

## Customization

### Modify Output Location

Edit the `$SaveFile` variable at the top of the script:
```powershell
$SaveFile = "C:\Diagrams\MyInfrastructure.drawio"
```

### Change Shape Styles (draw.io)

Edit the `$script:styles` hashtable in `vDiagram-DrawIO.ps1`:
```powershell
$script:styles = @{
    'VirtualCenter' = 'shape=ellipse;fillColor=#FF0000;strokeColor=#000000;'
    # ... modify other styles
}
```

### Adjust Spacing

Modify the coordinate calculations in the script:
```powershell
$x += 1.50  # Change horizontal spacing
$y += 1.50  # Change vertical spacing
```

## Best Practices

1. **Run during off-peak hours** for large environments
2. **Test with a single cluster first** using `-Cluster` parameter
3. **Review generated diagrams** and adjust spacing if needed
4. **Save multiple versions** for infrastructure change tracking
5. **Use draw.io version** for easier sharing and collaboration

## Examples

### Small Environment (1-2 hosts)
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "esxi01.lab.local"
```
Runtime: ~30 seconds

### Medium Environment (3-5 clusters, 20-30 hosts)
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com"
```
Runtime: 2-5 minutes

### Large Environment (Single Cluster)
```powershell
.\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com" -Cluster "Production"
```
Runtime: 1-3 minutes per cluster

## Credits

Original Visio script by Alan Renouf ([@alanrenouf](https://github.com/alanrenouf))

## License

This project is provided as-is for educational and professional use.

## Support

For issues or questions:
- Check the [Issues](https://github.com/alanrenouf/VisioPowerShell/issues) page
- Review VMware PowerCLI documentation
- Consult draw.io documentation at https://www.diagrams.net/doc/

## What Information is Included?

### Basic Diagrams (vDiagram.ps1 & vDiagram-DrawIO.ps1)
- Infrastructure hierarchy (vCenter → Clusters → Hosts → VMs)
- Component names
- VM operating system classification

### Detailed Diagram (vDiagram-DrawIO-Detailed.ps1)
Everything in basic diagrams, plus:
- **IP Addresses:** VM IPv4 addresses, ESXi management IPs, vMotion IPs
- **Network Topology:** Virtual switches, port groups, network connections
- **VLAN Information:** VLAN IDs for each port group
- **Hardware Details:** MAC addresses, network adapter names
- **Version Info:** ESXi version numbers
- **MTU Settings:** For virtual switches

## Version History

- **v1.0** - Original Visio-based script
- **v2.0** - Added draw.io XML export support (no Visio required)
- **v2.1** - Added detailed network diagram with IP addresses, VLANs, and full topology
- **v2.2** - Fixed PowerShell best practice issues (PSScriptAnalyzer compliance)

---

**Happy Diagramming!** 🎨📊
