# Unit tests for Convert.ps1 - running texconv, checking what it made, and
# putting it where the plan says.
#
#   Invoke-Pester -Path .\Tests\Convert.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Convert.ps1'
#
# Pester 5. texconv and texdiag are stood in for by two functions, which the code
# calls by name exactly as it calls the exes ('& $TexConvPath ...'). They work as
# a pair: the fake texconv writes, for every input, a small text file saying the
# size and format it was asked for - "FAKEDDS w=512 h=512 f=BC5_UNORM" - and the
# fake texdiag reads that back as texdiag would describe a real DDS. So every
# step the converter takes on its own is real: the flags it builds, the files it
# looks for, the checks it makes, the copies, backups and markers it writes.
#
# What the fakes cannot show - that the real texconv accepts those flags and
# produces a texture of the right size - Verify-Console.ps1 shows, converting real
# files. The flag probe is also run once against the bundled texconv here.
#
# Failures are switched on per test: a file texconv skips, an exit code, an
# output that is the wrong size or that texdiag cannot read.
#
# Type names are given as strings - New-Object BffPlan rather than
# [BffPlan]::new() - because a type literal in this file is resolved when the
# file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'TexInfo', 'Ba2', 'Planner', 'Convert') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    # --- the fake pair ----------------------------------------------------------
    function Read-FakeDds {
        param([string] $Path)
        $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
        if ("$text" -notmatch '^FAKEDDS w=(\d+) h=(\d+) f=(\S+)') { return $null }
        [pscustomobject]@{ W = [int] $Matches[1]; H = [int] $Matches[2]; F = $Matches[3] }
    }

    function Invoke-FakeTexConv {
        $list = @($args)
        [void] $script:convCalls.Add($list)

        if ($list.Count -eq 1 -and $list[0] -in '--help', '-h') {
            if ($script:helpThrows) { throw 'the program can''t start because MSVCP140.dll is missing' }
            return $script:help[$list[0]]
        }

        function Get-Value { param([string] $Flag) $i = [array]::IndexOf($list, $Flag); if ($i -ge 0) { $list[$i + 1] } }
        $o      = [array]::IndexOf($list, '-o')
        $outDir = $list[$o + 1]
        $inputs = if ($o + 2 -le $list.Count - 1) { $list[($o + 2)..($list.Count - 1)] } else { @() }

        foreach ($in in $inputs) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($in)
            if ($script:convSkip -contains $stem) { continue }
            $src  = Read-FakeDds $in
            $w    = if (Get-Value '-w') { Get-Value '-w' } else { $src.W }
            $h    = if (Get-Value '-h') { Get-Value '-h' } else { $src.H }
            $line = "FAKEDDS w=$w h=$h f=$(Get-Value '-f')"
            if ($script:convOverride.ContainsKey($stem)) { $line = $script:convOverride[$stem] }
            # Upper-case extension, as some texconv builds write it.
            Set-Content -LiteralPath (Join-Path $outDir "$stem.DDS") -Value $line
            "writing $outDir\$stem.DDS"
        }
        if ($script:convExit) { 'FAILED [something] (80004005)' }
        $global:LASTEXITCODE = $script:convExit
    }

    function Invoke-FakeTexDiag {
        foreach ($file in @($args | Select-Object -Skip 2)) {
            $d = Read-FakeDds $file
            if (-not $d) { "ERROR: Failed to read '$file'"; continue }
            $file
            "        width = $($d.W)"
            "       height = $($d.H)"
            "       format = $($d.F)"
            '    mipLevels = 1'
        }
    }

    $newHelp = @"
Microsoft (R) DirectX Texture Converter [DirectXTex] Version 2026.5.8.1
   -f <format>         format
   -bc <options>       Sets options for BC compression
   -sepalpha           resize/generate mips alpha channel separately from color channels
"@
    $oldHelp = @"
Microsoft (R) DirectX 11 Texture Converter (DirectXTex version)
   -f <format>         format
   -bcmax              Use exchaustive compression (BC7 only)
"@

    # --- test data --------------------------------------------------------------
    function New-FakeDds {
        param([string] $Path, [int] $Width = 1024, [int] $Height = $Width, [string] $Format = 'BC5_UNORM')
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        Set-Content -LiteralPath $Path -Value "FAKEDDS w=$Width h=$Height f=$Format"
        return $Path
    }

    function New-TestSettings {
        param([string] $Mode = 'OutputMod')
        @{
            Conversion = @{ Filter = 'FANT'; UseBcMax = $true }
            Output     = @{ Mode = $Mode; BackupSuffix = '.backup' }
        }
    }

    # A plan for a texture under a fresh mods folder in TestDrive, with its
    # destination in the output mod next to it.
    function New-TestPlan {
        param(
            [string] $Name = 'MaleHead_s.dds', [string] $Mod = 'Alpha', [string] $Action = 'Resize',
            [int] $Width = 1024, [int] $TargetWidth = 512, [string] $Format = 'BC5_UNORM', [string] $TargetFormat = 'BC5_UNORM',
            [string] $Origin = 'Loose', [string] $Mods = $script:mods, [switch] $NoFile
        )
        $rel = "textures\actors\character\BaseHumanMale\$Name"
        $t = New-Object BffTexture
        $t.Name = $Name; $t.ModName = $Mod; $t.RelativePath = $rel; $t.Origin = $Origin
        $t.Width = $Width; $t.Height = $Width; $t.Format = $Format; $t.Slot = 'Specular'
        $t.FullName = if ($Origin -eq 'BA2') { $rel.Replace('\', '/') } else { Join-Path $Mods "$Mod\$rel" }
        if ($Origin -eq 'BA2') { $t.ArchivePath = Join-Path $Mods "$Mod\$Mod - Textures.ba2" }
        if ($Origin -ne 'BA2' -and -not $NoFile) { [void] (New-FakeDds $t.FullName -Width $Width -Format $Format) }

        $p = New-Object BffPlan
        $p.Texture = $t; $p.Action = $Action
        $p.TargetWidth = $TargetWidth; $p.TargetHeight = $TargetWidth; $p.TargetFormat = $TargetFormat
        $p.Destination = Join-Path $Mods "$Mod face-Vanilla\$rel"
        return $p
    }

    function New-TestWorkspace {
        $w = Join-Path $TestDrive ('ws-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void] (New-Item -ItemType Directory -Path $w)
        return $w
    }

    function Invoke-TestConvert {
        param($Plan, $Settings = (New-TestSettings), $Entry, [string] $Workspace = (New-TestWorkspace))
        Invoke-BffConvert -Plan $Plan -Settings $Settings -Workspace $Workspace -TexConvPath 'Invoke-FakeTexConv' `
                          -TexDiagPath 'Invoke-FakeTexDiag' -ArchiveEntry $Entry -ProfileName 'Vanilla'
    }

    function New-TestBatch {
        param([object[]] $Plan)
        [pscustomobject]@{ Key = 'k'; Plans = @($Plan | ForEach-Object { [pscustomobject]@{ Plan = $_; SourcePath = $_.Texture.FullName } }) }
    }

    function Invoke-TestBatch {
        param([object[]] $Plan, $Settings = (New-TestSettings), [string] $Workspace = (New-TestWorkspace))
        @(Invoke-BffConversionBatch -Batch (New-TestBatch $Plan) -Settings $Settings -Workspace $Workspace `
                                    -TexConvPath 'Invoke-FakeTexConv' -TexDiagPath 'Invoke-FakeTexDiag' -ProfileName 'Vanilla')
    }
}

# One block around everything, for the BeforeEach: Pester 5 takes none at the
# root of a file.
Describe 'Convert.ps1' {

BeforeEach {
    $script:convCalls    = New-Object System.Collections.ArrayList
    $script:convSkip     = @()
    $script:convOverride = @{}
    $script:convExit     = 0
    $script:helpThrows   = $false
    $script:help         = @{ '--help' = $newHelp; '-h' = $newHelp }
    # The capability probe is cached per session; every test starts without it.
    $script:BffTexConvCaps = $null
    $script:mods = Join-Path $TestDrive ('mods-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

Describe 'the workspace' {
    It 'is a fresh folder under the temp folder, and goes away again' {
        $w = New-BffWorkspace
        try {
            Test-Path -LiteralPath $w | Should -BeTrue
            (Split-Path -Parent $w).TrimEnd('\') | Should -Be ([System.IO.Path]::GetTempPath().TrimEnd('\'))
            Split-Path -Leaf $w | Should -Match '^BlackFaceFix_[0-9a-f]{8}$'
            Set-Content -LiteralPath (Join-Path $w 'leftover.txt') -Value 'x'
        }
        finally { Remove-BffWorkspace -Path $w }
        Test-Path -LiteralPath $w | Should -BeFalse
    }

    It 'is not missed when it is already gone, or was never made' {
        { Remove-BffWorkspace -Path (Join-Path $TestDrive 'never') } | Should -Not -Throw
        { Remove-BffWorkspace -Path '' } | Should -Not -Throw
    }
}

Describe 'Get-BffTexConvCapability' {
    It 'finds the flags of the current texconv build' {
        $c = Get-BffTexConvCapability -TexConvPath 'Invoke-FakeTexConv'
        $c.BcMaxFlag | Should -Be @('-bc', 'x')
        $c.SepAlpha  | Should -BeTrue
        $c.Probed    | Should -BeTrue
    }

    It 'finds the flags of the 2017 build, which only prints its usage for -h' {
        $script:help = @{ '--help' = 'Unknown option: --help'; '-h' = $oldHelp }
        $c = Get-BffTexConvCapability -TexConvPath 'Invoke-FakeTexConv'
        $c.BcMaxFlag | Should -Be @('-bcmax')
        $c.SepAlpha  | Should -BeFalse
        @($script:convCalls).Count | Should -Be 2
    }

    It 'asks for nothing it cannot find in a texconv that will not start' {
        $script:helpThrows = $true
        $c = Get-BffTexConvCapability -TexConvPath 'Invoke-FakeTexConv'
        $c.BcMaxFlag | Should -BeNullOrEmpty
        $c.SepAlpha  | Should -BeFalse
        $c.Probed    | Should -BeFalse
    }

    It 'asks texconv once per session' {
        [void] (Get-BffTexConvCapability -TexConvPath 'Invoke-FakeTexConv')
        [void] (Get-BffTexConvCapability -TexConvPath 'Invoke-FakeTexConv')
        @($script:convCalls).Count | Should -Be 1
    }

    It 'reads the bundled texconv right' {
        $c = Get-BffTexConvCapability -TexConvPath (Get-BffTexConvPath -Root $tool)
        $c.Probed    | Should -BeTrue
        $c.BcMaxFlag | Should -Be @('-bc', 'x')
        $c.SepAlpha  | Should -BeTrue
    }
}

Describe 'Test-BffPlanResizes' {
    It 'is true when the width or the height changes' -TestCases @(
        @{ W = 512; H = 1024; Expected = $true }, @{ W = 1024; H = 512; Expected = $true }, @{ W = 1024; H = 1024; Expected = $false }
    ) {
        $p = New-TestPlan -TargetWidth 1024 -NoFile
        $p.TargetWidth = $W; $p.TargetHeight = $H
        Test-BffPlanResizes -Plan $p | Should -Be $Expected
    }
}

Describe 'the texconv flags' {
    BeforeEach { $p = New-TestPlan -NoFile }

    It 'resizes to one uncompressed level first, without the BC7-only flags' {
        $flags = Get-BffResizePassFlags -Plan $p -Flags @('-if', 'FANT', '-sepalpha', '-bc', 'x', '-bcmax')
        @($flags) | Should -Be @('-nologo', '-y', '-w', '512', '-h', '512', '-m', '1', '-f', 'R8G8B8A8_UNORM',
                                 '-if', 'FANT', '-sepalpha', '-ft', 'DDS')
    }

    It 'encodes with a fresh mip chain' {
        @(Get-BffEncodePassFlags -Plan $p -Flags @('-if', 'FANT')) |
            Should -Be @('-nologo', '-y', '-m', '0', '-f', 'BC5_UNORM', '-if', 'FANT', '-ft', 'DDS')
    }

    It 'keeps the source''s mip chain when asked to' {
        @(Get-BffEncodePassFlags -Plan $p -Flags @() -KeepMips) | Should -Be @('-nologo', '-y', '-f', 'BC5_UNORM', '-ft', 'DDS')
    }

    It 'filters with the setting, and treats alpha apart for the formats that carry it' -TestCases @(
        @{ Format = 'BC5_UNORM'; Expected = @('-if', 'FANT') }
        @{ Format = 'BC3_UNORM'; Expected = @('-if', 'FANT', '-sepalpha') }
        @{ Format = 'BC2_UNORM'; Expected = @('-if', 'FANT', '-sepalpha') }
        @{ Format = 'BC7_UNORM'; Expected = @('-if', 'FANT', '-sepalpha', '-bc', 'x') }
    ) {
        $p.TargetFormat = $Format
        @(Get-BffFormatFlags -Plan $p -Settings (New-TestSettings) -TexConvPath 'Invoke-FakeTexConv') | Should -Be $Expected
    }

    It 'leaves out what the settings and the texconv build do not want' {
        $p.TargetFormat = 'BC7_UNORM'
        $s = New-TestSettings
        $s.Conversion.Filter = ''; $s.Conversion.UseBcMax = $false
        @(Get-BffFormatFlags -Plan $p -Settings $s -TexConvPath 'Invoke-FakeTexConv') | Should -Be @('-sepalpha')

        $script:BffTexConvCaps = $null
        $script:help = @{ '--help' = ''; '-h' = '-f <format>' }
        @(Get-BffFormatFlags -Plan $p -Settings (New-TestSettings) -TexConvPath 'Invoke-FakeTexConv') | Should -Be @('-if', 'FANT')
    }
}

Describe 'Get-BffConversionPass' {
    It 'splits a resize in two: down to one level, then encode, with the input left for later' {
        $p = New-TestPlan -NoFile
        $passes = @(Get-BffConversionPass -SourcePath 'C:\src\a_s.dds' -Plan $p -Workspace 'C:\ws' `
                                          -Settings (New-TestSettings) -TexConvPath 'Invoke-FakeTexConv')
        $passes.Count | Should -Be 2
        $passes[0].OutputDirectory | Should -Be 'C:\ws\stage'
        @($passes[0].Arguments)[-3..-1] | Should -Be @('-o', 'C:\ws\stage', 'C:\src\a_s.dds')
        $passes[1].NeedsInput | Should -BeTrue
        $passes[1].OutputDirectory | Should -Be 'C:\ws\out'
        @($passes[1].Arguments)[-2..-1] | Should -Be @('-o', 'C:\ws\out')
        @($passes[1].Arguments) | Should -Contain '-m'
    }

    It 'reformats in one pass that keeps the mips' {
        $p = New-TestPlan -NoFile -Action 'Reformat' -TargetWidth 1024
        $passes = @(Get-BffConversionPass -SourcePath 'C:\src\a_s.dds' -Plan $p -Workspace 'C:\ws' -Settings (New-TestSettings) `
                                          -TexConvPath 'Invoke-FakeTexConv')
        $passes.Count | Should -Be 1
        @($passes[0].Arguments)[-3..-1] | Should -Be @('-o', 'C:\ws\out', 'C:\src\a_s.dds')
        @($passes[0].Arguments) | Should -Not -Contain '-m'
    }

    It 'finds texconv itself when not told where it is' {
        Mock Get-BffTexConvPath { 'Invoke-FakeTexConv' }
        @(Get-BffConversionPass -SourcePath 'a.dds' -Plan (New-TestPlan -NoFile) -Workspace 'C:\ws' -Settings (New-TestSettings)).Count |
            Should -Be 2
    }
}

Describe 'Save-BffConverted' {
    BeforeEach {
        $produced = New-FakeDds (Join-Path (New-TestWorkspace) 'out\MaleHead_s.DDS') -Width 512
    }

    It 'copies into the output mod, marks it as generated, and cleans up after itself' {
        $p = New-TestPlan
        Save-BffConverted -Plan $p -ProducedPath $produced -Settings (New-TestSettings) -ProfileName 'Vanilla'
        (Read-FakeDds $p.Destination).W | Should -Be 512
        Test-BffOutputMod -Path (Join-Path $script:mods 'Alpha face-Vanilla') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:mods 'Alpha face-Vanilla\BlackFaceFix-generated.txt') -Raw |
            Should -Match 'Source mod : Alpha'
        Test-Path -LiteralPath $produced | Should -BeFalse
        (Read-FakeDds $p.Texture.FullName).W | Should -Be 1024 -Because 'the source is never touched'
    }

    It 'writes over the source in place, keeping the original as a backup' {
        $p = New-TestPlan
        $p.Destination = $p.Texture.FullName
        Save-BffConverted -Plan $p -ProducedPath $produced -Settings (New-TestSettings -Mode 'InPlace')
        (Read-FakeDds $p.Texture.FullName).W | Should -Be 512
        (Read-FakeDds ($p.Texture.FullName + '.backup')).W | Should -Be 1024
        Test-Path -LiteralPath (Join-Path $script:mods 'Alpha face-Vanilla') | Should -BeFalse
    }

    It 'never overwrites the backup of the real original on a second run' {
        $p = New-TestPlan
        $p.Destination = $p.Texture.FullName
        Save-BffConverted -Plan $p -ProducedPath $produced -Settings (New-TestSettings -Mode 'InPlace')
        $again = New-FakeDds (Join-Path (New-TestWorkspace) 'out\MaleHead_s.DDS') -Width 256
        Save-BffConverted -Plan $p -ProducedPath $again -Settings (New-TestSettings -Mode 'InPlace')
        (Read-FakeDds ($p.Texture.FullName + '.backup')).W | Should -Be 1024
    }

    It 'backs nothing up for an archive''s texture, which goes to an output mod even in place' {
        $p = New-TestPlan -Origin 'BA2'
        Save-BffConverted -Plan $p -ProducedPath $produced -Settings (New-TestSettings -Mode 'InPlace')
        (Read-FakeDds $p.Destination).W | Should -Be 512
    }

    It 'writes no marker for a destination that is not inside an output mod' {
        $p = New-TestPlan
        $p.Destination = Join-Path $TestDrive 'loose\MaleHead_s.dds'
        Mock New-BffOutputMarker { }
        Mock Get-BffOutputModRoot { '' }
        Save-BffConverted -Plan $p -ProducedPath $produced -Settings (New-TestSettings)
        Should -Invoke New-BffOutputMarker -Times 0 -Exactly
        Test-Path -LiteralPath $p.Destination | Should -BeTrue
    }
}

Describe 'Invoke-BffConvert' {

    It 'does nothing, successfully, for a plan with nothing to do' {
        $r = Invoke-TestConvert (New-TestPlan -Action 'Skip')
        $r.Success | Should -BeTrue
        @($script:convCalls).Count | Should -Be 0
    }

    It 'resizes in two passes, checks the result, and places it' {
        $p = New-TestPlan
        $r = Invoke-TestConvert $p
        $r.Error   | Should -Be ''
        $r.Success | Should -BeTrue
        $r.Destination | Should -Be $p.Destination
        (Read-FakeDds $p.Destination) | Should -Not -BeNullOrEmpty
        "$((Read-FakeDds $p.Destination).W) $((Read-FakeDds $p.Destination).F)" | Should -Be '512 BC5_UNORM'
        $r.Command | Should -BeLike '"Invoke-FakeTexConv" -nologo * &&  "Invoke-FakeTexConv" -nologo *'
    }

    It 'reformats in one pass' {
        $p = New-TestPlan -Action 'Reformat' -TargetWidth 1024 -Format 'BC7_UNORM'
        (Invoke-TestConvert $p).Success | Should -BeTrue
        @($script:convCalls | Where-Object { $_.Count -gt 1 }).Count | Should -Be 1
        (Read-FakeDds $p.Destination).F | Should -Be 'BC5_UNORM'
    }

    It 'quotes a path with spaces in the command it reports' {
        $p = New-TestPlan -Mod 'Mod With Spaces'
        (Invoke-TestConvert $p).Command | Should -BeLike "*`"$($p.Texture.FullName)`"*"
    }

    It 'clears what an earlier conversion left in the workspace' {
        $ws = New-TestWorkspace
        $stale = New-FakeDds (Join-Path $ws 'out\stale.DDS')
        [void] (New-Item -ItemType Directory -Path (Join-Path $ws 'stage'))
        (Invoke-TestConvert (New-TestPlan) -Workspace $ws).Success | Should -BeTrue
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    Context 'an archive''s texture' {
        BeforeEach {
            Mock Expand-BffBa2Texture { New-FakeDds $Destination }
        }

        It 'is extracted to the workspace first, and the extracted copy removed after' {
            $ws = New-TestWorkspace
            $r = Invoke-TestConvert (New-TestPlan -Origin 'BA2') -Entry (New-Object BffArchiveEntry) -Workspace $ws
            $r.Success | Should -BeTrue
            Should -Invoke Expand-BffBa2Texture -Times 1 -Exactly -ParameterFilter { $Destination -eq (Join-Path $ws 'extracted_MaleHead_s.dds') }
            Test-Path -LiteralPath (Join-Path $ws 'extracted_MaleHead_s.dds') | Should -BeFalse
        }

        It 'cannot be converted without its archive entry' {
            (Invoke-TestConvert (New-TestPlan -Origin 'BA2')).Error | Should -Be 'no archive entry supplied for a BA2 texture'
        }
    }

    Context 'what goes wrong' {
        It 'says so when the source has gone' {
            $r = Invoke-TestConvert (New-TestPlan -NoFile)
            $r.Success | Should -BeFalse
            $r.Error   | Should -Be 'source file disappeared'
        }

        It 'reports texconv''s own words, and the command, when it fails' {
            $script:convExit = 1
            $r = Invoke-TestConvert (New-TestPlan)
            $r.Error   | Should -BeLike 'texconv failed (exit 1): *FAILED `[something`] (80004005)'
            $r.Command | Should -BeLike '"Invoke-FakeTexConv"*'
        }

        It 'reports a pass that wrote nothing as a failure, even when texconv said it was fine' {
            $script:convSkip = @('MaleHead_s')
            (Invoke-TestConvert (New-TestPlan)).Error | Should -BeLike 'texconv failed (exit 0)*'
        }

        It 'refuses a dependent pass that has nothing to depend on' {
            Mock Get-BffConversionPass { @([pscustomobject]@{ Arguments = @('-o', 'x'); OutputDirectory = 'x'; NeedsInput = $true }) }
            (Invoke-TestConvert (New-TestPlan)).Error | Should -Be 'the resize pass produced no intermediate file'
        }

        It 'places nothing texdiag cannot read' {
            $script:convOverride = @{ 'MaleHead_s' = 'not a texture' }
            $p = New-TestPlan -Action 'Reformat' -TargetWidth 1024
            (Invoke-TestConvert $p).Error | Should -Be 'texconv produced a file texdiag cannot read'
            Test-Path -LiteralPath $p.Destination | Should -BeFalse
        }

        It 'places nothing of the wrong size' {
            $script:convOverride = @{ 'MaleHead_s' = 'FAKEDDS w=256 h=256 f=BC5_UNORM' }
            (Invoke-TestConvert (New-TestPlan)).Error | Should -Be 'expected 512x512 but texconv produced 256x256'
        }

        It 'places nothing in the wrong format' {
            $script:convOverride = @{ 'MaleHead_s' = 'FAKEDDS w=512 h=512 f=BC7_UNORM' }
            (Invoke-TestConvert (New-TestPlan)).Error | Should -Be 'expected format BC5_UNORM but texconv produced BC7_UNORM'
        }

        It 'turns anything else that goes wrong into an error on the plan' {
            Mock Save-BffConverted { throw 'disk full' }
            $r = Invoke-TestConvert (New-TestPlan)
            $r.Success | Should -BeFalse
            $r.Error   | Should -Be 'disk full'
        }
    }

    It 'finds both tools itself when not told where they are' {
        Mock Get-BffTexConvPath { 'Invoke-FakeTexConv' }
        Mock Get-BffTexDiagPath { 'Invoke-FakeTexDiag' }
        (Invoke-BffConvert -Plan (New-TestPlan) -Settings (New-TestSettings) -Workspace (New-TestWorkspace)).Success |
            Should -BeTrue
    }
}

Describe 'Get-BffConversionBatch' {
    BeforeEach {
        function New-Item-For {
            param([string] $Source, [int] $Target = 512, [string] $Format = 'BC5_UNORM', [int] $Width = 1024)
            $p = New-TestPlan -NoFile -TargetWidth $Target -TargetFormat $Format -Width $Width
            [pscustomobject]@{ Plan = $p; SourcePath = $Source }
        }
    }

    It 'puts plans with the same target size, format and kind of work together' {
        $batches = @(Get-BffConversionBatch -Plan @(
            (New-Item-For 'C:\a\one_s.dds'), (New-Item-For 'C:\a\two_s.dds'),
            (New-Item-For 'C:\a\three_s.dds' -Format 'BC7_UNORM'),
            (New-Item-For 'C:\a\four_s.dds' -Target 1024 -Width 1024)
        ))
        $batches.Count | Should -Be 3
        @($batches[0].Plans).Count | Should -Be 2
        $batches[0].Key | Should -Be '512x512|BC5_UNORM|True'
        @($batches | ForEach-Object Key) | Should -Contain '1024x1024|BC5_UNORM|False'
    }

    It 'splits files of the same name, which texconv would write over each other' {
        $batches = @(Get-BffConversionBatch -Plan @(
            (New-Item-For 'C:\a\Head_s.dds'), (New-Item-For 'C:\b\head_S.dds'), (New-Item-For 'C:\c\other_s.dds')
        ))
        $batches.Count | Should -Be 2
        @($batches[0].Plans | ForEach-Object SourcePath) | Should -Be @('C:\a\Head_s.dds')
        @($batches[1].Plans | ForEach-Object SourcePath) | Should -Be @('C:\b\head_S.dds', 'C:\c\other_s.dds')
    }

    It 'splits a batch whose command line would be too long' {
        $batches = @(Get-BffConversionBatch -MaxCommandLine 40 -Plan @(
            (New-Item-For 'C:\a\one_s.dds'), (New-Item-For 'C:\a\two_s.dds'), (New-Item-For 'C:\a\three_s.dds')
        ))
        @($batches | ForEach-Object { @($_.Plans).Count }) | Should -Be @(2, 1)
    }
}

Describe 'Invoke-BffConversionBatch' {

    It 'resizes the whole batch in one call per pass, and places every file' {
        $plans = @((New-TestPlan -Name 'A_s.dds'), (New-TestPlan -Name 'B_s.dds'))
        $r = Invoke-TestBatch $plans
        @($r | Where-Object Success).Count | Should -Be 2
        @($script:convCalls).Count | Should -Be 3 -Because 'the help probe, then one call per pass'
        @($script:convCalls[1])[-2..-1] | Should -Be @($plans[0].Texture.FullName, $plans[1].Texture.FullName)
        foreach ($p in $plans) { (Read-FakeDds $p.Destination).W | Should -Be 512 }
        $r[0].Command | Should -BeLike '-nologo * &&  -nologo *'
    }

    It 'reformats in a single pass that keeps the mips' {
        $r = Invoke-TestBatch @((New-TestPlan -Action 'Reformat' -TargetWidth 1024 -Format 'BC7_UNORM'))
        $r[0].Success | Should -BeTrue
        @($script:convCalls).Count | Should -Be 2
        @($script:convCalls[1]) | Should -Not -Contain '-m'
    }

    It 'clears what an earlier batch left in the workspace' {
        $ws = New-TestWorkspace
        $stale = New-FakeDds (Join-Path $ws 'stage\stale.DDS')
        [void] (New-Item -ItemType Directory -Path (Join-Path $ws 'out'))
        [void] (Invoke-TestBatch @((New-TestPlan)) -Workspace $ws)
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It 'hands every file back for a retry when the resize pass made nothing' {
        $script:convSkip = @('A_s', 'B_s')
        $r = Invoke-TestBatch @((New-TestPlan -Name 'A_s.dds'), (New-TestPlan -Name 'B_s.dds'))
        @($r | ForEach-Object Retry) | Should -Be @($true, $true)
        $r[0].Error | Should -Be 'the resize pass produced nothing'
    }

    It 'hands back for a retry just the files it has no output for' {
        $script:convSkip = @('B_s')
        $r = Invoke-TestBatch @((New-TestPlan -Name 'A_s.dds'), (New-TestPlan -Name 'B_s.dds'))
        $r[0].Success | Should -BeTrue
        $r[1].Retry   | Should -BeTrue
        $r[1].Error   | Should -Be 'texconv produced no output for this file'
    }

    It 'hands back for a retry an output texdiag cannot read' {
        $script:convOverride = @{ 'A_s' = 'not a texture' }
        $r = Invoke-TestBatch @((New-TestPlan -Name 'A_s.dds' -Action 'Reformat' -TargetWidth 1024))
        $r[0].Retry | Should -BeTrue
        $r[0].Error | Should -Be 'output could not be read back'
    }

    It 'hands back for a retry an output of the wrong size or format' {
        $script:convOverride = @{ 'A_s' = 'FAKEDDS w=512 h=512 f=BC7_UNORM' }
        $r = Invoke-TestBatch @((New-TestPlan -Name 'A_s.dds'))
        $r[0].Retry | Should -BeTrue
        $r[0].Error | Should -Be 'expected 512x512 BC5_UNORM, got 512x512 BC7_UNORM'
    }

    It 'hands every file back when the encode pass made nothing at all' {
        $script:convOverride = @{}
        Mock Get-BffTextureInfo { throw 'texdiag must not be asked about nothing' }
        $p = New-TestPlan -Action 'Reformat' -TargetWidth 1024
        $script:convSkip = @('MaleHead_s')
        $r = Invoke-TestBatch @($p)
        $r[0].Retry | Should -BeTrue
    }

    It 'does not retry a file that converted but could not be placed' {
        Mock Save-BffConverted { throw 'access denied' }
        $r = Invoke-TestBatch @((New-TestPlan))
        $r[0].Success | Should -BeFalse
        $r[0].Retry   | Should -BeFalse
        $r[0].Error   | Should -Be 'access denied'
    }
}

Describe 'Invoke-BffPlanSet' {
    BeforeEach {
        Mock Get-BffTexConvPath { 'Invoke-FakeTexConv' }
        Mock Get-BffTexDiagPath { 'Invoke-FakeTexDiag' }
        $script:workspace = $null
        Mock New-BffWorkspace { $script:workspace = New-TestWorkspace; $script:workspace }
    }

    It 'converts only the plans that need work, and cleans up after itself' {
        $plans = @((New-TestPlan -Name 'A_s.dds'), (New-TestPlan -Name 'B_s.dds' -Action 'Skip'))
        $r = @(Invoke-BffPlanSet -Plan $plans -Settings (New-TestSettings) -Root $tool -ProfileName 'Vanilla')
        $r.Count | Should -Be 1
        $r[0].Success | Should -BeTrue
        Test-Path -LiteralPath $script:workspace | Should -BeFalse
    }

    It 'returns nothing, and starts nothing, when there is nothing to do' {
        @(Invoke-BffPlanSet -Plan @((New-TestPlan -Action 'Skip')) -Settings (New-TestSettings) -Root $tool).Count | Should -Be 0
        Should -Invoke New-BffWorkspace -Times 0 -Exactly
    }

    It 'reports progress per file' {
        $seen = New-Object System.Collections.ArrayList
        [void] (Invoke-BffPlanSet -Plan @((New-TestPlan -Name 'A_s.dds'), (New-TestPlan -Name 'B_s.dds')) `
                                  -Settings (New-TestSettings) -Root $tool `
                                  -Progress { param($done, $total, $plan) [void] $seen.Add("$done/$total $($plan.Texture.Name)") }.GetNewClosure())
        @($seen) | Should -Be @('1/2 A_s.dds', '2/2 B_s.dds')
    }

    It 'extracts archive textures into folders of their own, found by archive and path' {
        $a = New-TestPlan -Origin 'BA2' -Name 'Head_s.dds' -Mod 'Packed'
        $b = New-TestPlan -Origin 'BA2' -Name 'Head_s.dds' -Mod 'Other'
        $b.Texture.FullName = 'textures/other/Head_s.dds'
        $entries = @{
            ('{0}::{1}' -f $a.Texture.ArchivePath, $a.Texture.FullName) = New-Object BffArchiveEntry
            ('{0}::{1}' -f $b.Texture.ArchivePath, $b.Texture.FullName) = New-Object BffArchiveEntry
        }
        Mock Expand-BffBa2Texture { New-FakeDds $Destination }
        $r = @(Invoke-BffPlanSet -Plan @($a, $b) -Settings (New-TestSettings) -Root $tool -ArchiveEntryByPath $entries)
        @($r | Where-Object Success).Count | Should -Be 2
        Should -Invoke Expand-BffBa2Texture -Times 1 -Exactly -ParameterFilter { $Destination -like '*\src\1\Head_s.dds' }
        Should -Invoke Expand-BffBa2Texture -Times 1 -Exactly -ParameterFilter { $Destination -like '*\src\2\Head_s.dds' }
    }

    It 'fails, and carries on with the rest, a file it cannot get hold of' {
        $gone    = New-TestPlan -Name 'Gone_s.dds' -NoFile
        $noEntry = New-TestPlan -Origin 'BA2' -Name 'NoEntry_s.dds'
        $broken  = New-TestPlan -Origin 'BA2' -Name 'Broken_s.dds'
        $fine    = New-TestPlan -Name 'Fine_s.dds'
        $entries = @{ ('{0}::{1}' -f $broken.Texture.ArchivePath, $broken.Texture.FullName) = New-Object BffArchiveEntry }
        Mock Expand-BffBa2Texture { throw 'chunk is not zlib compressed' }

        $r = @(Invoke-BffPlanSet -Plan @($gone, $noEntry, $broken, $fine) -Settings (New-TestSettings) -Root $tool `
                                 -ArchiveEntryByPath $entries)
        ($r | Where-Object { $_.Plan -eq $gone }).Error    | Should -Be 'source file disappeared'
        ($r | Where-Object { $_.Plan -eq $noEntry }).Error | Should -Be 'no archive entry supplied for a BA2 texture'
        ($r | Where-Object { $_.Plan -eq $broken }).Error  | Should -Be 'chunk is not zlib compressed'
        ($r | Where-Object { $_.Plan -eq $fine }).Success  | Should -BeTrue
    }

    It 'fails an archive texture when no archive entries are passed at all' {
        $r = @(Invoke-BffPlanSet -Plan @((New-TestPlan -Origin 'BA2')) -Settings (New-TestSettings) -Root $tool)
        $r[0].Error | Should -Be 'no archive entry supplied for a BA2 texture'
    }

    It 'converts a file the batch could not do on its own, so the error lands on that file' {
        $a = New-TestPlan -Name 'A_s.dds'
        $b = New-TestPlan -Name 'B_s.dds' -Origin 'BA2'
        $entry   = New-Object BffArchiveEntry
        $entries = @{ ('{0}::{1}' -f $b.Texture.ArchivePath, $b.Texture.FullName) = $entry }
        Mock Expand-BffBa2Texture { New-FakeDds $Destination }
        Mock Invoke-BffConversionBatch {
            @($Batch.Plans | ForEach-Object { [pscustomobject]@{ Plan = $_.Plan; Success = $false; Retry = $true; Error = 'batch'; Destination = ''; Command = '' } })
        }
        Mock Invoke-BffConvert { [pscustomobject]@{ Plan = $Plan; Success = $true; Error = ''; Destination = $Plan.Destination; Command = 'alone' } }

        $r = @(Invoke-BffPlanSet -Plan @($a, $b) -Settings (New-TestSettings) -Root $tool -ArchiveEntryByPath $entries)
        @($r | ForEach-Object Command) | Should -Be @('alone', 'alone')
        Should -Invoke Invoke-BffConvert -Times 1 -Exactly -ParameterFilter { $Plan -eq $b -and $ArchiveEntry -eq $entry }
        Should -Invoke Invoke-BffConvert -Times 1 -Exactly -ParameterFilter { $Plan -eq $a -and -not $ArchiveEntry }
    }

    It 'retries without archive entries when none were passed' {
        Mock Invoke-BffConversionBatch {
            @($Batch.Plans | ForEach-Object { [pscustomobject]@{ Plan = $_.Plan; Success = $false; Retry = $true; Error = 'batch'; Destination = ''; Command = '' } })
        }
        Mock Invoke-BffConvert { [pscustomobject]@{ Plan = $Plan; Success = $true; Error = ''; Destination = ''; Command = '' } }
        [void] (Invoke-BffPlanSet -Plan @((New-TestPlan)) -Settings (New-TestSettings) -Root $tool)
        Should -Invoke Invoke-BffConvert -Times 1 -Exactly
    }

    It 'finds its tools next to itself when not given a root' {
        Mock Get-BffRoot { $tool }
        @(Invoke-BffPlanSet -Plan @((New-TestPlan)) -Settings (New-TestSettings)).Count | Should -Be 1
        Should -Invoke Get-BffTexConvPath -Times 1 -Exactly -ParameterFilter { $Root -eq $tool }
    }
}

Describe 'Restore-BffBackup' {
    BeforeEach {
        $root = Join-Path $TestDrive ('restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $one = New-FakeDds (Join-Path $root 'Alpha\a_s.dds') -Width 512
        $two = New-FakeDds (Join-Path $root 'Bravo\deep\b_d.dds') -Width 512
        [void] (New-FakeDds "$one.backup" -Width 1024)
        [void] (New-FakeDds "$two.backup" -Width 2048)
    }

    It 'puts every backup back over its original, and removes the backups' {
        $r = @(Restore-BffBackup -Path $root)
        $r.Count | Should -Be 2
        @($r | Where-Object Success).Count | Should -Be 2
        (Read-FakeDds $one).W | Should -Be 1024
        (Read-FakeDds $two).W | Should -Be 2048
        Test-Path -LiteralPath "$one.backup" | Should -BeFalse
    }

    It 'keeps the backups when asked to' {
        [void] (Restore-BffBackup -Path $root -KeepBackup)
        Test-Path -LiteralPath "$one.backup" | Should -BeTrue
        (Read-FakeDds $one).W | Should -Be 1024
    }

    It 'takes another backup suffix' {
        [void] (New-FakeDds "$one.orig" -Width 4096)
        [void] (Restore-BffBackup -Path $root -BackupSuffix '.orig')
        (Read-FakeDds $one).W | Should -Be 4096
    }

    It 'changes nothing with -WhatIf' {
        @(Restore-BffBackup -Path $root -WhatIf).Count | Should -Be 0
        (Read-FakeDds $one).W | Should -Be 512
    }

    It 'reports a file it could not restore, and restores the rest' {
        Mock Copy-Item { throw 'in use' } -ParameterFilter { $LiteralPath -like '*a_s.dds.backup' }
        $r = @(Restore-BffBackup -Path $root)
        ($r | Where-Object Path -eq $one).Success | Should -BeFalse
        ($r | Where-Object Path -eq $one).Error   | Should -Be 'in use'
        ($r | Where-Object Path -eq $two).Success | Should -BeTrue
    }
}

}
