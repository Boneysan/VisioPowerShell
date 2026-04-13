<#
.SYNOPSIS
  Transfer a file from a guest VM to the local machine via PowerCLI.
.DESCRIPTION
  Prompts for connection and guest OS details; validates inside-guest path; transfers file with logging.
#>

# Global script configuration
$ErrorActionPreference = 'Stop'
$LogFile = ".\vm_guest_copy.log"

# Function: Writes formatted log entries to both a file and the console with color-coding
function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Gray }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARN"    { Write-Host $Message -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
    }
}

# Function: Prompts the user for input with a default value provided
function Prompt-WithDefault {
    param([string]$PromptText,[string]$Default)
    Write-Host "$PromptText [`Default` = " -NoNewline -ForegroundColor Yellow
    Write-Host "$Default" -NoNewline -ForegroundColor Cyan
    Write-Host "]" -NoNewline -ForegroundColor Yellow
    $in = Read-Host
    if ($in) { $in } else { $Default }
}

# Function: Checks if a file or directory exists inside the guest OS
function Test-GuestPath {
    <#
      .SYNOPSIS  Return $true if path exists inside the guest.
      .PARAMETER VM          The VM object.
      .PARAMETER GuestCred   PSCredential for guest login.
      .PARAMETER Path        Guest absolute path (Windows or Linux).
      .PARAMETER IsWindows   Set $true for Windows guests.
    #>
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$GuestCred,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$IsWindows
    )
    if ($IsWindows) {
        # Escape single quotes for PowerShell-in-guest execution
        $escaped = $Path -replace "'","''"
        $script = "if (Test-Path -LiteralPath '$escaped') { 'FOUND' } else { 'MISSING' }"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Powershell
    } else {
        # Linux/Unix: Escape single quotes for Bash execution
        $escaped = $Path -replace "'","'\''"
        $script = "if [ -e '$escaped' ]; then echo FOUND; else echo MISSING; fi"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Bash
    }
    # Clean output and compare result
    ($res.ScriptOutput -replace '\s','') -eq 'FOUND'
}

# -------------------- Initial Defaults --------------------
$PathToSource = "C:\Temp\file.txt"
$PathToDest   = "C:\Users\Public\Downloads\file.txt"
$TargetVM     = "MyVM01"
$Server       = "c1r1r12-vcsa-01.texnet1.net"

# -------------------- Interactive Prompts --------------------
$PathToSource = Prompt-WithDefault "Enter the full path to the source file on the guest VM"  $PathToSource
$PathToDest   = Prompt-WithDefault "Enter the name of the target VM"                         $TargetVM
$Server       = Prompt-WithDefault "Enter the vCenter or ESXi server address"                $Server

# Gather necessary credentials
Write-Host "Enter vCenter/ESXi credentials:" -ForegroundColor Yellow
$ServerCred = Get-Credential -Message "vCenter/ESXi credentials for $Server"

Write-Host "Enter guest OS credentials:" -ForegroundColor Yellow
$GuestCred  = Get-Credential -Message "Guest OS credentials for VM '$TargetVM'"

# -------------------- Main Execution --------------------
Write-Log "=========================================================================" "INFO"
Write-Log "Starting VM Guest File Copy Script - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "=========================================================================" "INFO"

# Step 1: Connect to vCenter or ESXi Server
Write-Log "Connecting to ${Server} ..."
try {
    Connect-VIServer -Server $Server -Credential $ServerCred | Out-Null
    Write-Log "Connected to ${Server}." "SUCCESS"
} catch {
    Write-Log "Failed to connect to ${Server}: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Step 2: Locate the target Virtual Machine
$vm = Get-VM -Name $TargetVM -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Log "Target VM '$TargetVM' not found." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 3: Validate VM Guest State and VMware Tools status
$vmGuest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
if (-not $vmGuest) {
    Write-Log "Unable to query VM guest info (permissions or tools issue)." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Logic: Transfer requires VMware Tools to be running
$isWindows = $vmGuest.OSFullName -match 'Windows'
$toolsOk   = $vmGuest.State -eq 'Running' -and $vmGuest.ToolsStatus -notin @('toolsNotInstalled','toolsNotRunning')
if (-not $toolsOk) {
    Write-Log "VMware Tools not installed/running on '$TargetVM' (state: $($vmGuest.State), tools: $($vmGuest.ToolsStatus))." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 4: Verify the source path exists inside the guest OS before attempting transfer
Write-Log "Checking source path inside guest: $PathToSource ..."
$existsInGuest = $false
try {
    $existsInGuest = Test-GuestPath -VM $vm -GuestCred $GuestCred -Path $PathToSource -IsWindows:$isWindows
} catch {
    Write-Log "Guest path check failed: $($_.Exception.Message)" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

if (-not $existsInGuest) {
    Write-Log "Source path does not exist inside the guest: $PathToSource" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}
Write-Log "Source exists inside guest." "SUCCESS"

# Step 5: Prepare the local destination directory
try {
    $destDir = Split-Path -Path $PathToDest -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        Write-Log "Creating local destination directory: $destDir" "INFO"
        # Ensure parent path exists
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
} catch {
    Write-Log "Failed to prepare local destination directory: $($_.Exception.Message)" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 6: Perform the File Transfer
# Increase session timeout for potentially large file transfers
Set-PowerCLIConfiguration -WebOperationTimeoutSeconds 3600 -Scope Session -Confirm:$false | Out-Null
Write-Log "Transferring file from guest '$TargetVM' to local path '$PathToDest' ..."
try {
    Copy-VMGuestFile -VM $vm `
        -GuestCredential $GuestCred `
        -Source $PathToSource `
        -Destination $PathToDest `
        -GuestToLocal `
        -Force | Out-Null
    Write-Log "File transferred successfully." "SUCCESS"
} catch {
    Write-Log "File transfer failed: $($_.Exception.Message)" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 7: Cleanup and Disconnection
try {
    Disconnect-VIServer * -Confirm:$false | Out-Null
    Write-Log "Disconnected from vCenter/ESXi." "SUCCESS"
} catch {
    Write-Log "Warning: disconnect failed or was already disconnected: $($_.Exception.Message)" "WARN"
}

Write-Log "Script completed successfully!" "SUCCESS"
