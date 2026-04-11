<#
.SYNOPSIS
    Retrieves vmware.log console log lines from a VM's working directory on its datastore.

.DESCRIPTION
    Locates the vmware.log file in a VM's datastore folder and downloads a tail of log
    lines for review. This log contains guest console output, vmkernel messages, power
    events, VMware Tools activity, snapshot operations, and error traces. Useful for
    diagnosing VM boot failures, guest crashes, and unexplained power state changes in
    a cyber range environment.

.PARAMETER VMName
    Required. Name of the VM whose log to retrieve.

.PARAMETER Lines
    Optional. Number of lines to retrieve from the end of the log. Default: 100.

.PARAMETER Keyword
    Optional. Case-insensitive keyword to filter log lines (e.g. "error", "panic", "snapshot").

.PARAMETER LogFile
    Optional. Specific log filename to retrieve relative to the VM's working directory.
    Default: vmware.log

.PARAMETER vCenter
    Optional. The vCenter Server to connect to. If not specified, uses the existing connection.

.PARAMETER OutputFile
    Optional. Path to save the retrieved log lines as a text file.

.EXAMPLE
    .\Get-VMConsoleLog.ps1 -VMName "DC01" -Lines 200
    Retrieve the last 200 lines of the vmware.log for DC01.

.EXAMPLE
    .\Get-VMConsoleLog.ps1 -VMName "DC01" -Keyword "error" -OutputFile "dc01-errors.txt"
    Retrieve all error-related lines from DC01's vmware.log and save to file.

.OUTPUTS
    Text lines to console and optionally to -OutputFile.

.NOTES
    Requires:
    - VMware PowerCLI module
    - Read access to the VM's datastore via vCenter (uses Get-Item / Copy-DatastoreItem)
    - The VM must have a vmware.log present (created when the VM is first powered on)

    Author: GitHub Copilot
    Version: 1.0
    Date: April 4, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$false)]
    [int]$Lines = 100,

    [Parameter(Mandatory=$false)]
    [string]$Keyword,

    [Parameter(Mandatory=$false)]
    [string]$LogFile = 'vmware.log',

    [Parameter(Mandatory=$false)]
    [string]$vCenter = 'c1r1r12-vcsa-01.texnet1.net',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile
)

# --- Connection ---
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

# --- Resolve VM ---
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Error "VM '$VMName' not found."; exit 1 }

# --- Locate the VM's working directory via its config file path ---
$vmxPath = $vm.ExtensionData.Config.Files.VmPathName
# Format: [DatastoreName] VMFolder/VMName.vmx
if ($vmxPath -notmatch '^\[(.+?)\]\s+(.+)\.vmx$') {
    Write-Error "Unable to parse VM datastore path: $vmxPath"
    exit 1
}
$datastoreName = $Matches[1]
$vmRelPath     = $Matches[2]   # e.g. VMFolder/VMName
$vmDir         = Split-Path $vmRelPath -Parent
$logPath       = if ($vmDir) { "[$datastoreName] $vmDir/$LogFile" } else { "[$datastoreName] $LogFile" }

Write-Host "`n=== VM Console Log ===" -ForegroundColor Cyan
Write-Host "  VM         : $VMName" -ForegroundColor White
Write-Host "  Log Path   : $logPath" -ForegroundColor White
Write-Host "  Lines      : $Lines" -ForegroundColor White
Write-Host "  Keyword    : $(if ($Keyword) { $Keyword } else { '(none)' })`n" -ForegroundColor White

# --- Download log via datastore browser ---
$tempFile = [System.IO.Path]::GetTempFileName()
try {
    Copy-DatastoreItem -Item $logPath -Destination $tempFile -ErrorAction Stop
}
catch {
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    Write-Error "Failed to retrieve log file '$logPath': $_"
    exit 1
}

try {
    $allLines = Get-Content -Path $tempFile -ErrorAction Stop

    # Filter by keyword first, then tail
    if ($Keyword) {
        $filtered = $allLines | Where-Object { $_ -imatch [regex]::Escape($Keyword) }
    }
    else {
        $filtered = $allLines
    }

    $output = $filtered | Select-Object -Last $Lines

    if ($output.Count -eq 0) {
        Write-Host "  No matching log lines found." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Showing $($output.Count) line(s):`n" -ForegroundColor Gray
        foreach ($line in $output) {
            # Colorize lines containing common severity markers
            $color = if     ($line -imatch 'error|fault|panic|critical|fail')   { 'Red'    }
                     elseif ($line -imatch 'warn')                               { 'Yellow' }
                     else                                                        { 'Gray'   }
            Write-Host $line -ForegroundColor $color
        }

        if ($OutputFile) {
            $output | Set-Content -Path $OutputFile -Encoding UTF8
            Write-Host "`nLog saved to: $OutputFile" -ForegroundColor Green
        }
    }

    # Quick stats
    $errorCount = ($allLines | Where-Object { $_ -imatch 'error|fault|panic|critical' }).Count
    $warnCount  = ($allLines | Where-Object { $_ -imatch 'warn' }).Count
    Write-Host "`n--- Log Stats (full file) ---" -ForegroundColor Cyan
    Write-Host "  Total lines : $($allLines.Count)" -ForegroundColor White
    Write-Host "  Error/Fault : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red'    } else { 'White' })
    Write-Host "  Warnings    : $warnCount"  -ForegroundColor $(if ($warnCount  -gt 0) { 'Yellow' } else { 'White' })
}
finally {
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}
