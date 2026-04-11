# vSphere Power BI Dashboards

This solution exports comprehensive vSphere metrics via PowerCLI to CSV files that can be consumed by Power BI for creating interactive dashboards.

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   vCenter(s)    │───>│  PowerCLI Script │───>│   CSV Files     │
│                 │    │  (Scheduled Task)│    │  (or SQL/Share) │
└─────────────────┘    └──────────────────┘    └────────┬────────┘
                                                        │
                       ┌──────────────────┐    ┌────────▼────────┐
                       │    Power BI      │<───│  Data Gateway   │
                       │    Dashboards    │    │   (if needed)   │
                       └──────────────────┘    └─────────────────┘
```

## Quick Start

### 1. Run the Export Script

```powershell
# Single vCenter
.\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter.domain.local"

# Multiple vCenters
.\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter1.domain.local","vcenter2.domain.local"

# Custom output path and history
.\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter.domain.local" -OutputPath "D:\PowerBI\vSphereData" -DaysOfStats 14
```

### 2. Output Files Generated

| File | Dashboard | Description |
|------|-----------|-------------|
| `VM_RightSizing.csv` | Capacity & Waste | VM sizing analysis with CPU/Memory recommendations |
| `Zombie_VMs.csv` | Capacity & Waste | Powered-off VMs that may be candidates for deletion |
| `Snapshots.csv` | Capacity & Waste | All snapshots with age and size risk classification |
| `Datastore_Capacity.csv` | Capacity & Waste | Datastore free space and health status |
| `Cluster_Capacity.csv` | Capacity & Waste | vCPU:pCPU ratios and overcommitment |
| `Cluster_Performance.csv` | Performance | CPU ready, memory pressure, and swap metrics |
| `Datastore_Latency.csv` | Performance | Read/write latency for datastores |
| `Infrastructure_Hygiene.csv` | Hygiene | VMware Tools, hardware versions, ISO mounts |
| `Host_Inventory.csv` | Hygiene | ESXi host configuration and utilization |
| `VM_Changes.csv` | Change & Drift | VM creation, deletion, reconfiguration events |
| `DRS_Effectiveness.csv` | Change & Drift | DRS settings and vMotion activity |
| `Export_Summary.csv` | Metadata | Summary of each export run |

---

## Dashboard 1: Capacity & Waste

**Purpose:** Identify cost savings opportunities and resource waste.

### Key Visualizations

| Visual Type | Data Source | Configuration |
|-------------|-------------|---------------|
| **Gauge** | `Cluster_Capacity.csv` | Show `VCpuToPCpuRatio` with targets (Green: <3, Yellow: 3-4, Red: >4) |
| **Treemap** | `Datastore_Capacity.csv` | Size = `CapacityGB`, Color = `FreePercent` (conditional) |
| **Table** | `Zombie_VMs.csv` | Filter: `IsZombie = TRUE`, columns: VMName, DaysOff, UsedStorageGB |
| **Scatter Plot** | `Snapshots.csv` | X = `AgeInDays`, Y = `SizeGB`, Color = `RiskLevel` |
| **Bar Chart** | `VM_RightSizing.csv` | Filter: `CPURecommendation = Oversized` |

### DAX Measures

```dax
// Total Reclaimable Storage from Zombies
Zombie Storage GB = 
CALCULATE(
    SUM('Zombie_VMs'[UsedStorageGB]),
    'Zombie_VMs'[IsZombie] = TRUE
)

// Snapshot Risk Score
High Risk Snapshots = 
COUNTROWS(
    FILTER('Snapshots', 'Snapshots'[RiskLevel] IN {"High", "Critical"})
)

// Average vCPU Ratio
Avg vCPU Ratio = AVERAGE('Cluster_Capacity'[VCpuToPCpuRatio])
```

---

## Dashboard 2: Cluster Performance Heatmap

**Purpose:** Identify performance bottlenecks and "noisy neighbors."

### Key Visualizations

| Visual Type | Data Source | Configuration |
|-------------|-------------|---------------|
| **Matrix** | `Cluster_Performance.csv` | Rows = `EntityName`, Columns = `Hour`, Values = `Value` for cpu.ready.summation |
| **Line Chart** | `Cluster_Performance.csv` | X = `Timestamp`, Y = `Value`, filtered by `MetricId` |
| **Card** | `Cluster_Performance.csv` | Max CPU Ready in last 24h |
| **Clustered Bar** | `Datastore_Latency.csv` | Compare read vs write latency by datastore |

### Power BI Tips

1. **Conditional Formatting for Heatmap:**
   - CPU Ready > 5% = Red
   - Memory Balloon > 0 = Yellow
   - Latency > 20ms = Orange

2. **Filtering:**
   ```dax
   // Filter to show only problematic hosts
   CPU Ready Issues = 
   CALCULATE(
       COUNTROWS('Cluster_Performance'),
       'Cluster_Performance'[MetricId] = "cpu.ready.summation",
       'Cluster_Performance'[Value] > 5
   )
   ```

---

## Dashboard 3: Infrastructure Hygiene

**Purpose:** Track configuration drift and compliance.

### Key Visualizations

| Visual Type | Data Source | Configuration |
|-------------|-------------|---------------|
| **Donut Chart** | `Infrastructure_Hygiene.csv` | Count by `ToolsStatus` |
| **Bar Chart** | `Infrastructure_Hygiene.csv` | Count by `HardwareVersionNum` (sorted descending) |
| **Table** | `Infrastructure_Hygiene.csv` | Filter: `HasIsoMounted = TRUE` |
| **Stacked Bar** | `Infrastructure_Hygiene.csv` | Count by `GuestOSRunning` |
| **Card** | `Host_Inventory.csv` | Unique ESXi versions count |

### DAX Measures

```dax
// Tools Compliance Rate
Tools Compliance % = 
DIVIDE(
    COUNTROWS(FILTER('Infrastructure_Hygiene', 'Infrastructure_Hygiene'[ToolsStatus] = "toolsOk")),
    COUNTROWS('Infrastructure_Hygiene')
) * 100

// Outdated Hardware Count
Outdated Hardware = 
COUNTROWS(
    FILTER('Infrastructure_Hygiene', 'Infrastructure_Hygiene'[HardwareVersionNum] < 13)
)
```

---

## Dashboard 4: Change & Drift

**Purpose:** Track what changed and who changed it.

### Key Visualizations

| Visual Type | Data Source | Configuration |
|-------------|-------------|---------------|
| **Line Chart** | `VM_Changes.csv` | X = `Date`, Y = Count, split by `EventType` |
| **Bar Chart** | `VM_Changes.csv` | Count by `UserName` |
| **Table** | `VM_Changes.csv` | Recent changes with full details |
| **Card** | `DRS_Effectiveness.csv` | Total DRS vMotions in 24h |
| **Gauge** | `DRS_Effectiveness.csv` | Average DRS vMotions per day |

### DAX Measures

```dax
// Changes by Type
VM Creates = COUNTROWS(FILTER('VM_Changes', 'VM_Changes'[EventType] = "VM Created"))
VM Deletes = COUNTROWS(FILTER('VM_Changes', 'VM_Changes'[EventType] = "VM Removed"))
VM Reconfigs = COUNTROWS(FILTER('VM_Changes', 'VM_Changes'[EventType] = "VM Reconfigured"))

// DRS Activity Score
DRS Activity = SUM('DRS_Effectiveness'[DrsVMotions24h])
```

---

## Scheduling the Export

### Option 1: Windows Task Scheduler (Recommended)

```powershell
# Create a scheduled task to run daily at 6 AM
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument @"
-NoProfile -ExecutionPolicy Bypass -File "D:\Scripts\Export-vSphereMetricsForPowerBI.ps1" -vCenterServer "vcenter.domain.local" -OutputPath "D:\PowerBI\vSphereData"
"@

$trigger = New-ScheduledTaskTrigger -Daily -At "6:00AM"

$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\ServiceAccount" -LogonType Password -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName "vSphere-PowerBI-Export" -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

### Option 2: Store Credentials Securely

```powershell
# Save credentials to encrypted file (run once, interactively)
$cred = Get-Credential
$cred | Export-Clixml -Path "D:\Scripts\vcenter_cred.xml"

# In your scheduled script, load credentials:
$cred = Import-Clixml -Path "D:\Scripts\vcenter_cred.xml"
.\Export-vSphereMetricsForPowerBI.ps1 -vCenterServer "vcenter.domain.local" -Credential $cred
```

---

## Power BI Desktop Setup (Free Version)

Power BI Desktop is **completely free** and available from the Microsoft Store or [powerbi.microsoft.com](https://powerbi.microsoft.com/desktop/).

### Step 1: Load the CSV Files

1. Open **Power BI Desktop**
2. Click **Get Data** → **Text/CSV**
3. Navigate to your output folder (e.g., `C:\Data\vSphereMetrics`)
4. Select `VM_RightSizing.csv` → Click **Load**
5. Repeat for each CSV file you want to use

**Pro Tip: Load All CSVs at Once**
1. Click **Get Data** → **More...** → **Folder**
2. Enter the path to your CSV folder
3. Click **Combine & Transform Data**
4. Power BI will merge all CSVs with the same schema

### Step 2: Build the Capacity & Waste Dashboard

#### A. Create the vCPU:pCPU Ratio Gauge

1. Click the **Gauge** visual in the Visualizations pane
2. Drag `VCpuToPCpuRatio` from `Cluster_Capacity` to **Value**
3. Set **Target value** to `4` (danger threshold)
4. Set **Maximum value** to `8`
5. Click **Format** (paint roller icon):
   - Gauge axis → Min: `0`, Max: `8`
   - Colors → Set conditional formatting:
     - 0-3: Green
     - 3-4: Yellow  
     - 4+: Red

#### B. Create the Datastore Treemap

1. Click the **Treemap** visual
2. Drag `DatastoreName` to **Category**
3. Drag `CapacityGB` to **Values**
4. Click **Format** → **Data colors** → **Conditional formatting**
5. Configure:
   - Based on: `FreePercent`
   - Minimum color: Red (for low free space)
   - Maximum color: Green (for high free space)
   - Minimum value: `10`
   - Maximum value: `50`

#### C. Create the Zombie VMs Table

1. Click the **Table** visual
2. Add columns: `VMName`, `DaysOff`, `UsedStorageGB`, `Folder`
3. Click on the table → **Filters** pane
4. Drag `IsZombie` to Filters → Select only `TRUE`
5. Sort by `UsedStorageGB` descending (click column header)

#### D. Create the Snapshot Scatter Plot

1. Click the **Scatter chart** visual
2. Configure:
   - **X Axis**: `AgeInDays`
   - **Y Axis**: `SizeGB`
   - **Legend**: `RiskLevel`
   - **Details**: `VMName`
3. Top-right quadrant = **DANGER** (old + large snapshots)

#### E. Create the Oversized VMs Bar Chart

1. Click **Clustered bar chart**
2. Drag `VMName` to **Y Axis**
3. Drag `ConfiguredCPU` to **X Axis**
4. Add filter: `CPURecommendation` = `Oversized`
5. Sort by `ConfiguredCPU` descending

### Step 3: Build the Performance Heatmap Dashboard

#### A. Create the CPU Ready Heatmap (Matrix)

1. Click the **Matrix** visual
2. Configure:
   - **Rows**: `EntityName` (host name)
   - **Columns**: `Hour`
   - **Values**: `Value` (aggregation: Average)
3. Add filter: `MetricId` = `cpu.ready.summation`
4. Apply conditional formatting:
   - Click the dropdown on Value → **Conditional formatting** → **Background color**
   - Format style: Rules
   - Rule 1: If value ≥ 5, then Red
   - Rule 2: If value ≥ 2, then Yellow
   - Rule 3: Otherwise Green

#### B. Create Performance Trend Line Chart

1. Click **Line chart**
2. Configure:
   - **X Axis**: `Timestamp`
   - **Y Axis**: `Value`
   - **Legend**: `MetricId`
3. Add slicer for `EntityName` to filter by host

#### C. Add a Metric Slicer

1. Click **Slicer** visual
2. Drag `MetricId` to the slicer
3. Users can now filter all visuals by metric type

### Step 4: Build the Infrastructure Hygiene Dashboard

#### A. VMware Tools Status Donut Chart

1. Click **Donut chart**
2. Drag `ToolsStatus` to **Legend**
3. Drag `VMName` to **Values** (Count)
4. Format colors:
   - `toolsOk` = Green
   - `toolsOld` = Yellow
   - `toolsNotInstalled` = Red
   - `toolsNotRunning` = Orange

#### B. Hardware Version Bar Chart

1. Click **Clustered bar chart**
2. Drag `HardwareVersion` to **Y Axis**
3. Drag `VMName` to **X Axis** (Count)
4. Sort by `HardwareVersion` descending
5. Add conditional formatting (older versions = red)

#### C. ISO Mounted Alert Table

1. Click **Table** visual
2. Add: `VMName`, `IsoPath`, `Cluster`
3. Filter: `HasIsoMounted` = `TRUE`
4. Title: "⚠️ VMs with ISOs Mounted (vMotion Risk)"

#### D. Guest OS Distribution

1. Click **Pie chart** or **Donut chart**
2. Drag `GuestOSRunning` to **Legend**
3. Drag `VMName` to **Values** (Count)
4. Great for identifying Windows Server 2012/2016 for upgrades

### Step 5: Build the Change & Drift Dashboard

#### A. Change Activity Timeline

1. Click **Line chart**
2. Configure:
   - **X Axis**: `Date`
   - **Y Axis**: Count of `VMName`
   - **Legend**: `EventType`
3. Shows spikes in VM creates/deletes/reconfigs

#### B. Changes by User Bar Chart

1. Click **Clustered bar chart**
2. Drag `UserName` to **Y Axis**
3. Drag `VMName` to **X Axis** (Count)
4. Great for identifying who's making the most changes

#### C. Recent Changes Table

1. Click **Table**
2. Add: `Timestamp`, `VMName`, `EventType`, `UserName`, `Message`
3. Sort by `Timestamp` descending
4. Limit to top 50 with a Top N filter

#### D. DRS Activity Cards

1. Add three **Card** visuals:
   - Card 1: Sum of `DrsVMotions24h` → Title: "DRS vMotions (24h)"
   - Card 2: Sum of `DrsVMotions7d` → Title: "DRS vMotions (7 days)"
   - Card 3: Average of `AvgDrsVMotionsPerDay` → Title: "Avg Daily vMotions"

### Step 6: Create Measures (DAX)

1. Click **Modeling** tab → **New Measure**
2. Add these calculated measures:

```dax
// Zombie Storage Reclaimable
Zombie Storage GB = 
CALCULATE(
    SUM('Zombie_VMs'[UsedStorageGB]),
    'Zombie_VMs'[IsZombie] = TRUE
)
```

```dax
// High Risk Snapshot Count
High Risk Snapshots = 
COUNTROWS(
    FILTER('Snapshots', 'Snapshots'[RiskLevel] IN {"High", "Critical"})
)
```

```dax
// Tools Compliance Percentage
Tools Compliance % = 
DIVIDE(
    COUNTROWS(FILTER('Infrastructure_Hygiene', 'Infrastructure_Hygiene'[ToolsStatus] = "toolsOk")),
    COUNTROWS('Infrastructure_Hygiene')
) * 100
```

```dax
// Total Snapshot Size
Total Snapshot GB = SUM('Snapshots'[SizeGB])
```

### Step 7: Create Dashboard Pages

1. Right-click on the page tab at the bottom
2. **Rename** to "Capacity & Waste"
3. **Add Page** for each dashboard:
   - Page 1: Capacity & Waste
   - Page 2: Cluster Performance
   - Page 3: Infrastructure Hygiene
   - Page 4: Change & Drift

### Step 8: Add Slicers for Filtering

Add these slicers to each page for interactivity:

| Slicer | Data Source | Purpose |
|--------|-------------|---------|
| vCenter | Any table with `vCenter` column | Filter by vCenter |
| Cluster | Any table with `Cluster` column | Filter by cluster |
| Date Range | `CollectionDate` | Filter by time period |

### Step 9: Save and Refresh

1. **Save** your `.pbix` file
2. To refresh data after re-running the export script:
   - Click **Home** → **Refresh**
3. For automatic refresh, publish to Power BI Service (requires Pro license)

### Step 10: Share Your Dashboard (Free Options)

| Method | How |
|--------|-----|
| **Export to PDF** | File → Export → PDF |
| **Publish to Web** | File → Publish → Publish to Web (creates public link) |
| **Share .pbix file** | Send the file directly; recipient needs Power BI Desktop |
| **Export to PowerPoint** | File → Export → PowerPoint |

---

## Power BI Service (Cloud) Options

| Method | Complexity | Best For |
|--------|------------|----------|
| **OneDrive/SharePoint** | Low | Small teams, simple setup |
| **Azure SQL Database** | Medium | Enterprise, need query performance |
| **On-Premises Gateway** | Medium | Keep data on-prem, scheduled refresh |
| **Azure Blob Storage** | Medium | Large datasets, cost-effective |

### Sample Data Model

```
┌─────────────────────┐
│ VM_RightSizing      │
│ - VMName (PK)       │──────────┐
│ - Cluster           │          │
│ - vCenter           │          │
└─────────────────────┘          │
                                 │
┌─────────────────────┐          │     ┌─────────────────────┐
│ Cluster_Capacity    │          ├────>│ Dim_Cluster         │
│ - ClusterName (PK)  │──────────┤     │ - ClusterName (PK)  │
│ - vCenter           │          │     │ - vCenter           │
└─────────────────────┘          │     └─────────────────────┘
                                 │
┌─────────────────────┐          │
│ Infrastructure_     │          │
│ Hygiene             │──────────┘
│ - VMName (PK)       │
│ - Cluster           │
└─────────────────────┘
```

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Script times out | Reduce `DaysOfStats` or run during off-hours |
| Missing stats | Ensure vCenter stats level is set to 2 or higher |
| Memory errors | Process VMs in batches (modify the script) |
| Credential errors | Use `Export-Clixml` for secure credential storage |

### Performance Tips

1. **Run during off-peak hours** - Stats collection is CPU-intensive on vCenter
2. **Use a dedicated service account** - With read-only vCenter access
3. **Consider stats retention** - vCenter defaults to keeping detailed stats for 1 day only
4. **Parallelize vCenter connections** - For multi-vCenter environments

---

## Extending the Solution

### Adding Custom Metrics

Add new export functions to the script following this pattern:

```powershell
function Export-CustomMetric {
    Write-Log "Collecting Custom Metrics..."
    
    $data = Get-VM | ForEach-Object {
        [PSCustomObject]@{
            VMName         = $_.Name
            CustomField    = $_.ExtensionData.CustomValue
            CollectionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    
    $outputFile = Join-Path $OutputPath "Custom_Metrics.csv"
    $data | Export-Csv $outputFile -NoTypeInformation -Force
    Write-Log "Exported $($data.Count) records to $outputFile" -Level SUCCESS
}
```

### Exporting to SQL Instead of CSV

Replace the CSV export with SQL insert:

```powershell
# Requires SqlServer module
$data | Write-SqlTableData -ServerInstance "sqlserver" -DatabaseName "vSphereMetrics" -SchemaName "dbo" -TableName "VM_RightSizing" -Force
```

---

## License

This script is provided as-is for the VMware community. Feel free to modify and distribute.
