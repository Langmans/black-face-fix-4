# Unit tests for TexInfo.ps1 - finding texdiag and texconv, and reading what
# texdiag says about a texture.
#
#   Invoke-Pester -Path .\Tests\TexInfo.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\TexInfo.ps1'
#
# Pester 5. texdiag's output is played back by Invoke-FakeTexDiag, a function:
# the code runs texdiag as '& $TexDiagPath ...', which calls a function by name
# exactly as it calls an exe, so the parser sees the same lines it would from
# the real tool, batch by batch.
#
# The tool search is tested on folders built in TestDrive, with PATH and
# LOCALAPPDATA pointed at TestDrive too for the tests that need them empty -
# a developer machine may well have texdiag on PATH through winget. Only the
# start check runs the real thing: the texconv and texdiag bundled in MSFT\.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'TexInfo') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    # --- the fake texdiag -------------------------------------------------------
    # $script:fake maps a path to the lines texdiag prints for it; a path not in
    # the map gets the lines texdiag prints for a file it cannot open.
    function New-FakeRecord {
        param([string] $EchoedPath, [int] $Width = 1024, [int] $Height = $Width, [string] $Format = 'BC5_UNORM',
              [int] $Mips = 11, [string[]] $Extra = @())
        @(
            $EchoedPath
            "        width = $Width"
            "       height = $Height"
            '        depth = 1'
            "    mipLevels = $Mips"
            '    arraySize = 1'
            "       format = $Format"
            '    dimension = 2D'
            '   alpha mode = Unknown'
            "       images = $Mips"
            '   pixel size = 1365 (KB)'
        ) + $Extra
    }

    function Invoke-FakeTexDiag {
        [void] $script:fakeCalls.Add(@($args))
        # info -nologo <files...>
        foreach ($file in @($args | Select-Object -Skip 2)) {
            if ($script:fake.ContainsKey($file)) { $script:fake[$file] }
            else { "ERROR: Failed to open '$file' (80070002: The system cannot find the file specified.)" }
        }
    }

    function New-TestTexture {
        param([string] $FullName)
        $t = New-Object BffTexture
        $t.FullName = $FullName; $t.Name = Split-Path -Leaf $FullName
        return $t
    }

    # --- tool search ------------------------------------------------------------
    # A folder of empty files named like the tools. The search only checks that a
    # file is there, and never starts it.
    function New-ToolFolder {
        param([string] $Name, [string[]] $Tool = @('texdiag', 'texconv'))
        $dir = Join-Path $TestDrive $Name
        [void] (New-Item -ItemType Directory -Path $dir -Force)
        foreach ($t in $Tool) { [void] (New-Item -ItemType File -Path (Join-Path $dir "$t.exe") -Force) }
        return $dir
    }

    # A tool root of its own per test: the search caches by root, so a fresh root
    # is a fresh search.
    function New-ToolRoot {
        param([switch] $Bundled)
        $root = Join-Path $TestDrive ('root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void] (New-Item -ItemType Directory -Path $root)
        if ($Bundled) { [void] (New-ToolFolder (Join-Path (Split-Path -Leaf $root) 'MSFT')) }
        return $root
    }

    function New-ToolSettings {
        param([string] $TexTools, [bool] $PreferSystem = $false)
        $s = @{ Conversion = @{ PreferSystemTools = $PreferSystem }; Paths = @{} }
        if ($TexTools) { $s.Paths.TexTools = $TexTools }
        return $s
    }
}

Describe 'Resolve-BffTexTool' {
    BeforeEach {
        # Nothing on PATH and no winget packages, unless a test puts some there.
        $savedPath  = $env:PATH
        $savedLocal = $env:LOCALAPPDATA
        $env:PATH         = New-ToolFolder 'empty-path' -Tool @()
        $env:LOCALAPPDATA = Join-Path $TestDrive 'no-local-app-data'
    }
    AfterEach {
        $env:PATH         = $savedPath
        $env:LOCALAPPDATA = $savedLocal
    }

    It 'uses the copy bundled with the tool' {
        $root = New-ToolRoot -Bundled
        Resolve-BffTexTool -Name 'texdiag' -Root $root | Should -Be (Join-Path $root 'MSFT\texdiag.exe')
    }

    It 'prefers the folder named in Paths.TexTools' {
        $root = New-ToolRoot -Bundled
        $own  = New-ToolFolder 'own-tools'
        Resolve-BffTexTool -Name 'texconv' -Root $root -Settings (New-ToolSettings -TexTools $own) |
            Should -Be (Join-Path $own 'texconv.exe')
    }

    It 'falls back when the folder in Paths.TexTools does not hold the tool' {
        $root = New-ToolRoot -Bundled
        Resolve-BffTexTool -Name 'texconv' -Root $root -Settings (New-ToolSettings -TexTools (Join-Path $TestDrive 'nothing')) |
            Should -Be (Join-Path $root 'MSFT\texconv.exe')
    }

    It 'takes settings that say nothing about tools' {
        $root = New-ToolRoot -Bundled
        Resolve-BffTexTool -Name 'texdiag' -Root $root -Settings @{ Conversion = @{}; Paths = @{} } |
            Should -Be (Join-Path $root 'MSFT\texdiag.exe')
    }

    It 'finds the tool on PATH when nothing is bundled' {
        $env:PATH = New-ToolFolder 'on-path'
        Resolve-BffTexTool -Name 'texdiag' -Root (New-ToolRoot) | Should -Be (Join-Path $TestDrive 'on-path\texdiag.exe')
    }

    It 'prefers PATH over the bundled copy with PreferSystemTools' {
        $env:PATH = New-ToolFolder 'on-path'
        Resolve-BffTexTool -Name 'texdiag' -Root (New-ToolRoot -Bundled) -Settings (New-ToolSettings -PreferSystem $true) |
            Should -Be (Join-Path $TestDrive 'on-path\texdiag.exe')
    }

    It 'still uses the bundled copy with PreferSystemTools when there is no other' {
        $root = New-ToolRoot -Bundled
        Resolve-BffTexTool -Name 'texdiag' -Root $root -Settings (New-ToolSettings -PreferSystem $true) |
            Should -Be (Join-Path $root 'MSFT\texdiag.exe')
    }

    It 'finds what winget installed but has not put on PATH yet' {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'local'
        $pkg = 'local\Microsoft\WinGet\Packages\Microsoft.DirectXTex.Texconv_Microsoft.Winget.Source_8wekyb3d8bbwe'
        [void] (New-ToolFolder $pkg -Tool 'texconv')
        # A package folder for the right tool that does not hold it is passed over.
        [void] (New-ToolFolder 'local\Microsoft\WinGet\Packages\Microsoft.DirectXTex.Texconv_broken' -Tool @())
        Resolve-BffTexTool -Name 'texconv' -Root (New-ToolRoot) | Should -Be (Join-Path $TestDrive "$pkg\texconv.exe")
    }

    It 'says where it looked and how to get the tool when it is nowhere' {
        $root = New-ToolRoot
        { Resolve-BffTexTool -Name 'texdiag' -Root $root } |
            Should -Throw -ExpectedMessage "texdiag.exe not found.*'$(Join-Path $root 'MSFT')'*winget install Microsoft.DirectXTex.texdiag*"
    }

    It 'remembers what it found for a root' {
        $root = New-ToolRoot -Bundled
        $first = Resolve-BffTexTool -Name 'texdiag' -Root $root
        Remove-Item -LiteralPath $first
        Resolve-BffTexTool -Name 'texdiag' -Root $root | Should -Be $first
    }

    It 'looks next to the tool itself when not given a root' {
        $root = New-ToolRoot -Bundled
        Mock Get-BffRoot { $root }
        Resolve-BffTexTool -Name 'texdiag' | Should -Be (Join-Path $root 'MSFT\texdiag.exe')
    }

    It 'has a shorthand for each tool' {
        $root = New-ToolRoot -Bundled
        Get-BffTexDiagPath -Root $root | Should -Be (Join-Path $root 'MSFT\texdiag.exe')
        Get-BffTexConvPath -Root $root | Should -Be (Join-Path $root 'MSFT\texconv.exe')
    }

    It 'has shorthands that look next to the tool when not given a root' {
        $root = New-ToolRoot -Bundled
        Mock Get-BffRoot { $root }
        Get-BffTexDiagPath | Should -Be (Join-Path $root 'MSFT\texdiag.exe')
        Get-BffTexConvPath | Should -Be (Join-Path $root 'MSFT\texconv.exe')
    }
}

Describe 'Test-BffToolchain' {
    It 'is happy with the tools that ship with it' {
        $check = Test-BffToolchain -Root $tool
        @($check.Problems).Count | Should -Be 0
        @($check.Paths) | Should -Be @((Join-Path $tool 'MSFT\texdiag.exe'), (Join-Path $tool 'MSFT\texconv.exe'))
    }

    It 'looks next to the tool itself when not given a root' {
        Mock Get-BffRoot { $tool }
        @((Test-BffToolchain).Problems).Count | Should -Be 0
    }

    It 'explains a tool that is there but will not start' {
        # An empty file named texdiag.exe is not a program Windows can run - the
        # same failure a missing Visual C++ runtime gives, seen from here.
        $root = New-ToolRoot -Bundled
        $check = Test-BffToolchain -Root $root
        @($check.Problems).Count | Should -Be 2
        $check.Problems[0] | Should -BeLike '*texdiag.exe will not start.*Visual C++ 2015-2022 Redistributable*(Output was: *'
        @($check.Paths).Count | Should -Be 2
    }

    It 'passes on why a tool could not be found' {
        $savedPath  = $env:PATH
        $savedLocal = $env:LOCALAPPDATA
        try {
            $env:PATH         = New-ToolFolder 'empty-path-2' -Tool @()
            $env:LOCALAPPDATA = Join-Path $TestDrive 'no-local-app-data'
            $check = Test-BffToolchain -Root (New-ToolRoot)
        }
        finally {
            $env:PATH         = $savedPath
            $env:LOCALAPPDATA = $savedLocal
        }
        @($check.Problems).Count | Should -Be 2
        $check.Problems[0] | Should -BeLike 'texdiag.exe not found.*'
        @($check.Paths).Count | Should -Be 0
    }
}

Describe 'ConvertTo-BffPathKey' {
    It 'makes two spellings of one path the same' {
        ConvertTo-BffPathKey ' C:/Mods/Alpha/Head_D.DDS ' | Should -Be (ConvertTo-BffPathKey 'c:\mods\alpha\head_d.dds')
    }

    It 'lower-cases, uses backslashes and drops a trailing one' {
        ConvertTo-BffPathKey 'C:/Mods/Alpha/' | Should -Be 'c:\mods\alpha'
    }

    It 'is empty for nothing' {
        ConvertTo-BffPathKey '' | Should -Be ''
        ConvertTo-BffPathKey $null | Should -Be ''
    }
}

Describe 'Get-BffTextureInfo' {
    BeforeEach {
        $script:fake      = @{}
        $script:fakeCalls = New-Object System.Collections.ArrayList
    }

    It 'reads every property by its name' {
        $script:fake['C:\m\Head_s.dds'] = New-FakeRecord 'C:\m\Head_s.dds' -Width 512 -Format 'BC5_UNORM' -Mips 10
        $r = @(Get-BffTextureInfo -Path 'C:\m\Head_s.dds' -TexDiagPath 'Invoke-FakeTexDiag')
        $r.Count | Should -Be 1
        $r[0].Ok        | Should -BeTrue
        $r[0].Error     | Should -Be ''
        $r[0].Width     | Should -Be 512
        $r[0].Height    | Should -Be 512
        $r[0].Format    | Should -Be 'BC5_UNORM'
        $r[0].MipLevels | Should -Be 10
        $r[0].Depth     | Should -Be 1
        $r[0].ArraySize | Should -Be 1
        $r[0].Dimension | Should -Be '2D'
        $r[0].AlphaMode | Should -Be 'Unknown'
        $r[0].SizeKB    | Should -Be 1365
    }

    It 'calls texdiag info without its banner' {
        $script:fake['C:\m\a.dds'] = New-FakeRecord 'C:\m\a.dds'
        [void] (Get-BffTextureInfo -Path 'C:\m\a.dds' -TexDiagPath 'Invoke-FakeTexDiag')
        @($script:fakeCalls[0])[0..1] | Should -Be @('info', '-nologo')
    }

    It 'is not thrown by lines it does not expect, wherever they come' {
        $script:fake['C:\m\a.dds'] = @('build = 2026.5.8.1', '') + (New-FakeRecord 'C:\m\a.dds' -Extra @('     cubemap = no', 'some note'))
        $r = @(Get-BffTextureInfo -Path 'C:\m\a.dds' -TexDiagPath 'Invoke-FakeTexDiag')
        $r[0].Ok    | Should -BeTrue
        $r[0].Width | Should -Be 1024
    }

    It 'matches the path texdiag echoes however it spells it, and hands back the caller''s spelling' {
        $script:fake['C:\Mods\Alpha\Head_d.DDS'] = New-FakeRecord 'c:/mods/alpha/head_d.dds'
        $r = @(Get-BffTextureInfo -Path 'C:\Mods\Alpha\Head_d.DDS' -TexDiagPath 'Invoke-FakeTexDiag')
        $r[0].Ok   | Should -BeTrue
        $r[0].Path | Should -Be 'C:\Mods\Alpha\Head_d.DDS'
    }

    It 'reports a file texdiag could not read, in the caller''s order' {
        $script:fake['C:\m\good.dds'] = New-FakeRecord 'C:\m\good.dds'
        $r = @(Get-BffTextureInfo -Path 'C:\m\gone.dds', 'C:\m\good.dds' -TexDiagPath 'Invoke-FakeTexDiag')
        $r[0].Path  | Should -Be 'C:\m\gone.dds'
        $r[0].Ok    | Should -BeFalse
        $r[0].Error | Should -Be 'texdiag could not read this file'
        $r[0].Width | Should -Be 0
        $r[1].Ok    | Should -BeTrue
    }

    It 'counts a record without a size or a format as unread' -TestCases @(
        @{ Drop = 'width' }, @{ Drop = 'format' }
    ) {
        $script:fake['C:\m\a.dds'] = @(New-FakeRecord 'C:\m\a.dds' | Where-Object { $_ -notmatch "^\s*$Drop = " })
        (@(Get-BffTextureInfo -Path 'C:\m\a.dds' -TexDiagPath 'Invoke-FakeTexDiag'))[0].Ok | Should -BeFalse
    }

    It 'reads 0 for a number texdiag left out or did not print as one' {
        $script:fake['C:\m\a.dds'] = @(
            'C:\m\a.dds'
            '        width = 1024'
            '       format = BC7_UNORM'
            '    mipLevels = many'
        )
        $r = (@(Get-BffTextureInfo -Path 'C:\m\a.dds' -TexDiagPath 'Invoke-FakeTexDiag'))[0]
        $r.Ok        | Should -BeTrue
        $r.Height    | Should -Be 0
        $r.MipLevels | Should -Be 0
        $r.SizeKB    | Should -Be 0
        $r.Dimension | Should -Be ''
    }

    It 'asks texdiag in batches, and reports progress after each' {
        $paths = 1..5 | ForEach-Object { "C:\m\t$_.dds" }
        foreach ($p in $paths) { $script:fake[$p] = New-FakeRecord $p }
        $seen = New-Object System.Collections.ArrayList
        $r = @(Get-BffTextureInfo -Path $paths -TexDiagPath 'Invoke-FakeTexDiag' -BatchSize 2 `
                                  -Progress { param($done, $total) [void] $seen.Add("$done/$total") }.GetNewClosure())
        $r.Count | Should -Be 5
        @($r | Where-Object Ok).Count | Should -Be 5
        $script:fakeCalls.Count | Should -Be 3
        @($seen) | Should -Be @('2/5', '4/5', '5/5')
    }

    It 'returns nothing for nothing, without starting texdiag' {
        @(Get-BffTextureInfo -Path @() -TexDiagPath 'Invoke-FakeTexDiag').Count | Should -Be 0
        $script:fakeCalls.Count | Should -Be 0
    }

    It 'finds texdiag itself when it is not told where it is' {
        Mock Get-BffTexDiagPath { 'Invoke-FakeTexDiag' }
        $script:fake['C:\m\a.dds'] = New-FakeRecord 'C:\m\a.dds'
        (@(Get-BffTextureInfo -Path 'C:\m\a.dds'))[0].Ok | Should -BeTrue
    }
}

Describe 'Update-BffTextureInfo' {
    BeforeEach {
        $script:info = @()
        Mock Get-BffTextureInfo { $script:info }
    }

    It 'fills in size, format and mips, and returns the textures it could read' {
        $a = New-TestTexture 'C:\m\a_d.dds'
        $b = New-TestTexture 'C:\m\b_d.dds'
        $script:info = @(
            [pscustomobject]@{ Path = 'C:\m\a_d.dds'; Ok = $true; Width = 2048; Height = 2048; Format = 'BC7_UNORM'; MipLevels = 12; Error = '' }
            [pscustomobject]@{ Path = 'C:\m\b_d.dds'; Ok = $false; Width = 0; Height = 0; Format = ''; MipLevels = 0; Error = 'texdiag could not read this file' }
        )
        $ok = @(Update-BffTextureInfo -Texture @($a, $b) -TexDiagPath 'texdiag.exe')
        $ok.Count | Should -Be 1
        $ok[0] | Should -Be $a
        "$($a.Width)x$($a.Height) $($a.Format) $($a.MipLevels)" | Should -Be '2048x2048 BC7_UNORM 12'
    }

    It 'hands the ones it could not read to -FailedVariable' {
        $script:info = @([pscustomobject]@{ Path = 'C:\m\b_d.dds'; Ok = $false; Error = 'texdiag could not read this file' })
        [void] (Update-BffTextureInfo -Texture (New-TestTexture 'C:\m\b_d.dds') -TexDiagPath 'texdiag.exe' -FailedVariable 'unread')
        @($unread).Count | Should -Be 1
        $unread[0].Path  | Should -Be 'C:\m\b_d.dds'
        $unread[0].Error | Should -Be 'texdiag could not read this file'
    }

    It 'ignores a record for a file it did not ask about' {
        $script:info = @([pscustomobject]@{ Path = 'C:\m\other.dds'; Ok = $true; Width = 1; Height = 1; Format = 'X'; MipLevels = 1 })
        @(Update-BffTextureInfo -Texture (New-TestTexture 'C:\m\a_d.dds') -TexDiagPath 'texdiag.exe').Count | Should -Be 0
    }

    It 'passes the progress callback on' {
        $script:info = @()
        $cb = { param($done, $total) }
        [void] (Update-BffTextureInfo -Texture (New-TestTexture 'C:\m\a_d.dds') -TexDiagPath 'texdiag.exe' -Progress $cb)
        Should -Invoke Get-BffTextureInfo -Times 1 -Exactly -ParameterFilter { $Progress -eq $cb -and $Path -contains 'C:\m\a_d.dds' }
    }

    It 'returns nothing for nothing, without starting texdiag' {
        @(Update-BffTextureInfo -Texture @() -TexDiagPath 'texdiag.exe').Count | Should -Be 0
        Should -Invoke Get-BffTextureInfo -Times 0 -Exactly
    }

    It 'finds texdiag itself when it is not told where it is' {
        Mock Get-BffTexDiagPath { 'C:\found\texdiag.exe' }
        [void] (Update-BffTextureInfo -Texture (New-TestTexture 'C:\m\a_d.dds'))
        Should -Invoke Get-BffTextureInfo -Times 1 -Exactly -ParameterFilter { $TexDiagPath -eq 'C:\found\texdiag.exe' }
    }
}
