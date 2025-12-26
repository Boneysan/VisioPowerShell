<#
.SYNOPSIS
    Lists VM names organized by folder.

.DESCRIPTION
    This script retrieves all VMs grouped by their folder location in vCenter.
    Simple and fast - just displays VM names without collecting statistics.

.PARAMETER vCenter
    Optional. The VMware vCenter Server to connect to. If not specified, uses existing PowerCLI connection.

.PARAMETER FolderName
    Optional. Specific folder name to query. If not specified, shows all folders.

.PARAMETER IncludePoweredOff
    Optional. Include powered-off VMs in the results. Default: Only powered-on VMs.

.PARAMETER ExcludeTemplates
    Optional. Exclude template VMs from the list. Default: Include templates.

.PARAMETER OutputFile
    Optional. Path to export results as CSV. If not specified, displays results in console.

.EXAMPLE
    .\Get-VMNamesByFolder.ps1
    Shows all VM names grouped by folder.

.EXAMPLE
    .\Get-VMNamesByFolder.ps1 -FolderName "Production"
    Shows VM names only in the Production folder.

.EXAMPLE
    .\Get-VMNamesByFolder.ps1 -OutputFile "vm-names.csv"
    Exports VM names by folder to CSV.

.EXAMPLE
    .\Get-VMNamesByFolder.ps1 -IncludePoweredOff -ExcludeTemplates
    Shows all VMs (including powered off) but excludes templates.

.OUTPUTS
    Console output or CSV file with:
    - Folder: VM folder name
    - FolderPath: Full folder path
    - VMName: Virtual machine name
    - PowerState: Current power state
    - IsTemplate: Whether the VM is a template

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to vCenter
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$vCenter,
    
    [Parameter(Mandatory=$false)]
    [string]$FolderName,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludePoweredOff,
    
    [Parameter(Mandatory=$false)]
    [switch]$ExcludeTemplates,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# Connect to vCenter if specified or prompt if needed
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
    # Check for existing connection
    $existingConnection = Get-VIServer -ErrorAction SilentlyContinue
    if ($existingConnection) {
        Write-Host "Using existing vCenter connection: $($existingConnection.Name)" -ForegroundColor Yellow
    }
    else {
        # Prompt for vCenter server
        Write-Host "No active vCenter connection found." -ForegroundColor Yellow
        $vCenterInput = Read-Host "Enter vCenter server name or IP address"
        
        if ([string]::IsNullOrWhiteSpace($vCenterInput)) {
            Write-Error "No vCenter server specified. Exiting."
            exit 1
        }
        
        try {
            Write-Host "Connecting to vCenter: $vCenterInput..." -ForegroundColor Cyan
            Connect-VIServer -Server $vCenterInput -ErrorAction Stop | Out-Null
            Write-Host "Connected successfully" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to connect to vCenter: $_"
            exit 1
        }
    }
}

# Get folders
Write-Host "Retrieving VM folders..." -ForegroundColor Cyan
if ($FolderName) {
    $folders = Get-Folder -Type VM -Name $FolderName -ErrorAction SilentlyContinue
    if (-not $folders) {
        Write-Error "Folder '$FolderName' not found."
        exit 1
    }
}
else {
    $folders = Get-Folder -Type VM | Sort-Object Name
}

Write-Host "  Found $($folders.Count) folder(s)" -ForegroundColor White

$allResults = @()
$totalVMs = 0

foreach ($folder in $folders) {
    Write-Host "`nProcessing folder: $($folder.Name)" -ForegroundColor Cyan
    
    # Get VMs in this folder (non-recursive)
    $vms = Get-VM -Location $folder -ErrorAction SilentlyContinue
    
    # Apply filters
    if (-not $IncludePoweredOff) {
        $vms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }
    }
    
    if ($ExcludeTemplates) {
        $vms = $vms | Where-Object { -not $_.ExtensionData.Config.Template }
    }
    
    if ($vms.Count -eq 0) {
        Write-Host "  No VMs found (after applying filters)" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  Found $($vms.Count) VM(s)" -ForegroundColor White
    $totalVMs += $vms.Count
    
    # Build folder path
    $folderPath = $folder.Name
    $parent = $folder.Parent
    while ($parent -and $parent.Name -ne 'vm') {
        $folderPath = "$($parent.Name)/$folderPath"
        $parent = $parent.Parent
    }
    
    foreach ($vm in $vms) {
        $result = [PSCustomObject]@{
            Folder = $folder.Name
            FolderPath = $folderPath
            VMName = $vm.Name
            PowerState = $vm.PowerState
            IsTemplate = $vm.ExtensionData.Config.Template
        }
        
        $allResults += $result
        Write-Host "    - $($vm.Name) [$($vm.PowerState)]" -ForegroundColor White
    }
}

# Output results
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "VM Names Summary" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($OutputFile) {
    $absolutePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
    $allResults | Export-Csv -Path $absolutePath -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults exported to: $absolutePath" -ForegroundColor Green
}

# Display grouped by folder
Write-Host "`nVMs by Folder:" -ForegroundColor Cyan
$allResults | Group-Object Folder | ForEach-Object {
    Write-Host "`n  $($_.Name) ($($_.Count) VMs):" -ForegroundColor Yellow
    $_.Group | ForEach-Object {
        $status = if ($_.IsTemplate) { "Template" } else { $_.PowerState }
        Write-Host "    - $($_.VMName) [$status]" -ForegroundColor White
    }
}

# Summary statistics
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Total Folders: $($folders.Count)" -ForegroundColor White
Write-Host "  Total VMs: $totalVMs" -ForegroundColor White

$poweredOn = ($allResults | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
$poweredOff = ($allResults | Where-Object { $_.PowerState -ne 'PoweredOn' }).Count
$templates = ($allResults | Where-Object { $_.IsTemplate }).Count

Write-Host "  Powered On: $poweredOn" -ForegroundColor White
Write-Host "  Powered Off: $poweredOff" -ForegroundColor White
Write-Host "  Templates: $templates" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Green
