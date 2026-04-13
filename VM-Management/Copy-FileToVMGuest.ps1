<#
.SYNOPSIS
  Transfer a file from the local machine to a guest VM via PowerCLI.
.DESCRIPTION
  Prompts for connection and guest OS details; validates local source path and guest destination path; transfers file with logging.
#>

# Global script configuration and error handling
$ErrorActionPreference = 'Stop'
$LogFile = ".\vm_guest_upload.log"

# Function: Logs messages with a timestamp and severity level to file and console
function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    # Append to log file
    Add-Content -Path $LogFile -Value $entry
    # Output to console with appropriate color
    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Gray }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARN"    { Write-Host $Message -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
    }
}

# Function: Requests user input and provides a default if none is entered
function Prompt-WithDefault {
    param([string]$PromptText,[string]$Default)
    Write-Host "$PromptText [`Default` = " -NoNewline -ForegroundColor Yellow
    Write-Host "$Default" -NoNewline -ForegroundColor Cyan
    Write-Host "]" -NoNewline -ForegroundColor Yellow
    $in = Read-Host
    if ($in) { $in } else { $Default }
}

# Function: Checks if a specific path exists within the target VM guest OS
function Test-GuestPath {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$GuestCred,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$IsWindows
    )

    if ($IsWindows) {
        # Logic: Use PowerShell inside the guest to check path existence
        $script = "if (Test-Path -LiteralPath `"$Path`") { 'FOUND' } else { 'MISSING' }"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Powershell
    }
    else {
        # Logic: Use Bash inside the guest to check path existence (for Linux/Unix)
        $escaped = $Path -replace '"','\"'
        $script = "if [ -e `"$escaped`" ]; then echo FOUND; else echo MISSING; fi"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Bash
    }

    # Clean the script output and evaluate the result
    ($res.ScriptOutput -replace '\s','') -eq 'FOUND'
}

# -------------------- Initial Configuration Defaults --------------------
$PathToSource = "C:\Users\Public\Downloads\file.txt"
$PathToDest   = "C:\Temp\file.txt"
$TargetVM     = "MyVM01"
$Server       = "c1r1r12-vcsa-01.texnet1.net"

# -------------------- User Interaction Phase --------------------
$PathToSource = Prompt-WithDefault "Enter the full path to the source file on the local machine" $PathToSource
$PathToDest   = Prompt-WithDefault "Enter the full destination path on the guest VM"             $PathToDest
$TargetVM     = Prompt-WithDefault "Enter the name of the target VM"                             $TargetVM
$Server       = Prompt-WithDefault "Enter the vCenter or ESXi server address"                    $Server

# Gather credentials for both the infrastructure and the guest OS
Write-Host "Enter vCenter/ESXi credentials:" -ForegroundColor Yellow
$ServerCred = Get-Credential -Message "vCenter/ESXi credentials for $Server"

Write-Host "Enter guest OS credentials:" -ForegroundColor Yellow
$GuestCred  = Get-Credential -Message "Guest OS credentials for VM '$TargetVM'"

# -------------------- Main Execution Phase --------------------
Write-Log "=========================================================================" "INFO"
Write-Log "Starting VM Guest File Upload Script - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "=========================================================================" "INFO"

# Step 1: Validate the local source file exists and is accessible
if (-not (Test-Path -LiteralPath $PathToSource -PathType Leaf)) {
    Write-Log "Local source file does not exist or is a directory: $PathToSource" "ERROR"
    exit 1
}
Write-Log "Local source file found: $PathToSource" "SUCCESS"

# Step 2: Establish connection to the vCenter/ESXi Server
Write-Log "Connecting to $Server ..."
try {
    Connect-VIServer -Server $Server -Credential $ServerCred | Out-Null
    Write-Log "Connected to $Server." "SUCCESS"
} catch {
    Write-Log "Failed to connect to ${Server}: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Step 3: Locate the target Virtual Machine object
$vm = Get-VM -Name $TargetVM -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Log "Target VM '$TargetVM' not found." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 4: Verify VM and VMware Tools status
$vmGuest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
if (-not $vmGuest) {
    Write-Log "Unable to query VM guest info (permissions or tools issue)." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Logic: Transfer is only possible if VMware Tools are installed and running
$isWindows = $vmGuest.OSFullName -match 'Windows'
$toolsOk   = $vmGuest.State -eq 'Running' -and $vmGuest.ToolsStatus -notin @('toolsNotInstalled','toolsNotRunning')
if (-not $toolsOk) {
    Write-Log "VMware Tools not installed/running on '$TargetVM' (state: $($vmGuest.State), tools: $($vmGuest.ToolsStatus))." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 5: Ensure the destination directory exists within the guest OS
try {
    # Logic: Handle path differences between Windows and Linux/Unix guests
    if ($isWindows) {
        $destDir = Split-Path -Path $PathToDest -Parent
    } else {
        $lastSlash = $PathToDest.LastIndexOf('/')
        $destDir = if ($lastSlash -gt 0) { $PathToDest.Substring(0, $lastSlash) } else { '' }
    }
    
    # Check if directory exists; if not, create it
    if ($destDir -and -not (Test-GuestPath -VM $vm -GuestCred $GuestCred -Path $destDir -IsWindows $isWindows)) {
        Write-Log "Guest destination directory does not exist. Creating: $destDir" "INFO"
        if ($isWindows) {
            $script = "New-Item -Path `"$destDir`" -ItemType Directory -Force | Out-Null"
            Invoke-VMScript -VM $vm -ScriptText $script -GuestCredential $GuestCred -ScriptType Powershell | Out-Null
        } else {
            $escaped = $destDir -replace '"','\"'
            $script = "mkdir -p `"$escaped`""
            Invoke-VMScript -VM $vm -ScriptText $script -GuestCredential $GuestCred -ScriptType Bash | Out-Null
        }
        Write-Log "Guest destination directory created." "SUCCESS"
    }
} catch {
    Write-Log "Failed to prepare guest destination directory: $($_.Exception.Message)" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 6: Perform the File Transfer (Local to Guest)
# Increase session timeout to allow for large file uploads
Set-PowerCLIConfiguration -WebOperationTimeoutSeconds 3600 -Scope Session -Confirm:$false | Out-Null
Write-Log "Transferring file from local '$PathToSource' to guest '${TargetVM}:$PathToDest' ..."
try {
    Copy-VMGuestFile -VM $vm `
        -GuestCredential $GuestCred `
        -Source $PathToSource `
        -Destination $PathToDest `
        -LocalToGuest `
        -Force | Out-Null
    Write-Log "File transferred successfully." "SUCCESS"
} catch {
    Write-Log "File transfer failed: $($_.Exception.Message)" "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Step 7: Clean up and Disconnect
try {
    Disconnect-VIServer * -Confirm:$false | Out-Null
    Write-Log "Disconnected from vCenter/ESXi." "SUCCESS"
} catch {
    Write-Log "Warning: disconnect failed or was already disconnected: $($_.Exception.Message)" "WARN"
}

Write-Log "Script completed successfully!" "SUCCESS"
