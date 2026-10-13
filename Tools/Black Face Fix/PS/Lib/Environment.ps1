# Environment.ps1 - locating Fallout 4, Mod Organizer 2 and LooksMenu, and
# deciding which resolution profile the user is actually on.

function Read-BffIniFile {
    <#
    .SYNOPSIS
    Minimal INI reader. Returns @{ SectionName = @{ key = value } }.
    Keys are case-insensitive; values keep their original case.
    Trailing '; comments' are stripped, which f4ee.ini uses heavily.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $result  = @{}
    $section = ''
    $result[$section] = @{}

    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $result.ContainsKey($section)) { $result[$section] = @{} }
            continue
        }

        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }

        $key   = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim()

        # f4ee.ini writes 'uTintWidth=1024 ; Default[1024]'
        $comment = $value.IndexOf(';')
        if ($comment -ge 0) { $value = $value.Substring(0, $comment).Trim() }

        $result[$section][$key] = $value
    }

    return $result
}

function ConvertFrom-BffMO2Value {
    <#
    .SYNOPSIS
    Unwraps Mod Organizer's Qt-serialised values.
    'gamePath=@ByteArray(C:\\Steam\\...)' -> 'C:\Steam\...'
    #>
    [CmdletBinding()]
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $v = $Value.Trim()
    if ($v -match '^@ByteArray\((.*)\)$') { $v = $Matches[1] }
    if ($v -match '^@Variant\(') { return '' }   # binary blob, not a path

    # Qt escapes backslashes in ini values.
    return $v.Replace('\\', '\')
}

function Get-BffFallout4Path {
    <#
    .SYNOPSIS
    Finds the Fallout 4 install folder: explicit setting, then MO2's gamePath,
    then the registry key the original script used.
    #>
    [CmdletBinding()]
    param(
        [string] $Override,
        [string] $MO2GamePath
    )

    $candidates = @($Override, $MO2GamePath)

    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Bethesda Softworks\Fallout4' -ErrorAction Stop
        $candidates += $reg.'Installed Path'
    }
    catch {
        Write-Verbose "Registry key for Fallout 4 not readable: $($_.Exception.Message)"
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $path = $c.TrimEnd('\')
        # Path.Combine: Join-Path fails outright on a drive that is not there, and
        # then the candidates after this one are never tried.
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($path, 'Data'))) { return $path }
    }

    throw 'Could not find the Fallout 4 install folder. Set Paths.Fallout4 in Config\Settings.psd1.'
}

function Get-BffMO2Info {
    <#
    .SYNOPSIS
    Locates the Mod Organizer 2 instance and returns its paths plus the selected
    profile. Returns $null when MO2 is not in use - the tool still works on the
    game's own Data folder in that case.

    Detection order:
      1. Paths.MO2 from Settings.psd1
      2. walking up from the tool's own folder (it usually lives inside a mod)
      3. PS\MOInstall.txt from V3 (holds the mods folder)
      4. %LOCALAPPDATA%\ModOrganizer\<instance>\ModOrganizer.ini
    #>
    [CmdletBinding()]
    param(
        [string] $Override,
        [string] $Root = (Get-BffRoot)
    )

    $iniPath = $null

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $candidate = [System.IO.Path]::Combine($Override.TrimEnd('\'), 'ModOrganizer.ini')
        if (Test-Path -LiteralPath $candidate) { $iniPath = $candidate }
        else { Write-Warning "Paths.MO2 is set to '$Override' but there is no ModOrganizer.ini there." }
    }

    if (-not $iniPath) {
        # <MO2>\mods\<thismod>\Tools\Black Face Fix -> four levels up.
        $walk = $Root
        for ($i = 0; $i -lt 6 -and $walk; $i++) {
            $candidate = Join-Path $walk 'ModOrganizer.ini'
            if (Test-Path -LiteralPath $candidate) { $iniPath = $candidate; break }
            $walk = Split-Path -Parent $walk
        }
    }

    if (-not $iniPath) {
        $legacy = Join-Path $Root 'PS\MOInstall.txt'
        if (Test-Path -LiteralPath $legacy) {
            $modsPath = (Get-Content -LiteralPath $legacy -TotalCount 1).Trim()
            if ($modsPath -and (Test-Path -LiteralPath $modsPath)) {
                $candidate = Join-Path (Split-Path -Parent $modsPath) 'ModOrganizer.ini'
                if (Test-Path -LiteralPath $candidate) { $iniPath = $candidate }
            }
        }
    }

    if (-not $iniPath) {
        $instanceRoot = Join-Path $env:LOCALAPPDATA 'ModOrganizer'
        if (Test-Path -LiteralPath $instanceRoot) {
            $found = Get-ChildItem -LiteralPath $instanceRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'ModOrganizer.ini' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($found) { $iniPath = $found }
        }
    }

    if (-not $iniPath) { return $null }

    $mo2Root = Split-Path -Parent $iniPath
    $ini     = Read-BffIniFile -Path $iniPath

    $general  = if ($ini.ContainsKey('General'))  { $ini['General'] }  else { @{} }
    $settings = if ($ini.ContainsKey('Settings')) { $ini['Settings'] } else { @{} }

    # MO2 only writes these when they differ from the defaults under the instance root.
    #
    # Path.Combine, not Join-Path: Join-Path fails on a drive that is not there, and
    # an ini pointing at an unplugged disk has to give paths that simply do not
    # exist, not no paths at all.
    $baseDir = ConvertFrom-BffMO2Value $settings['base_directory']
    if (-not $baseDir) { $baseDir = $mo2Root }

    $modsPath = ConvertFrom-BffMO2Value $settings['mod_directory']
    if (-not $modsPath) { $modsPath = [System.IO.Path]::Combine($baseDir, 'mods') }

    $profilesPath = ConvertFrom-BffMO2Value $settings['profiles_directory']
    if (-not $profilesPath) { $profilesPath = [System.IO.Path]::Combine($baseDir, 'profiles') }

    $overwritePath = ConvertFrom-BffMO2Value $settings['overwrite_directory']
    if (-not $overwritePath) { $overwritePath = [System.IO.Path]::Combine($baseDir, 'overwrite') }

    return [pscustomobject]@{
        IniPath         = $iniPath
        Root            = $mo2Root
        ModsPath        = $modsPath
        ProfilesPath    = $profilesPath
        OverwritePath   = $overwritePath
        GamePath        = ConvertFrom-BffMO2Value $general['gamePath']
        GameName        = ConvertFrom-BffMO2Value $general['gameName']
        SelectedProfile = ConvertFrom-BffMO2Value $general['selected_profile']
    }
}

function Get-BffModList {
    <#
    .SYNOPSIS
    Reads modlist.txt for one MO2 profile.

    In modlist.txt the FIRST line is the highest priority mod, so Priority 0 wins
    conflicts. Prefixes: '+' enabled, '-' disabled, '*' DLC/backup placeholder
    (not a real mod folder).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $MO2,
        [string] $ProfileName
    )

    if (-not $ProfileName) { $ProfileName = $MO2.SelectedProfile }
    if (-not $ProfileName) { return @() }

    $listPath = Join-Path (Join-Path $MO2.ProfilesPath $ProfileName) 'modlist.txt'
    if (-not (Test-Path -LiteralPath $listPath)) {
        Write-Warning "modlist.txt not found for MO2 profile '$ProfileName' at '$listPath'."
        return @()
    }

    $result   = New-Object System.Collections.Generic.List[object]
    $priority = 0

    foreach ($line in (Get-Content -LiteralPath $listPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        $flag = $trimmed.Substring(0, 1)
        $name = $trimmed.Substring(1)

        if ($flag -eq '*') { continue }                 # DLC placeholder
        if ($name -match '_separator$') { continue }    # UI separator

        $result.Add([pscustomobject]@{
            Name     = $name
            Enabled  = ($flag -eq '+')
            Priority = $priority
        })
        $priority++
    }

    return $result
}

function Test-BffHdDlc {
    <#
    .SYNOPSIS
    True when the HD Texture Pack DLC is present. The engine only forces head
    speculars to 1024 when DLCUltraHighResolution is an enabled plugin, so the
    plugin list is checked when we have one; otherwise fall back to the archives.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Fallout4Path,
        [object] $MO2,
        [string] $ProfileName
    )

    $dataPath   = Join-Path $Fallout4Path 'Data'
    $hasArchive = @(Get-ChildItem -LiteralPath $dataPath -Filter 'DLCUltraHighResolution*.ba2' -ErrorAction SilentlyContinue).Count -gt 0

    if ($MO2) {
        if (-not $ProfileName) { $ProfileName = $MO2.SelectedProfile }
        $pluginsPath = Join-Path (Join-Path $MO2.ProfilesPath $ProfileName) 'plugins.txt'
        if (Test-Path -LiteralPath $pluginsPath) {
            $enabled = Get-Content -LiteralPath $pluginsPath |
                Where-Object { $_.Trim().StartsWith('*') } |
                ForEach-Object { $_.Trim().Substring(1) }
            return [bool] ($enabled -contains 'DLCUltraHighResolution.esm')
        }
    }

    return $hasArchive
}

function Get-BffF4eeConfig {
    <#
    .SYNOPSIS
    Finds every F4SE\Plugins\f4ee.ini and works out which one MO2 actually serves
    to the game, then reads uTintWidth / uTintHeight from it.

    Returns $null when LooksMenu is not installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Fallout4Path,
        [object] $MO2,
        [object] $ModList
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    # Loose file in the game's own Data folder always loses to MO2's virtual FS,
    # so give it the worst priority.
    $gameIni = Join-Path $Fallout4Path 'Data\F4SE\Plugins\f4ee.ini'
    if (Test-Path -LiteralPath $gameIni) {
        $candidates.Add([pscustomobject]@{ Path = $gameIni; ModName = '(game data)'; Priority = [int]::MaxValue })
    }

    if ($MO2 -and (Test-Path -LiteralPath $MO2.ModsPath)) {
        $priorityOf = @{}
        foreach ($m in $ModList) { $priorityOf[$m.Name] = $m }

        foreach ($dir in (Get-ChildItem -LiteralPath $MO2.ModsPath -Directory -ErrorAction SilentlyContinue)) {
            $ini = Join-Path $dir.FullName 'F4SE\Plugins\f4ee.ini'
            if (-not (Test-Path -LiteralPath $ini)) { continue }

            $entry = $priorityOf[$dir.Name]
            if ($entry -and -not $entry.Enabled) { continue }   # disabled mod never applies

            $priority = if ($entry) { $entry.Priority } else { [int]::MaxValue - 1 }
            $candidates.Add([pscustomobject]@{ Path = $ini; ModName = $dir.Name; Priority = $priority })
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    # Lowest Priority number wins: first line of modlist.txt is the top of the stack.
    $ordered = $candidates | Sort-Object Priority
    $winner  = $ordered[0]

    $ini      = Read-BffIniFile -Path $winner.Path
    $charGen  = if ($ini.ContainsKey('CharGen')) { $ini['CharGen'] } else { @{} }

    # LooksMenu's own default, kept for a value that is missing or not a number.
    # Parsed into a scratch variable: TryParse writes 0 into its target when it
    # fails, which would read as a 0px tint.
    $width  = 1024
    $height = 1024
    $n = 0
    if ([int]::TryParse([string] $charGen['uTintWidth'],  [ref] $n)) { $width  = $n }
    if ([int]::TryParse([string] $charGen['uTintHeight'], [ref] $n)) { $height = $n }

    return [pscustomobject]@{
        Path        = $winner.Path
        ModName     = $winner.ModName
        TintWidth   = $width
        TintHeight  = $height
        AllFound    = $ordered
        Overridden  = ($ordered.Count -gt 1)
    }
}

function Resolve-BffProfile {
    <#
    .SYNOPSIS
    Picks the profile that matches the install, from the HD DLC state and the
    LooksMenu tint resolution.

    uTintWidth is what LooksMenu renders tint masks at, and tints must match the
    head textures, so it is the strongest signal for 2K/4K. It says nothing about
    the specular, which is what the HD DLC check is for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]   $HasHdDlc,
        [object] $F4ee,
        [string] $Root = (Get-BffRoot)
    )

    $tint    = if ($F4ee) { $F4ee.TintWidth } else { 0 }
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($tint -ge 4096) {
        $name = '4K'
        $reasons.Add("LooksMenu uTintWidth is $tint")
    }
    elseif ($tint -ge 2048) {
        $name = '2K'
        $reasons.Add("LooksMenu uTintWidth is $tint")
    }
    elseif ($HasHdDlc) {
        $name = 'HD DLC'
        $reasons.Add('DLCUltraHighResolution is present and enabled')
        if ($F4ee) { $reasons.Add("LooksMenu uTintWidth is $tint") }
    }
    else {
        $name = 'Vanilla'
        $reasons.Add('no HD Texture Pack DLC found')
        if ($F4ee) { $reasons.Add("LooksMenu uTintWidth is $tint") }
        else { $reasons.Add('LooksMenu not installed') }
    }

    return [pscustomobject]@{
        Profile = Get-BffProfile -Name $name -Root $Root
        Reasons = $reasons
    }
}

function Test-BffProfileConsistency {
    <#
    .SYNOPSIS
    Warns when the chosen profile and f4ee.ini disagree. Returns warning strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffProfile] $Profile,
        [object] $F4ee
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not $F4ee) { return $warnings }

    $want = [int] $Profile.F4EE.uTintWidth

    if ($F4ee.TintWidth -ne $want -or $F4ee.TintHeight -ne $want) {
        # Each -f expression gets its own parentheses: inside a method call the
        # commas would otherwise be read as extra arguments to .Add().
        if ($F4ee.TintWidth -lt $want) {
            $warnings.Add((
                ("Profile '{0}' targets {1}px face textures, but LooksMenu renders tint masks at {2}x{3}. " +
                 "The engine will downsample your textures to {2} and the tints will not match. " +
                 "Set uTintWidth and uTintHeight to {1} in {4}.") -f
                 $Profile.Name, $want, $F4ee.TintWidth, $F4ee.TintHeight, $F4ee.Path))
        }
        else {
            $warnings.Add((
                ("Profile '{0}' targets {1}px face textures, but LooksMenu renders tint masks at {2}x{3}. " +
                 "Tints will be larger than the head textures and will not match. " +
                 "Set uTintWidth and uTintHeight to {1} in {4}.") -f
                 $Profile.Name, $want, $F4ee.TintWidth, $F4ee.TintHeight, $F4ee.Path))
        }
    }

    if ($F4ee.Overridden) {
        $others = ($F4ee.AllFound | Select-Object -Skip 1 | ForEach-Object { $_.ModName }) -join ', '
        $warnings.Add(
            ("More than one f4ee.ini is installed. '{0}' wins on MO2 priority; also present in: {1}." -f
             $F4ee.ModName, $others))
    }

    return $warnings
}

function Get-BffEnvironment {
    <#
    .SYNOPSIS
    One call that resolves everything the rest of the tool needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Settings,
        [string] $Root = (Get-BffRoot),
        [string] $ProfileOverride
    )

    $mo2 = Get-BffMO2Info -Override $Settings.Paths.MO2 -Root $Root

    $fo4 = Get-BffFallout4Path -Override $Settings.Paths.Fallout4 -MO2GamePath $(if ($mo2) { $mo2.GamePath } else { '' })

    $mo2ProfileName = $Settings.Paths.MO2Profile
    if (-not $mo2ProfileName -and $mo2) { $mo2ProfileName = $mo2.SelectedProfile }

    $modList = if ($mo2) { Get-BffModList -MO2 $mo2 -ProfileName $mo2ProfileName } else { @() }
    $hasHd   = Test-BffHdDlc -Fallout4Path $fo4 -MO2 $mo2 -ProfileName $mo2ProfileName
    $f4ee    = Get-BffF4eeConfig -Fallout4Path $fo4 -MO2 $mo2 -ModList $modList

    $requested = if ($ProfileOverride) { $ProfileOverride } else { $Settings.Profile }
    $detected  = Resolve-BffProfile -HasHdDlc $hasHd -F4ee $f4ee -Root $Root

    if ($requested -and $requested -ne 'Auto') {
        $active   = Get-BffProfile -Name $requested -Root $Root
        $autoUsed = $false
    }
    else {
        $active   = $detected.Profile
        $autoUsed = $true
    }

    return [pscustomobject]@{
        Root             = $Root
        Fallout4Path     = $fo4
        DataPath         = (Join-Path $fo4 'Data')
        MO2              = $mo2
        MO2ProfileName   = $mo2ProfileName
        ModList          = $modList
        HasHdDlc         = $hasHd
        F4ee             = $f4ee
        Profile          = $active
        ProfileAutoDetected = $autoUsed
        DetectedProfile  = $detected.Profile
        DetectionReasons = @($detected.Reasons)
        # @(): an empty List unwraps to $null, and callers under Set-StrictMode then
        # throw on .Count.
        Warnings         = @(Test-BffProfileConsistency -Profile $active -F4ee $f4ee)
    }
}
