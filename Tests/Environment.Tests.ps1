# Unit tests for Environment.ps1 - finding Fallout 4, Mod Organizer and
# LooksMenu, and working out which profile the install is on.
#
#   Invoke-Pester -Path .\Tests\Environment.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Environment.ps1'
#
# Pester 5. Installs are built in TestDrive: a game folder, a Mod Organizer
# instance with its ini, profiles and mods, and f4ee.ini files where a test
# wants them. The registry is mocked, and LOCALAPPDATA points into TestDrive, so
# what is installed on the machine running the tests makes no difference.
#
# Type names are given as strings - New-Object BffProfile rather than
# [BffProfile]::new() - because a type literal in this file is resolved when the
# file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'Environment') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    function New-TestDir {
        param([string] $Relative)
        $path = Join-Path $TestDrive $Relative
        [void] (New-Item -ItemType Directory -Path $path -Force)
        return $path
    }

    function Set-TestFile {
        param([string] $Path, [string[]] $Line)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        Set-Content -LiteralPath $Path -Value $Line -Encoding UTF8
    }

    function New-TestName { 'x' + [guid]::NewGuid().ToString('N').Substring(0, 8) }

    # A drive letter this machine does not have, the way an unplugged disk looks.
    $missingDrive = [char[]] 'ZYXWVUTSRQPONMLKJIHGFE' |
                    Where-Object { -not (Test-Path -LiteralPath "$($_):\") } | Select-Object -First 1

    # A Mod Organizer instance with a mods folder and one profile, 'Main'.
    function New-TestMO2 {
        param([string[]] $IniLine = @('[General]', 'selected_profile=@ByteArray(Main)'))
        $root = New-TestDir (Join-Path (New-TestName) 'MO2')
        Set-TestFile (Join-Path $root 'ModOrganizer.ini') $IniLine
        [void] (New-Item -ItemType Directory -Path (Join-Path $root 'mods'), (Join-Path $root 'profiles\Main') -Force)
        return $root
    }

    # What Get-BffMO2Info returns for a root, without reading an ini.
    function New-TestMO2Info {
        param([string] $Root, [string] $Profile = 'Main')
        [pscustomobject]@{
            Root = $Root; ModsPath = Join-Path $Root 'mods'; ProfilesPath = Join-Path $Root 'profiles'
            SelectedProfile = $Profile; GamePath = ''
        }
    }

    function New-TestGame {
        $game = New-TestDir (Join-Path (New-TestName) 'Fallout 4')
        [void] (New-Item -ItemType Directory -Path (Join-Path $game 'Data'))
        return $game
    }

    function New-TestF4ee {
        param([string] $Path, [int] $Width = 1024, [int] $Height = $Width)
        Set-TestFile $Path @('[CharGen]', "uTintWidth=$Width ; Default[1024]", "uTintHeight=$Height ; Default[1024]")
    }

    function New-TestProfile {
        param([string] $Name = 'Vanilla', [int] $Tint = 1024)
        $p = New-Object BffProfile
        $p.Name = $Name
        $p.Sizes = @{ Diffuse = $Tint; Other = $Tint }
        $p.F4EE  = @{ uTintWidth = $Tint; uTintHeight = $Tint }
        return $p
    }
}

Describe 'Read-BffIniFile' {
    It 'reads sections and keys, and drops comments' {
        $ini = Join-Path $TestDrive 'a.ini'
        Set-TestFile $ini @(
            'top=level'
            '; a comment'
            '# another'
            ''
            '[CharGen]'
            'uTintWidth=2048 ; Default[1024]'
            '  spaced  =  out  '
            '=no key'
            'no equals sign'
            '[Empty]'
            '[CharGen]'
            'again=yes'
        )
        $r = Read-BffIniFile -Path $ini
        $r['']['top']                | Should -Be 'level'
        $r['CharGen']['uTintWidth']  | Should -Be '2048'
        $r['CharGen']['spaced']      | Should -Be 'out'
        $r['CharGen']['again']       | Should -Be 'yes'
        $r['CharGen'].Count          | Should -Be 3
        $r['Empty'].Count            | Should -Be 0
    }

    It 'reads keys whatever their case, and keeps the case of values' {
        $ini = Join-Path $TestDrive 'b.ini'
        Set-TestFile $ini @('[General]', 'GamePath=C:\Games\Fallout 4')
        (Read-BffIniFile -Path $ini)['general']['gamepath'] | Should -Be 'C:\Games\Fallout 4'
    }

    It 'stops on a file that is not there' {
        { Read-BffIniFile -Path (Join-Path $TestDrive 'none.ini') } | Should -Throw
    }
}

Describe 'ConvertFrom-BffMO2Value' {
    It 'unwraps what Mod Organizer writes' -TestCases @(
        @{ Raw = '@ByteArray(C:\\Steam\\steamapps\\common\\Fallout 4)'; Value = 'C:\Steam\steamapps\common\Fallout 4' }
        @{ Raw = 'C:\\Plain';                                            Value = 'C:\Plain' }
        @{ Raw = '  Main  ';                                             Value = 'Main' }
        @{ Raw = '@Variant(\0\0\0\x7f\0\0\0\x18)';                       Value = '' }
        @{ Raw = '';                                                     Value = '' }
        @{ Raw = '   ';                                                  Value = '' }
    ) {
        ConvertFrom-BffMO2Value $Raw | Should -Be $Value
    }
}

Describe 'Get-BffFallout4Path' {
    BeforeEach {
        Mock Get-ItemProperty { throw 'no such key' }
    }

    It 'uses the folder it is told to use' {
        $game = New-TestGame
        Get-BffFallout4Path -Override "$game\" | Should -Be $game
    }

    It 'uses the game Mod Organizer runs when not told' {
        $game = New-TestGame
        Get-BffFallout4Path -MO2GamePath $game | Should -Be $game
    }

    It 'uses the install the registry knows last' {
        $game = New-TestGame
        Mock Get-ItemProperty { [pscustomobject]@{ 'Installed Path' = "$game\" } }
        Get-BffFallout4Path -Override (Join-Path $TestDrive 'not-a-game') | Should -Be $game
    }

    It 'passes over a folder on a drive that is not plugged in' {
        $game = New-TestGame
        Get-BffFallout4Path -Override "$($missingDrive):\Games\Fallout 4" -MO2GamePath $game | Should -Be $game
    }

    It 'passes over a folder without a Data folder in it' {
        $game = New-TestGame
        Get-BffFallout4Path -Override (New-TestDir (New-TestName)) -MO2GamePath $game | Should -Be $game
    }

    It 'says where to set it when there is no game anywhere' {
        { Get-BffFallout4Path } | Should -Throw -ExpectedMessage 'Could not find the Fallout 4 install folder. Set Paths.Fallout4 in Config\Settings.psd1.'
    }
}

Describe 'Get-BffMO2Info' {
    BeforeEach {
        $savedLocal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = New-TestDir (New-TestName)
        # Deep enough that walking up from it stays inside TestDrive.
        $lonelyRoot = New-TestDir (Join-Path (New-TestName) 'a\b\c\d\e')
    }
    AfterEach { $env:LOCALAPPDATA = $savedLocal }

    It 'uses the folder it is told to use' {
        $mo2 = New-TestMO2
        (Get-BffMO2Info -Override "$mo2\" -Root $lonelyRoot).Root | Should -Be $mo2
    }

    It 'warns about a folder that holds no Mod Organizer, and looks on' {
        $empty = New-TestDir (New-TestName)
        $r = Get-BffMO2Info -Override $empty -Root $lonelyRoot -WarningVariable warned -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        "$warned" | Should -Be "Paths.MO2 is set to '$empty' but there is no ModOrganizer.ini there."
    }

    It 'finds the instance it is installed in, walking up from the tool' {
        $mo2  = New-TestMO2
        $root = New-TestDir (Join-Path (Split-Path -Leaf (Split-Path -Parent $mo2)) 'MO2\mods\Black Face Fix\Tools\Black Face Fix')
        (Get-BffMO2Info -Root $root).IniPath | Should -Be (Join-Path $mo2 'ModOrganizer.ini')
    }

    It 'finds it through the mods folder the old version saved' {
        $mo2 = New-TestMO2
        Set-TestFile (Join-Path $lonelyRoot 'PS\MOInstall.txt') @("$mo2\mods  ")
        (Get-BffMO2Info -Root $lonelyRoot).Root | Should -Be $mo2
    }

    It 'passes over a saved mods folder that is gone, or that has no instance next to it' -TestCases @(
        @{ Saved = 'gone' }, @{ Saved = 'bare' }
    ) {
        $target = if ($Saved -eq 'gone') { Join-Path $TestDrive 'gone\mods' } else { New-TestDir (Join-Path (New-TestName) 'mods') }
        Set-TestFile (Join-Path $lonelyRoot 'PS\MOInstall.txt') @($target)
        Get-BffMO2Info -Root $lonelyRoot | Should -BeNullOrEmpty
    }

    It 'finds an instance in Mod Organizer''s own app data folder' {
        $inst = Join-Path $env:LOCALAPPDATA 'ModOrganizer\Fallout 4'
        Set-TestFile (Join-Path $inst 'ModOrganizer.ini') @('[General]')
        [void] (New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'ModOrganizer\Skyrim'))
        (Get-BffMO2Info -Root $lonelyRoot).Root | Should -Be $inst
    }

    It 'is $null when there is no Mod Organizer anywhere' {
        Get-BffMO2Info -Root $lonelyRoot | Should -BeNullOrEmpty
    }

    It 'is $null when the app data folder holds no instance' {
        [void] (New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'ModOrganizer\Empty') -Force)
        Get-BffMO2Info -Root $lonelyRoot | Should -BeNullOrEmpty
    }

    It 'puts mods, profiles and overwrite under the instance unless the ini moves them' {
        $mo2 = New-TestMO2 -IniLine @(
            '[General]'
            'gamePath=@ByteArray(C:\\Games\\Fallout 4)'
            'gameName=Fallout 4'
            'selected_profile=@ByteArray(Main)'
        )
        $r = Get-BffMO2Info -Override $mo2 -Root $lonelyRoot
        $r.ModsPath        | Should -Be (Join-Path $mo2 'mods')
        $r.ProfilesPath    | Should -Be (Join-Path $mo2 'profiles')
        $r.OverwritePath   | Should -Be (Join-Path $mo2 'overwrite')
        $r.GamePath        | Should -Be 'C:\Games\Fallout 4'
        $r.GameName        | Should -Be 'Fallout 4'
        $r.SelectedProfile | Should -Be 'Main'
    }

    It 'follows the folders the ini moves' {
        $mo2 = New-TestMO2 -IniLine @(
            '[Settings]'
            'mod_directory=@ByteArray(D:\\MO2Mods)'
            'profiles_directory=@ByteArray(D:\\MO2Profiles)'
            'overwrite_directory=@ByteArray(D:\\MO2Overwrite)'
        )
        $r = Get-BffMO2Info -Override $mo2 -Root $lonelyRoot
        $r.ModsPath      | Should -Be 'D:\MO2Mods'
        $r.ProfilesPath  | Should -Be 'D:\MO2Profiles'
        $r.OverwritePath | Should -Be 'D:\MO2Overwrite'
        $r.GamePath      | Should -Be ''
    }

    It 'puts them all under a moved base directory, even on a drive that is not plugged in' {
        $mo2 = New-TestMO2 -IniLine @('[Settings]', "base_directory=@ByteArray($($missingDrive):\\Base)")
        $r = Get-BffMO2Info -Override $mo2 -Root $lonelyRoot
        $r.ModsPath      | Should -Be "$($missingDrive):\Base\mods"
        $r.ProfilesPath  | Should -Be "$($missingDrive):\Base\profiles"
        $r.OverwritePath | Should -Be "$($missingDrive):\Base\overwrite"
    }

    It 'warns about a folder on a drive that is not plugged in, and looks on' {
        $r = Get-BffMO2Info -Override "$($missingDrive):\MO2" -Root $lonelyRoot -WarningVariable warned -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        "$warned" | Should -BeLike "Paths.MO2 is set to '$($missingDrive):\MO2' but*"
    }

    It 'walks up from the tool itself when not given a root' {
        Mock Get-BffRoot { $lonelyRoot }
        Get-BffMO2Info | Should -BeNullOrEmpty
    }
}

Describe 'Get-BffModList' {
    BeforeEach {
        $mo2  = New-TestMO2
        $info = New-TestMO2Info $mo2
        Set-TestFile (Join-Path $mo2 'profiles\Main\modlist.txt') @(
            '# This file was automatically generated by Mod Organizer.'
            '+Top Mod'
            '-Switched Off'
            ''
            '*DLC: Far Harbor'
            '+Faces_separator'
            '+Bottom Mod'
        )
    }

    It 'reads the selected profile''s mods, top of the list first' {
        $list = @(Get-BffModList -MO2 $info)
        @($list | ForEach-Object Name) | Should -Be @('Top Mod', 'Switched Off', 'Bottom Mod')
        @($list | ForEach-Object Priority) | Should -Be @(0, 1, 2)
        @($list | ForEach-Object Enabled) | Should -Be @($true, $false, $true)
    }

    It 'reads another profile when asked to' {
        Set-TestFile (Join-Path $mo2 'profiles\Other\modlist.txt') @('+Only One')
        @(Get-BffModList -MO2 $info -ProfileName 'Other' | ForEach-Object Name) | Should -Be @('Only One')
    }

    It 'is empty when no profile is selected' {
        @(Get-BffModList -MO2 (New-TestMO2Info $mo2 -Profile '')).Count | Should -Be 0
    }

    It 'warns, and is empty, when the profile has no modlist.txt' {
        $r = @(Get-BffModList -MO2 $info -ProfileName 'Missing' -WarningVariable warned -WarningAction SilentlyContinue)
        $r.Count | Should -Be 0
        "$warned" | Should -BeLike "modlist.txt not found for MO2 profile 'Missing' at '*'."
    }
}

Describe 'Test-BffHdDlc' {
    BeforeEach {
        $game = New-TestGame
        $mo2  = New-TestMO2
    }

    It 'goes by the archive when there is no Mod Organizer' {
        Test-BffHdDlc -Fallout4Path $game | Should -BeFalse
        Set-TestFile (Join-Path $game 'Data\DLCUltraHighResolution - Textures01.ba2') @('')
        Test-BffHdDlc -Fallout4Path $game | Should -BeTrue
    }

    It 'goes by the plugin list when Mod Organizer has one' {
        Set-TestFile (Join-Path $game 'Data\DLCUltraHighResolution - Textures01.ba2') @('')
        Set-TestFile (Join-Path $mo2 'profiles\Main\plugins.txt') @('*Fallout4.esm', 'DLCUltraHighResolution.esm')
        Test-BffHdDlc -Fallout4Path $game -MO2 (New-TestMO2Info $mo2) | Should -BeFalse -Because 'the plugin is there but switched off'
    }

    It 'sees the plugin switched on in the profile it is given' {
        Set-TestFile (Join-Path $mo2 'profiles\Other\plugins.txt') @('*Fallout4.esm', ' *DLCUltraHighResolution.esm')
        Test-BffHdDlc -Fallout4Path $game -MO2 (New-TestMO2Info $mo2) -ProfileName 'Other' | Should -BeTrue
    }

    It 'goes by the archive when the profile has no plugin list' {
        Set-TestFile (Join-Path $game 'Data\DLCUltraHighResolution - Main.ba2') @('')
        Test-BffHdDlc -Fallout4Path $game -MO2 (New-TestMO2Info $mo2) | Should -BeTrue
    }
}

Describe 'Get-BffF4eeConfig' {
    BeforeEach {
        $game = New-TestGame
        $mo2  = New-TestMO2
        $info = New-TestMO2Info $mo2
        $gameIni = Join-Path $game 'Data\F4SE\Plugins\f4ee.ini'
        function Get-ModIni { param([string] $Mod) Join-Path $mo2 "mods\$Mod\F4SE\Plugins\f4ee.ini" }
    }

    It 'is $null without LooksMenu' {
        Get-BffF4eeConfig -Fallout4Path $game -MO2 $info -ModList @() | Should -BeNullOrEmpty
        Get-BffF4eeConfig -Fallout4Path $game | Should -BeNullOrEmpty
    }

    It 'reads the tint size from the game''s own Data folder' {
        New-TestF4ee $gameIni -Width 2048
        $r = Get-BffF4eeConfig -Fallout4Path $game
        $r.Path       | Should -Be $gameIni
        $r.ModName    | Should -Be '(game data)'
        $r.TintWidth  | Should -Be 2048
        $r.TintHeight | Should -Be 2048
        $r.Overridden | Should -BeFalse
    }

    It 'takes the copy Mod Organizer serves: a mod over the game, the higher mod over the lower' {
        New-TestF4ee $gameIni -Width 1024
        New-TestF4ee (Get-ModIni 'Low')  -Width 2048
        New-TestF4ee (Get-ModIni 'High') -Width 4096
        New-TestF4ee (Get-ModIni 'Unlisted') -Width 512
        [void] (New-Item -ItemType Directory -Path (Join-Path $mo2 'mods\No LooksMenu'))
        $list = @(
            [pscustomobject]@{ Name = 'High'; Enabled = $true; Priority = 0 }
            [pscustomobject]@{ Name = 'Low';  Enabled = $true; Priority = 5 }
        )
        $r = Get-BffF4eeConfig -Fallout4Path $game -MO2 $info -ModList $list
        $r.ModName    | Should -Be 'High'
        $r.TintWidth  | Should -Be 4096
        $r.Overridden | Should -BeTrue
        @($r.AllFound | ForEach-Object ModName) | Should -Be @('High', 'Low', 'Unlisted', '(game data)')
    }

    It 'never takes the copy from a mod that is switched off' {
        New-TestF4ee $gameIni -Width 1024
        New-TestF4ee (Get-ModIni 'Off') -Width 4096
        $r = Get-BffF4eeConfig -Fallout4Path $game -MO2 $info -ModList @([pscustomobject]@{ Name = 'Off'; Enabled = $false; Priority = 0 })
        $r.ModName | Should -Be '(game data)'
    }

    It 'falls back to 1024 for a size it cannot read' {
        Set-TestFile $gameIni @('[CharGen]', 'uTintWidth=wide', 'uTintHeight=')
        $r = Get-BffF4eeConfig -Fallout4Path $game
        $r.TintWidth  | Should -Be 1024
        $r.TintHeight | Should -Be 1024
    }

    It 'falls back to 1024 when there is no CharGen section' {
        Set-TestFile $gameIni @('[Other]', 'x=1')
        (Get-BffF4eeConfig -Fallout4Path $game).TintWidth | Should -Be 1024
    }

    It 'leaves out the mods when the mods folder is gone' {
        New-TestF4ee $gameIni
        Remove-Item -LiteralPath (Join-Path $mo2 'mods') -Recurse
        (Get-BffF4eeConfig -Fallout4Path $game -MO2 $info -ModList @()).ModName | Should -Be '(game data)'
    }
}

Describe 'Resolve-BffProfile' {
    It 'picks a profile from the LooksMenu tint size and the HD DLC' -TestCases @(
        @{ Tint = 4096; Hd = $false; Name = '4K' }
        @{ Tint = 2048; Hd = $true;  Name = '2K' }
        @{ Tint = 1024; Hd = $true;  Name = 'HD DLC' }
        @{ Tint = 1024; Hd = $false; Name = 'Vanilla' }
    ) {
        $r = Resolve-BffProfile -HasHdDlc $Hd -F4ee ([pscustomobject]@{ TintWidth = $Tint }) -Root $tool
        $r.Profile.Name | Should -Be $Name
        @($r.Reasons) | Should -Contain "LooksMenu uTintWidth is $Tint"
    }

    It 'says why it picked the HD DLC profile' {
        $r = Resolve-BffProfile -HasHdDlc $true -Root $tool
        $r.Profile.Name | Should -Be 'HD DLC'
        @($r.Reasons) | Should -Be @('DLCUltraHighResolution is present and enabled')
    }

    It 'says why it picked vanilla, LooksMenu or not' {
        @((Resolve-BffProfile -HasHdDlc $false -Root $tool).Reasons) |
            Should -Be @('no HD Texture Pack DLC found', 'LooksMenu not installed')
    }

    It 'looks for the profiles next to the tool when not given a root' {
        Mock Get-BffRoot { $tool }
        (Resolve-BffProfile -HasHdDlc $false).Profile.Name | Should -Be 'Vanilla'
    }
}

Describe 'Test-BffProfileConsistency' {
    It 'has nothing to say without LooksMenu' {
        @(Test-BffProfileConsistency -Profile (New-TestProfile)).Count | Should -Be 0
    }

    It 'has nothing to say when the tint size matches the profile' {
        $f4ee = [pscustomobject]@{ TintWidth = 1024; TintHeight = 1024; Path = 'f4ee.ini'; Overridden = $false }
        @(Test-BffProfileConsistency -Profile (New-TestProfile) -F4ee $f4ee).Count | Should -Be 0
    }

    It 'warns that tints smaller than the profile get the textures downsampled' {
        $f4ee = [pscustomobject]@{ TintWidth = 1024; TintHeight = 1024; Path = 'C:\x\f4ee.ini'; Overridden = $false }
        $w = @(Test-BffProfileConsistency -Profile (New-TestProfile -Name '2K' -Tint 2048) -F4ee $f4ee)
        $w.Count | Should -Be 1
        $w[0] | Should -Be ("Profile '2K' targets 2048px face textures, but LooksMenu renders tint masks at 1024x1024. " +
                            'The engine will downsample your textures to 1024 and the tints will not match. ' +
                            'Set uTintWidth and uTintHeight to 2048 in C:\x\f4ee.ini.')
    }

    It 'warns that tints larger than the profile will not match' {
        $f4ee = [pscustomobject]@{ TintWidth = 1024; TintHeight = 2048; Path = 'C:\x\f4ee.ini'; Overridden = $false }
        $w = @(Test-BffProfileConsistency -Profile (New-TestProfile) -F4ee $f4ee)
        $w[0] | Should -BeLike "*renders tint masks at 1024x2048. Tints will be larger than the head textures*"
    }

    It 'names the other f4ee.ini files when more than one is installed' {
        $f4ee = [pscustomobject]@{
            TintWidth = 1024; TintHeight = 1024; Path = 'a'; ModName = 'High'; Overridden = $true
            AllFound = @([pscustomobject]@{ ModName = 'High' }, [pscustomobject]@{ ModName = 'Low' },
                         [pscustomobject]@{ ModName = '(game data)' })
        }
        @(Test-BffProfileConsistency -Profile (New-TestProfile) -F4ee $f4ee) |
            Should -Be @("More than one f4ee.ini is installed. 'High' wins on MO2 priority; also present in: Low, (game data).")
    }
}

Describe 'Get-BffEnvironment' {
    BeforeEach {
        $script:mo2Info = [pscustomobject]@{ Root = 'C:\MO2'; GamePath = 'C:\Games\Fallout 4'; SelectedProfile = 'Main' }
        Mock Get-BffMO2Info { $script:mo2Info }
        Mock Get-BffFallout4Path { 'C:\Games\Fallout 4' }
        Mock Get-BffModList { @([pscustomobject]@{ Name = 'Alpha'; Enabled = $true; Priority = 0 }) }
        Mock Test-BffHdDlc { $true }
        Mock Get-BffF4eeConfig { $null }

        function New-TestSettings {
            param([string] $Profile = 'Auto', [string] $MO2Profile = '')
            @{ Profile = $Profile; Paths = @{ MO2 = 'C:\MO2'; Fallout4 = ''; MO2Profile = $MO2Profile } }
        }
    }

    It 'puts together the game, Mod Organizer, the mod list and the profile it detected' {
        $e = Get-BffEnvironment -Settings (New-TestSettings) -Root $tool
        $e.Root                | Should -Be $tool
        $e.Fallout4Path        | Should -Be 'C:\Games\Fallout 4'
        $e.DataPath            | Should -Be 'C:\Games\Fallout 4\Data'
        $e.MO2                 | Should -Be $script:mo2Info
        $e.MO2ProfileName      | Should -Be 'Main'
        @($e.ModList).Count    | Should -Be 1
        $e.HasHdDlc            | Should -BeTrue
        $e.F4ee                | Should -BeNullOrEmpty
        $e.Profile.Name        | Should -Be 'HD DLC'
        $e.ProfileAutoDetected | Should -BeTrue
        $e.DetectedProfile.Name | Should -Be 'HD DLC'
        $e.DetectionReasons    | Should -Be @('DLCUltraHighResolution is present and enabled')
        $e.Warnings.Count      | Should -Be 0
    }

    It 'asks for the game Mod Organizer runs' {
        [void] (Get-BffEnvironment -Settings (New-TestSettings) -Root $tool)
        Should -Invoke Get-BffFallout4Path -Times 1 -Exactly -ParameterFilter { $MO2GamePath -eq 'C:\Games\Fallout 4' }
    }

    It 'uses the profile it is told to, and still says what it detected' {
        $e = Get-BffEnvironment -Settings (New-TestSettings -Profile '4K') -Root $tool
        $e.Profile.Name         | Should -Be '4K'
        $e.ProfileAutoDetected  | Should -BeFalse
        $e.DetectedProfile.Name | Should -Be 'HD DLC'
    }

    It 'lets the command line overrule the settings'' profile' {
        (Get-BffEnvironment -Settings (New-TestSettings -Profile '4K') -Root $tool -ProfileOverride '2K').Profile.Name |
            Should -Be '2K'
    }

    It 'reads the Mod Organizer profile it is told to' {
        $e = Get-BffEnvironment -Settings (New-TestSettings -MO2Profile 'Survival') -Root $tool
        $e.MO2ProfileName | Should -Be 'Survival'
        Should -Invoke Get-BffModList -Times 1 -Exactly -ParameterFilter { $ProfileName -eq 'Survival' }
    }

    It 'works without Mod Organizer, on the game alone' {
        $script:mo2Info = $null
        $e = Get-BffEnvironment -Settings (New-TestSettings) -Root $tool
        $e.MO2 | Should -BeNullOrEmpty
        @($e.ModList).Count | Should -Be 0
        Should -Invoke Get-BffModList -Times 0 -Exactly
        Should -Invoke Get-BffFallout4Path -Times 1 -Exactly -ParameterFilter { $MO2GamePath -eq '' }
    }

    It 'carries the profile warnings' {
        Mock Get-BffF4eeConfig { [pscustomobject]@{ TintWidth = 2048; TintHeight = 2048; Path = 'f4ee.ini'; Overridden = $false } }
        $e = Get-BffEnvironment -Settings (New-TestSettings -Profile 'Vanilla') -Root $tool
        $e.Warnings.Count | Should -Be 1
    }

    It 'looks next to the tool when not given a root' {
        Mock Get-BffRoot { $tool }
        (Get-BffEnvironment -Settings (New-TestSettings)).Root | Should -Be $tool
    }
}
