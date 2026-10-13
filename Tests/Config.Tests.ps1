# Unit tests for Config.ps1 - loading the settings, the profiles and the slot
# rules, and mapping a file name onto a slot.
#
#   Invoke-Pester -Path .\Tests\Config.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Config.ps1'
#
# Pester 5. The files the tool ships are loaded once each, to show they load;
# everything about how they are read is tested on small ones written to TestDrive,
# so a change to the shipped settings cannot change what these tests expect.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    # A tool folder of its own, holding only the files a test writes into it.
    function New-TestRoot {
        $root = Join-Path $TestDrive ('root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($d in 'Config', 'Profiles', 'Rules') { [void] (New-Item -ItemType Directory -Path (Join-Path $root $d) -Force) }
        return $root
    }

    function Set-TestFile {
        param([string] $Root, [string] $Relative, [string] $Text)
        Set-Content -LiteralPath (Join-Path $Root $Relative) -Value $Text -Encoding UTF8
    }

    function New-TestProfileFile {
        param([string] $Root, [string] $File, [string] $Name, [string] $Sizes = 'Diffuse = 1024; Normal = 1024; Specular = 512')
        Set-TestFile $Root "Profiles\$File" "@{ Name = '$Name'; Description = 'test'; Sizes = @{ $Sizes }; F4EE = @{ uTintWidth = 1024; uTintHeight = 1024 } }"
    }

    function New-TestRules {
        param([string] $DefaultSlot = 'Diffuse')
        $rules = New-Object System.Collections.Generic.List[object]
        foreach ($r in @(
            @{ Slot = 'Specular'; Suffixes = @('_s', '_spec', '_specular') }
            @{ Slot = 'Skin';     Suffixes = @('_sk', '_sss', '_c') }
            @{ Slot = 'Diffuse';  Suffixes = @('_d', '') }
        )) {
            $rule = New-Object BffSlotRule
            $rule.Slot = $r.Slot; $rule.Suffixes = $r.Suffixes
            $rules.Add($rule)
        }
        return [pscustomobject]@{ Rules = $rules; DefaultSlot = $DefaultSlot }
    }
}

Describe 'Get-BffRoot' {
    It 'is the Black Face Fix folder, two above the library' {
        Get-BffRoot | Should -Be $tool
    }
}

Describe 'Import-BffSettings' {
    It 'loads the settings the tool ships' {
        $s = Import-BffSettings -Root $tool
        $s.Output.Mode | Should -Not -BeNullOrEmpty
        $s.Conversion.ContainsKey('ForceVanillaFormats') | Should -BeTrue
    }

    It 'loads them from next to the tool when not given a root' {
        $root = New-TestRoot
        Set-TestFile $root 'Config\Settings.psd1' "@{ Profile = 'HD DLC' }"
        Mock Get-BffRoot { $root }
        (Import-BffSettings).Profile | Should -Be 'HD DLC'
    }

    It 'fills in whole sections a settings file leaves out' {
        $root = New-TestRoot
        Set-TestFile $root 'Config\Settings.psd1' '@{}'
        $s = Import-BffSettings -Root $root
        $s.Profile             | Should -Be 'Auto'
        $s.Output.Mode         | Should -Be 'OutputMod'
        $s.Conversion.MinSize  | Should -Be 256
        $s.Logging.Debug       | Should -BeFalse
    }

    It 'fills in single keys a section leaves out, and keeps the ones it has' {
        $root = New-TestRoot
        Set-TestFile $root 'Config\Settings.psd1' "@{ Output = @{ Mode = 'InPlace' } }"
        $s = Import-BffSettings -Root $root
        $s.Output.Mode         | Should -Be 'InPlace'
        $s.Output.BackupSuffix | Should -Be '.backup'
    }

    It 'lets Settings.local.psd1 change single keys, and replace values that are not sections' {
        $root = New-TestRoot
        Set-TestFile $root 'Config\Settings.psd1' "@{ Profile = 'Auto'; Paths = @{ MO2 = 'C:\Shipped' } }"
        Set-TestFile $root 'Config\Settings.local.psd1' "@{ Profile = '4K'; Paths = @{ MO2 = 'D:\Mine' }; Extra = 1 }"
        $s = Import-BffSettings -Root $root
        $s.Profile        | Should -Be '4K'
        $s.Paths.MO2      | Should -Be 'D:\Mine'
        $s.Paths.Fallout4 | Should -Be ''
        $s.Extra          | Should -Be 1
    }

    It 'says where it looked when there is no settings file' {
        $root = New-TestRoot
        { Import-BffSettings -Root $root } | Should -Throw -ExpectedMessage "Settings.psd1 not found at '$root\Config\Settings.psd1'."
    }
}

Describe 'Get-BffProfileList' {
    It 'loads the four profiles the tool ships, sorted by file' {
        @(Get-BffProfileList -Root $tool | ForEach-Object Name) | Should -Be @('2K', '4K', 'HD DLC', 'Vanilla')
    }

    It 'reads every field, and remembers where it came from' {
        $root = New-TestRoot
        New-TestProfileFile $root 'Test.psd1' 'Test' 'Diffuse = 2048; Other = 512'
        $p = @(Get-BffProfileList -Root $root)[0]
        $p.Name             | Should -Be 'Test'
        $p.Description      | Should -Be 'test'
        $p.Sizes.Diffuse    | Should -Be 2048
        $p.SizeFor('Other') | Should -Be 512
        $p.F4EE.uTintWidth  | Should -Be 1024
        $p.SourcePath       | Should -Be (Join-Path $root 'Profiles\Test.psd1')
    }

    It 'sizes the slots a profile does not name like its diffuse' {
        $root = New-TestRoot
        New-TestProfileFile $root 'Test.psd1' 'Test' 'Diffuse = 2048'
        (@(Get-BffProfileList -Root $root)[0]).SizeFor('Glow') | Should -Be 2048
    }

    It 'loads them from next to the tool when not given a root' {
        Mock Get-BffRoot { $tool }
        @(Get-BffProfileList).Count | Should -Be 4
    }

    It 'says so when the profiles folder is missing' {
        $root = New-TestRoot
        Remove-Item -LiteralPath (Join-Path $root 'Profiles')
        { Get-BffProfileList -Root $root } | Should -Throw -ExpectedMessage "Profiles folder not found at '*'."
    }

    It 'says so when the profiles folder is empty' {
        { Get-BffProfileList -Root (New-TestRoot) } | Should -Throw -ExpectedMessage "No profiles found in '*'."
    }
}

Describe 'Get-BffProfile' {
    It 'finds a profile by its name or by its file name' -TestCases @(
        @{ Asked = 'HD DLC' }, @{ Asked = 'HD-DLC' }, @{ Asked = ' HD DLC ' }
    ) {
        (Get-BffProfile -Name $Asked -Root $tool).Name | Should -Be 'HD DLC'
    }

    It 'finds a profile whose name differs from its file' {
        $root = New-TestRoot
        New-TestProfileFile $root 'Ultra-Wide.psd1' 'Big Heads'
        (Get-BffProfile -Name 'Ultra-Wide' -Root $root).Name | Should -Be 'Big Heads'
        (Get-BffProfile -Name 'Big Heads' -Root $root).Name  | Should -Be 'Big Heads'
    }

    It 'names the profiles there are when asked for one that is not' {
        { Get-BffProfile -Name '8K' -Root $tool } | Should -Throw -ExpectedMessage "Unknown profile '8K'. Available: 2K, 4K, HD DLC, Vanilla."
    }

    It 'looks next to the tool when not given a root' {
        Mock Get-BffRoot { $tool }
        (Get-BffProfile -Name 'Vanilla').Name | Should -Be 'Vanilla'
    }
}

Describe 'Import-BffSlotRules' {
    It 'loads the rules the tool ships' {
        $r = Import-BffSlotRules -Root $tool
        @($r.Rules | ForEach-Object Slot) | Should -Contain 'Specular'
        $r.DefaultSlot | Should -Be 'Diffuse'
        $r.TintExtraFormats | Should -Contain 'BC4_UNORM'
        ($r.Rules | Where-Object Slot -eq 'Skin').EnforceSize     | Should -BeFalse
        ($r.Rules | Where-Object Slot -eq 'Specular').EnforceSize | Should -BeTrue
    }

    It 'enforces the size of a slot unless it opts out, and allows no extra formats unless listed' {
        $root = New-TestRoot
        Set-TestFile $root 'Rules\SlotRules.psd1' @'
@{
    Slots = @(
        @{ Slot = 'Normal'; Suffixes = '_n'; AllowedFormats = 'BC5_UNORM'; DefaultFormat = 'BC5_UNORM' }
    )
    DefaultSlot = 'Normal'
}
'@
        $r = Import-BffSlotRules -Root $root
        $r.Rules[0].EnforceSize     | Should -BeTrue
        $r.Rules[0].Suffixes        | Should -Be @('_n')
        $r.Rules[0].AllowedFormats  | Should -Be @('BC5_UNORM')
        $r.Rules[0].DefaultFormat   | Should -Be 'BC5_UNORM'
        @($r.TintExtraFormats).Count | Should -Be 0
    }

    It 'loads them from next to the tool when not given a root' {
        Mock Get-BffRoot { $tool }
        (Import-BffSlotRules).DefaultSlot | Should -Be 'Diffuse'
    }

    It 'says where it looked when there is no rules file' {
        { Import-BffSlotRules -Root (New-TestRoot) } | Should -Throw -ExpectedMessage "SlotRules.psd1 not found at '*\Rules\SlotRules.psd1'."
    }
}

Describe 'Get-BffFileSuffix' {
    It 'finds the suffix before the extension, lower-cased' -TestCases @(
        @{ Name = 'AGCP Beauty Mark 1_d.DDS'; Suffix = '_d' }
        @{ Name = 'MaleHead_SSS.DDS';         Suffix = '_sss' }
        @{ Name = 'Face_Specular.dds';        Suffix = '_specular' }
        @{ Name = 'AGCP Crescent.dds';        Suffix = '' }
        @{ Name = 'EyeLinerThin1.DDS';        Suffix = '' }
        @{ Name = 'Facepaint_41.dds';         Suffix = '' }
    ) {
        Get-BffFileSuffix -FileName $Name | Should -Be $Suffix
    }
}

Describe 'Resolve-BffSlot' {
    It 'maps a suffix onto its slot' {
        (Resolve-BffSlot -FileName 'MaleHead_s.dds' -SlotRules (New-TestRules)).Slot | Should -Be 'Specular'
    }

    It 'never lets a short suffix shadow a longer one' {
        (Resolve-BffSlot -FileName 'MaleHead_sss.dds' -SlotRules (New-TestRules)).Slot | Should -Be 'Skin'
    }

    It 'takes the default slot for a suffix no rule knows' {
        (Resolve-BffSlot -FileName 'MaleHead_glow.dds' -SlotRules (New-TestRules)).Slot | Should -Be 'Diffuse'
    }

    It 'says so when the default slot does not exist either' {
        { Resolve-BffSlot -FileName 'MaleHead_glow.dds' -SlotRules (New-TestRules -DefaultSlot 'Glow') } |
            Should -Throw -ExpectedMessage "No slot rule matched 'MaleHead_glow.dds' and DefaultSlot 'Glow' does not exist."
    }
}
