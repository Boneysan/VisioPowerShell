# vSphere Operations Dashboard for Power BI

This solution provides 6 key dashboard tiles for VMware vSphere operations monitoring, similar to VMware Aria Operations dashboards. The PowerShell script exports comprehensive metrics to CSV files that Power BI consumes.

## Quick Start

### 1. Run the Export Script

```powershell
# Basic usage - vCenter only
.\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.domain.local"

# With NSX for network health monitoring
.\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.domain.local" -NSXManager "nsx.domain.local"

# With cloud metrics comparison
.\Export-vSphereOperationsDashboard.ps1 -vCenterServer "vcenter.domain.local" -IncludeCloudMetrics -CloudCostPerVCpuHour 0.06

# Multiple vCenters with custom output
.\Export-vSphereOperationsDashboard.ps1 `
    -vCenterServer "vcenter1.domain.local","vcenter2.domain.local" `
    -OutputPath "D:\PowerBI\Operations" `
    -DaysOfHistory 14
```

### 2. Schedule Regular Updates

Create a Windows Task Scheduler task to run every 4-6 hours:

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Scripts\Export-vSphereOperationsDashboard.ps1`" -vCenterServer `"vcenter.domain.local`""

$trigger = New-ScheduledTaskTrigger -Daily -At "6:00AM" -RepetitionInterval (New-TimeSpan -Hours 6)

$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\ServiceAccount" -LogonType Password

Register-ScheduledTask -TaskName "vSphere Operations Dashboard Export" -Action $action -Trigger $trigger -Principal $principal
```

---

## Data Files Generated

| File | Tile | Description |
|------|------|-------------|
| `Tile1_Cluster_Health.csv` | Environment Health | Cluster health status, HA/DRS state |
| `Tile1_Critical_Alerts.csv` | Environment Health | Critical events and alarms |
| `Tile1_Major_Incidents.csv` | Environment Health | Host failures and cluster issues |
| `Tile1_Health_Summary.csv` | Environment Health | Overall health metrics |
| `Tile2_Capacity_Headroom.csv` | Capacity Headroom | CPU/Memory/Storage headroom with days to exhaustion |
| `Tile3_Cost_Efficiency.csv` | Cost & Efficiency | Detailed VM efficiency analysis |
| `Tile3_Cost_Summary.csv` | Cost & Efficiency | Aggregate savings opportunities |
| `Tile4_SLA_Performance.csv` | SLA & Performance | VM performance metrics and breaches |
| `Tile4_SLA_Summary.csv` | SLA & Performance | Performance summary stats |
| `Tile5_PortGroup_Health.csv` | Network/NSX Health | Network port group inventory |
| `Tile5_NSX_Health.csv` | Network/NSX Health | NSX health status |
| `Tile5_Network_Summary.csv` | Network/NSX Health | Network health summary |
| `Tile6_Hybrid_Footprint.csv` | Hybrid Footprint | On-prem and cloud resource breakdown |
| `Tile6_Hybrid_Summary.csv` | Hybrid Footprint | Hybrid environment summary |
| `Export_Summary.csv` | Metadata | Export run summary and stats |

---

## Tile 1: Environment Health

**Objective:** Show overall infrastructure health status with healthy/total clusters, critical alerts, and major incidents.

### Power BI Setup

**Data Sources:**
- `Tile1_Health_Summary.csv` (primary)
- `Tile1_Cluster_Health.csv` (detailed)
- `Tile1_Critical_Alerts.csv` (details)

### Visualizations

#### 1.1 Cluster Health Card
**Visual Type:** Card with conditional formatting

**DAX Measure:**
```dax
Cluster Health Ratio = 
VAR HealthyClusters = MAX('Tile1_Health_Summary'[HealthyClusters])
VAR TotalClusters = MAX('Tile1_Health_Summary'[TotalClusters])
RETURN
    HealthyClusters & " / " & TotalClusters
```

**Conditional Formatting:**
```dax
Cluster Health Color = 
VAR HealthyClusters = MAX('Tile1_Health_Summary'[HealthyClusters])
VAR TotalClusters = MAX('Tile1_Health_Summary'[TotalClusters])
VAR HealthPercent = DIVIDE(HealthyClusters, TotalClusters, 0)
RETURN
    SWITCH(
        TRUE(),
        HealthPercent = 1, "#2ECC71",  // Green - All healthy
        HealthPercent >= 0.8, "#F39C12",  // Orange - Some issues
        "#E74C3C"  // Red - Critical
    )
```

#### 1.2 Critical Alerts Card
**Visual Type:** Card

**DAX Measure:**
```dax
Critical Alerts Count = 
MAX('Tile1_Health_Summary'[CriticalAlerts])
```

**Conditional Formatting:**
```dax
Alert Severity Color = 
VAR AlertCount = MAX('Tile1_Health_Summary'[CriticalAlerts])
RETURN
    SWITCH(
        TRUE(),
        AlertCount = 0, "#2ECC71",  // Green
        AlertCount <= 5, "#F39C12",  // Orange
        "#E74C3C"  // Red
    )
```

#### 1.3 Major Incidents (7d) Card
**Visual Type:** Card

**DAX Measure:**
```dax
Major Incidents 7d = 
MAX('Tile1_Health_Summary'[MajorIncidents7d])
```

#### 1.4 Cluster Health Details
**Visual Type:** Table or Matrix

**Columns to Display:**
- ClusterName
- HealthStatus (with conditional formatting)
- HealthyHosts / TotalHosts
- HAEnabled
- DRSEnabled
- VmCount

**DAX for Conditional Formatting:**
```dax
Health Status Color = 
SWITCH(
    'Tile1_Cluster_Health'[HealthStatus],
    "Healthy", "#2ECC71",
    "Degraded", "#F39C12",
    "Critical", "#E74C3C",
    "#95A5A6"  // Gray for unknown
)
```

#### 1.5 Recent Critical Alerts Timeline
**Visual Type:** Table (filtered to Critical severity)

**Filter:** `Tile1_Critical_Alerts[Severity] = "Critical"`

**Columns:**
- Timestamp
- Severity
- EntityName
- Message

---

## Tile 2: Capacity Headroom

**Objective:** Show CPU, Memory, and Storage capacity headroom by cluster with estimated days to exhaustion.

### Power BI Setup

**Data Source:** `Tile2_Capacity_Headroom.csv`

### Visualizations

#### 2.1 Capacity Headroom by Resource Type
**Visual Type:** Clustered Bar Chart

**Axis:** ClusterName  
**Values:** 
- CpuHeadroomPercent
- MemHeadroomPercent
- StorageHeadroomPercent

**DAX Measures:**
```dax
Avg CPU Headroom = 
AVERAGE('Tile2_Capacity_Headroom'[CpuHeadroomPercent])

Avg Memory Headroom = 
AVERAGE('Tile2_Capacity_Headroom'[MemHeadroomPercent])

Avg Storage Headroom = 
AVERAGE('Tile2_Capacity_Headroom'[StorageHeadroomPercent])
```

#### 2.2 Days to Exhaustion Cards
**Visual Type:** Card (3 separate cards or multi-row card)

**DAX Measures:**
```dax
Min CPU Days to Exhaustion = 
VAR MinDays = MIN('Tile2_Capacity_Headroom'[CpuDaysToExhaustion])
RETURN
    IF(MinDays >= 999, "999+", FORMAT(MinDays, "0") & " days")

Min Memory Days to Exhaustion = 
VAR MinDays = MIN('Tile2_Capacity_Headroom'[MemDaysToExhaustion])
RETURN
    IF(MinDays >= 999, "999+", FORMAT(MinDays, "0") & " days")

Min Storage Days to Exhaustion = 
VAR MinDays = MIN('Tile2_Capacity_Headroom'[StorageDaysToExhaustion])
RETURN
    IF(MinDays >= 999, "999+", FORMAT(MinDays, "0") & " days")
```

**Conditional Formatting:**
```dax
Days to Exhaustion Color = 
VAR MinDays = MIN('Tile2_Capacity_Headroom'[CpuDaysToExhaustion])
RETURN
    SWITCH(
        TRUE(),
        MinDays >= 999, "#2ECC71",  // Green - No concern
        MinDays >= 180, "#2ECC71",  // Green - 6+ months
        MinDays >= 90, "#F39C12",   // Orange - 3-6 months
        MinDays >= 30, "#E67E22",   // Dark orange - 1-3 months
        "#E74C3C"  // Red - <30 days
    )
```

#### 2.3 Capacity Headroom Donut Chart
**Visual Type:** Donut Chart (for each cluster)

**Legend:** Resource Type (CPU, Memory, Storage)  
**Values:** Headroom Percent

**Use a slicer for ClusterName to switch between clusters**

#### 2.4 Detailed Capacity Table
**Visual Type:** Table

**Columns:**
- ClusterName
- CpuHeadroomPercent
- CpuDaysToExhaustion
- MemHeadroomPercent
- MemDaysToExhaustion
- StorageHeadroomPercent
- StorageDaysToExhaustion

**Conditional Formatting:** Apply to Days columns using the color formula above.

#### 2.5 Growth Rate Trend
**Visual Type:** Line Chart

**Axis:** ClusterName  
**Values:**
- CpuGrowthRatePerDay
- MemGrowthRatePerDay
- StorageGrowthRatePerDay

---

## Tile 3: Cost & Efficiency

**Objective:** Identify idle and oversized VMs with estimated cost savings from rightsizing or decommissioning.

### Power BI Setup

**Data Sources:**
- `Tile3_Cost_Summary.csv` (primary)
- `Tile3_Cost_Efficiency.csv` (detailed)

### Visualizations

#### 3.1 Idle VMs Card
**Visual Type:** Card

**DAX Measure:**
```dax
Idle VMs Count = 
MAX('Tile3_Cost_Summary'[IdleVMs])
```

#### 3.2 Oversized VMs Card
**Visual Type:** Card

**DAX Measure:**
```dax
Oversized VMs Count = 
MAX('Tile3_Cost_Summary'[OversizedVMs])
```

#### 3.3 Potential Savings Card
**Visual Type:** Card with currency formatting

**DAX Measures:**
```dax
Monthly Savings = 
FORMAT(
    MAX('Tile3_Cost_Summary'[PotentialMonthlySavings]),
    "$#,##0.00"
)

Annual Savings = 
FORMAT(
    MAX('Tile3_Cost_Summary'[PotentialAnnualSavings]),
    "$#,##0.00"
)
```

#### 3.4 Efficiency Breakdown
**Visual Type:** Stacked Bar Chart

**DAX for Categories:**
```dax
Efficiency Categories = 
SUMMARIZE(
    'Tile3_Cost_Efficiency',
    'Tile3_Cost_Efficiency'[IsIdle],
    'Tile3_Cost_Efficiency'[IsOversized],
    "Count", COUNTROWS('Tile3_Cost_Efficiency')
)
```

#### 3.5 Top Savings Opportunities
**Visual Type:** Table (Top N filter: Top 20 by PotentialSavingsMonthly)

**Columns:**
- VMName
- Cluster
- IsIdle / IsOversized
- ConfiguredCPU → RecommendedCPU
- ConfiguredMemoryGB → RecommendedMemoryGB
- PotentialSavingsMonthly
- PotentialSavingsAnnual

**Filter:** `IsIdle = TRUE OR IsOversized = TRUE`

#### 3.6 Savings by Cluster
**Visual Type:** Clustered Column Chart

**Axis:** Cluster  
**Values:** 

**DAX Measure:**
```dax
Savings by Cluster = 
CALCULATE(
    SUM('Tile3_Cost_Efficiency'[PotentialSavingsMonthly]),
    ALLEXCEPT('Tile3_Cost_Efficiency', 'Tile3_Cost_Efficiency'[Cluster])
)
```

#### 3.7 Efficiency Scatter Plot
**Visual Type:** Scatter Chart

**X-Axis:** AvgCpuPercent  
**Y-Axis:** AvgMemPercent  
**Size:** PotentialSavingsMonthly  
**Color:** IsIdle or IsOversized (use conditional formatting)

---

## Tile 4: SLA & Performance

**Objective:** Show VMs breaching performance thresholds with trend comparison to previous period.

### Power BI Setup

**Data Sources:**
- `Tile4_SLA_Summary.csv` (primary)
- `Tile4_SLA_Performance.csv` (detailed)

### Visualizations

#### 4.1 VMs Breaching Thresholds Card
**Visual Type:** Card with percentage

**DAX Measures:**
```dax
Breaching VMs = 
MAX('Tile4_SLA_Summary'[VmsBreachingThresholds])

Percent Breaching = 
FORMAT(
    MAX('Tile4_SLA_Summary'[PercentBreaching]) / 100,
    "0.0%"
)
```

**Conditional Formatting:**
```dax
Breach Severity Color = 
VAR PercentBreaching = MAX('Tile4_SLA_Summary'[PercentBreaching])
RETURN
    SWITCH(
        TRUE(),
        PercentBreaching <= 5, "#2ECC71",   // Green - <5%
        PercentBreaching <= 15, "#F39C12",  // Orange - 5-15%
        "#E74C3C"  // Red - >15%
    )
```

#### 4.2 Severity Breakdown
**Visual Type:** Donut Chart

**Legend:** Severity (Critical, Warning, Normal)

**DAX Measures:**
```dax
Critical VMs = MAX('Tile4_SLA_Summary'[CriticalVMs])
Warning VMs = MAX('Tile4_SLA_Summary'[WarningVMs])
Normal VMs = MAX('Tile4_SLA_Summary'[NormalVMs])
```

#### 4.3 Performance Trends
**Visual Type:** Line and Clustered Column Chart

**Shared Axis:** VMName (filtered to top 20 breaching VMs)  
**Column Values:** AvgCpuReadyPercent, AvgMemoryPercent  
**Line Values:** CpuReadyTrendPercent, MemoryTrendPercent

**DAX for Trend Indicator:**
```dax
Trend Indicator = 
VAR CpuTrend = AVERAGE('Tile4_SLA_Performance'[CpuReadyTrendPercent])
VAR MemTrend = AVERAGE('Tile4_SLA_Performance'[MemoryTrendPercent])
VAR AvgTrend = (CpuTrend + MemTrend) / 2
RETURN
    IF(AvgTrend > 10, "⬆ Worsening",
       IF(AvgTrend < -10, "⬇ Improving", "➡ Stable"))
```

#### 4.4 Breaching VMs Detail Table
**Visual Type:** Table

**Filter:** `BreachingThresholds = TRUE`

**Columns:**
- VMName
- Cluster
- Severity (with conditional formatting)
- MaxCpuReadyPercent
- MaxMemoryPercent
- CpuReadyTrendPercent (with up/down arrows)
- MemoryTrendPercent

**Conditional Formatting for Trends:**
```dax
Trend Icon = 
SWITCH(
    TRUE(),
    'Tile4_SLA_Performance'[CpuReadyTrendPercent] > 20, "🔴 ⬆",
    'Tile4_SLA_Performance'[CpuReadyTrendPercent] > 0, "🟡 ⬆",
    'Tile4_SLA_Performance'[CpuReadyTrendPercent] < -20, "🟢 ⬇",
    "⚪ ➡"
)
```

#### 4.5 Performance Heatmap
**Visual Type:** Matrix

**Rows:** VMName  
**Columns:** Metric (CPU Ready, Memory Usage)  
**Values:** Performance value with conditional formatting

**Conditional Formatting:**
- Red: >10% CPU Ready or >95% Memory
- Orange: >5% CPU Ready or >85% Memory
- Green: Otherwise

---

## Tile 5: Network/NSX Health

**Objective:** Display NSX system health indicator and critical network virtualization alerts.

### Power BI Setup

**Data Sources:**
- `Tile5_Network_Summary.csv` (primary)
- `Tile5_NSX_Health.csv`
- `Tile5_PortGroup_Health.csv`

### Visualizations

#### 5.1 NSX Health Status Card
**Visual Type:** Card with icon

**DAX Measure:**
```dax
NSX Health Status = 
VAR Status = MAX('Tile5_NSX_Health'[HealthStatus])
RETURN
    SWITCH(
        Status,
        "Healthy", "✅ Healthy",
        "Degraded", "⚠️ Degraded",
        "Critical", "🔴 Critical",
        "Unknown", "❓ Unknown",
        "N/A", "⚫ Not Configured",
        "❓ " & Status
    )
```

**Conditional Formatting:**
```dax
NSX Health Color = 
VAR Status = MAX('Tile5_NSX_Health'[HealthStatus])
RETURN
    SWITCH(
        Status,
        "Healthy", "#2ECC71",
        "Degraded", "#F39C12",
        "Critical", "#E74C3C",
        "#95A5A6"  // Gray
    )
```

#### 5.2 NSX Critical Alerts Card
**Visual Type:** Card

**DAX Measure:**
```dax
NSX Critical Alerts = 
MAX('Tile5_Network_Summary'[NSXCriticalAlerts])
```

#### 5.3 Port Group Summary
**Visual Type:** Table

**Columns:**
- PortGroupName
- VirtualSwitch
- VLanId
- VMCount

**Sort by:** VMCount descending

#### 5.4 Network Infrastructure Count
**Visual Type:** Multi-row Card

**DAX Measures:**
```dax
Total Port Groups = 
MAX('Tile5_Network_Summary'[TotalPortGroups])

Total Virtual Switches = 
MAX('Tile5_Network_Summary'[TotalVirtualSwitches])
```

#### 5.5 NSX Status Details
**Visual Type:** Table (single row)

**Columns from Tile5_NSX_Health:**
- NSXManager
- Status
- HealthStatus
- Message

---

## Tile 6: Hybrid Footprint (Optional)

**Objective:** Compare on-premises vs cloud resource usage and cost.

### Power BI Setup

**Data Sources:**
- `Tile6_Hybrid_Summary.csv` (primary)
- `Tile6_Hybrid_Footprint.csv` (detailed)

### Visualizations

#### 6.1 Environment Distribution
**Visual Type:** Donut Chart

**Legend:** Environment (On-Premises, Cloud)  
**Values:** VMCount

**DAX Measures:**
```dax
On-Prem VMs = 
MAX('Tile6_Hybrid_Summary'[OnPremVMs])

Cloud VMs = 
MAX('Tile6_Hybrid_Summary'[CloudVMs])

On-Prem Percentage = 
FORMAT(
    MAX('Tile6_Hybrid_Summary'[OnPremPercentage]) / 100,
    "0.0%"
)
```

#### 6.2 Cost Comparison
**Visual Type:** Clustered Bar Chart

**Axis:** Environment  
**Values:** MonthlyCost

**DAX for Cost Breakdown:**
```dax
Total Monthly Cost = 
SUM('Tile6_Hybrid_Footprint'[MonthlyCost])

Cost per VM = 
DIVIDE(
    SUM('Tile6_Hybrid_Footprint'[MonthlyCost]),
    SUM('Tile6_Hybrid_Footprint'[VMCount]),
    0
)
```

#### 6.3 Resource Comparison Table
**Visual Type:** Table

**Rows from Tile6_Hybrid_Footprint:**
- Environment
- VMCount
- TotalVCPUs
- TotalMemoryGB
- TotalStorageGB
- MonthlyCost
- AnnualCost

#### 6.4 Cost Trend (if historical data available)
**Visual Type:** Line Chart

**X-Axis:** CollectionDate  
**Y-Axis:** TotalMonthlyCost  
**Legend:** Environment

---

## Complete Dashboard Layout Recommendation

### Page 1: Executive Summary
**Layout:** 2x3 grid

| Tile 1: Environment Health | Tile 2: Capacity Headroom |
|----------------------------|---------------------------|
| • Cluster health ratio     | • Headroom donut          |
| • Critical alerts          | • Days to exhaustion      |
| • Major incidents          |                           |

| Tile 3: Cost & Efficiency  | Tile 4: SLA & Performance |
|----------------------------|---------------------------|
| • Idle VMs count           | • Breaching VMs %         |
| • Oversized VMs count      | • Severity breakdown      |
| • Monthly savings          |                           |

| Tile 5: Network/NSX Health | Tile 6: Hybrid Footprint  |
|----------------------------|---------------------------|
| • NSX health status        | • Environment split       |
| • Critical alerts          | • Cost comparison         |

### Page 2: Detailed Analysis
- Drill-through pages for each tile
- Detailed tables with all metrics
- Historical trends if time-series data is maintained

---

## Refresh Schedule Recommendations

1. **Automated Export:** Run PowerShell script every 4-6 hours via Task Scheduler
2. **Power BI Refresh:** 
   - Power BI Desktop: Manual refresh or on-open
   - Power BI Service: Configure dataset refresh every 4-8 hours
3. **Data Gateway:** Required if Power BI Service is used with file-based data sources

---

## Advanced DAX Measures

### Overall Health Score
```dax
Overall Health Score = 
VAR ClusterHealth = DIVIDE(
    MAX('Tile1_Health_Summary'[HealthyClusters]),
    MAX('Tile1_Health_Summary'[TotalClusters]),
    0
)
VAR PerfHealth = 1 - (
    DIVIDE(
        MAX('Tile4_SLA_Summary'[VmsBreachingThresholds]),
        MAX('Tile4_SLA_Summary'[TotalVMs]),
        0
    )
)
VAR AlertPenalty = IF(MAX('Tile1_Health_Summary'[CriticalAlerts]) > 10, 0.9, 1)
VAR Score = (ClusterHealth * 0.4 + PerfHealth * 0.6) * AlertPenalty * 100
RETURN
    ROUND(Score, 0)
```

### Capacity Risk Indicator
```dax
Capacity Risk = 
VAR MinDays = MIN(
    MIN('Tile2_Capacity_Headroom'[CpuDaysToExhaustion]),
    MIN(
        MIN('Tile2_Capacity_Headroom'[MemDaysToExhaustion]),
        MIN('Tile2_Capacity_Headroom'[StorageDaysToExhaustion])
    )
)
RETURN
    SWITCH(
        TRUE(),
        MinDays < 30, "🔴 High Risk (<30 days)",
        MinDays < 90, "🟡 Medium Risk (<90 days)",
        MinDays < 180, "🟢 Low Risk (<180 days)",
        "✅ No Risk"
    )
```

### ROI from Rightsizing
```dax
Annual ROI Percentage = 
VAR AnnualSavings = MAX('Tile3_Cost_Summary'[PotentialAnnualSavings])
VAR CurrentAnnualCost = 
    CALCULATE(
        SUM('Tile3_Cost_Efficiency'[CurrentMonthlyCost]) * 12,
        'Tile3_Cost_Efficiency'[IsIdle] = TRUE || 
        'Tile3_Cost_Efficiency'[IsOversized] = TRUE
    )
VAR ROI = DIVIDE(AnnualSavings, CurrentAnnualCost, 0) * 100
RETURN
    FORMAT(ROI, "0.0") & "%"
```

### Time-based Filters

```dax
Last Collection = 
CALCULATE(
    MAX('Export_Summary'[ExportDateTime]),
    ALL('Export_Summary')
)

Is Latest Data = 
'Export_Summary'[ExportDateTime] = [Last Collection]
```

---

## Troubleshooting

### Common Issues

1. **No NSX Data:**
   - Ensure NSXManager parameter is provided
   - Install NSX PowerCLI module: `Install-Module VMware.VimAutomation.Nsxt`
   - Verify NSX credentials

2. **Incomplete Performance Stats:**
   - Increase `DaysOfHistory` parameter
   - Check vCenter statistics collection levels (Level 2 recommended)
   - Verify VM tools are installed and running

3. **Days to Exhaustion shows 999:**
   - Normal if usage is declining or stable
   - Need more historical data for accurate trending
   - Consider running script for 2-4 weeks to establish baseline

4. **Power BI Refresh Fails:**
   - Verify CSV file paths in Power BI
   - Check file permissions
   - Ensure scheduled task is running successfully

---

## Next Steps

1. **Import Data to Power BI:**
   - Open Power BI Desktop
   - Get Data → Text/CSV
   - Navigate to output path (default: C:\Data\vSphereOperations)
   - Import all Tile*.csv files

2. **Create Relationships:**
   - Most tiles are independent
   - Link via `vCenter` or `ClusterName` if needed for cross-filtering

3. **Build Visualizations:**
   - Follow tile-by-tile guidance above
   - Apply conditional formatting for health indicators
   - Add slicers for vCenter, Cluster, or date ranges

4. **Publish to Power BI Service:**
   - Publish report to workspace
   - Configure scheduled refresh
   - Set up data gateway if needed

5. **Set Up Alerts:**
   - Configure data alerts for critical thresholds
   - Email notifications for capacity warnings
   - Mobile app push notifications

---

## Support & Resources

- **VMware Aria Operations Dashboards:** [Broadcom TechDocs](https://techdocs.broadcom.com/us/en/vmware-cis/aria/aria-operations/8-18/vmware-aria-operations-configuration-guide-8-18/predefined-dashboards-in-vrealize-operations-manager/performance-dashboards.html)
- **PowerCLI Documentation:** [VMware Developer](https://developer.vmware.com/powercli)
- **Power BI DAX Reference:** [Microsoft Docs](https://docs.microsoft.com/en-us/dax/)

---

## Version History

- **v1.0** - Initial release with 6 dashboard tiles
  - Environment Health
  - Capacity Headroom
  - Cost & Efficiency
  - SLA & Performance
  - Network/NSX Health
  - Hybrid Footprint
