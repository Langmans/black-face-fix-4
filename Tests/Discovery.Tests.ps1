# Unit tests for Discovery.ps1 - which files count as face textures, and where
# they are looked for.
#
#   Invoke-Pester -Path .\Tests\Discovery.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Discovery.ps1'
#
# Pester 5. Classification is tested on paths alone. The walk over a Mod
# Organizer install is tested on a real, small one built in Pester's TestDrive:
# a mods folder, an overwrite folder and a game Data folder, with a handful of
# head, body and tint mask files. The BA2 reader is mocked - what it reads out
# of an archive is Ba2.ps1's to test, what discovery does with it is tested here.
#
# Folder names in TestDrive carry no square brackets, though real output mods do:
# Pester's TestDrive cleanup reads them as a wildcard and fails the whole file.
#
# Type names are given as strings - New-Object BffArchiveEntry rather than
# [BffArchiveEntry]::new() - because a type literal in this file is resolved when
# the file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'TexInfo', 'Ba2', 'Planner', 'Discovery') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    $rules = Import-BffSlotRules -Root $tool

    # A vanilla list of two named actors and one shared helper map.
    $vanilla = [pscustomobject]@{
        Textures = @{
            'actors\character\preston\preston_d.dds' = 'Diffuse'
            'actors\character\mayor\mayor_s.dds'     = 'Specular'
        }
        Exclude  = @('actors\character\humancommon\blankdetailmap.dds')
    }

    function New-TestSettings {
        return @{
            Scope = @{
                IncludeGameData          = $true
                IncludeOverwrite         = $true
                IncludeFaceCustomization = $false
                OnlyEnabledMods          = $false
                ExcludeMods              = @()
                ExcludePathPatterns      = @('\\hair\\', '\\eyes\\', '\\facegendata\\')
            }
            FaceRules = @{
                HeadNamePattern = 'head'
                FullScanFolders = @('Character Assets\FaceDetails', 'Character Assets\TintMasks')
            }
            Output = @{ OutputModNameFormat = '{0} [face-{1}]' }
        }
    }

    function Test-Path-Of {
        param([string] $RelativePath, [hashtable] $Settings = (New-TestSettings))
        Test-BffFaceTexture -RelativePath $RelativePath -VanillaFaceTextures $vanilla -SlotRules $rules -Settings $Settings
    }

    # An empty file is enough: discovery looks at names, never at contents.
    function New-TestFile {
        param([string] $Path)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        [void] (New-Item -ItemType File -Path $Path -Force)
    }

    # A Mod Organizer install under TestDrive, and the environment that points at
    # it. Each test gets a fresh one, so a test can add to it freely.
    function New-TestInstall {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $mods = Join-Path $root 'MO2\mods'
        $over = Join-Path $root 'MO2\overwrite'
        $data = Join-Path $root 'Game\Data'
        foreach ($d in $mods, $over, $data) { [void] (New-Item -ItemType Directory -Path $d -Force) }

        return [pscustomobject]@{
            Root         = $root
            Mods         = $mods
            Environment  = [pscustomobject]@{
                Root     = $root
                DataPath = $data
                MO2      = [pscustomobject]@{ ModsPath = $mods; OverwritePath = $over }
                ModList  = @()
            }
        }
    }

    function New-TestModEntry {
        param([string] $Name, [bool] $Enabled = $true, [int] $Priority = 0)
        [pscustomobject]@{ Name = $Name; Enabled = $Enabled; Priority = $Priority }
    }

    function Get-RootName {
        param($Install, [hashtable] $Settings = (New-TestSettings))
        @(Get-BffSourceRoot -Environment $Install.Environment -Settings $Settings | ForEach-Object Name)
    }
}

Describe 'Import-BffVanillaFaceTextures' {
    It 'reads the list baked out of the game''s texture sets' {
        $v = Import-BffVanillaFaceTextures -Root $tool
        $v.Textures.Count | Should -BeGreaterThan 0
        $v.Textures['actors\character\mayor\mayor_d.dds'] | Should -Be 'Diffuse'
        $v.Exclude | Should -Contain 'actors\character\humancommon\blankdetailmap.dds'
    }

    It 'warns and carries on with an empty list when the file is missing' {
        Mock Get-BffRoot { $TestDrive }
        $v = Import-BffVanillaFaceTextures -WarningVariable warned -WarningAction SilentlyContinue
        $v.Textures.Count | Should -Be 0
        @($v.Exclude).Count | Should -Be 0
        "$warned" | Should -BeLike '*named-actor faces (Preston, Mayor, Piper) will not be detected*'
    }
}

Describe 'Test-BffFaceTexture' {

    Context 'what is never a face texture' {
        It 'leaves out anything outside actors\character' {
            Test-Path-Of 'armor\headgear\Headgear01_d.dds' | Should -BeNullOrEmpty
        }

        It 'leaves out the shared helper maps, even under a face folder' {
            Test-Path-Of 'actors\character\HumanCommon\BlankDetailmap.dds' | Should -BeNullOrEmpty
        }

        It 'leaves out hair, eyes and FaceGen data' -TestCases @(
            @{ Rel = 'actors\character\hair\MaleHeadHair_d.dds' }
            @{ Rel = 'actors\character\eyes\HeadEye_d.dds' }
            @{ Rel = 'actors\character\FaceGenData\FaceTint\Fallout4.esm\00001234_head.dds' }
        ) {
            Test-Path-Of $Rel | Should -BeNullOrEmpty
        }

        It 'leaves out body textures that sit right next to the head' -TestCases @(
            @{ Rel = 'actors\character\BaseHumanMale\BaseMaleBody_s.dds' }
            @{ Rel = 'actors\character\BaseHumanFemale\FemaleBody_s.dds' }
        ) {
            Test-Path-Of $Rel | Should -BeNullOrEmpty
        }

        It 'leaves out FaceCustomization unless it is asked for' {
            Test-Path-Of 'actors\character\FaceCustomization\Fallout4.esm\00001234_d.dds' | Should -BeNullOrEmpty
        }
    }

    Context 'the three layers' {
        It 'knows a named actor from the game''s own list, whatever the name looks like' {
            $m = Test-Path-Of 'actors\character\Mayor\Mayor_s.dds'
            $m.Slot   | Should -Be 'Specular'
            $m.Source | Should -Be 'vanilla texture set'
        }

        It 'reads the list with either slash and any case' {
            (Test-Path-Of 'ACTORS/Character/Preston/Preston_D.DDS').Source | Should -Be 'vanilla texture set'
        }

        It 'takes everything under a tint mask folder, and names that folder' {
            $m = Test-Path-Of 'actors\character\Character Assets\TintMasks\AGCP Crescent.dds'
            $m.Slot   | Should -Be 'Diffuse'
            $m.Source | Should -Be 'Character Assets\TintMasks'
        }

        It 'gives a face detail its slot by suffix' {
            $m = Test-Path-Of 'actors\character\Character Assets\FaceDetails\Wrinkles_n.dds'
            $m.Slot   | Should -Be 'Normal'
            $m.Source | Should -Be 'Character Assets\FaceDetails'
        }

        It 'reads a full scan folder written with forward slashes or a trailing slash' {
            $settings = New-TestSettings
            $settings.FaceRules.FullScanFolders = @('Character Assets/Scars/')
            (Test-Path-Of 'actors\character\Character Assets\Scars\Scar01_d.dds' -Settings $settings).Source |
                Should -Be 'Character Assets/Scars/'
        }

        It 'takes FaceCustomization when it is asked for' {
            $settings = New-TestSettings
            $settings.Scope.IncludeFaceCustomization = $true
            $m = Test-Path-Of 'actors\character\FaceCustomization\Fallout4.esm\00001234_s.dds' -Settings $settings
            $m.Slot   | Should -Be 'Specular'
            $m.Source | Should -Be 'FaceCustomization'
        }

        It 'takes a head by its name anywhere else' -TestCases @(
            @{ Rel = 'actors\character\BaseHumanMale\MaleHead_n.dds';                  Slot = 'Normal' }
            @{ Rel = 'actors\character\BaseHumanFemale\HeadWrinkles_n.dds';            Slot = 'Normal' }
            @{ Rel = 'actors\character\BaseHumanFemale\FemaleHeadWeathered1_s.dds';    Slot = 'Specular' }
            @{ Rel = 'actors\character\BaseHumanMale\MaleHead_sk.dds';                 Slot = 'Skin' }
            @{ Rel = 'actors\character\BaseHumanMale\MaleHead.dds';                    Slot = 'Diffuse' }
        ) {
            $m = Test-Path-Of $Rel
            $m.Source | Should -Be 'head name'
            $m.Slot   | Should -Be $Slot
        }

        It 'calls only what is under FaceDetails or TintMasks a mask' -TestCases @(
            @{ Rel = 'actors\character\Character Assets\TintMasks\Blusher.dds';       IsMask = $true }
            @{ Rel = 'actors\character\Character Assets\FaceDetails\Freckles_d.dds';  IsMask = $true }
            @{ Rel = 'actors\character\FaceCustomization\Fallout4.esm\00001234_d.dds'; IsMask = $false }
            @{ Rel = 'actors\character\Mayor\Mayor_s.dds';                            IsMask = $false }
            @{ Rel = 'actors\character\BaseHumanMale\MaleHead_d.dds';                 IsMask = $false }
        ) {
            $settings = New-TestSettings
            $settings.Scope.IncludeFaceCustomization = $true
            (Test-Path-Of $Rel -Settings $settings).IsMask | Should -Be $IsMask
        }

        It 'checks the game''s list before the folders' {
            $own = [pscustomobject]@{
                Textures = @{ 'actors\character\character assets\tintmasks\special_s.dds' = 'Specular' }
                Exclude  = @()
            }
            $m = Test-BffFaceTexture -RelativePath 'actors\character\Character Assets\TintMasks\Special_s.dds' `
                                     -VanillaFaceTextures $own -SlotRules $rules -Settings (New-TestSettings)
            $m.Source | Should -Be 'vanilla texture set'
        }
    }
}

Describe 'Get-BffSourceRoot' {
    BeforeEach {
        $i = New-TestInstall
        foreach ($n in 'Alpha', 'Bravo', 'Charlie') { [void] (New-Item -ItemType Directory -Path (Join-Path $i.Mods $n)) }
    }

    It 'lists the game data, every mod, and the overwrite folder' {
        Get-RootName $i | Should -Be @('(game data)', 'Alpha', 'Bravo', 'Charlie', '(overwrite)')
    }

    It 'says what kind of source each one is' {
        $r = @(Get-BffSourceRoot -Environment $i.Environment -Settings (New-TestSettings))
        $r[0].Kind  | Should -Be 'GameData'
        $r[1].Kind  | Should -Be 'Mod'
        $r[-1].Kind | Should -Be 'Overwrite'
        $r[1].Path  | Should -Be (Join-Path $i.Mods 'Alpha')
    }

    It 'ranks them the way Mod Organizer does: overwrite on top, game data at the bottom' {
        $i.Environment.ModList = @((New-TestModEntry 'Alpha' -Priority 3))
        $r = @(Get-BffSourceRoot -Environment $i.Environment -Settings (New-TestSettings))
        ($r | Where-Object Name -eq '(overwrite)').Priority   | Should -Be -1
        ($r | Where-Object Name -eq 'Alpha').Priority         | Should -Be 3
        ($r | Where-Object Name -eq 'Bravo').Priority         | Should -Be ([int]::MaxValue - 1)
        ($r | Where-Object Name -eq '(game data)').Priority   | Should -Be ([int]::MaxValue)
    }

    It 'leaves out the game data and the overwrite folder when told to' {
        $settings = New-TestSettings
        $settings.Scope.IncludeGameData  = $false
        $settings.Scope.IncludeOverwrite = $false
        Get-RootName $i $settings | Should -Be @('Alpha', 'Bravo', 'Charlie')
    }

    It 'leaves out a game data or overwrite folder that is not there' {
        Remove-Item -LiteralPath $i.Environment.DataPath, $i.Environment.MO2.OverwritePath -Recurse
        Get-RootName $i | Should -Be @('Alpha', 'Bravo', 'Charlie')
    }

    It 'leaves out the mods it is told to' {
        $settings = New-TestSettings
        $settings.Scope.ExcludeMods = @('Bravo')
        Get-RootName $i $settings | Should -Not -Contain 'Bravo'
    }

    It 'never reads its own output back in' {
        [void] (New-BffOutputMarker -ModRoot (Join-Path $i.Mods 'Alpha face-Vanilla'))
        [void] (New-Item -ItemType Directory -Path (Join-Path $i.Mods 'Alpha - face textures resized for Vanilla'))
        Get-RootName $i | Should -Be @('(game data)', 'Alpha', 'Bravo', 'Charlie', '(overwrite)')
    }

    Context 'with only enabled mods' {
        BeforeEach {
            $settings = New-TestSettings
            $settings.Scope.OnlyEnabledMods = $true
        }

        It 'leaves out a mod the profile has switched off' {
            $i.Environment.ModList = @((New-TestModEntry 'Alpha'), (New-TestModEntry 'Bravo' -Enabled $false),
                                       (New-TestModEntry 'Charlie'))
            Get-RootName $i $settings | Should -Not -Contain 'Bravo'
        }

        It 'leaves out a folder the profile does not list at all' {
            $i.Environment.ModList = @((New-TestModEntry 'Alpha'), (New-TestModEntry 'Bravo'))
            Get-RootName $i $settings | Should -Not -Contain 'Charlie'
        }

        It 'keeps every folder when there is no mod list to go by' {
            Get-RootName $i $settings | Should -Be @('(game data)', 'Alpha', 'Bravo', 'Charlie', '(overwrite)')
        }

        It 'is only applied when asked for' {
            $i.Environment.ModList = @((New-TestModEntry 'Bravo' -Enabled $false))
            Get-RootName $i | Should -Contain 'Bravo'
        }
    }

    It 'lists only the game data without Mod Organizer' {
        $i.Environment.MO2 = $null
        Get-RootName $i | Should -Be @('(game data)')
    }

    It 'lists nothing from a Mod Organizer whose mods folder is gone' {
        Remove-Item -LiteralPath $i.Mods -Recurse
        Get-RootName $i | Should -Be @('(game data)')
    }
}

Describe 'Get-BffCandidate' {
    BeforeEach {
        $i = New-TestInstall
        $char = 'textures\actors\character'
        New-TestFile (Join-Path $i.Mods "Alpha\$char\BaseHumanMale\MaleHead_d.dds")
        New-TestFile (Join-Path $i.Mods "Alpha\$char\BaseHumanMale\BaseMaleBody_s.dds")
        New-TestFile (Join-Path $i.Mods "Alpha\$char\Character Assets\TintMasks\Blusher.dds")
        New-TestFile (Join-Path $i.Mods 'Bravo\textures\armor\Helmet_d.dds')
        New-TestFile (Join-Path $i.Environment.DataPath "$char\Preston\Preston_d.dds")
        New-TestFile (Join-Path $i.Environment.MO2.OverwritePath "$char\BaseHumanFemale\FemaleHead_s.dds")

        function Find-Candidate {
            param([scriptblock] $Progress)
            @(Get-BffCandidate -Environment $i.Environment -Settings (New-TestSettings) -SlotRules $rules `
                               -VanillaFaceTextures $vanilla -Progress $Progress)
        }
    }

    It 'finds the face textures and nothing else' {
        @(Find-Candidate | ForEach-Object Name | Sort-Object) |
            Should -Be @('Blusher.dds', 'FemaleHead_s.dds', 'MaleHead_d.dds', 'Preston_d.dds')
    }

    It 'describes a mod''s texture' {
        $t = Find-Candidate | Where-Object Name -eq 'MaleHead_d.dds'
        $t.FullName     | Should -Be (Join-Path $i.Mods "Alpha\$char\BaseHumanMale\MaleHead_d.dds")
        $t.RelativePath | Should -Be "$char\BaseHumanMale\MaleHead_d.dds"
        $t.ModName      | Should -Be 'Alpha'
        $t.Origin       | Should -Be 'Loose'
        $t.Slot         | Should -Be 'Diffuse'
        $t.IsTintMask   | Should -BeFalse
        $t.MatchedBy    | Should -Be 'head name'
    }

    It 'leaves the size and format for texdiag to fill in' {
        $t = Find-Candidate | Where-Object Name -eq 'MaleHead_d.dds'
        $t.Width  | Should -Be 0
        $t.Format | Should -BeNullOrEmpty
    }

    It 'marks what it found in a tint mask folder as a mask' {
        $t = Find-Candidate | Where-Object Name -eq 'Blusher.dds'
        $t.IsTintMask | Should -BeTrue
        $t.MatchedBy  | Should -Be 'Character Assets\TintMasks'
    }

    It 'does not mark a FaceCustomization texture as a mask: it is a face map baked for one NPC' {
        New-TestFile (Join-Path $i.Mods "Alpha\$char\FaceCustomization\Fallout4.esm\00001234_d.dds")
        $settings = New-TestSettings
        $settings.Scope.IncludeFaceCustomization = $true
        $t = @(Get-BffCandidate -Environment $i.Environment -Settings $settings -SlotRules $rules -VanillaFaceTextures $vanilla) |
             Where-Object Name -eq '00001234_d.dds'
        $t.MatchedBy  | Should -Be 'FaceCustomization'
        $t.IsTintMask | Should -BeFalse
    }

    It 'says where the game data and the overwrite folder''s textures came from' {
        $all = Find-Candidate
        $p = $all | Where-Object Name -eq 'Preston_d.dds'
        $p.Origin    | Should -Be 'GameData'
        $p.ModName   | Should -Be '(game data)'
        $p.MatchedBy | Should -Be 'vanilla texture set'
        $p.IsTintMask | Should -BeFalse
        ($all | Where-Object Name -eq 'FemaleHead_s.dds').Origin | Should -Be 'Overwrite'
    }

    It 'reports its progress once per source' {
        $calls = New-Object System.Collections.ArrayList
        [void] (Find-Candidate -Progress { param($done, $total, $name) [void] $calls.Add("$done/$total $name") }.GetNewClosure())
        @($calls) | Should -Be @('1/4 (game data)', '2/4 Alpha', '3/4 Bravo', '4/4 (overwrite)')
    }

    It 'reads the vanilla list itself when it is not given one' {
        Mock Import-BffVanillaFaceTextures { $vanilla }
        $found = @(Get-BffCandidate -Environment $i.Environment -Settings (New-TestSettings) -SlotRules $rules)
        $found.Count | Should -Be 4
        Should -Invoke Import-BffVanillaFaceTextures -Times 1 -Exactly -ParameterFilter { $Root -eq $i.Root }
    }
}

Describe 'Get-BffArchiveCandidate' {
    BeforeEach {
        $i = New-TestInstall
        New-TestFile (Join-Path $i.Mods 'Alpha\Alpha - Textures.ba2')
        New-TestFile (Join-Path $i.Mods 'Bravo\Bravo - Main.ba2')

        function New-TestEntry {
            param([string] $Path, [bool] $HasMetadata = $true)
            $e = New-Object BffArchiveEntry
            $e.InternalPath = $Path; $e.HasMetadata = $HasMetadata
            $e.Width = 2048; $e.Height = 2048; $e.Format = 'BC7_UNORM'; $e.MipLevels = 12
            return $e
        }

        $script:entries = @{
            'Alpha - Textures.ba2' = [pscustomobject]@{ Error = ''; Entries = @(
                (New-TestEntry 'textures/actors/character/basehumanmale/malehead_d.dds')
                (New-TestEntry 'textures\actors\character\basehumanmale\basemalebody_d.dds')
                (New-TestEntry 'Textures\Actors\Character\Character Assets\FaceDetails\Freckles_d.dds' -HasMetadata $false)
            ) }
            'Bravo - Main.ba2' = [pscustomobject]@{ Error = 'not a BA2 archive'; Entries = @() }
        }
        Mock Read-BffBa2Index { $script:entries[(Split-Path -Leaf $Path)] }
        Mock Read-BffBa2GnrlHeader { $true }

        function Find-ArchiveCandidate {
            param([scriptblock] $Progress)
            @(Get-BffArchiveCandidate -Environment $i.Environment -Settings (New-TestSettings) -SlotRules $rules `
                                      -VanillaFaceTextures $vanilla -Progress $Progress)
        }
    }

    It 'finds the face textures inside an archive, and reports one it could not read' {
        $found = Find-ArchiveCandidate
        $found.Count | Should -Be 3
        @($found | Where-Object Texture | ForEach-Object { $_.Texture.Name }) | Should -Be @('malehead_d.dds', 'Freckles_d.dds')
    }

    It 'asks the reader for character textures only' {
        [void] (Find-ArchiveCandidate)
        Should -Invoke Read-BffBa2Index -Times 2 -Exactly -ParameterFilter { $PathFilter -eq 'actors\\character\\' }
    }

    It 'describes an archive''s texture with what the file table says' {
        $hit = Find-ArchiveCandidate | Where-Object { $_.Texture -and $_.Texture.Name -eq 'malehead_d.dds' }
        $t = $hit.Texture
        $t.FullName     | Should -Be 'textures/actors/character/basehumanmale/malehead_d.dds'
        $t.RelativePath | Should -Be 'textures\actors\character\basehumanmale\malehead_d.dds'
        $t.ModName      | Should -Be 'Alpha'
        $t.Origin       | Should -Be 'BA2'
        $t.ArchivePath  | Should -Be (Join-Path $i.Mods 'Alpha\Alpha - Textures.ba2')
        $t.Slot         | Should -Be 'Diffuse'
        $t.MatchedBy    | Should -Be 'head name'
        $t.IsTintMask   | Should -BeFalse
        "$($t.Width)x$($t.Height) $($t.Format) $($t.MipLevels)" | Should -Be '2048x2048 BC7_UNORM 12'
        $hit.SourceKind | Should -Be 'Mod'
        $hit.Entry      | Should -Not -BeNullOrEmpty
        $hit.Error      | Should -Be ''
    }

    It 'reads the DDS header of an entry whose file table carries no size, and only that one' {
        $hit = Find-ArchiveCandidate | Where-Object { $_.Texture -and $_.Texture.Name -eq 'Freckles_d.dds' }
        $hit.Texture.IsTintMask | Should -BeTrue
        Should -Invoke Read-BffBa2GnrlHeader -Times 1 -Exactly -ParameterFilter { $Entry.InternalPath -like '*Freckles_d.dds' }
    }

    It 'keeps an archive it could not read as a finding, with the reason' {
        $bad = Find-ArchiveCandidate | Where-Object { -not $_.Texture }
        $bad.ModName     | Should -Be 'Bravo'
        $bad.ArchivePath | Should -Be (Join-Path $i.Mods 'Bravo\Bravo - Main.ba2')
        $bad.Error       | Should -Be 'not a BA2 archive'
    }

    It 'reports its progress once per source' {
        $calls = New-Object System.Collections.ArrayList
        [void] (Find-ArchiveCandidate -Progress { param($done, $total, $name) [void] $calls.Add("$done/$total $name") }.GetNewClosure())
        @($calls) | Should -Be @('1/4 (game data)', '2/4 Alpha', '3/4 Bravo', '4/4 (overwrite)')
    }

    It 'reads the vanilla list itself when it is not given one' {
        Mock Import-BffVanillaFaceTextures { $vanilla }
        @(Get-BffArchiveCandidate -Environment $i.Environment -Settings (New-TestSettings) -SlotRules $rules).Count |
            Should -Be 3
        Should -Invoke Import-BffVanillaFaceTextures -Times 1 -Exactly
    }
}
