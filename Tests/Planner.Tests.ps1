# Unit tests for Planner.ps1 - what happens to each texture, and why.
#
#   Invoke-Pester -Path .\Tests\Planner.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Planner.ps1'
#
# Pester 5. The planner is decided against the slot rules the tool ships, read
# from Rules\SlotRules.psd1, because those rules are what a plan has to be right
# about: a 1024 specular going to 512 BC5 is a fact about Fallout 4, not about
# a fixture. Settings and the profile are built here, so a change to the default
# settings cannot quietly change what these tests expect.
#
# texdiag is never run: Update-BffPlanForExistingOutput is fed what texdiag
# would have said. Files the planner writes go to Pester's TestDrive.
#
# Type names are given as strings - New-Object BffTexture rather than
# [BffTexture]::new() - because a type literal in this file is resolved when the
# file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'TexInfo', 'Planner') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    $rules = Import-BffSlotRules -Root $tool

    # The vanilla sizes. No size for Skin, so it falls through to Other.
    $testProfile = New-Object BffProfile
    $testProfile.Name  = 'Vanilla'
    $testProfile.Sizes = @{ Diffuse = 1024; Normal = 1024; Specular = 512; ModelSpaceNormal = 1024; Other = 1024 }

    function New-TestSettings {
        return @{
            Conversion = @{ RequireSquare = $true; MinSize = 256; ForceVanillaFormats = $false }
            Output     = @{
                Mode                = 'OutputMod'
                OutputModNameFormat = '{0} [face-{1}]'
                GameDataModName     = 'Fallout 4 Data'
                OverwriteModName    = 'MO2 Overwrite'
            }
        }
    }

    function New-TestTexture {
        param(
            [string] $Slot   = 'Diffuse',
            [int]    $Width  = 1024,
            [int]    $Height = $Width,
            [string] $Format = 'BC7_UNORM',
            [bool]   $Tint   = $false,
            [string] $Mod    = 'Alpha',
            [string] $Rel    = 'textures\actors\character\BaseHumanMale\MaleHead_d.dds',
            [string] $Origin = 'Loose'
        )
        $t = New-Object BffTexture
        $t.Slot = $Slot; $t.Width = $Width; $t.Height = $Height; $t.Format = $Format
        $t.IsTintMask = $Tint; $t.ModName = $Mod; $t.RelativePath = $Rel; $t.Origin = $Origin
        $t.Name     = Split-Path -Leaf $Rel
        $t.FullName = if ($Origin -eq 'BA2') { $Rel } else { "C:\MO2\mods\$Mod\$Rel" }
        return $t
    }

    function Get-TestPlan {
        param($Texture, [switch] $Force, [hashtable] $Settings = (New-TestSettings), $Rules = $rules)
        return New-BffPlan -Texture $Texture -Profile $testProfile -SlotRules $Rules -Settings $Settings -Force:$Force
    }

    function New-TestEnvironment {
        param([string] $ModsPath = 'C:\MO2\mods')
        return [pscustomobject]@{
            Profile = $testProfile
            MO2     = if ($ModsPath) { [pscustomobject]@{ ModsPath = $ModsPath } } else { $null }
            Root    = 'C:\Tools\Black Face Fix'
        }
    }

    function New-TestPlanFor {
        param([string] $Action, [string] $Destination, $Texture = (New-TestTexture),
              [int] $Width = 1024, [string] $Format = 'BC3_UNORM')
        $p = New-Object BffPlan
        $p.Texture = $Texture; $p.Action = $Action; $p.Destination = $Destination
        $p.TargetWidth = $Width; $p.TargetHeight = $Width; $p.TargetFormat = $Format
        return $p
    }
}

Describe 'New-BffPlan' {

    Context 'what it refuses to plan' {
        It 'gives up on a slot the rules do not know' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Glow')
            $p.Action | Should -Be 'Error'
            $p.Error  | Should -Be "no slot rule for slot 'Glow'"
            $p.Reason | Should -Be $p.Error
        }

        It 'gives up on a texture whose size could not be read' {
            $p = Get-TestPlan (New-TestTexture -Width 0 -Height 0)
            $p.Action | Should -Be 'Error'
            $p.Error  | Should -Be 'no dimensions could be read'
        }

        It 'only reports a texture that is not square, and keeps it as it is' {
            $p = Get-TestPlan (New-TestTexture -Width 64 -Height 128 -Format 'BC6H_UF16')
            $p.Action | Should -Be 'Review'
            $p.TargetWidth  | Should -Be 64
            $p.TargetHeight | Should -Be 128
            $p.TargetFormat | Should -Be 'BC6H_UF16'
            $p.Reason | Should -BeLike 'Diffuse: 64x128 BC6H_UF16 is not square, so it is left alone.*palette strip.'
        }

        It 'plans a texture that is not square when squareness is not required' {
            $settings = New-TestSettings
            $settings.Conversion.RequireSquare = $false
            $p = Get-TestPlan (New-TestTexture -Width 2048 -Height 1024) -Settings $settings
            $p.Action | Should -Be 'Resize'
            $p.TargetHeight | Should -Be 1024
        }

        It 'only reports a texture below the safety floor' {
            $p = Get-TestPlan (New-TestTexture -Width 128 -Format 'R8G8B8A8_UNORM')
            $p.Action | Should -Be 'Review'
            $p.TargetWidth  | Should -Be 128
            $p.TargetFormat | Should -Be 'R8G8B8A8_UNORM'
            $p.Reason | Should -Be 'Diffuse: 128x128 R8G8B8A8_UNORM is below the 256px safety floor, so it is left alone.'
        }
    }

    Context 'a texture that is already right' {
        It 'is skipped, and says what it matched' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 512 -Format 'BC5_UNORM')
            $p.Action   | Should -Be 'Skip'
            $p.SizeOk   | Should -BeTrue
            $p.FormatOk | Should -BeTrue
            $p.Reason   | Should -Be "already correct: 512x512 BC5_UNORM matches profile 'Vanilla'"
        }

        It 'says both halves are fine, for the window''s two marks' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 512 -Format 'BC5_UNORM')
            $p.SizeReason   | Should -Be "size 512x512 already matches profile 'Vanilla'"
            $p.FormatReason | Should -Be 'BC5_UNORM is valid for a specular map and is kept'
        }

        It 'is re-encoded anyway with -Force, and says that is why' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 512 -Format 'BC5_UNORM') -Force
            $p.Action | Should -Be 'Reformat'
            $p.TargetFormat | Should -Be 'BC5_UNORM'
            $p.Reason | Should -Be 'already correct (512x512 BC5_UNORM), but -Force was given'
        }

        It 'keeps every diffuse format the game or the CK uses' -TestCases @(
            @{ Format = 'BC1_UNORM' }, @{ Format = 'BC3_UNORM' }, @{ Format = 'BC7_UNORM' }, @{ Format = 'BC7_UNORM_SRGB' }
        ) {
            (Get-TestPlan (New-TestTexture -Format $Format)).Action | Should -Be 'Skip'
        }
    }

    Context 'the size' {
        It 'scales a specular down to the profile' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 1024 -Format 'BC5_UNORM')
            $p.Action | Should -Be 'Resize'
            $p.TargetWidth  | Should -Be 512
            $p.TargetHeight | Should -Be 512
            $p.TargetFormat | Should -Be 'BC5_UNORM'
            $p.SizeReason | Should -Be "profile 'Vanilla' wants specular at 512x512, this is 1024x1024, so it is scaled down to 512x512"
            $p.Reason | Should -Be ($p.SizeReason + '; format BC5_UNORM is already valid and is kept')
        }

        It 'scales a texture smaller than the profile up' {
            $p = Get-TestPlan (New-TestTexture -Width 512)
            $p.Action | Should -Be 'Resize'
            $p.SizeReason | Should -BeLike '*so it is scaled up to 1024x1024'
        }

        It 'leaves the size of a skin map alone, whatever the profile says' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Skin' -Width 2048 -Format 'BC7_UNORM')
            $p.Action | Should -Be 'Skip'
            $p.TargetWidth | Should -Be 2048
            $p.SizeReason | Should -Be '2048x2048 is left as it is - skin maps take no part in the head/tint matching'
            $p.Reason | Should -Be 'Skin: 2048x2048 BC7_UNORM left as is - skin maps take no part in the head/tint matching'
        }

        It 'still re-encodes a skin map when forced, at its own size' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Skin' -Width 2048 -Format 'BC7_UNORM') -Force
            $p.Action | Should -Be 'Reformat'
            $p.TargetWidth | Should -Be 2048
        }
    }

    Context 'the format' {
        It 're-encodes a format the slot does not take, to the slot''s default' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 512 -Format 'BC7_UNORM')
            $p.Action | Should -Be 'Reformat'
            $p.TargetFormat | Should -Be 'BC5_UNORM'
            $p.FormatReason | Should -Be ('BC7_UNORM is not valid for a specular map (allowed: BC5_UNORM, BC5_SNORM), ' +
                                          'so it is re-encoded as BC5_UNORM')
            $p.Reason | Should -Be ('size 512x512 is already correct; ' + $p.FormatReason)
        }

        It 'does both in one go when size and format are wrong' {
            $p = Get-TestPlan (New-TestTexture -Slot 'Specular' -Width 1024 -Format 'BC7_UNORM')
            $p.Action | Should -Be 'ResizeAndReformat'
            $p.TargetWidth  | Should -Be 512
            $p.TargetFormat | Should -Be 'BC5_UNORM'
            $p.Reason | Should -Be ($p.SizeReason + '; ' + $p.FormatReason)
        }

        It 'never picks a floating point format for a diffuse' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC6H_SF16')
            $p.TargetFormat | Should -Be 'BC3_UNORM'
        }

        It 'takes any format for a skin map' {
            (Get-TestPlan (New-TestTexture -Slot 'Skin' -Format 'BC6H_UF16')).FormatOk | Should -BeTrue
        }
    }

    Context 'tint masks' {
        It 'keeps a single channel mask under FaceDetails or TintMasks' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC4_UNORM' -Tint $true)
            $p.Action | Should -Be 'Skip'
            $p.TargetFormat | Should -Be 'BC4_UNORM'
        }

        It 'does not extend that to a head diffuse' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC4_UNORM')
            $p.Action | Should -Be 'Reformat'
            $p.FormatReason | Should -Not -BeLike '*allowed:*BC4*' -Because 'the allowed list for a head has no BC4 in it'
            $p.FormatReason | Should -BeLike 'BC4_UNORM is not valid for a diffuse map (allowed: BC1_UNORM,*BC7_UNORM_SRGB), so*'
        }

        It 'names the mask formats among the allowed ones when a mask is re-encoded' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC6H_UF16' -Tint $true)
            $p.FormatReason | Should -BeLike '*BC7_UNORM_SRGB, BC4_UNORM, BC4_SNORM), so it is re-encoded as BC3_UNORM'
        }

        It 'treats a mask like any texture when the rules list no extra formats' {
            $bare = [pscustomobject]@{ Rules = $rules.Rules; DefaultSlot = 'Diffuse' }
            $p = Get-TestPlan (New-TestTexture -Format 'BC4_UNORM' -Tint $true) -Rules $bare
            $p.Action | Should -Be 'Reformat'
        }
    }

    Context 'with ForceVanillaFormats' {
        BeforeEach {
            $vanilla = New-TestSettings
            $vanilla.Conversion.ForceVanillaFormats = $true
        }

        It 're-encodes a legal format that is not the one the game ships' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC7_UNORM') -Settings $vanilla
            $p.Action | Should -Be 'Reformat'
            $p.TargetFormat | Should -Be 'BC3_UNORM'
            $p.FormatReason | Should -Be ('BC7_UNORM is re-encoded as BC3_UNORM: Fallout 4 ships every diffuse map as BC3_UNORM, ' +
                                          'and one texture array cannot hold two formats (Conversion.ForceVanillaFormats)')
        }

        It 'keeps the format the game ships' {
            (Get-TestPlan (New-TestTexture -Format 'BC3_UNORM') -Settings $vanilla).Action | Should -Be 'Skip'
        }

        It 'no longer spares a single channel mask' {
            $p = Get-TestPlan (New-TestTexture -Format 'BC4_UNORM' -Tint $true) -Settings $vanilla
            $p.TargetFormat | Should -Be 'BC3_UNORM'
        }

        It 'leaves a slot that takes any format out of it' {
            (Get-TestPlan (New-TestTexture -Slot 'Skin' -Format 'BC7_UNORM') -Settings $vanilla).Action | Should -Be 'Skip'
        }
    }
}

Describe 'New-BffPlanSet' {
    It 'plans every texture, and gives a destination only to the ones that change' {
        $plans = @(New-BffPlanSet -Texture @(
                       (New-TestTexture -Format 'BC3_UNORM'),
                       (New-TestTexture -Width 2048 -Mod 'Bravo')) `
                   -Profile $testProfile -SlotRules $rules -Settings (New-TestSettings) -Environment (New-TestEnvironment))
        $plans.Count | Should -Be 2
        $plans[0].Action      | Should -Be 'Skip'
        $plans[0].Destination | Should -BeNullOrEmpty
        $plans[1].Action      | Should -Be 'Resize'
        $plans[1].Destination | Should -Be 'C:\MO2\mods\Bravo [face-Vanilla]\textures\actors\character\BaseHumanMale\MaleHead_d.dds'
    }

    It 'takes a single texture as well as a list' {
        @(New-BffPlanSet -Texture (New-TestTexture) -Profile $testProfile -SlotRules $rules `
                         -Settings (New-TestSettings) -Environment (New-TestEnvironment)).Count | Should -Be 1
    }

    It 'passes -Force on' {
        $p = @(New-BffPlanSet -Texture (New-TestTexture -Format 'BC3_UNORM') -Profile $testProfile -SlotRules $rules `
                              -Settings (New-TestSettings) -Environment (New-TestEnvironment) -Force)
        $p[0].Action | Should -Be 'Reformat'
    }

    It 'refuses an output path Windows could not write, and says how to fix it' {
        $deep = New-TestEnvironment -ModsPath ('C:\' + ('x' * 200))
        $p = @(New-BffPlanSet -Texture (New-TestTexture -Width 2048) -Profile $testProfile -SlotRules $rules `
                              -Settings (New-TestSettings) -Environment $deep)
        $p[0].Action | Should -Be 'Error'
        $p[0].Error  | Should -Match '^the output path would be \d+ characters, over the Windows limit of 260$'
        $p[0].Reason | Should -BeLike '*Shorten Output.OutputModNameFormat*'
    }
}

Describe 'Get-BffOutputModName' {
    It 'names the output after its source mod and the profile' {
        Get-BffOutputModName -ModName 'Alpha' -ProfileName 'HD DLC' -Settings (New-TestSettings) |
            Should -Be 'Alpha [face-HD DLC]'
    }

    It 'gives a readable name to sources that are not mods' -TestCases @(
        @{ Source = '(game data)'; Expected = 'Fallout 4 Data [face-Vanilla]' }
        @{ Source = '(overwrite)'; Expected = 'MO2 Overwrite [face-Vanilla]' }
    ) {
        Get-BffOutputModName -ModName $Source -ProfileName 'Vanilla' -Settings (New-TestSettings) | Should -Be $Expected
    }

    It 'drops what Windows will not take in a folder name' {
        $settings = New-TestSettings
        $settings.Output.OutputModNameFormat = '{0} [face:{1}]'
        Get-BffOutputModName -ModName 'Alpha' -ProfileName 'A/B' -Settings $settings | Should -Be 'Alpha [faceAB]'
    }

    It 'trims what is left' {
        $settings = New-TestSettings
        $settings.Output.OutputModNameFormat = ' {0} {1} '
        Get-BffOutputModName -ModName 'Alpha' -ProfileName 'Vanilla' -Settings $settings | Should -Be 'Alpha Vanilla'
    }
}

Describe 'the output marker' {
    It 'is a file of its own name' {
        Get-BffOutputMarkerName | Should -Be 'BlackFaceFix-generated.txt'
    }

    It 'is created, with its folder, and says what the folder is' {
        # No brackets in the name, though real output has them: Pester's TestDrive
        # cleanup reads them as a wildcard and fails the whole file.
        $root = Join-Path $TestDrive 'Alpha face-Vanilla'
        $path = New-BffOutputMarker -ModRoot $root -SourceMod 'Alpha' -ProfileName 'Vanilla'
        $path | Should -Be (Join-Path $root 'BlackFaceFix-generated.txt')
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'Source mod : Alpha'
        $text | Should -Match 'Profile    : Vanilla'
        $text | Should -Match 'Created    : \d{4}-\d\d-\d\d \d\d:\d\d'
    }

    It 'is written without a byte order mark' {
        $path  = New-BffOutputMarker -ModRoot (Join-Path $TestDrive 'NoBom')
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'G')
    }

    It 'is left alone when it is already there' {
        $root = Join-Path $TestDrive 'Existing'
        $path = New-BffOutputMarker -ModRoot $root -SourceMod 'First'
        [System.IO.File]::WriteAllText($path, 'kept')
        New-BffOutputMarker -ModRoot $root -SourceMod 'Second' | Should -Be $path
        Get-Content -LiteralPath $path -Raw | Should -Be 'kept'
    }

    It 'marks a folder as generated, and only that folder' {
        $root = Join-Path $TestDrive 'Marked'
        [void] (New-BffOutputMarker -ModRoot $root)
        Test-BffOutputMod -Path $root | Should -BeTrue
        Test-BffOutputMod -Path $TestDrive | Should -BeFalse
    }
}

Describe 'Get-BffOutputModPattern' {
    It 'matches the older long name' {
        'Alpha - face textures resized for Vanilla' | Should -Match (Get-BffOutputModPattern -Settings (New-TestSettings))
    }

    It 'leaves current output and ordinary mods to the marker' -TestCases @(
        @{ Name = 'Alpha [face-Vanilla]' }, @{ Name = 'Some Armour [2K]' }
    ) {
        $Name | Should -Not -Match (Get-BffOutputModPattern -Settings (New-TestSettings) -Root $tool)
    }
}

Describe 'Get-BffOutputModRoot and Get-BffOutputModDisplayName' {
    It 'cut the texture''s own path off the destination' {
        $p = New-TestPlanFor -Action 'Resize' `
                             -Destination 'C:\MO2\mods\Alpha [face-Vanilla]\textures\actors\character\BaseHumanMale\MaleHead_d.dds'
        Get-BffOutputModRoot -Plan $p | Should -Be 'C:\MO2\mods\Alpha [face-Vanilla]'
        Get-BffOutputModDisplayName -Plan $p | Should -Be 'Alpha [face-Vanilla]'
    }

    It 'are not fooled by a texture in a folder named after a plugin' {
        $rel = 'textures\actors\character\FaceCustomization\Some.esp\00001234_d.dds'
        $p = New-TestPlanFor -Action 'Resize' -Texture (New-TestTexture -Rel $rel) `
                             -Destination "C:\MO2\mods\Alpha [face-Vanilla]\$rel"
        Get-BffOutputModDisplayName -Plan $p | Should -Be 'Alpha [face-Vanilla]'
    }

    It 'ignore case, as Windows does' {
        $p = New-TestPlanFor -Action 'Resize' `
                             -Destination 'C:\MO2\mods\Alpha [face-Vanilla]\TEXTURES\Actors\Character\BaseHumanMale\malehead_d.DDS'
        Get-BffOutputModRoot -Plan $p | Should -Be 'C:\MO2\mods\Alpha [face-Vanilla]'
    }

    It 'fall back to the folder the file is in when the destination does not end in its path' {
        $p = New-TestPlanFor -Action 'Resize' -Destination 'C:\Elsewhere\MaleHead_d.dds'
        Get-BffOutputModRoot -Plan $p | Should -Be 'C:\Elsewhere'
    }

    It 'are empty for a plan that writes nothing' {
        $p = New-TestPlanFor -Action 'Skip' -Destination ''
        Get-BffOutputModRoot -Plan $p        | Should -Be ''
        Get-BffOutputModDisplayName -Plan $p | Should -Be ''
    }
}

Describe 'Get-BffDestination' {
    It 'writes into an output mod named after the source, under Mod Organizer''s mods' {
        Get-BffDestination -Texture (New-TestTexture) -Settings (New-TestSettings) -Environment (New-TestEnvironment) |
            Should -Be 'C:\MO2\mods\Alpha [face-Vanilla]\textures\actors\character\BaseHumanMale\MaleHead_d.dds'
    }

    It 'writes next to the tool when there is no Mod Organizer' {
        Get-BffDestination -Texture (New-TestTexture) -Settings (New-TestSettings) -Environment (New-TestEnvironment -ModsPath '') |
            Should -Be 'C:\Tools\Black Face Fix\Output\Alpha [face-Vanilla]\textures\actors\character\BaseHumanMale\MaleHead_d.dds'
    }

    It 'writes over the source in place' {
        $settings = New-TestSettings
        $settings.Output.Mode = 'InPlace'
        $t = New-TestTexture
        Get-BffDestination -Texture $t -Settings $settings -Environment (New-TestEnvironment) | Should -Be $t.FullName
    }

    It 'still writes an archive''s texture to an output mod in place, since an archive cannot be written into' {
        $settings = New-TestSettings
        $settings.Output.Mode = 'InPlace'
        $t = New-TestTexture -Origin 'BA2'
        Get-BffDestination -Texture $t -Settings $settings -Environment (New-TestEnvironment) |
            Should -BeLike 'C:\MO2\mods\Alpha `[face-Vanilla`]\textures\*'
    }
}

Describe 'Update-BffPlanForExistingOutput' {
    BeforeEach {
        $out = Join-Path $TestDrive 'out_d.dds'
        Set-Content -LiteralPath $out -Value 'x'
        $script:info = @()
        Mock Get-BffTextureInfo { $script:info }
    }

    It 'skips work an earlier run already did' {
        $p = New-TestPlanFor -Action 'Resize' -Destination $out
        $script:info = @([pscustomobject]@{ Path = $out; Ok = $true; Width = 1024; Height = 1024; Format = 'BC3_UNORM' })
        $r = @(Update-BffPlanForExistingOutput -Plan @($p) -TexDiagPath 'texdiag.exe')
        $r[0].Action | Should -Be 'Skip'
        $r[0].Reason | Should -Be 'an earlier run already produced this: the output mod holds a 1024x1024 BC3_UNORM copy'
    }

    It 'matches texdiag''s echo of the path however it spells it' {
        $p = New-TestPlanFor -Action 'Resize' -Destination $out
        $script:info = @([pscustomobject]@{ Path = $out.ToUpperInvariant().Replace('\', '/'); Ok = $true
                                            Width = 1024; Height = 1024; Format = 'BC3_UNORM' })
        (@(Update-BffPlanForExistingOutput -Plan @($p) -TexDiagPath 'texdiag.exe'))[0].Action | Should -Be 'Skip'
    }

    It 'redoes an output that does not match the plan' -TestCases @(
        @{ Width = 512;  Height = 512;  Format = 'BC3_UNORM' }
        @{ Width = 1024; Height = 512;  Format = 'BC3_UNORM' }
        @{ Width = 1024; Height = 1024; Format = 'BC7_UNORM' }
    ) {
        $p = New-TestPlanFor -Action 'Resize' -Destination $out
        $script:info = @([pscustomobject]@{ Path = $out; Ok = $true; Width = $Width; Height = $Height; Format = $Format })
        (@(Update-BffPlanForExistingOutput -Plan @($p) -TexDiagPath 'texdiag.exe'))[0].Action | Should -Be 'Resize'
    }

    It 'redoes an output texdiag could not read, or did not report' {
        $a = New-TestPlanFor -Action 'Resize' -Destination $out
        $b = New-TestPlanFor -Action 'Resize' -Destination (Join-Path $TestDrive 'other_d.dds')
        Set-Content -LiteralPath $b.Destination -Value 'x'
        $script:info = @([pscustomobject]@{ Path = $out; Ok = $false; Width = 1024; Height = 1024; Format = 'BC3_UNORM' })
        $r = @(Update-BffPlanForExistingOutput -Plan @($a, $b) -TexDiagPath 'texdiag.exe')
        $r.Action | Should -Be @('Resize', 'Resize')
    }

    It 'does not ask texdiag about plans with nothing to compare' {
        $plans = @(
            (New-TestPlanFor -Action 'Skip'   -Destination $out)
            (New-TestPlanFor -Action 'Resize' -Destination '')
            (New-TestPlanFor -Action 'Resize' -Destination (Join-Path $TestDrive 'missing_d.dds'))
        )
        # In place: the destination is the source, which says nothing about earlier runs.
        $inPlace = New-TestPlanFor -Action 'Resize' -Destination ''
        $inPlace.Destination = $inPlace.Texture.FullName
        $plans += $inPlace

        $r = @(Update-BffPlanForExistingOutput -Plan $plans -TexDiagPath 'texdiag.exe')
        $r.Count | Should -Be 4
        Should -Invoke Get-BffTextureInfo -Times 0 -Exactly
    }

    It 'finds texdiag itself when it is not told where it is' {
        Mock Get-BffTexDiagPath { 'C:\found\texdiag.exe' }
        [void] (Update-BffPlanForExistingOutput -Plan @(New-TestPlanFor -Action 'Resize' -Destination $out))
        Should -Invoke Get-BffTextureInfo -Times 1 -Exactly -ParameterFilter { $TexDiagPath -eq 'C:\found\texdiag.exe' }
    }
}

Describe 'Get-BffPlanSummary' {
    BeforeAll {
        function New-SummaryPlan {
            param([string] $Action, [string] $Slot = 'Diffuse', [string] $Mod = 'Alpha')
            New-TestPlanFor -Action $Action -Destination '' -Texture (New-TestTexture -Slot $Slot -Mod $Mod)
        }
    }

    It 'counts every outcome' {
        $s = Get-BffPlanSummary -Plan @(
            (New-SummaryPlan 'Resize'), (New-SummaryPlan 'Reformat'), (New-SummaryPlan 'ResizeAndReformat'),
            (New-SummaryPlan 'Skip'), (New-SummaryPlan 'Skip'), (New-SummaryPlan 'Review'), (New-SummaryPlan 'Error'))
        $s.Total    | Should -Be 7
        $s.Changing | Should -Be 3
        $s.Skipped  | Should -Be 2
        $s.Review   | Should -Be 1
        $s.Failed   | Should -Be 1
    }

    It 'puts the most common action first' {
        $s = Get-BffPlanSummary -Plan @((New-SummaryPlan 'Resize'), (New-SummaryPlan 'Skip'), (New-SummaryPlan 'Skip'))
        $s.ByAction[0].Action | Should -Be 'Skip'
        $s.ByAction[0].Count  | Should -Be 2
    }

    It 'counts only the work per slot and per mod' {
        $s = Get-BffPlanSummary -Plan @(
            (New-SummaryPlan 'Resize' -Slot 'Specular' -Mod 'Alpha'),
            (New-SummaryPlan 'Resize' -Slot 'Specular' -Mod 'Bravo'),
            (New-SummaryPlan 'Reformat' -Slot 'Diffuse' -Mod 'Bravo'),
            (New-SummaryPlan 'Skip' -Slot 'Normal' -Mod 'Charlie'))
        @($s.BySlot | ForEach-Object { '{0}={1}' -f $_.Slot, $_.Count }) | Should -Be @('Specular=2', 'Diffuse=1')
        @($s.ByMod)[0].Mod   | Should -Be 'Bravo'
        @($s.ByMod)[0].Count | Should -Be 2
        @($s.ByMod).Mod      | Should -Not -Contain 'Charlie'
    }
}
