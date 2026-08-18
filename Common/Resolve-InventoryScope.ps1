#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers to pick a vSphere VM folder (network) or port group.

.DESCRIPTION
    Used by folder- and network-scoped scripts so they do not assume a classroom
    such as CL1, CL5, or IRDev. After a vCenter session exists, these functions
    list available VM folders (and optionally port groups) and prompt for a choice.

    Dot-source this file from a sibling category folder:

        . (Join-Path $PSScriptRoot '..\Common\Resolve-InventoryScope.ps1')

.NOTES
    Author:  Mike Zomer
    Version: 1.0
    Date:    August 18, 2026
#>

function Select-VIListItem {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [scriptblock]$Label = { param($Item) $Item.ToString() }
    )

    if (-not $Items -or $Items.Count -eq 0) { return $null }

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = & $Label $Items[$i]
        Write-Host ("  [{0,2}] {1}" -f ($i + 1), $text) -ForegroundColor White
    }
    Write-Host ""

    $raw = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $raw = $raw.Trim()
    $num = 0
    if ([int]::TryParse($raw, [ref]$num) -and $num -ge 1 -and $num -le $Items.Count) {
        return $Items[$num - 1]
    }

    $byName = @($Items | Where-Object {
        ($_.Name -and $_.Name -eq $raw) -or
        ($_.Label -and $_.Label -eq $raw) -or
        ("$_" -eq $raw)
    })
    if ($byName.Count -eq 1) { return $byName[0] }

    $byLike = @($Items | Where-Object {
        ($_.Name -and $_.Name -like $raw) -or
        ($_.Label -and $_.Label -like "$raw*")
    })
    if ($byLike.Count -eq 1) { return $byLike[0] }

    return $null
}

function Get-VISelectableFolders {
    param(
        [string[]]$ExcludeNames = @('vm')
    )

    $folders = @(Get-Folder -Type VM -ErrorAction Stop |
        Where-Object { $_.Name -notin $ExcludeNames } |
        Sort-Object Name)

    foreach ($folder in $folders) {
        $parent = if ($folder.Parent) { $folder.Parent.Name } else { '' }
        $label = if ($parent -and $parent -ne 'vm' -and $parent -ne 'Datacenters') {
            "$($folder.Name)  (in $parent)"
        }
        else {
            $folder.Name
        }

        [PSCustomObject]@{
            Name   = $folder.Name
            Parent = $parent
            Label  = $label
            Folder = $folder
        }
    }
}

function Resolve-VIFolderFromName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )

    $leaf = ($FolderName -split '[\\/]' | Select-Object -Last 1).Trim()
    $matches = @(Get-Folder -Name $leaf -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'VM' })

    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -eq 1) { return $matches[0] }

    $pathNeedle = ($FolderName -replace '[\\/]', '.*')
    $pathMatch = @($matches | Where-Object { $_.ToString() -match $pathNeedle })
    if ($pathMatch.Count -ge 1) { return $pathMatch[0] }

    Write-Warning "Multiple folders named '$leaf'. Using first match: $($matches[0].Name) in $($matches[0].Parent.Name)"
    return $matches[0]
}

function Resolve-VIFolderScope {
    <#
    .SYNOPSIS
        Resolve a VM folder from -Folder or an interactive picker.
    .OUTPUTS
        PSCustomObject with Name, Folder, All
    #>
    param(
        [string]$FolderName,
        [switch]$AllowAll,
        [string[]]$ExcludeNames = @('vm'),
        [string]$Prompt = 'Select a network / folder (number or name, e.g. CL1, CL5, IRDev)'
    )

    if ($FolderName) {
        $trimmed = $FolderName.Trim()
        if ($AllowAll -and $trimmed -eq 'All') {
            return [PSCustomObject]@{ Name = 'All'; Folder = $null; All = $true }
        }

        $folder = Resolve-VIFolderFromName -FolderName $trimmed
        if (-not $folder) {
            throw "Folder '$FolderName' was not found."
        }
        return [PSCustomObject]@{ Name = $folder.Name; Folder = $folder; All = $false }
    }

    $choices = [System.Collections.Generic.List[object]]::new()
    if ($AllowAll) {
        $choices.Add([PSCustomObject]@{
            Name   = 'All'
            Parent = ''
            Label  = 'All (entire inventory)'
            Folder = $null
        })
    }

    foreach ($item in @(Get-VISelectableFolders -ExcludeNames $ExcludeNames)) {
        $choices.Add($item)
    }

    if ($choices.Count -eq 0 -or ($AllowAll -and $choices.Count -eq 1)) {
        throw "No VM folders were found in vCenter."
    }

    Write-Host ""
    Write-Host "Available networks / folders:" -ForegroundColor Yellow
    $picked = Select-VIListItem -Items $choices.ToArray() -Prompt $Prompt -Label { param($i) $i.Label }

    if (-not $picked) {
        $typed = Read-Host "Or type a folder name (e.g. CL1, CL5, IRDev)$(if ($AllowAll) { '; All = entire inventory' })"
        if ([string]::IsNullOrWhiteSpace($typed)) {
            throw "No network / folder selected."
        }
        $typed = $typed.Trim()
        if ($AllowAll -and $typed -eq 'All') {
            return [PSCustomObject]@{ Name = 'All'; Folder = $null; All = $true }
        }
        $folder = Resolve-VIFolderFromName -FolderName $typed
        if (-not $folder) {
            throw "Folder '$typed' was not found."
        }
        return [PSCustomObject]@{ Name = $folder.Name; Folder = $folder; All = $false }
    }

    if ($picked.Name -eq 'All') {
        return [PSCustomObject]@{ Name = 'All'; Folder = $null; All = $true }
    }

    return [PSCustomObject]@{ Name = $picked.Name; Folder = $picked.Folder; All = $false }
}

function Get-VISelectableNetworks {
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($pg in @(Get-VDPortgroup -ErrorAction SilentlyContinue)) {
        if ($pg.Name) { $names.Add($pg.Name) }
    }
    foreach ($pg in @(Get-VirtualPortGroup -ErrorAction SilentlyContinue)) {
        if ($pg.Name) { $names.Add($pg.Name) }
    }

    return @($names | Sort-Object -Unique)
}

function Resolve-VINetworkScope {
    <#
    .SYNOPSIS
        Resolve a port group / network name from -NetworkName or an interactive picker.
    #>
    param(
        [string]$NetworkName,
        [string]$Prompt = 'Select a network / port group (number or name)'
    )

    if ($NetworkName) { return $NetworkName.Trim() }

    $networks = @(Get-VISelectableNetworks)
    if ($networks.Count -eq 0) {
        $typed = Read-Host "No port groups discovered. Enter a network / port group name"
        if ([string]::IsNullOrWhiteSpace($typed)) {
            throw "Network name is required."
        }
        return $typed.Trim()
    }

    $choices = @($networks | ForEach-Object {
        [PSCustomObject]@{ Name = $_; Label = $_ }
    })

    Write-Host ""
    Write-Host "Available networks / port groups:" -ForegroundColor Yellow
    $picked = Select-VIListItem -Items $choices -Prompt $Prompt -Label { param($i) $i.Label }

    if ($picked) { return $picked.Name }

    $typed = Read-Host "Or type a network / port group name"
    if ([string]::IsNullOrWhiteSpace($typed)) {
        throw "No network selected."
    }
    return $typed.Trim()
}

function Import-VIInventoryScopeHelper {
    <#
    .SYNOPSIS
        Dot-source this helper from a script living in a category subfolder.
    #>
    param([string]$ScriptRoot)

    $path = Join-Path $ScriptRoot '..\Common\Resolve-InventoryScope.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required helper not found: $path"
    }
    . $path
}
