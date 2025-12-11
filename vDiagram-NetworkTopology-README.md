# vDiagram-NetworkTopology.ps1 - Context Document

## Overview
Advanced VMware network topology visualization tool that generates Draw.io diagrams showing VMs, networks, VLANs, subnets, and security zones with detailed VM information.

## Current Status
**Version**: 1.0  
**Last Updated**: December 5, 2025  
**Status**: Production Ready  
**Lines of Code**: 893

## Features Implemented

### Core Functionality
- ✅ **Multiple Grouping Modes**:
  - `VLAN` - Group networks by VLAN ID with swim lanes or flat layout
  - `SecurityZone` - Group by security classification (DMZ, Management, Infrastructure, Production, Development, Corporate, Guest, Unclassified)
  - `Subnet` - Group by IP subnet (/24 CIDR)
  - `Layer2Domain` - (Declared but not implemented)

- ✅ **Swim Lane Containers**: Color-coded containers for organized visualization
- ✅ **Gateway VM Identification**: Highlights VMs with multiple network adapters (firewalls, routers)
- ✅ **Isolated Network Detection**: Identifies networks with 0-1 VMs
- ✅ **Multi-row Layout**: Automatically wraps VMs to new rows when container width is exceeded

### VM Details Display
Each VM shows:
- VM name
- Network adapter information (per adapter):
  - Adapter name (e.g., "Network adapter 1")
  - IPv4 address (filtered, excludes IPv6 and link-local)
  - Network/port group name
  - MAC address
- System information:
  - CPU count
  - RAM in GB
  - Power state (PoweredOn/PoweredOff/Suspended)

### Visual Specifications
- **VM Boxes**: 200px × 420px (sized for VMs with 7+ network adapters)
- **Horizontal Spacing**: 220px between VMs
- **Vertical Spacing**: 450px between network rows in swim lanes, 480px in flat layouts
- **Container Dimensions**:
  - VLAN swim lanes: 1200px wide, height = 300 + (networks × 480)
  - SecurityZone swim lanes: 1400px wide, height = 300 + (networks × 480)
  - Flat layouts: Dynamic width up to 1400px
- **Row Wrapping**: VMs wrap to new rows automatically (5-6 VMs per row depending on mode)

### Network Discovery
- Discovers port groups from all ESXi hosts
- Three fallback methods for port group discovery (handles edge cases)
- Supports both standard and distributed virtual switches
- Deduplicates port groups across hosts
- Handles VLANs (0 = untagged, 1-4095 = tagged)

### Security Zone Classification
Auto-classifies networks based on naming patterns:
- **DMZ**: DMZ, External, Internet, INTRNET
- **Management**: Management, Mgmt, mc-internal, fw-mgmt
- **Infrastructure**: vMotion, vSAN, Storage, BMC
- **Production**: Production, PROD, OPS
- **Development**: Dev, Test, QA, IQT, DevTest
- **Corporate**: Office, OFFICE
- **Guest**: Guest, VDE
- **Unclassified**: Everything else

## Usage Examples

### Basic VLAN Diagram
```powershell
.\vDiagram-NetworkTopology.ps1 -vCenter vcsa.example.com -GroupBy VLAN
```

### Security Zone View with Swim Lanes
```powershell
.\vDiagram-NetworkTopology.ps1 -vCenter vcsa.example.com `
    -GroupBy SecurityZone `
    -IncludeSwimLanes `
    -IdentifyGateways `
    -OutputFile "network-security-zones.drawio"
```

### Subnet View with Isolated Networks
```powershell
.\vDiagram-NetworkTopology.ps1 -vCenter vcsa.example.com `
    -GroupBy Subnet `
    -ShowIsolatedNetworks
```

### Using Existing Connection
```powershell
Connect-VIServer -Server vcsa.example.com
.\vDiagram-NetworkTopology.ps1 -GroupBy VLAN -IncludeSwimLanes
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-vCenter` | String | None | vCenter server FQDN or IP (optional if already connected) |
| `-OutputFile` | String | "network-topology.drawio" | Output file path (relative or absolute) |
| `-GroupBy` | String | "VLAN" | Grouping mode: VLAN, Subnet, SecurityZone, Layer2Domain |
| `-IncludeSwimLanes` | Switch | False | Use swim lane containers for grouping |
| `-ShowIsolatedNetworks` | Switch | False | Include networks with 0-1 VMs |
| `-IdentifyGateways` | Switch | False | Highlight VMs with multiple network adapters |

## Known Issues & Limitations

### Current Limitations
1. **Layer2Domain Mode**: Declared in ValidateSet but not implemented in switch statement
2. **Port Group Discovery**: May miss port groups in complex DVS configurations
3. **Large Environments**: Diagrams with 100+ VMs per network may be difficult to navigate
4. **Guest Info Requirements**: VM details require VMware Tools to be installed and running
5. **IP Address Display**: Currently shows only first IPv4 address per adapter, not all IPs

### Performance Notes
- **Data Collection**: ~5-10 seconds for 100 VMs
- **Diagram Generation**: ~2-5 seconds for 100 VMs
- **Memory Usage**: ~50-100MB for typical environments

## Architecture

### Key Functions

#### `Get-SubnetFromIP`
Calculates /24 subnet from IP address using CIDR mask logic.

#### `Get-NetworkSecurityZone`
Classifies networks into security zones based on naming patterns and VLAN IDs.

#### `Get-VMNetworkDetails`
Extracts detailed VM information formatted as HTML for Draw.io display:
- Iterates through all network adapters
- Filters IPv4 addresses (excludes IPv6 and link-local)
- Formats output with `<br>` tags for HTML rendering
- Returns single string with all details

#### `Analyze-NetworkTopology`
Core analysis engine that builds topology data structure:
- Creates hashtables for Networks, VLANs, Subnets, SecurityZones
- Analyzes port groups and VMs
- Identifies gateway VMs (multiple adapters)
- Detects isolated networks
- Calculates subnets from IP addresses
- Groups networks by classification

**Data Structure**:
```powershell
@{
    Networks = @{
        "NetworkName" = @{
            Name, VLanId, Switch, VMs[], IPAddresses[], 
            Subnets[], SecurityZone, IsIsolated, Type
        }
    }
    VLANs = @{ VLanId = @{ VLanId, Networks[], VMs[] } }
    Subnets = @{ "10.0.0.0/24" = @{ Subnet, Networks[], VMs[], IPAddresses[] } }
    SecurityZones = @{ "DMZ" = @{ Zone, Networks[], VMs[] } }
    GatewayVMs = @( @{ Name, Networks[], IPAddresses[], AdapterCount } )
    IsolatedNetworks = @()
    Statistics = @{ TotalVMs, TotalNetworks, TotalAdapters }
}
```

#### `Export-NetworkTopologyDiagram`
Generates Draw.io XML with proper mxGraph structure:
- Creates XML document with UTF-8 encoding
- Builds mxGraphModel with cells and geometry
- Implements grouping logic for each mode
- Handles row wrapping and spacing
- Adds legend and statistics
- Saves to absolute path

### XML Helpers
- `New-DrawIOShape`: Creates VM and network shapes with Cisco icons
- `New-DrawIOContainer`: Creates swim lane containers with custom colors
- `Connect-DrawIOShape`: Creates edges between shapes with orthogonal routing

## Development History

### Major Iterations
1. **Initial Creation** - Basic VLAN grouping with simple layout
2. **Arithmetic Bug Fix** - Fixed `$currentId+1` expression evaluation with parentheses
3. **Path Resolution** - Added absolute path display for output file location
4. **VM Details Addition** - Integrated Get-VMNetworkDetails function from vDiagram-DrawIO-Detailed.ps1
5. **HTML Rendering Fix** - Changed `\n` to `<br>` tags, added `html=1` style attribute
6. **Spacing Increase #1** - Increased VM boxes from 160×100 to 200×280, spacing from 80-90px to 300px
7. **Spacing Increase #2** - Further increased to 420px height, 450-480px vertical spacing (50% more)
8. **Row Wrapping Implementation** - Added automatic row wrapping for all display modes, removed VM limits

### Recent Changes (Current Session)
- **Row Wrapping**: Added logic to wrap VMs to new rows when X position exceeds container width
- **VM Limits Removed**: Changed from `Select-Object -First X` to displaying all VMs
- **Dynamic Height**: Container heights now adjust based on actual VM count and row wrapping
- **All Modes Updated**: VLAN (swim lane & flat), SecurityZone, and Subnet modes all support full VM display

## Testing Recommendations

### Before Making Changes
1. Test with small environment (10-20 VMs)
2. Test with network containing 1 VM (edge case)
3. Test with network containing 50+ VMs (row wrapping)
4. Test with VM having 7+ network adapters (vertical spacing)
5. Test all three grouping modes
6. Test with and without swim lanes
7. Verify gateway VM highlighting works

### After Making Changes
1. Check output file is valid Draw.io XML
2. Open in Draw.io web/desktop to verify rendering
3. Verify all VMs appear (count matches statistics)
4. Check row wrapping works correctly
5. Verify VM details display properly with `<br>` tags
6. Check swim lane container sizes accommodate all content

## Future Enhancement Ideas

### Not Yet Implemented
- [ ] **Layer2Domain Mode**: Implement physical L2 domain grouping
- [ ] **Dynamic VM Box Heights**: Size boxes based on adapter count
- [ ] **Service/Port Information**: Add optional port scanning via Invoke-VMScript
- [ ] **Guest OS Details**: Include hostname, OS name, disk usage, Tools version
- [ ] **Export Formats**: Add PDF, PNG, SVG export options
- [ ] **Performance Optimization**: Add `-MaxVMsPerNetwork` parameter for large environments
- [ ] **Progressive Detail Levels**: Summary vs. detailed view toggle
- [ ] **Multiple IP Display**: Show all IPs per adapter, not just first
- [ ] **Custom Styling**: Allow color scheme customization
- [ ] **Interactive Filters**: Generate separate diagrams per VLAN/zone
- [ ] **Relationship Mapping**: Show VM-to-VM communication paths

### Credential-Based Features (Requires Guest Credentials)
- [ ] **Open Ports**: Use Invoke-VMScript to get netstat/ss output
- [ ] **Running Services**: Query services via guest OS commands
- [ ] **Firewall Rules**: Extract local firewall configurations
- [ ] **Application Detection**: Identify web servers, databases, etc.

## Dependencies
- **PowerShell**: 5.1+ (Windows PowerShell) or 7+ (PowerShell Core)
- **VMware.PowerCLI**: 12.0+
- **Permissions**: Read access to vCenter, VMs, and network configuration

## File Locations
- **Script**: `d:\GitHub\VisioPowerShell\vDiagram-NetworkTopology.ps1`
- **Example Output**: `d:\GitHub\VisioPowerShell\newdraw.drawio`
- **Reference Script**: `d:\GitHub\VisioPowerShell\vDiagram-DrawIO-Detailed.ps1`

## Related Files
- `vDiagram-DrawIO-Detailed.ps1` - Original detailed VM diagram script (source of Get-VMNetworkDetails pattern)
- `vDiagram.ps1` - Basic Visio diagram generator

## Notes for Future Development
- Container height formula: `baseHeight + (networkCount × rowHeight)`
- Row wrapping triggers when `X > containerWidth - vmBoxWidth`
- `[Math]::Max($y, $startY) + spacing` ensures minimum spacing even with wrapping
- SecurityZone mode uses different icon colors for gateway VMs (gold/orange)
- All Draw.io shapes require `html=1` in style for HTML rendering
- Parent attribute links shapes to containers (swim lanes)

## Troubleshooting

### Common Issues
**"No VMs found"**: Check PowerState filter, may need to include PoweredOff VMs  
**"No network adapters found"**: Verify Get-NetworkAdapter cmdlet works  
**"Port groups missing"**: Check ESXi host network permissions  
**"VMs not showing"**: Verify row wrapping logic, check X/Y coordinates  
**"Details on one line"**: Ensure `html=1` is in style attribute  
**"VMs cramped"**: Increase box height and vertical spacing  
**"VMs off-screen"**: Check row wrapping triggers correctly  

### Debug Steps
1. Check PowerCLI connection: `Get-VIServer`
2. Verify data collection: Check VM/adapter/port group counts in output
3. Examine topology structure: `$topology | ConvertTo-Json -Depth 5`
4. Test single network: Filter to one network for debugging
5. Validate XML: Open output file in text editor, check structure
6. Draw.io validation: Import file and check for rendering errors

## Contact & Support
- **Repository**: github.com/alanrenouf/VisioPowerShell
- **Author**: Alan Renouf (referenced in repo)
- **Contributors**: [Add contributors here]

---
**Document Version**: 1.0  
**Last Reviewed**: December 5, 2025  
**Maintained By**: Project Team
