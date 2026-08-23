# Config.ps1 - loading Settings.psd1, Profiles\*.psd1 and Rules\SlotRules.psd1.

function Get-BffRoot {
    <#
    .SYNOPSIS
    Returns the 'Black Face Fix' folder, i.e. the parent of PS\.
    #>
    [CmdletBinding()]
    param()
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Import-BffSettings {
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot))

    $path = Join-Path $Root 'Config\Settings.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Settings.psd1 not found at '$path'."
    }

    $settings = Import-PowerShellDataFile -LiteralPath $path

    # Fill in anything an older or hand-edited Settings.psd1 might be missing, so
    # the rest of the code can index freely.
    $defaults = @{
        Profile    = 'Auto'
        Paths      = @{ Fallout4 = ''; MO2 = ''; MO2Profile = ''; TexTools = '' }
        Scope      = @{
            OnlyEnabledMods = $true; IncludeGameData = $true; IncludeOverwrite = $true
            IncludeFaceCustomization = $false; IncludeArchives = $true; FixArchives = $false
            ExcludePathPatterns = @('\\Hair\\'); ExcludeMods = @()
        }
        Output     = @{ Mode = 'OutputMod'
                        OutputModNameFormat = '{0} - face textures resized for {1}'
                        GameDataModName = 'Fallout 4 Data'; OverwriteModName = 'MO2 Overwrite'
                        BackupSuffix = '.backup' }
        Conversion = @{ Filter = 'FANT'; UseBcMax = $true; MinSize = 256; RequireSquare = $true; PreferSystemTools = $false }
        Logging    = @{ Debug = $false }
    }

    foreach ($key in $defaults.Keys) {
        if (-not $settings.ContainsKey($key)) {
            $settings[$key] = $defaults[$key]
        }
        elseif ($defaults[$key] -is [hashtable]) {
            foreach ($sub in $defaults[$key].Keys) {
                if (-not $settings[$key].ContainsKey($sub)) {
                    $settings[$key][$sub] = $defaults[$key][$sub]
                }
            }
        }
    }

    return $settings
}

function Get-BffProfileList {
    <#
    .SYNOPSIS
    Loads every Profiles\*.psd1 as a BffProfile.
    #>
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot))

    $dir = Join-Path $Root 'Profiles'
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Profiles folder not found at '$dir'."
    }

    $result = New-Object System.Collections.Generic.List[BffProfile]
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.psd1' -File | Sort-Object Name)) {
        $data = Import-PowerShellDataFile -LiteralPath $file.FullName

        # Deliberately not named $profile: that is a PowerShell automatic variable.
        $prof             = [BffProfile]::new()
        $prof.Name        = $data.Name
        $prof.Description = $data.Description
        $prof.Sizes       = $data.Sizes
        $prof.F4EE        = $data.F4EE
        $prof.SourcePath  = $file.FullName

        if (-not $prof.Sizes.ContainsKey('Other')) {
            $prof.Sizes['Other'] = $prof.Sizes['Diffuse']
        }

        $result.Add($prof)
    }

    if ($result.Count -eq 0) {
        throw "No profiles found in '$dir'."
    }
    return $result
}

function Get-BffProfile {
    <#
    .SYNOPSIS
    Finds one profile by name. Matches the Name field or the file name, so both
    'HD DLC' and 'HD-DLC' work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Root = (Get-BffRoot)
    )

    $profiles = Get-BffProfileList -Root $Root
    $needle   = $Name.Replace('-', ' ').Trim()

    foreach ($p in $profiles) {
        $fileStem = [System.IO.Path]::GetFileNameWithoutExtension($p.SourcePath).Replace('-', ' ')
        if ($p.Name -eq $needle -or $fileStem -eq $needle) { return $p }
    }

    $known = ($profiles | ForEach-Object { $_.Name }) -join ', '
    throw "Unknown profile '$Name'. Available: $known."
}

function Import-BffSlotRules {
    <#
    .SYNOPSIS
    Loads Rules\SlotRules.psd1 into BffSlotRule objects.
    #>
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot))

    $path = Join-Path $Root 'Rules\SlotRules.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "SlotRules.psd1 not found at '$path'."
    }

    $data  = Import-PowerShellDataFile -LiteralPath $path
    $rules = New-Object System.Collections.Generic.List[BffSlotRule]

    foreach ($entry in $data.Slots) {
        $rule                = [BffSlotRule]::new()
        $rule.Slot           = $entry.Slot
        $rule.Suffixes       = @($entry.Suffixes)
        $rule.AllowedFormats = @($entry.AllowedFormats)
        $rule.DefaultFormat  = $entry.DefaultFormat
        # Size enforcement is on unless a slot explicitly opts out.
        $rule.EnforceSize    = if ($entry.ContainsKey('EnforceSize')) { [bool] $entry.EnforceSize } else { $true }
        $rules.Add($rule)
    }

    return [pscustomobject]@{
        Rules       = $rules
        DefaultSlot = $data.DefaultSlot
    }
}

function Get-BffFileSuffix {
    <#
    .SYNOPSIS
    Returns the slot suffix of a texture file name, lowercased, or '' when there
    is none.

    .EXAMPLE
    Get-BffFileSuffix 'AGCP Beauty Mark 1_d.DDS'   ->  '_d'
    Get-BffFileSuffix 'MaleHead_SSS.DDS'           ->  '_sss'
    Get-BffFileSuffix 'AGCP Crescent.dds'          ->  ''
    Get-BffFileSuffix 'EyeLinerThin1.DDS'          ->  ''
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $FileName)

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

    # Only letters count as a suffix: 'EyeLiner02' and 'Facepaint41' have no slot.
    if ($stem -match '(_[A-Za-z]+)$') {
        return $Matches[1].ToLowerInvariant()
    }
    return ''
}

function Resolve-BffSlot {
    <#
    .SYNOPSIS
    Maps a texture file name onto a slot rule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [object] $SlotRules
    )

    $suffix = Get-BffFileSuffix -FileName $FileName

    # Longest suffix first so '_sss' is never shadowed by '_s'.
    $ordered = $SlotRules.Rules | Sort-Object { -($_.Suffixes | Measure-Object -Property Length -Maximum).Maximum }

    foreach ($rule in $ordered) {
        if ($rule.Suffixes -contains $suffix) { return $rule }
    }

    foreach ($rule in $SlotRules.Rules) {
        if ($rule.Slot -eq $SlotRules.DefaultSlot) { return $rule }
    }

    throw "No slot rule matched '$FileName' and DefaultSlot '$($SlotRules.DefaultSlot)' does not exist."
}
