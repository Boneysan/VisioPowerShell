<#
.SYNOPSIS
    Scans datastores for VMDK files not attached to any registered VM.

.DESCRIPTION
    Enumerates all VMDK files present on datastores and compares them against the
    list of disks used by registered VMs. Any VMDK not belonging to a registered
    VM is flagged as orphaned and included in the report for manual review and
    reclamation.

.PARAMETER ClusterName
    Optional. Scope the scan to datastores accessible from a specific cluster.

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses existing connection.

.PARAMETER DatastoreName
    Optional. Limit scan to a single named datastore.

.PARAMETER OutputFile
    Required. Path to export the orphaned VMDK report as CSV.

.PARAMETER IncludeSizeGB
    Optional. Switch. Include file size lookup (slower; requires datastore browsing).

.EXAMPLE
    .\Get-OrphanedVMDKs.ps1 -ClusterName "Production" -OutputFile "orphans.csv"
    Scans all datastores in the Production cluster.

.EXAMPLE
    .\Get-OrphanedVMDKs.ps1 -DatastoreName "DS-NFS-01" -IncludeSizeGB -OutputFile "nfs-orphans.csv"
    Scans a specific datastore with file size information.

.OUTPUTS
    CSV with columns: DatastoreName, VMDKPath, SizeGB, LastModified, OrphanReason

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to datastore file browser and VM configuration

    Author: GitHub Copilot
    Version: 1.0
    Date: March 5, 2026
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$DatastoreName,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeSizeGB
)

if ($vCenter) {
    try {
        Write-Host "Connecting to vCenter: $vCenter..." -ForegroundColor Cyan
        Connect-VIServer -Server $vCenter -ErrorAction Stop | Out-Null
        Write-Host "Connected successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to vCenter: $_"
        exit 1
    }
}
else {
    Write-Host "Using existing vCenter connection..." -ForegroundColor Yellow
    if (-not (Get-VIServer -ErrorAction SilentlyContinue)) {
        Write-Error "No active vCenter connection. Please connect first or specify -vCenter parameter."
        exit 1
    }
}

# Build datastore list
if ($DatastoreName) {
    $datastores = Get-Datastore -Name $DatastoreName -ErrorAction SilentlyContinue
    if (-not $datastores) { Write-Error "Datastore '$DatastoreName' not found."; exit 1 }
}
elseif ($ClusterName) {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) { Write-Error "Cluster '$ClusterName' not found."; exit 1 }
    $datastores = Get-Datastore -RelatedObject $cluster
}
else {
    $datastores = Get-Datastore
}
$datastores = $datastores | Sort-Object -Property MoRef -Unique | Where-Object { $_.Type -ne 'vsan' }

# Build set of all VMDKs in use by registered VMs
Write-Host "Building index of VMDKs in use by registered VMs..." -ForegroundColor Cyan
$usedVmdks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($vm in (Get-VM -ErrorAction SilentlyContinue)) {
    foreach ($hd in ($vm | Get-HardDisk -ErrorAction SilentlyContinue)) {
        $null = $usedVmdks.Add($hd.Filename)
    }
}

# Add snapshot VMDKs (delta disks)
foreach ($snap in (Get-VM -ErrorAction SilentlyContinue | Get-Snapshot -ErrorAction SilentlyContinue)) {
    foreach ($disk in $snap.Vm.ExtensionData.Snapshot.RootSnapshotList) {
        # covered by Get-HardDisk on the VM view
    }
}

Write-Host "  $($usedVmdks.Count) VMDKs in use by registered VMs" -ForegroundColor White

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$dsCount = 0

foreach ($ds in $datastores) {
    $dsCount++
    Write-Host "  [$dsCount/$($datastores.Count)] Browsing: $($ds.Name)..." -ForegroundColor White

    try {
        $dsBrowser  = Get-View $ds.ExtensionData.Browser
        $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        $fileQuery   = New-Object VMware.Vim.VmDiskFileQuery
        $fileQuery.Details = New-Object VMware.Vim.VmDiskFileQueryFlags
        $fileQuery.Details.FileSize     = $true
        $fileQuery.Details.Modification = $true
        $fileQuery.Details.DiskType     = $true
        $searchSpec.Query   = @($fileQuery)
        $searchSpec.Details = New-Object VMware.Vim.FileQueryFlags
        $searchSpec.Details.FileSize     = $true
        $searchSpec.Details.Modification = $true
        $searchSpec.Recurse = $true

        $task    = $dsBrowser.SearchDatastoreSubFolders_Task("[$($ds.Name)]", $searchSpec)
        $taskView = Get-View $task
        while ($taskView.Info.State -eq 'running' -or $taskView.Info.State -eq 'queued') {
            Start-Sleep -Milliseconds 500
            $taskView.UpdateViewData('Info.State')
        }

        if ($taskView.Info.State -eq 'success') {
            $searchResults = $taskView.Info.Result
            foreach ($folder in $searchResults) {
                foreach ($file in $folder.File) {
                    if ($file -isnot [VMware.Vim.VmDiskFileInfo]) { continue }

                    $fullPath = "$($folder.FolderPath)$($file.Path)"

                    # Skip delta/snapshot disks (contain -delta or -0000 in name)
                    if ($file.Path -match '-\d{6}\.vmdk$|-delta\.vmdk$') { continue }
                    # Skip descriptor files (no extent file)
                    if ($file.DiskType -eq $null) { continue }

                    if (-not $usedVmdks.Contains($fullPath)) {
                        $sizeGB = if ($IncludeSizeGB -and $file.FileSize) {
                            [math]::Round($file.FileSize / 1GB, 2)
                        } else { 'N/A' }

                        $results.Add([PSCustomObject]@{
                            DatastoreName = $ds.Name
                            VMDKPath      = $fullPath
                            SizeGB        = $sizeGB
                            LastModified  = if ($file.Modification) { $file.Modification.ToString('yyyy-MM-dd') } else { 'N/A' }
                            OrphanReason  = 'Not attached to any registered VM'
                        })
                    }
                }
            }
        }
        else {
            Write-Warning "  Search failed for $($ds.Name): $($taskView.Info.Error.LocalizedMessage)"
        }
    }
    catch {
        Write-Warning "Error browsing datastore $($ds.Name): $_"
    }
}

Write-Host "Exporting $($results.Count) orphaned VMDK records to: $OutputFile" -ForegroundColor Cyan
$results | Export-Csv -Path $OutputFile -NoTypeInformation

$totalSizeGB = if ($IncludeSizeGB) {
    [math]::Round(($results | Where-Object { $_.SizeGB -ne 'N/A' } | Measure-Object -Property SizeGB -Sum).Sum, 2)
} else { 'N/A (run with -IncludeSizeGB)' }

Write-Host "`n=== Orphaned VMDK Summary ===" -ForegroundColor Cyan
Write-Host "  Datastores scanned : $dsCount" -ForegroundColor White
Write-Host "  Orphaned VMDKs     : $($results.Count)" -ForegroundColor $(if ($results.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Reclaimable space  : $totalSizeGB GB" -ForegroundColor White
Write-Host "  Output             : $OutputFile" -ForegroundColor White
