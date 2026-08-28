# Discovery.ps1 - finding the textures that are actually face textures.
#
# The V3 script used three loose regexes over the whole mods folder. That produced
# both false positives ('Headgear01_d.dds' in a hair mod matches its head pattern)
# and silent misses (its Preston/Mayor patterns had an unclosed group, so they threw
# a regex error that $ErrorActionPreference = 'silentlycontinue' swallowed).
#
# Three layers instead, checked in order:
#   1. exact paths from Rules\VanillaFaceTextures.psd1, baked out of the game's own
#      TXST records - the only way to catch Preston_d.dds / Mayor_s.dds / Piper
#   2. FullScanFolders (FaceDetails, TintMasks) - everything underneath counts
#   3. HeadNamePattern anywhere else under textures\actors\character
#
# Everything else is left alone. That matters: body textures live right next to head
# textures (BaseHumanMale\BaseMaleBody_s.dds is 4096, femalebody_s.dds is 8192), so
# a rule as loose as "any _s under actors\character" would wreck them.

function Import-BffVanillaFaceTextures {
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot))

    $path = Join-Path $Root 'Rules\VanillaFaceTextures.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "VanillaFaceTextures.psd1 not found at '$path'; named-actor faces (Preston, Mayor, Piper) will not be detected."
        return [pscustomobject]@{ Textures = @{}; Exclude = @() }
    }

    $data = Import-PowerShellDataFile -LiteralPath $path
    return [pscustomobject]@{
        Textures = $data.Textures
        Exclude  = @($data.Exclude)
    }
}

function Get-BffSourceRoot {
    <#
    .SYNOPSIS
    Every folder that can hold loose textures, in the order they should be reported.
    Kind is GameData, Mod or Overwrite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Environment,
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $roots = New-Object System.Collections.Generic.List[object]

    if ($Settings.Scope.IncludeGameData -and (Test-Path -LiteralPath $Environment.DataPath)) {
        $roots.Add([pscustomobject]@{
            Name = '(game data)'; Path = $Environment.DataPath; Kind = 'GameData'; Priority = [int]::MaxValue
        })
    }

    $mo2 = $Environment.MO2
    if ($mo2 -and (Test-Path -LiteralPath $mo2.ModsPath)) {

        $entryOf = @{}
        foreach ($m in $Environment.ModList) { $entryOf[$m.Name] = $m }

        # Never scan our own output: those folders hold already-fixed copies, and
        # treating them as sources would let a fix become the input to the next fix.
        $outputPattern = Get-BffOutputModPattern -Settings $Settings -Root $Environment.Root

        foreach ($dir in (Get-ChildItem -LiteralPath $mo2.ModsPath -Directory -ErrorAction SilentlyContinue)) {
            if ($Settings.Scope.ExcludeMods -contains $dir.Name) { continue }
            if (Test-BffOutputMod -Path $dir.FullName) { continue }
            if ($outputPattern -and $dir.Name -match $outputPattern) { continue }

            $entry = $entryOf[$dir.Name]

            if ($Settings.Scope.OnlyEnabledMods) {
                # Unknown folders are skipped when a modlist exists: MO2 does not
                # serve a mod that is not in the profile's list.
                if (-not $entry) {
                    if ($Environment.ModList.Count -gt 0) { continue }
                }
                elseif (-not $entry.Enabled) { continue }
            }

            $roots.Add([pscustomobject]@{
                Name     = $dir.Name
                Path     = $dir.FullName
                Kind     = 'Mod'
                Priority = $(if ($entry) { $entry.Priority } else { [int]::MaxValue - 1 })
            })
        }

        if ($Settings.Scope.IncludeOverwrite -and (Test-Path -LiteralPath $mo2.OverwritePath)) {
            $roots.Add([pscustomobject]@{
                Name = '(overwrite)'; Path = $mo2.OverwritePath; Kind = 'Overwrite'; Priority = -1
            })
        }
    }

    return $roots
}

function Test-BffFaceTexture {
    <#
    .SYNOPSIS
    Decides whether one texture is a face texture, and which slot it belongs to.

    .PARAMETER RelativePath
    Path relative to the textures\ folder, e.g. 'actors\character\preston\preston_d.dds'.

    .OUTPUTS
    $null when it is not a face texture, otherwise a hashtable with Slot and Source
    ('vanilla list', 'FaceDetails', 'head name', ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [object] $VanillaFaceTextures,
        [Parameter(Mandatory)] [object] $SlotRules,
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $key      = $RelativePath.Replace('/', '\').ToLowerInvariant()
    $fileName = Split-Path $RelativePath -Leaf

    # Shared helper maps (BlankDetailmap.dds) are never face textures.
    if ($VanillaFaceTextures.Exclude -contains $key) { return $null }

    foreach ($pattern in $Settings.Scope.ExcludePathPatterns) {
        if ($key -match $pattern.ToLowerInvariant()) { return $null }
    }

    if (-not ($key -match '^actors\\character\\')) {
        return $null
    }

    # --- layer 1: the game's own texture set declarations ----------------------
    if ($VanillaFaceTextures.Textures.ContainsKey($key)) {
        return @{ Slot = $VanillaFaceTextures.Textures[$key]; Source = 'vanilla texture set' }
    }

    $inner = $key -replace '^actors\\character\\', ''

    # --- layer 2: folders where everything counts ------------------------------
    foreach ($folder in $Settings.FaceRules.FullScanFolders) {
        $prefix = ($folder.Replace('/', '\').ToLowerInvariant().TrimEnd('\')) + '\'
        if ($inner.StartsWith($prefix)) {
            $rule = Resolve-BffSlot -FileName $fileName -SlotRules $SlotRules
            return @{ Slot = $rule.Slot; Source = $folder }
        }
    }

    if ($inner.StartsWith('facecustomization\')) {
        if (-not $Settings.Scope.IncludeFaceCustomization) { return $null }
        $rule = Resolve-BffSlot -FileName $fileName -SlotRules $SlotRules
        return @{ Slot = $rule.Slot; Source = 'FaceCustomization' }
    }

    # --- layer 3: name based, everywhere else ----------------------------------
    if ($fileName -match $Settings.FaceRules.HeadNamePattern) {
        $rule = Resolve-BffSlot -FileName $fileName -SlotRules $SlotRules
        return @{ Slot = $rule.Slot; Source = 'head name' }
    }

    return $null
}

function Get-BffCandidate {
    <#
    .SYNOPSIS
    Walks every source root and returns BffTexture objects for the face textures.
    Metadata (width/height/format) is NOT filled in yet - Update-BffTextureInfo does
    that in one batched texdiag pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Environment,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [object]    $SlotRules,
        [object] $VanillaFaceTextures,
        [scriptblock] $Progress
    )

    if (-not $VanillaFaceTextures) {
        $VanillaFaceTextures = Import-BffVanillaFaceTextures -Root $Environment.Root
    }

    $roots  = Get-BffSourceRoot -Environment $Environment -Settings $Settings
    $result = New-Object System.Collections.Generic.List[BffTexture]
    $index  = 0

    foreach ($root in $roots) {
        $index++
        if ($Progress) { & $Progress $index $roots.Count $root.Name }

        # Cheap gate: skip the whole mod when it has no character textures at all.
        # Without this, 300+ mods each get a full recursive walk.
        $charRoot = Join-Path $root.Path 'textures\actors\character'
        if (-not (Test-Path -LiteralPath $charRoot)) { continue }

        $texturesRoot = Join-Path $root.Path 'textures'

        foreach ($file in (Get-ChildItem -LiteralPath $charRoot -Recurse -Filter '*.dds' -File -ErrorAction SilentlyContinue)) {

            $relative = $file.FullName.Substring($texturesRoot.Length).TrimStart('\')

            $match = Test-BffFaceTexture -RelativePath $relative `
                                         -VanillaFaceTextures $VanillaFaceTextures `
                                         -SlotRules $SlotRules `
                                         -Settings $Settings
            if (-not $match) { continue }

            $t              = [BffTexture]::new()
            $t.FullName     = $file.FullName
            $t.Name         = $file.Name
            $t.RelativePath = Join-Path 'textures' $relative
            $t.ModName      = $root.Name
            $t.Origin       = $(if ($root.Kind -eq 'Mod') { 'Loose' } else { $root.Kind })
            $t.Slot         = $match.Slot
            $t.IsTintMask   = ($match.Source -ne 'vanilla texture set' -and $match.Source -ne 'head name')
            $t.MatchedBy    = $match.Source

            $result.Add($t)
        }
    }

    return $result
}

function Get-BffArchiveCandidate {
    <#
    .SYNOPSIS
    Same classification, applied to the contents of BA2 archives. Nothing is
    unpacked here: for DX10 archives the size and format come straight out of the
    file table, and GNRL entries only have their DDS header read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Environment,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [object]    $SlotRules,
        [object] $VanillaFaceTextures,
        [scriptblock] $Progress
    )

    if (-not $VanillaFaceTextures) {
        $VanillaFaceTextures = Import-BffVanillaFaceTextures -Root $Environment.Root
    }

    $roots  = Get-BffSourceRoot -Environment $Environment -Settings $Settings
    $result = New-Object System.Collections.Generic.List[object]
    $index  = 0

    foreach ($root in $roots) {
        $index++
        if ($Progress) { & $Progress $index $roots.Count $root.Name }

        foreach ($archive in (Get-ChildItem -LiteralPath $root.Path -Filter '*.ba2' -File -ErrorAction SilentlyContinue)) {

            $idx = Read-BffBa2Index -Path $archive.FullName -PathFilter 'actors\\character\\'
            if ($idx.Error) {
                $result.Add([pscustomobject]@{
                    ModName = $root.Name; ArchivePath = $archive.FullName
                    SourceKind = $root.Kind
                    Texture = $null; Error = $idx.Error
                })
                continue
            }

            foreach ($entry in $idx.Entries) {
                $relative = $entry.InternalPath.Replace('/', '\')
                $relative = $relative -replace '(?i)^textures\\', ''

                $match = Test-BffFaceTexture -RelativePath $relative `
                                             -VanillaFaceTextures $VanillaFaceTextures `
                                             -SlotRules $SlotRules `
                                             -Settings $Settings
                if (-not $match) { continue }

                if (-not $entry.HasMetadata) {
                    [void] (Read-BffBa2GnrlHeader -Entry $entry)
                }

                $t              = [BffTexture]::new()
                $t.FullName     = $entry.InternalPath
                $t.Name         = Split-Path $entry.InternalPath -Leaf
                $t.RelativePath = Join-Path 'textures' $relative
                $t.ModName      = $root.Name
                $t.Origin       = 'BA2'
                $t.ArchivePath  = $archive.FullName
                $t.Slot         = $match.Slot
                $t.IsTintMask   = ($match.Source -ne 'vanilla texture set' -and $match.Source -ne 'head name')
            $t.MatchedBy    = $match.Source
                $t.Width        = $entry.Width
                $t.Height       = $entry.Height
                $t.Format       = $entry.Format
                $t.MipLevels    = $entry.MipLevels

                $result.Add([pscustomobject]@{
                    ModName = $root.Name; ArchivePath = $archive.FullName
                    SourceKind = $root.Kind
                    Texture = $t; Entry = $entry; Error = ''
                })
            }
        }
    }

    return $result
}
