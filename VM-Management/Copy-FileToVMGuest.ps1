<#
.SYNOPSIS
  Transfer a file from the local machine to a guest VM via PowerCLI.
.DESCRIPTION
  Prompts for connection and guest OS details; validates local source path and guest destination path; transfers file with logging.
#>

$ErrorActionPreference = 'Stop'
$LogFile = ".\vm_guest_upload.log"

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

function Prompt-WithDefault {
    param([string]$PromptText,[string]$Default)
    Write-Host "$PromptText [`Default` = " -NoNewline -ForegroundColor Yellow
    Write-Host "$Default" -NoNewline -ForegroundColor Cyan
    Write-Host "]" -NoNewline -ForegroundColor Yellow
    $in = Read-Host
    if ($in) { $in } else { $Default }
}



function Test-GuestPath {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$GuestCred,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$IsWindows
    )

    if ($IsWindows) {
        # Windows: wrap in double quotes for Test-Path
        $script = "if (Test-Path -LiteralPath `"$Path`") { 'FOUND' } else { 'MISSING' }"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Powershell
    }
    else {
        # Linux: wrap in double quotes, escape existing double quotes
        $escaped = $Path -replace '"','\"'
        $script = "if [ -e `"$escaped`" ]; then echo FOUND; else echo MISSING; fi"
        $res = Invoke-VMScript -VM $VM -ScriptText $script -GuestCredential $GuestCred -ScriptType Bash
    }

    ($res.ScriptOutput -replace '\s','') -eq 'FOUND'
}

# -------------------- Defaults --------------------
$PathToSource = "C:\Users\Public\Downloads\file.txt"
$PathToDest   = "C:\Temp\file.txt"
$TargetVM     = "MyVM01"
$Server       = "c1r1r12-vcsa-01.texnet1.net"
# ---------------------------------------------------------------

# -------------------- Prompts --------------------
$PathToSource = Prompt-WithDefault "Enter the full path to the source file on the local machine" $PathToSource
$PathToDest   = Prompt-WithDefault "Enter the full destination path on the guest VM"             $PathToDest
$TargetVM     = Prompt-WithDefault "Enter the name of the target VM"                             $TargetVM
$Server       = Prompt-WithDefault "Enter the vCenter or ESXi server address"                    $Server

Write-Host "Enter vCenter/ESXi credentials:" -ForegroundColor Yellow
$ServerCred = Get-Credential -Message "vCenter/ESXi credentials for $Server"

Write-Host "Enter guest OS credentials:" -ForegroundColor Yellow
$GuestCred  = Get-Credential -Message "Guest OS credentials for VM '$TargetVM'"

# -------------------- Start --------------------
Write-Log "=========================================================================" "INFO"
Write-Log "Starting VM Guest File Upload Script - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "=========================================================================" "INFO"

# Validate local source path
if (-not (Test-Path -LiteralPath $PathToSource -PathType Leaf)) {
    Write-Log "Local source file does not exist or is a directory: $PathToSource" "ERROR"
    exit 1
}
Write-Log "Local source file found: $PathToSource" "SUCCESS"

# Connect to vCenter/ESXi
Write-Log "Connecting to $Server ..."
try {
    Connect-VIServer -Server $Server -Credential $ServerCred | Out-Null
    Write-Log "Connected to $Server." "SUCCESS"
} catch {
    Write-Log "Failed to connect to ${Server}: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Resolve VM
$vm = Get-VM -Name $TargetVM -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Log "Target VM '$TargetVM' not found." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Check VM guest info & VMware Tools
$vmGuest = Get-VMGuest -VM $vm -ErrorAction SilentlyContinue
if (-not $vmGuest) {
    Write-Log "Unable to query VM guest info (permissions or tools issue)." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

$isWindows = $vmGuest.OSFullName -match 'Windows'
$toolsOk   = $vmGuest.State -eq 'Running' -and $vmGuest.ToolsStatus -notin @('toolsNotInstalled','toolsNotRunning')
if (-not $toolsOk) {
    Write-Log "VMware Tools not installed/running on '$TargetVM' (state: $($vmGuest.State), tools: $($vmGuest.ToolsStatus))." "ERROR"
    Disconnect-VIServer * -Confirm:$false | Out-Null
    exit 1
}

# Ensure guest destination directory exists
try {
    # Split-Path on Windows mangles Linux forward-slash paths; handle separately
    if ($isWindows) {
        $destDir = Split-Path -Path $PathToDest -Parent
    } else {
        $lastSlash = $PathToDest.LastIndexOf('/')
        $destDir = if ($lastSlash -gt 0) { $PathToDest.Substring(0, $lastSlash) } else { '' }
    }
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

# Transfer
# Increase timeout for large files (default 300s is often too short for large transfers)
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

# Disconnect
try {
    Disconnect-VIServer * -Confirm:$false | Out-Null
    Write-Log "Disconnected from vCenter/ESXi." "SUCCESS"
} catch {
    Write-Log "Warning: disconnect failed or was already disconnected: $($_.Exception.Message)" "WARN"
}

Write-Log "Script completed successfully!" "SUCCESS"
