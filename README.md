# VisioPowerShell — VMware vSphere Management Scripts

A comprehensive PowerShell toolkit for VMware vSphere — covering infrastructure diagramming, operational reporting, security compliance, capacity planning, storage management, networking, patch management, cluster health monitoring, VM lifecycle management, troubleshooting diagnostics, and Power BI dashboard exports. All scripts use VMware PowerCLI and require no additional dependencies beyond what is listed per script.

## Overview

**85 scripts across 17 management domains**, organized to provide end-to-end vSphere operational visibility:

| Domain | Scripts | Summary |
|--------|--------:|---------|
| Diagramming | 4 | Visio and draw.io infrastructure and network topology diagrams |
| Inventory & Reporting | 7 | VM lifecycle, utilization, network IP mapping |
| Security & Compliance | 5 | ESXi baseline auditing, permissions, certificates, login events, VM security |
| Storage Management | 9 | Overcommit, orphaned VMDKs, SPBM, RDMs, disk layout, vSAN, SDRS, snapshot audit, path health |
| Networking | 5 | VDS auditing, network consistency, VMkernel adapters, physical NICs, NSX |
| Backup & DR | 4 | Backup status, replication, VM config export, DR readiness |
| Operations | 7 | Cluster config, DRS rules, resource pools, alarms, vMotion history, services, maintenance |
| Change Management | 4 | Configuration baselines, drift detection, hardware versions, host profiles |
| Capacity Planning | 3 | Capacity forecasting, right-sizing, what-if analysis |
| Patch Management | 2 | ESXi patch levels, vLCM/VUM compliance |
| Licensing | 1 | License audit and expiration tracking |
| Tags & Organization | 3 | Tag inventory, bulk assignments, custom attributes |
| Templates & Content Library | 2 | Template inventory, content library reporting |
| Alarm Management | 1 | Alarm definition audit |
| Power BI | 2 | vSphere metrics and operations dashboard CSV exports |
| Reporting | 2 | Full cluster audit orchestrator, multi-cluster comparison |
| Deployment Diagnostics | 1 | VM deployment and customization diagnostics |
| VM Management | 5 | Template cloning, snapshots, bulk power operations, disk expansion |
| Troubleshooting | 12 | VM connectivity, firewall, event logs, diagnostics, Tools health, event timeline |
| Cluster Health | 6 | Point-in-time health bundle, host availability, resource pressure, datastore health, HA readiness, DRS analysis |

---

## Repository Structure

```
VisioPowerShell/
├── README.md
├── Alarm-Management/
│   └── Get-AlarmDefinitionAudit.ps1
├── Backup-DR/
│   ├── Export-VMConfiguration.ps1
│   ├── Get-DRReadinessReport.ps1
│   ├── Get-ReplicationStatus.ps1
│   └── Test-VMBackupStatus.ps1
├── Capacity-Planning/
│   ├── Get-CapacityForecast.ps1
│   ├── Get-VMRightSizingDetailed.ps1
│   └── Get-WhatIfCapacityAnalysis.ps1
├── Change-Management/
│   ├── Export-ClusterConfiguration.ps1
│   ├── Get-HostProfileCompliance.ps1
│   ├── Get-VMHardwareVersionReport.ps1
│   └── Test-ConfigurationDrift.ps1
├── Deployment-Diagnostics/
│   └── Get-DeploymentDiagnostics.ps1
├── Diagramming/
│   ├── vDiagram.ps1
│   ├── vDiagram-DrawIO.ps1
│   ├── vDiagram-DrawIO-Detailed.ps1
│   ├── vDiagram-NetworkTopology.ps1
│   ├── vDiagram-NetworkTopology-README.md
│   └── Assets/
│       ├── My-VI-Shapes.vss
│       ├── diagram.drawio
│       └── newdraw.drawio
├── Inventory-Reporting/
│   ├── Export-NetworkIPAddresses.ps1
│   ├── Get-InfraUtilizationWithFolders.ps1
│   ├── Get-VMHostUtilization.ps1
│   ├── Get-VMLifecycle.ps1
│   ├── Get-VMNamesByFolder.ps1
│   ├── Get-VMUtilization.ps1
│   └── Get-VMUtilizationByFolder.ps1
├── Licensing/
│   └── Get-LicenseAudit.ps1
├── Networking/
│   ├── Get-NSXSegmentAudit.ps1
│   ├── Get-PhysicalNICInventory.ps1
│   ├── Get-VDSwitchAudit.ps1
│   ├── Get-VMKernelAdapterReport.ps1
│   └── Test-NetworkConsistency.ps1
├── Operations/
│   ├── Get-ActiveAlarms.ps1
│   ├── Get-ClusterConfigurationReport.ps1
│   ├── Get-DRSRulesAndGroups.ps1
│   ├── Get-HostServiceStatus.ps1
│   ├── Get-ResourcePoolConfiguration.ps1
│   ├── Get-vMotionHistory.ps1
│   └── Set-HostMaintenanceWorkflow.ps1
├── Patch-Management/
│   ├── Get-ESXiPatchLevel.ps1
│   └── Get-VUMComplianceReport.ps1
├── PowerBI/
│   ├── Export-vSphereMetricsForPowerBI.ps1
│   ├── Export-vSphereOperationsDashboard.ps1
│   ├── PowerBI-vSphere-Dashboards-README.md
│   └── PowerBI-OperationsDashboard-README.md
├── Reporting/
│   ├── Compare-MultiClusterConfig.ps1
│   └── Export-FullClusterAudit.ps1
├── Security-Compliance/
│   ├── Get-CertificateStatus.ps1
│   ├── Get-FailedLoginAudit.ps1
│   ├── Get-vSpherePermissionsAudit.ps1
│   ├── Test-ESXiSecurityBaseline.ps1
│   └── Test-VMSecurityConfiguration.ps1
├── Storage-Management/
│   ├── Get-DatastoreClusterConfig.ps1
│   ├── Get-DatastoreOvercommit.ps1
│   ├── Get-OrphanedVMDKs.ps1
│   ├── Get-RDMInventory.ps1
│   ├── Get-StoragePolicyCompliance.ps1
│   ├── Get-VMDiskLayout.ps1
│   ├── Get-VMSnapshotAudit.ps1
│   ├── Get-vSANHealthReport.ps1
│   └── Test-StoragePathHealth.ps1
├── Tags-Organization/
│   ├── Get-CustomAttributeReport.ps1
│   ├── Get-TagInventory.ps1
│   └── Set-BulkTagAssignment.ps1
├── VM-Management/
│   ├── Copy-VMsToTemplates.ps1
│   ├── Expand-VMDiskSpace.ps1
│   ├── Invoke-BulkPowerOperation.ps1
│   ├── New-RangeSnapshot.ps1
│   └── Reset-RangeExercise.ps1
├── Troubleshooting/
│   ├── Get-VMConsoleLog.ps1
│   ├── Get-VMDisconnectDiagnostics.ps1
│   ├── Get-VMEventLog.ps1
│   ├── Get-VMEventTimeline.ps1
│   ├── Get-VMNetworkDiagnostics.ps1
│   ├── Get-VMToolsStatus.ps1
│   ├── Test-CrossSubnetConnectivity.ps1
│   ├── Test-ServicePortReachability.ps1
│   ├── Test-StatefulFirewallIssues.ps1
│   ├── Test-vCenterConnectivity.ps1
│   ├── Test-VMConnectivity.ps1
│   └── Test-VMToolsHealth.ps1
└── Cluster-Health/
    ├── Get-ClusterHealthBundle.ps1
    ├── Get-DatastoreHealthReport.ps1
    ├── Get-DRSMigrationAnalysis.ps1
    ├── Get-HostAvailabilityReport.ps1
    ├── Get-ResourcePressureReport.ps1
    └── Test-HAReadiness.ps1
```

---

## Installation

### 1. Install VMware PowerCLI

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser
```

### 2. Clone the repository

```powershell
git clone https://github.com/alanrenouf/VisioPowerShell.git
cd VisioPowerShell
```

### 3. Set execution policy (if needed)

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4. One-time PowerCLI configuration

```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false
```

---

## Scripts by Domain

---

### Diagramming

Generates draw.io or Visio diagrams of your vSphere infrastructure — no network access to VMs required beyond vCenter connectivity.

| Script | Output | Description |
|--------|--------|-------------|
| `vDiagram.ps1` | `.vsd` | Visio diagram of vCenter → Cluster → Host → VM hierarchy. Requires Microsoft Visio and `Assets/My-VI-Shapes.vss` copied to `My Documents\My Shapes\`. |
| `vDiagram-DrawIO.ps1` | `.drawio` | draw.io XML hierarchy diagram. VMs color-coded by OS (Windows=blue, Linux=teal, Other=gray). No local app required; open at https://app.diagrams.net. |
| `vDiagram-DrawIO-Detailed.ps1` | `.drawio` | Extends the basic draw.io diagram with virtual switches, port groups, VLAN IDs, IP addresses, MAC addresses, and NIC-to-network connections. |
| `vDiagram-NetworkTopology.ps1` | `.drawio` | Network-centric diagram grouped by VLAN, subnet, security zone, or L2 domain. Supports swim lanes, gateway identification, and isolated network display. See `vDiagram-NetworkTopology-README.md` for full parameter reference. |

**Common usage:**

```powershell
# Basic draw.io diagram
.\Diagramming\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com"

# Detailed network topology grouped by VLAN
.\Diagramming\vDiagram-NetworkTopology.ps1 -VIServer "vcenter.company.com" -GroupBy VLAN -IncludeSwimLanes

# Single-cluster scope
.\Diagramming\vDiagram-DrawIO.ps1 -VIServer "vcenter.company.com" -Cluster "Production"
```

---

### Inventory & Reporting

Read-only VM and host inventory scripts. All export to CSV.

| Script | Description |
|--------|-------------|
| `Export-NetworkIPAddresses.ps1` | VM → network adapter → IP/MAC/DHCP mapping for all powered-on VMs. |
| `Get-InfraUtilizationWithFolders.ps1` | Combined ESXi host and VM QuickStats utilization with vSphere folder paths. Fast — no historical stat collection. |
| `Get-VMHostUtilization.ps1` | Per-host CPU/memory utilization with overutilization flags and VM placement recommendations. |
| `Get-VMLifecycle.ps1` | Per-VM lifecycle report: power state, creation date, snapshots, VM Tools, CPU/RAM/disk allocations. |
| `Get-VMNamesByFolder.ps1` | Simple VM name list organized by folder. Supports filtering and CSV export. |
| `Get-VMUtilization.ps1` | Historical CPU/memory/disk/network stats via `Get-Stat` for VMs in a specified folder. |
| `Get-VMUtilizationByFolder.ps1` | Same as above but iterates all folders with per-folder aggregate summaries. |

```powershell
.\Inventory-Reporting\Get-VMLifecycle.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -OutputFile "C:\Reports\lifecycle.csv"
.\Inventory-Reporting\Export-NetworkIPAddresses.ps1 -vCenter "vcenter.company.com"
```

---

### Security & Compliance

Audits ESXi host hardening, VM security settings, certificates, permissions, and authentication events.

| Script | Description |
|--------|-------------|
| `Test-ESXiSecurityBaseline.ps1` | Audits ESXi hosts against CIS Level 1, CIS Level 2, or DISA-STIG profile. Checks SSH, lockdown mode, NTP, syslog, SNMP, firewall, TLS, account policy, CEIP, and MOB. Supports `-RemediateFindings`. |
| `Get-vSpherePermissionsAudit.ps1` | Exports all roles, permission assignments, and privilege sets across the vCenter inventory hierarchy. Flags Administrator-level grants, overly broad datacenter permissions, and orphaned accounts. |
| `Test-VMSecurityConfiguration.ps1` | Audits VM-level security controls: copy/paste/DnD isolation, console connection limits, device presence, encryption/vTPM status, and annotation secrets. |
| `Get-CertificateStatus.ps1` | Reports certificate expiration for vCenter (VECS stores) and all ESXi hosts. Flags Warning (default 60 days) and Critical (default 30 days) thresholds. |
| `Get-FailedLoginAudit.ps1` | Extracts failed authentication events and optionally permission change events from the vCenter event stream. Supports configurable lookback window. |

```powershell
# Audit all hosts against CIS Level 1
.\Security-Compliance\Test-ESXiSecurityBaseline.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -BaselineProfile CIS-Level1

# Certificate expiration check with 90-day warning
.\Security-Compliance\Get-CertificateStatus.ps1 -vCenter "vcenter.company.com" -WarningDays 90
```

---

### Storage Management

Reports on datastore health, thin provisioning exposure, orphaned VMDKs, storage policies, and vSAN.

| Script | Description |
|--------|-------------|
| `Get-DatastoreOvercommit.ps1` | Thin provisioning overcommit ratio per datastore. Flags Warning (default 150%) and Critical (default 200%) thresholds. |
| `Get-OrphanedVMDKs.ps1` | Scans datastores for VMDKs not attached to any registered VM. Optionally reports file sizes for reclamation planning. |
| `Get-StoragePolicyCompliance.ps1` | SPBM compliance status per VM virtual disk. Filters to non-compliant disks only with `-IncludeNonCompliant`. |
| `Get-VMDiskLayout.ps1` | Per-VM disk detail: VMDK path, provisioning type, controller type, bus/unit number, persistence mode, and storage policy. |
| `Get-RDMInventory.ps1` | All Raw Device Mappings with LUN IDs, compatibility mode, sharing status, capacity, and associated VMs. |
| `Get-vSANHealthReport.ps1` | vSAN cluster health tests, disk group status, capacity/dedup/compression savings, and optional object compliance. Outputs multiple CSVs. |
| `Get-DatastoreClusterConfig.ps1` | Storage DRS (SDRS) pod configuration: automation level, I/O load balance, space/latency thresholds, affinity rules, and capacity summary. |
| `Get-VMSnapshotAudit.ps1` | Audits all VM snapshots for age, chain depth, and stale snapshot detection. Flags snapshots exceeding configurable age or chain-depth thresholds. Pre-screens VMs using ExtensionData to skip VMs with no snapshots and avoid slow Get-Snapshot calls. |
| `Test-StoragePathHealth.ps1` | Per-host LUN multipath health: active/standby/dead path counts, PSP policy per LUN, cross-host PSP inconsistency detection, and datastore name mapping. Flags LUNs with dead paths or below the minimum active path threshold. |

```powershell
.\Storage-Management\Get-DatastoreOvercommit.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com"
.\Storage-Management\Get-OrphanedVMDKs.ps1 -vCenter "vcenter.company.com" -IncludeSizeGB
.\Storage-Management\Get-VMSnapshotAudit.ps1 -ClusterName "Prod" -MaxAgeDays 3 -OutputFile "snapshots.csv"
.\Storage-Management\Test-StoragePathHealth.ps1 -ClusterName "Prod" -MinActivePaths 2 -OutputFile "paths.csv"
```

---

### Networking

Audits distributed switches, VMkernel adapters, physical NICs, host network consistency, and NSX segments.

| Script | Description |
|--------|-------------|
| `Get-VDSwitchAudit.ps1` | VDS configuration audit: version, MTU, port groups, VLAN/PVLAN, traffic shaping, LACP, NetFlow, health check, and failover policy. Outputs multiple CSVs. |
| `Test-NetworkConsistency.ps1` | Compares vSwitches, port groups, NIC teaming, VMkernel adapters, and MTU across all cluster hosts against a reference host. Reports per-host drift. |
| `Get-VMKernelAdapterReport.ps1` | All VMkernel adapters per host: IP, subnet, gateway, enabled services (management/vMotion/vSAN/FT/provisioning/replication), MTU, TCP/IP stack, VLAN. |
| `Get-PhysicalNICInventory.ps1` | Per-host vmnic inventory: driver, driver version, firmware version, link speed, duplex, MAC, and associated vSwitch. |
| `Get-NSXSegmentAudit.ps1` | NSX Manager REST API inventory of segments, transport zones, connected VMs, and DFW rule sections. Exports separate CSVs per domain. |

```powershell
.\Networking\Test-NetworkConsistency.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com"
.\Networking\Get-VDSwitchAudit.ps1 -vCenter "vcenter.company.com" -IncludePortGroupDetail
```

---

### Backup & DR

Validates backup coverage, replication compliance, and DR readiness.

| Script | Description |
|--------|-------------|
| `Test-VMBackupStatus.ps1` | Checks CBT status and a configurable custom attribute (e.g., `LastBackupDate`) per VM. Flags VMs exceeding the maximum backup age as Warning or Critical. |
| `Get-ReplicationStatus.ps1` | vSphere Replication status per VM: configured RPO, current RPO compliance, replication state, last sync time, and target site. |
| `Export-VMConfiguration.ps1` | Exports full VM configuration (VMX-equivalent) to per-VM JSON files plus a master index CSV. Enables VM rebuild if vCenter is lost. |
| `Get-DRReadinessReport.ps1` | DR readiness assessment covering HA config, replication status, RPO compliance, snapshot age, datastore free space, single points of failure, and optionally SRM recovery plans. |

```powershell
.\Backup-DR\Test-VMBackupStatus.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -MaxBackupAgeDays 1
.\Backup-DR\Export-VMConfiguration.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -OutputFolder "D:\DR\VMConfigs"
```

---

### Operations

Cluster configuration reporting, DRS rules, resource pools, alarm visibility, vMotion history, host services, and maintenance mode workflows.

| Script | Description |
|--------|-------------|
| `Get-ClusterConfigurationReport.ps1` | Complete cluster config dump: HA, DRS, EVC, admission control, VM restart priority, host isolation response, and proactive HA. One row per setting. |
| `Get-DRSRulesAndGroups.ps1` | All DRS rules (VM-VM affinity/anti-affinity, VM-to-host) and DRS groups with member lists, enabled state, and mandatory flags. |
| `Get-ResourcePoolConfiguration.ps1` | Resource pool hierarchy with CPU/memory shares, reservations, limits, expandable reservation settings, and VM counts. |
| `Get-ActiveAlarms.ps1` | All currently triggered alarms for cluster hosts and VMs: alarm name, entity, severity, triggered time, and acknowledgment status. Filterable by severity. |
| `Get-vMotionHistory.ps1` | vMotion/svMotion event history from vCenter: source/destination host, trigger type (user/DRS/maintenance), duration, and result. |
| `Get-HostServiceStatus.ps1` | Running state and startup policy for all (or filtered) services per ESXi host. Useful for detecting SSH/shell/SNMP left enabled. |
| `Set-HostMaintenanceWorkflow.ps1` | Structured maintenance mode workflow with pre-flight checks (alarms, HA admission control, vSAN data migration mode). Supports Enter/Exit and `-DryRun`. |

```powershell
.\Operations\Get-ActiveAlarms.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -Severity Critical
.\Operations\Set-HostMaintenanceWorkflow.ps1 -HostName "esxi01.company.com" -vCenter "vcenter.company.com" -DryRun
```

---

### Change Management

Configuration baseline export and drift detection for cluster and host settings.

| Script | Description |
|--------|-------------|
| `Export-ClusterConfiguration.ps1` | Captures a point-in-time JSON baseline of cluster and host configuration: HA, DRS, EVC, admission control, host configs, network profiles, and resource pool hierarchy. |
| `Test-ConfigurationDrift.ps1` | Compares live configuration against a baseline exported by `Export-ClusterConfiguration.ps1`. Reports added/changed/removed values per entity and property path. |
| `Get-VMHardwareVersionReport.ps1` | VM hardware (VMX) versions vs. each host's maximum supported version. Flags VMs eligible for upgrade with a configurable minimum version threshold. |
| `Get-HostProfileCompliance.ps1` | Host profile compliance per host: attached profile name, compliant/non-compliant status, non-compliant settings, and last check time. |

```powershell
# Capture baseline
.\Change-Management\Export-ClusterConfiguration.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -OutputFolder "D:\Baselines\2026-03-07"

# Compare next week
.\Change-Management\Test-ConfigurationDrift.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -BaselineFolder "D:\Baselines\2026-03-07"
```

---

### Capacity Planning

Forecasting, right-sizing, and what-if modeling using historical vCenter statistics.

| Script | Description |
|--------|-------------|
| `Get-CapacityForecast.ps1` | Projects CPU, memory, and storage exhaustion dates using weighted linear regression on historical stats. Reports growth rate, projected full date, and confidence level. |
| `Get-VMRightSizingDetailed.ps1` | Per-VM right-sizing using P95 CPU and memory statistics. Recommends vCPU/vRAM reductions with configurable burst headroom and projected savings. |
| `Get-WhatIfCapacityAnalysis.ps1` | Simulates AddVMs, RemoveHost, or ExpandCluster scenarios. Reports projected CPU/memory/storage headroom and pass/fail per resource after the scenario. |

```powershell
.\Capacity-Planning\Get-CapacityForecast.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -DaysOfHistory 60 -ForecastDays 90
.\Capacity-Planning\Get-VMRightSizingDetailed.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -DaysOfStats 30
```

---

### Patch Management

ESXi host patching status and vSphere Lifecycle Manager / Update Manager compliance.

| Script | Description |
|--------|-------------|
| `Get-ESXiPatchLevel.ps1` | Per-host ESXi version, build number, installed VIBs, and comparison against a target build. Flags hosts needing patching and intra-cluster patch drift. |
| `Get-VUMComplianceReport.ps1` | vLCM/VUM baseline or desired-state image compliance per host: compliance status, missing patches, and last scan time. Optionally triggers a live scan. |

```powershell
.\Patch-Management\Get-ESXiPatchLevel.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -TargetBuild 23305545
```

---

### Licensing

| Script | Description |
|--------|-------------|
| `Get-LicenseAudit.ps1` | All vCenter license keys (masked): edition, capacity, used licenses, expiration date, and assigned entities. Flags expired and soon-to-expire licenses with a configurable warning window (default 90 days). |

---

### Tags & Organization

| Script | Description |
|--------|-------------|
| `Get-TagInventory.ps1` | All tag categories, tags, and assignments across VMs/hosts/datastores/clusters/networks. Exports separate CSVs for assignments and category definitions. |
| `Set-BulkTagAssignment.ps1` | Applies or removes vSphere tags in bulk from a CSV input (EntityName / EntityType / TagName / CategoryName / Action). Supports `-WhatIf`. |
| `Get-CustomAttributeReport.ps1` | All custom attribute definitions and their values across VMs, hosts, datastores, and clusters. |

---

### Templates & Content Library

| Script | Description |
|--------|-------------|
| `Get-TemplateInventory.ps1` | VM template and content library item inventory: OS, hardware version, VM Tools version, creation/modification date, and stale flag (configurable threshold, default 180 days). |
| `Get-ContentLibraryReport.ps1` | Content library configuration: type (local/subscribed), storage backing, sync status, item count, total size, and last sync time. |

---

### Alarm Management

| Script | Description |
|--------|-------------|
| `Get-AlarmDefinitionAudit.ps1` | All alarm definitions at vCenter/datacenter/cluster/host level: trigger expressions, configured actions (email/SNMP/script), enabled state, and entities with no alarm coverage. |

---

### Power BI

Exports vSphere metrics to CSV for Power BI dashboard consumption. See the READMEs in the `PowerBI/` folder for dashboard setup instructions.

| Script | Description |
|--------|-------------|
| `Export-vSphereMetricsForPowerBI.ps1` | Four metric categories: Capacity & Waste (right-sizing, zombies, snapshots), Cluster Performance (CPU ready, memory pressure, latency), Infrastructure Hygiene (tools, hardware versions, drift), Change & Drift (VM events, DRS effectiveness). Supports multiple vCenters. |
| `Export-vSphereOperationsDashboard.ps1` | Six Aria Operations–style tiles: Environment Health, Capacity Headroom (days to exhaustion), Cost & Efficiency, SLA & Performance, Network/NSX Health, and Hybrid Footprint (on-prem vs cloud cost). |

```powershell
# Schedule daily via Task Scheduler
.\PowerBI\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter1","vcenter2" -OutputPath "D:\PowerBI\Data" -DaysOfStats 14
.\PowerBI\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.company.com" -OutputPath "D:\PowerBI\Ops"
```

---

### Reporting

| Script | Description |
|--------|-------------|
| `Export-FullClusterAudit.ps1` | Orchestrator — runs all audit scripts in dependency order, collects outputs into a timestamped folder, and generates a master HTML/Markdown summary. Accepts a `-Domains` filter (Security, Storage, Network, Operations, All). |
| `Compare-MultiClusterConfig.ps1` | Side-by-side configuration comparison across multiple clusters or vCenters: HA, DRS, networking, storage, host versions. Outputs a CSV with a column per cluster and a `Consistent` flag per setting. |

```powershell
# Full audit across all domains
.\Reporting\Export-FullClusterAudit.ps1 -ClusterName "Prod" -vCenter "vcenter.company.com" -OutputFolder "D:\Audits\2026-03-07" -Domains All

# Compare prod and DR clusters
.\Reporting\Compare-MultiClusterConfig.ps1 -vCenter "vcenter.company.com" -ClusterNames "Prod","DR"
```

---

### Deployment Diagnostics

| Script | Description |
|--------|-------------|
| `Get-DeploymentDiagnostics.ps1` | Collects VM deployment diagnostics: customization events, VM Tools status, task history, and optionally in-guest logs (sysprep/cloud-init/vmware-imc). Outputs an HTML report. Primary use case: diagnosing Terraform/Caster deployment failures. |

---

### VM Management

Lifecycle and operational management for VM fleets — cloning, snapshots, power operations, and disk expansion.

| Script | Description |
|--------|-------------|
| `Copy-VMsToTemplates.ps1` | Clones all VMs in a vSphere folder to VM templates. Optionally powers off source VMs before cloning and powers them back on afterward. Supports `-NameSuffix`, custom target folder/datastore, and `-DryRun`. |
| `New-RangeSnapshot.ps1` | Creates a named snapshot across all VMs in a folder simultaneously. Consistent naming with timestamp suffix. Used to checkpoint a cyber range before an exercise. |
| `Reset-RangeExercise.ps1` | Reverts all VMs in a folder to the most recent matching snapshot. Used to restore a cyber range to a clean baseline after an exercise. Supports `-SnapshotName` filter and `-DryRun`. |
| `Invoke-BulkPowerOperation.ps1` | Powers on, powers off, suspends, or reboots all VMs in a folder. Supports ordered shutdown/startup sequences and `-DryRun`. |
| `Expand-VMDiskSpace.ps1` | Extends a VM virtual disk and optionally expands the guest OS partition (Windows via diskpart, Linux via growpart/resize2fs). Validates current disk size before expanding. |

```powershell
# Snapshot an entire exercise range
.\VM-Management\New-RangeSnapshot.ps1 -SourceFolder "CyberRange\Exercise01" -SnapshotName "PreExercise"

# Reset the range back to baseline
.\VM-Management\Reset-RangeExercise.ps1 -SourceFolder "CyberRange\Exercise01" -SnapshotName "PreExercise"

# Clone VMs to templates, powering them off first
.\VM-Management\Copy-VMsToTemplates.ps1 -SourceFolder "CyberRange\Exercise01" -TemplateFolder "Templates\CyberRange" -PowerOffBeforeClone -DryRun
```

---

### Troubleshooting

Connectivity tests, event log extraction, and diagnostic reporting. TCP-based tests run from the machine executing the script and require network access to the VM networks.

| Script | Description |
|--------|-------------|
| `Test-vCenterConnectivity.ps1` | Validates connectivity to vCenter: DNS resolution, TCP 443 reachability, PowerCLI authentication, and API response time. First-step check before running other scripts. |
| `Test-VMConnectivity.ps1` | Tests ICMP and configurable TCP ports from the local machine to a list of VMs. Reports per-VM/per-port reachability with latency. |
| `Test-ServicePortReachability.ps1` | TCP port reachability check for service-specific port sets (RDP, SSH, HTTP/S, DNS, SMB, etc.) against one or more target VMs. |
| `Test-CrossSubnetConnectivity.ps1` | Tests connectivity from the local machine to VMs across multiple subnets. Flags routing issues when cross-subnet tests fail while same-subnet tests succeed. |
| `Test-StatefulFirewallIssues.ps1` | Diagnoses asymmetric routing and stateful firewall problems by testing connection establishment from both directions between VM pairs. |
| `Get-VMEventLog.ps1` | Extracts VM-specific events from the vCenter event stream with configurable lookback, event type filter, and CSV export. |
| `Get-VMDisconnectDiagnostics.ps1` | Correlates host disconnect events, datastore accessibility events, and VM state changes to help identify what caused a VM to become unreachable. |
| `Get-VMNetworkDiagnostics.ps1` | Reports VM network adapter configuration, port group assignment, VLAN, IP address (via VMware Tools), MAC address, and link state. |
| `Get-VMToolsStatus.ps1` | VMware Tools install status and version per VM. Flags not-installed, outdated (configurable version threshold), and not-running states. |
| `Get-VMConsoleLog.ps1` | Retrieves the most recent vmware.log entries from the VM's datastore directory. Useful for diagnosing boot failures and BSOD/panic events. |
| `Test-VMToolsHealth.ps1` | Comprehensive VMware Tools audit covering installation status, running state, version currency (blacklisted/too-old/too-new/unmanaged), and upgrade policy per VM. Classifies each VM with an Assessment label and Recommendation. |
| `Get-VMEventTimeline.ps1` | Pulls a colour-coded chronological event timeline for a single VM. Categorises events as POWER/MIGRATE/SNAPSHOT/CLONE/RECONFIGURE/ALARM/DEPLOY/TOOLS/ERROR/OTHER using the vCenter EventManager collector API for efficient server-side filtering. |

```powershell
# Quick connectivity pre-check
.\Troubleshooting\Test-vCenterConnectivity.ps1 -vCenter "vcenter.company.com"

# Test RDP/SSH access to a VM list
.\Troubleshooting\Test-ServicePortReachability.ps1 -VMNames "vm01","vm02" -ServiceProfile RDP

# Pull last 2 hours of events for a VM
.\Troubleshooting\Get-VMEventLog.ps1 -VMName "vm01" -HoursBack 2 -vCenter "vcenter.company.com"

# Tools health across a folder
.\Troubleshooting\Test-VMToolsHealth.ps1 -FolderName "IR-Dev" -OutputFile "tools-health.csv"

# Reconstruct what happened to a VM in the last 24 h
.\Troubleshooting\Get-VMEventTimeline.ps1 -VMName "WIN-DC-01" -HoursBack 24
```

---

### Cluster Health

Point-in-time cluster health checks using cached QuickStats — no historical stat collection required. Designed as a daily morning check or pre/post change validation.

| Script | Description |
|--------|-------------|
| `Get-ClusterHealthBundle.ps1` | All-in-one health bundle: HA/DRS/EVC configuration, host availability, CPU/memory resource pressure, datastore capacity/accessibility, VM snapshot/Tools/consolidation health, recent critical events, and active alarms. Single script for a complete cluster snapshot. |
| `Get-HostAvailabilityReport.ps1` | Per-host connection state, power state, maintenance mode, lockdown mode, and key management service health (vpxa, hostd, ntpd, SSH). Supports `-ExpectLockdownDisabled` policy enforcement. |
| `Get-ResourcePressureReport.ps1` | CPU and memory pressure report: per-host utilization with configurable thresholds, cluster-wide vCPU/vRAM overcommit ratios, VMs actively ballooning or swapping, and top-N VMs by CPU and memory consumption. |
| `Get-DatastoreHealthReport.ps1` | Datastore health across four dimensions: capacity/free space thresholds, datastore accessibility, cross-host mount consistency (datastores missing from some hosts), and VMFS multipath LUN path health. |
| `Test-HAReadiness.ps1` | Validates HA readiness across all clusters: HA enabled state, heartbeat datastore count (flags < 2), admission control policy and failover level, host isolation response, current host health, HA-disabled VM overrides, and a simulated largest-host-failure capacity check. |
| `Get-DRSMigrationAnalysis.ps1` | Analyses DRS migration history: total migrations per VM with thrashing detection (configurable threshold), migration heat map (busiest source/destination hosts), and current compliance status of all DRS affinity/anti-affinity rules vs. actual VM placement. |

```powershell
# Full morning health check
.\Cluster-Health\Get-ClusterHealthBundle.ps1 -ClusterName "Cluster01" -OutputFile "health-$(Get-Date -Format 'yyyyMMdd').csv"

# Quick resource pressure snapshot
.\Cluster-Health\Get-ResourcePressureReport.ps1 -ClusterName "Cluster01" -TopVMCount 15

# Datastore capacity report with tighter thresholds
.\Cluster-Health\Get-DatastoreHealthReport.ps1 -ClusterName "Cluster01" -WarnPct 75 -CritPct 85

# HA readiness check across all clusters
.\Cluster-Health\Test-HAReadiness.ps1 -OutputFile "ha-readiness.csv"

# DRS analysis: detect thrashing and rule violations
.\Cluster-Health\Get-DRSMigrationAnalysis.ps1 -ClusterName "Cluster01" -HoursBack 12 -ThrashThreshold 5
```

---

## Troubleshooting

### PowerCLI not found
```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
```

### Certificate warnings
```powershell
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### Connection issues
- Verify network access to vCenter on TCP 443
- Confirm the account has at minimum read-only access to the target cluster
- For NSX scripts: confirm NSX Manager API access on TCP 443

### Visio not found (`vDiagram.ps1` only)
Use `Diagramming/vDiagram-DrawIO.ps1` instead — it requires no local application, only PowerCLI.

### Missing Visio shapes (`vDiagram.ps1` only)
Copy `Diagramming/Assets/My-VI-Shapes.vss` to `%USERPROFILE%\Documents\My Shapes\`.

---

## Best Practices

1. Run read-only audit scripts during off-peak hours in large environments
2. Use `Export-FullClusterAudit.ps1` for scheduled comprehensive audits — it handles dependency ordering automatically
3. Establish a baseline with `Export-ClusterConfiguration.ps1` before any change window, then run `Test-ConfigurationDrift.ps1` after
4. Schedule Power BI exports as daily Windows Task Scheduler jobs for up-to-date dashboards
5. Use `-WhatIf` / `-DryRun` on any script that modifies state (`Set-BulkTagAssignment.ps1`, `Set-HostMaintenanceWorkflow.ps1`, `Test-ESXiSecurityBaseline.ps1 -RemediateFindings`)

---

## Credits

Original Visio diagramming script by Alan Renouf ([@alanrenouf](https://github.com/alanrenouf))

## License

This project is provided as-is for educational and professional use.
