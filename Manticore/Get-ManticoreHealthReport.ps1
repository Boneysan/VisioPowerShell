<#
.SYNOPSIS
    Comprehensive health-check script for Manticore (ELK stack) deployments via PowerCLI.

.DESCRIPTION
    Connects to vCenter and uses Invoke-VMScript to run diagnostics across all Manticore
    nodes: mcac1, mcweb1, mcesq1-3, mcflog1, mcnet1-2.

    Checks performed:
      - VMware Tools reachability (all nodes)
      - Docker container Up/down state (all nodes)
      - Docker HEALTHCHECK status - flags containers that are Up but internally unhealthy (all nodes)
      - Failed systemd services (all nodes)
      - Container CPU/memory stats - flags >80% CPU or >90% MEM (all nodes)
      - PCAP collector service status and today's index freshness (net sensors)
      - Neo4j stack health (mcflog1)
      - RocketChat, Keycloak, MediaWiki, GBA/network-protocol-flows stacks (mcweb1)
      - Elasticsearch cluster health - green/yellow/red (mcesq1)
      - Elasticsearch index doc counts for: search-zeek, network_flow_summaries*, filebeat-7.16.2*, winlogbeat*, search-suricata (mcesq1)

    Optionally attempts to restart failed docker-compose stacks with -AutoFix.
    Optionally exports results to CSV with -OutputFile.

.PARAMETER vCenter
    vCenter server address. Default: c1r1r12-vcsa-01.texnet1.net

.PARAMETER RangeSuffix
    Suffix appended to base VM names. Example: 'IR-Dev' makes VMs mcflog1-IR-Dev, mcesq1-IR-Dev, etc.
    Leave blank if VMs use base names only.

.PARAMETER AutoFix
    If specified, attempts to restart failed docker-compose stacks automatically.

.PARAMETER OutputFile
    Optional path to export all results as a CSV file.

.EXAMPLE
    .\Get-ManticoreHealthReport.ps1 -RangeSuffix "IR-Dev"
    Run health check against the IR-Dev range deployment.

.EXAMPLE
    .\Get-ManticoreHealthReport.ps1 -RangeSuffix "IR-Dev" -AutoFix -OutputFile "C:\Reports\manticore-health.csv"
    Run health check, attempt auto-fixes on failed stacks, and export the report.

.NOTES
    Requires:
      - VMware PowerCLI module
      - VMware Tools installed and running on all Manticore VMs
      - Sufficient vCenter permissions to use Invoke-VMScript

    VM layout (Manticore 1.20):
      mcac1    10.20.0.10  - MCAC / RHIDM controller
      mcweb1   10.20.0.11  - Web server (Kibana, RocketChat, Keycloak, MediaWiki, GBA)
      mcesq1   10.20.0.12  - Elasticsearch node 1
      mcesq2   10.20.0.13  - Elasticsearch node 2
      mcesq3   10.20.0.14  - Elasticsearch node 3
      mcflog1  10.20.0.15  - Log aggregation / Logstash / Neo4j
      mcnet1   10.20.0.16  - Network sensor 1
      mcnet2   10.20.0.17  - Network sensor 2

    Author: GitHub Copilot
    Version: 1.1
    Date: April 10, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$RangeSuffix = '',

    [Parameter(Mandatory=$false)]
    [switch]$AutoFix,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$LogFile = ".\manticore_health.log"
$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ===================== HELPERS =====================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message"
    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Gray }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARN"    { Write-Host $Message -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
        "HEADER"  { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
    }
}

function Add-Result {
    param(
        [string]$VM,
        [string]$Check,
        [string]$Status,   # PASS | WARN | FAIL
        [string]$Detail
    )
    $Results.Add([PSCustomObject]@{
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        VM        = $VM
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
    })
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'DarkYellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] {1}: {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}

function Get-VMName {
    param([string]$Base)
    if ($RangeSuffix) { "$Base-$RangeSuffix" } else { $Base }
}

function Invoke-GuestBash {
    param(
        $VM,
        [System.Management.Automation.PSCredential]$Cred,
        [string]$Script
    )
    try {
        $res = Invoke-VMScript -VM $VM -GuestCredential $Cred -ScriptText $Script `
            -ScriptType Bash -ErrorAction Stop
        return $res.ScriptOutput
    } catch {
        return $null
    }
}

# ===================== CHECK FUNCTIONS =====================

function Test-DockerContainers {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label)
    $out = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null"

    if ($null -eq $out) {
        Add-Result $Label "Docker Containers" "WARN" "Unable to query docker"
        return
    }

    $lines = $out.Trim() -split '\r?\n' | Where-Object { $_ -match '\|' }
    if ($lines.Count -eq 0) {
        Add-Result $Label "Docker Containers" "WARN" "No containers found"
        return
    }

    # Not running at all
    $notUp       = @($lines | Where-Object { $_ -notmatch '\|Up ' })
    # Running but Docker HEALTHCHECK reports unhealthy
    $upUnhealthy = @($lines | Where-Object { $_ -match '\|Up ' -and $_ -match '\(unhealthy\)' })

    foreach ($c in $notUp) {
        $name, $status = $c -split '\|', 2
        Add-Result $Label "Docker: $($name.Trim())" "FAIL" "State: $($status.Trim())"
    }
    foreach ($c in $upUnhealthy) {
        $name, $status = $c -split '\|', 2
        Add-Result $Label "Docker: $($name.Trim())" "FAIL" "Up but HEALTHCHECK failing: $($status.Trim())"
    }
    if (-not $notUp -and -not $upUnhealthy) {
        Add-Result $Label "Docker Containers" "PASS" "All $($lines.Count) container(s) Up and healthy"
    }
}

function Test-FailedServices {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label)
    $out = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print \$1}'"

    if ($null -eq $out) {
        Add-Result $Label "Systemd Services" "WARN" "Unable to query systemctl"
        return
    }

    $failed = @($out.Trim() -split '\r?\n' | Where-Object { $_ -match '\S' })
    if ($failed.Count -gt 0) {
        Add-Result $Label "Systemd Services" "FAIL" "Failed unit(s): $($failed -join ', ')"
    } else {
        Add-Result $Label "Systemd Services" "PASS" "No failed services"
    }
}

function Test-PcapCollector {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label)

    # Service state
    $svcRaw   = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "systemctl is-active pcap-collector.service 2>/dev/null"
    $svcState = if ($svcRaw) { $svcRaw.Trim() } else { 'unknown' }

    switch ($svcState) {
        'active'   { Add-Result $Label "PCAP Collector Service" "PASS" "pcap-collector.service is active" }
        'inactive' { Add-Result $Label "PCAP Collector Service" "WARN" "Inactive (normal before capture is started)" }
        default    { Add-Result $Label "PCAP Collector Service" "FAIL" "State: '$svcState'" }
    }

    # RX packets increasing (spot check - two reads 2 seconds apart)
    $rx1 = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "cat /proc/net/dev 2>/dev/null | awk 'NR>2 {sum+=\$2} END{print sum}'"
    Start-Sleep -Seconds 2
    $rx2 = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "cat /proc/net/dev 2>/dev/null | awk 'NR>2 {sum+=\$2} END{print sum}'"
    if ($null -ne $rx1 -and $null -ne $rx2) {
        $rx1Long = 0L; $rx2Long = 0L
        [long]::TryParse($rx1.Trim(), [ref]$rx1Long) | Out-Null
        [long]::TryParse($rx2.Trim(), [ref]$rx2Long) | Out-Null
        $diff = $rx2Long - $rx1Long
        if ($diff -gt 0) {
            Add-Result $Label "Network RX Traffic" "PASS" "Interfaces receiving packets (+$diff bytes in 2s)"
        } else {
            Add-Result $Label "Network RX Traffic" "WARN" "No RX increase detected in 2s - verify mirrored port is active"
        }
    }

    # Today's PCAP indices
    $dateDir = Get-Date -Format "yyyy/MM/dd"
    $idxRaw   = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "ls /var/pcap/indices/$dateDir 2>/dev/null | wc -l"
    $count  = 0
    [int]::TryParse($(if ($idxRaw) { $idxRaw.Trim() } else { '0' }), [ref]$count) | Out-Null
    if ($count -gt 0) {
        Add-Result $Label "PCAP Indices (Today)" "PASS" "$count index file(s) under /var/pcap/indices/$dateDir"
    } else {
        Add-Result $Label "PCAP Indices (Today)" "WARN" "No indices for $dateDir - normal if capture not started"
    }
}

function Test-DockerStack {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label, [string]$StackName)

    $out = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | grep -i '$StackName'"

    if ($null -eq $out -or $out.Trim() -eq '') {
        Add-Result $Label "Stack: $StackName" "WARN" "No matching containers found"
        return $false
    }

    $unhealthy = @($out.Trim() -split '\r?\n' | Where-Object { $_ -notmatch '\|Up ' })
    if ($unhealthy) {
        $names = ($unhealthy | ForEach-Object { ($_ -split '\|')[0].Trim() }) -join ', '
        Add-Result $Label "Stack: $StackName" "FAIL" "Not running: $names"
        return $false
    }

    Add-Result $Label "Stack: $StackName" "PASS" "All containers Up"
    return $true
}

function Repair-DockerStack {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label, [string]$StackDir, [string]$StackName)

    Write-Log "  AutoFix: Restarting $StackName on $Label ($StackDir) ..." "WARN"
    $script = "cd $StackDir && docker-compose down -v 2>&1; docker-compose up -d 2>&1 | tail -5"
    $out = Invoke-GuestBash -VM $VM -Cred $Cred -Script $script

    if ($out) {
        $summary = ($out.Trim() -replace '\r?\n', ' ').Substring(0, [Math]::Min(120, $out.Trim().Length))
        Add-Result $Label "AutoFix: $StackName" "WARN" "Restart issued - $summary"
    } else {
        Add-Result $Label "AutoFix: $StackName" "FAIL" "AutoFix command failed or timed out"
    }
}

function Test-ElasticsearchHealth {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label)

    # Cluster health
    $clusterOut = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "curl -s http://localhost:9200/_cluster/health 2>/dev/null"

    if ($null -eq $clusterOut -or $clusterOut.Trim() -eq '') {
        Add-Result $Label "ES Cluster Health" "WARN" "No response from Elasticsearch API on port 9200"
    } else {
        try {
            $json       = $clusterOut.Trim() | ConvertFrom-Json
            $esStatus   = $json.status
            $nodes      = $json.number_of_nodes
            $shards     = $json.active_shards
            $unassigned = $json.unassigned_shards
            $detail     = "status=$esStatus, nodes=$nodes, active_shards=$shards, unassigned=$unassigned"
            switch ($esStatus) {
                'green'  { Add-Result $Label "ES Cluster Health" "PASS" $detail }
                'yellow' { Add-Result $Label "ES Cluster Health" "WARN" $detail }
                'red'    { Add-Result $Label "ES Cluster Health" "FAIL" $detail }
                default  { Add-Result $Label "ES Cluster Health" "WARN" "Unknown status: $detail" }
            }
        } catch {
            $snip = $clusterOut.Trim().Substring(0, [Math]::Min(80, $clusterOut.Trim().Length))
            Add-Result $Label "ES Cluster Health" "WARN" "Failed to parse API response: $snip"
        }
    }

    # Key Manticore index doc counts (per Operations Check guide)
    $indices = @('search-zeek','network_flow_summaries*','filebeat-7.16.2*','winlogbeat*','search-suricata')
    foreach ($idx in $indices) {
        $idxOut = Invoke-GuestBash -VM $VM -Cred $Cred `
            -Script "curl -s 'http://localhost:9200/_cat/indices/$idx?h=index,health,docs.count&s=index' 2>/dev/null"

        if ($null -eq $idxOut -or $idxOut.Trim() -eq '') {
            Add-Result $Label "ES Index: $idx" "WARN" "Index not found or no response"
            continue
        }

        $idxLines = @($idxOut.Trim() -split '\r?\n' | Where-Object { $_ -match '\S' })
        if ($idxLines.Count -eq 0) {
            Add-Result $Label "ES Index: $idx" "WARN" "Index does not exist - no data ingested yet"
            continue
        }

        foreach ($line in $idxLines) {
            $parts    = $line -split '\s+', 3
            $idxName  = if ($parts.Count -gt 0) { $parts[0].Trim() } else { $idx }
            $health   = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '?' }
            $docCount = if ($parts.Count -gt 2) { $parts[2].Trim() } else { '0' }
            $detail   = "docs=$docCount, health=$health"
            $docLong  = 0L
            [long]::TryParse($docCount, [ref]$docLong) | Out-Null
            $flag = switch ($health) {
                'green'  { if ($docLong -gt 0) { 'PASS' } else { 'WARN' } }
                'yellow' { 'WARN' }
                'red'    { 'FAIL' }
                default  { 'WARN' }
            }
            if ($health -eq 'green' -and $docLong -eq 0) { $detail += ' - index exists but empty (no data yet)' }
            Add-Result $Label "ES Index: $idxName" $flag $detail
        }
    }
}

function Test-ContainerStats {
    param($VM, [System.Management.Automation.PSCredential]$Cred, [string]$Label)

    $out = Invoke-GuestBash -VM $VM -Cred $Cred `
        -Script "docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null"

    if ($null -eq $out -or $out.Trim() -eq '') {
        Add-Result $Label "Container Stats" "WARN" "No stats returned (no running containers?)"
        return
    }

    $lines   = @($out.Trim() -split '\r?\n' | Where-Object { $_ -match '\|' })
    $flagged = 0

    foreach ($line in $lines) {
        $parts  = $line -split '\|', 3
        if ($parts.Count -lt 3) { continue }
        $name   = $parts[0].Trim()
        $cpuStr = $parts[1].Trim() -replace '%',''
        $memStr = $parts[2].Trim() -replace '%',''
        $cpu    = 0.0; $mem = 0.0
        [double]::TryParse($cpuStr, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$cpu) | Out-Null
        [double]::TryParse($memStr, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mem) | Out-Null
        if ($cpu -gt 80 -or $mem -gt 90) {
            Add-Result $Label "Stats: $name" "WARN" "High resource usage - CPU:$($parts[1].Trim()) MEM:$($parts[2].Trim())"
            $flagged++
        }
    }

    if ($flagged -eq 0) {
        Add-Result $Label "Container Stats" "PASS" "$($lines.Count) container(s) within normal CPU/MEM thresholds"
    }
}

# ===================== MAIN =====================

Write-Log "=====================================================================" "INFO"
Write-Log "Manticore Health Check - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "Range Suffix : $(if ($RangeSuffix) { $RangeSuffix } else { '(none - using base names)' })" "INFO"
Write-Log "AutoFix      : $AutoFix" "INFO"
Write-Log "=====================================================================" "INFO"

# --- Credentials ---
Write-Host "`nEnter vCenter credentials:" -ForegroundColor Yellow
$vCenterCred = Get-Credential -Message "vCenter credentials for $vCenter"

Write-Host "`nEnter root credentials for standard nodes (mcesq1-3, mcweb1, mcflog1, mcnet1-2):" -ForegroundColor Yellow
$RootCred = Get-Credential -Message "Root credentials (default user: root)"

Write-Host "`nEnter credentials for mcac1 (default user: root):" -ForegroundColor Yellow
$McacCred = Get-Credential -Message "Credentials for mcac1"

# --- Connect to vCenter ---
Write-Log "Connecting to $vCenter ..." "INFO"
try {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -WebOperationTimeoutSeconds 120 -Scope Session -Confirm:$false | Out-Null
    Connect-VIServer -Server $vCenter -Credential $vCenterCred | Out-Null
    Write-Log "Connected to $vCenter." "SUCCESS"
} catch {
    Write-Log "Failed to connect to vCenter: $($_.Exception.Message)" "ERROR"
    exit 1
}

# --- Node definitions ---
# Roles: docker, services, pcap, neo4j, webstacks
$Nodes = @(
    [PSCustomObject]@{ Base='mcac1';   Cred=$McacCred; Roles=@('docker','services','containerstats') }
    [PSCustomObject]@{ Base='mcesq1';  Cred=$RootCred; Roles=@('docker','services','containerstats','elasticsearch') }
    [PSCustomObject]@{ Base='mcesq2';  Cred=$RootCred; Roles=@('docker','services','containerstats') }
    [PSCustomObject]@{ Base='mcesq3';  Cred=$RootCred; Roles=@('docker','services','containerstats') }
    [PSCustomObject]@{ Base='mcweb1';  Cred=$RootCred; Roles=@('docker','services','containerstats','webstacks') }
    [PSCustomObject]@{ Base='mcflog1'; Cred=$RootCred; Roles=@('docker','services','containerstats','neo4j') }
    [PSCustomObject]@{ Base='mcnet1';  Cred=$RootCred; Roles=@('docker','services','containerstats','pcap') }
    [PSCustomObject]@{ Base='mcnet2';  Cred=$RootCred; Roles=@('docker','services','containerstats','pcap') }
)

# Docker-compose stacks on mcweb1 (dir → search keyword)
$WebStacks = @(
    [PSCustomObject]@{ Dir='/var/nyx/rocket_chat'; Name='rocketchat' }
    [PSCustomObject]@{ Dir='/var/nyx/keycloak';    Name='keycloak' }
    [PSCustomObject]@{ Dir='/var/nyx/mediawiki';   Name='mediawiki' }
    [PSCustomObject]@{ Dir='/var/nyx/gba';         Name='network_protocol_flows' }
)

# --- Run checks per node ---
foreach ($node in $Nodes) {
    $vmName = Get-VMName $node.Base
    Write-Log "$vmName" "HEADER"

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Add-Result $vmName "VM Found" "FAIL" "VM '$vmName' not found in vCenter"
        continue
    }

    $vmGuest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
    $toolsOk = $vmGuest -and
               $vmGuest.State -eq 'Running' -and
               $vmGuest.ToolsStatus -notin @('toolsNotInstalled', 'toolsNotRunning')

    if (-not $toolsOk) {
        Add-Result $vmName "VMware Tools" "FAIL" `
            "Tools not ready (state: $($vmGuest.State), status: $($vmGuest.ToolsStatus))"
        continue
    }
    Add-Result $vmName "VMware Tools" "PASS" "Running"

    $cred = $node.Cred

    if ('docker'        -in $node.Roles) { Test-DockerContainers    -VM $vm -Cred $cred -Label $vmName }
    if ('services'      -in $node.Roles) { Test-FailedServices      -VM $vm -Cred $cred -Label $vmName }
    if ('containerstats'-in $node.Roles) { Test-ContainerStats      -VM $vm -Cred $cred -Label $vmName }
    if ('pcap'          -in $node.Roles) { Test-PcapCollector       -VM $vm -Cred $cred -Label $vmName }
    if ('elasticsearch' -in $node.Roles) { Test-ElasticsearchHealth -VM $vm -Cred $cred -Label $vmName }

    if ('neo4j' -in $node.Roles) {
        $ok = Test-DockerStack -VM $vm -Cred $cred -Label $vmName -StackName 'neo4j'
        if (-not $ok -and $AutoFix) {
            Repair-DockerStack -VM $vm -Cred $cred -Label $vmName -StackDir '/var/nyx/neo4j' -StackName 'neo4j'
        }
    }

    if ('webstacks' -in $node.Roles) {
        foreach ($stack in $WebStacks) {
            $ok = Test-DockerStack -VM $vm -Cred $cred -Label $vmName -StackName $stack.Name
            if (-not $ok -and $AutoFix) {
                Repair-DockerStack -VM $vm -Cred $cred -Label $vmName -StackDir $stack.Dir -StackName $stack.Name
            }
        }
    }
}

# ===================== SUMMARY =====================

Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

$pass = ($Results | Where-Object Status -eq 'PASS').Count
$warn = ($Results | Where-Object Status -eq 'WARN').Count
$fail = ($Results | Where-Object Status -eq 'FAIL').Count

Write-Host ("  PASS: {0}   WARN: {1}   FAIL: {2}   Total: {3}" -f $pass, $warn, $fail, $Results.Count) -ForegroundColor White
Write-Log "SUMMARY - PASS: $pass  WARN: $warn  FAIL: $fail" "INFO"

if ($fail -gt 0) {
    Write-Host "`nFailed Checks:" -ForegroundColor Red
    $Results | Where-Object Status -eq 'FAIL' | ForEach-Object {
        Write-Host ("  [{0}] {1} - {2}" -f $_.VM, $_.Check, $_.Detail) -ForegroundColor Red
        $logLine = 'FAIL | {0} | {1} | {2}' -f $_.VM, $_.Check, $_.Detail
        Write-Log $logLine 'ERROR'
    }
}

if ($warn -gt 0) {
    Write-Host "`nWarnings:" -ForegroundColor DarkYellow
    $Results | Where-Object Status -eq 'WARN' | ForEach-Object {
        Write-Host ("  [{0}] {1} - {2}" -f $_.VM, $_.Check, $_.Detail) -ForegroundColor DarkYellow
        $logLine = 'WARN | {0} | {1} | {2}' -f $_.VM, $_.Check, $_.Detail
        Write-Log $logLine 'WARN'
    }
}

if ($OutputFile) {
    try {
        $Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
        Write-Log "Results exported to: $OutputFile" "SUCCESS"
        Write-Host "`nResults exported to: $OutputFile" -ForegroundColor Green
    } catch {
        Write-Log "Export failed: $($_.Exception.Message)" "ERROR"
    }
}

# --- Disconnect ---
try {
    Disconnect-VIServer * -Confirm:$false | Out-Null
    Write-Log "Disconnected from vCenter." "SUCCESS"
} catch {
    Write-Log "Disconnect warning: $($_.Exception.Message)" "WARN"
}

Write-Log "Health check complete." "SUCCESS"
Write-Host "`nHealth check complete. Log: $LogFile" -ForegroundColor Green
