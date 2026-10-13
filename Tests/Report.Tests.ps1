# Unit tests for Report.ps1 - the console report, the CSV and the log file.
#
#   Invoke-Pester -Path .\Tests\Report.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Report.ps1'
#
# Pester 5. What a report says is read back the way a user reads it after the
# fact: from the log file, written with Save-BffLog into TestDrive. The console
# stays quiet (Set-BffQuiet) except in the tests about the console itself, where
# Write-Host is mocked.
#
# Type names are given as strings - New-Object BffPlan rather than
# [BffPlan]::new() - because a type literal in this file is resolved when the
# file is parsed, which is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'Report') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    # Every line written since the last Clear-BffLog.
    function Get-LoggedLine {
        $path = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N') + '.log')
        [void] (Save-BffLog -Path $path)
        return @(Get-Content -LiteralPath $path)
    }

    function New-TestPlan {
        param([string] $Action = 'Resize', [string] $Mod = 'Alpha', [string] $Name = 'MaleHead_s.dds',
              [string] $Reason = 'too big', [string] $Error = '')
        $t = New-Object BffTexture
        $t.ModName = $Mod; $t.Name = $Name; $t.Slot = 'Specular'; $t.Origin = 'Loose'
        $t.Width = 1024; $t.Height = 1024; $t.Format = 'BC5_UNORM'; $t.MipLevels = 11
        $t.FullName = "C:\MO2\mods\$Mod\textures\$Name"
        $p = New-Object BffPlan
        $p.Texture = $t; $p.Action = $Action; $p.Reason = $Reason; $p.Error = $Error
        $p.TargetWidth = 512; $p.TargetHeight = 512; $p.TargetFormat = 'BC5_UNORM'
        $p.SizeOk = $false; $p.FormatOk = $true
        $p.Destination = "C:\MO2\mods\$Mod [face-Vanilla]\textures\$Name"
        return $p
    }

    function New-TestEnvironment {
        $prof = New-Object BffProfile
        $prof.Name = 'Vanilla'; $prof.Description = 'Base game textures'
        $prof.Sizes = @{ Diffuse = 1024; Normal = 1024; Specular = 512; Other = 1024 }
        [pscustomobject]@{
            Fallout4Path        = 'C:\Games\Fallout 4'
            MO2                 = [pscustomobject]@{ Root = 'C:\MO2' }
            MO2ProfileName      = 'Main'
            ModList             = @([pscustomobject]@{ Enabled = $true }, [pscustomobject]@{ Enabled = $false })
            HasHdDlc            = $false
            F4ee                = [pscustomobject]@{ TintWidth = 1024; TintHeight = 1024; ModName = 'LooksMenu' }
            Profile             = $prof
            ProfileAutoDetected = $true
            DetectionReasons    = @('no HD Texture Pack DLC found', 'LooksMenu uTintWidth is 1024')
            Warnings            = @()
        }
    }

    Set-BffQuiet $true
}

AfterAll { Set-BffQuiet $false }

Describe 'the log' {
    BeforeEach { Clear-BffLog }

    It 'keeps every line, in order, for the log file' {
        Write-BffLine 'one'
        Write-BffLine
        Write-BffLine 'three' 'Red' -NoConsole
        Get-LoggedLine | Should -Be @('one', '', 'three')
    }

    It 'starts empty again after Clear-BffLog' {
        Write-BffLine 'gone'
        Clear-BffLog
        Write-BffLine 'kept'
        Get-LoggedLine | Should -Be @('kept')
    }

    It 'is written as UTF-8 without a byte order mark, making its folder first' {
        # A mod name with umlauts, as character codes so this file's own encoding
        # cannot get in the way.
        $name = "$([char]0xD6)lm$([char]0xFC)hle"
        Write-BffLine $name
        $path = Join-Path $TestDrive 'Logs\deep\run.log'
        Save-BffLog -Path $path | Should -Be $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..1] | Should -Be @(0xC3, 0x96)
        [System.IO.File]::ReadAllText($path).TrimEnd() | Should -Be $name
    }

    It 'saves a relative path where PowerShell is, not where the process started' {
        Push-Location $TestDrive
        try { Save-BffLog -Path 'bare.log' | Should -Be (Join-Path $TestDrive 'bare.log') }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $TestDrive 'bare.log') | Should -BeTrue
    }
}

Describe 'the console' {
    BeforeEach {
        Clear-BffLog
        Mock Write-Host { }
    }
    AfterEach { Set-BffQuiet $true }

    It 'prints each line in its colour' {
        Set-BffQuiet $false
        Write-BffLine 'hello' 'Cyan'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'hello' -and $ForegroundColor -eq 'Cyan' }
    }

    It 'prints nothing for a line meant for the log only' {
        Set-BffQuiet $false
        Write-BffLine 'quiet' -NoConsole
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'prints nothing at all while quiet, and still logs' {
        Set-BffQuiet
        Write-BffLine 'hidden'
        Should -Invoke Write-Host -Times 0 -Exactly
        Get-LoggedLine | Should -Be @('hidden')
    }
}

Describe 'Write-BffBanner' {
    BeforeEach { Clear-BffLog }

    It 'names the tool and its version, in a box that stays square' {
        Write-BffBanner -Version '4.2'
        $lines = Get-LoggedLine
        $lines | Should -Contain '  #     B L A C K   F A C E   F I X                                  #'
        $box = @($lines | Where-Object { $_ -match '#' })
        @($box | ForEach-Object Length | Sort-Object -Unique) | Should -Be @(70)
        ($lines | Where-Object { $_ -match 'version' }) | Should -BeLike '*version 4.2 *#'
    }

    It 'says 4.0 when not given a version' {
        Write-BffBanner
        (Get-LoggedLine | Where-Object { $_ -match 'version' }) | Should -BeLike '*version 4.0 *'
    }
}

Describe 'Write-BffEnvironmentReport' {
    BeforeEach { Clear-BffLog; $e = New-TestEnvironment }

    It 'describes the install, and the profile it picked and why' {
        Write-BffEnvironmentReport -Environment $e
        $lines = Get-LoggedLine
        $lines | Should -Contain '  Fallout 4        : C:\Games\Fallout 4'
        $lines | Should -Contain '  Mod Organizer 2  : C:\MO2'
        $lines | Should -Contain '  MO2 profile      : Main'
        $lines | Should -Contain '  Mods             : 1 enabled of 2'
        $lines | Should -Contain '  HD Texture DLC   : no'
        $lines | Should -Contain '  LooksMenu tints  : 1024x1024  (from LooksMenu)'
        $lines | Should -Contain 'Profile: Vanilla   (auto-detected)'
        $lines | Should -Contain '  Base game textures'
        $lines | Should -Contain '  because: no HD Texture Pack DLC found, LooksMenu uTintWidth is 1024'
        $lines | Should -Contain '  targets: diffuse 1024, normal 1024, specular 512'
    }

    It 'says when there is no Mod Organizer, no LooksMenu, and the HD DLC is there' {
        $e.MO2 = $null; $e.F4ee = $null; $e.HasHdDlc = $true
        Write-BffEnvironmentReport -Environment $e
        $lines = Get-LoggedLine
        $lines | Should -Contain '  Mod Organizer 2  : not found, scanning the game Data folder only'
        $lines | Should -Contain '  LooksMenu        : not installed'
        $lines | Should -Contain '  HD Texture DLC   : yes'
        $lines | Should -Not -Contain '  MO2 profile      : Main'
    }

    It 'says where a profile came from that was not detected, without a because' {
        $e.ProfileAutoDetected = $false
        Write-BffEnvironmentReport -Environment $e
        $lines = Get-LoggedLine
        $lines | Should -Contain 'Profile: Vanilla   (set in Settings.psd1 or on the command line)'
        @($lines | Where-Object { $_ -like '*because:*' }).Count | Should -Be 0
    }

    It 'ends with every warning' {
        $e.Warnings = @('first thing', 'second thing')
        Write-BffEnvironmentReport -Environment $e
        $lines = Get-LoggedLine
        $lines | Should -Contain 'WARNING: first thing'
        $lines | Should -Contain 'WARNING: second thing'
    }
}

Describe 'Write-BffPlanTable' {
    BeforeEach { Clear-BffLog }

    It 'says so when nothing changes' {
        Write-BffPlanTable -Plan @((New-TestPlan -Action 'Skip'))
        Get-LoggedLine | Should -Contain 'Nothing needs changing - every face texture already matches the profile.'
    }

    It 'lists what changes, with what it is now and what it will be' {
        Write-BffPlanTable -Plan @((New-TestPlan), (New-TestPlan -Action 'Skip' -Name 'Other_d.dds'))
        $lines = Get-LoggedLine
        $lines | Should -Contain 'Textures that will change (1)'
        $row = @($lines | Where-Object { $_ -like '  Alpha*' })
        $row.Count | Should -Be 1
        $row[0] | Should -Match '^  Alpha\s+MaleHead_s\.dds\s+Specular\s+1024x1024 BC5_UNORM\s+512x512 BC5_UNORM\s+Resize$'
    }

    It 'shortens a name too long for its column' {
        Write-BffPlanTable -Plan @((New-TestPlan -Mod ('M' * 40)))
        (Get-LoggedLine | Where-Object { $_ -like '  MMM*' }) | Should -BeLike ('  ' + ('M' * 27) + '~ *')
    }

    It 'stops at MaxRows and points at the CSV for the rest' {
        Write-BffPlanTable -Plan @(1..5 | ForEach-Object { New-TestPlan -Name "T$_.dds" }) -MaxRows 2
        $lines = Get-LoggedLine
        @($lines | Where-Object { $_ -like '  Alpha*' }).Count | Should -Be 2
        $lines | Should -Contain '  ... and 3 more, see the CSV for the full list'
    }

    It 'lists every row with -All' {
        Write-BffPlanTable -Plan @(1..5 | ForEach-Object { New-TestPlan -Name "T$_.dds" }) -MaxRows 2 -All
        $lines = Get-LoggedLine
        @($lines | Where-Object { $_ -like '  Alpha*' }).Count | Should -Be 5
        @($lines | Where-Object { $_ -like '*more, see the CSV*' }).Count | Should -Be 0
    }

    It 'groups the reasons, the most common first' {
        Write-BffPlanTable -Plan @((New-TestPlan -Reason 'rare'), (New-TestPlan -Reason 'common'), (New-TestPlan -Reason 'common'))
        $lines = Get-LoggedLine
        $why = [array]::IndexOf($lines, 'Why')
        $lines[$why + 1] | Should -Be '      2 x  common'
        $lines[$why + 2] | Should -Be '      1 x  rare'
    }

    It 'lists what it leaves alone on purpose, grouped by why' {
        Write-BffPlanTable -Plan @((New-TestPlan -Action 'Review' -Reason 'not square'), (New-TestPlan -Action 'Review' -Reason 'not square'))
        $lines = Get-LoggedLine
        $lines | Should -Contain 'Left alone on purpose (2)'
        $lines | Should -Contain '      2 x  not square'
    }

    It 'lists the first ten it could not read, and why' {
        Write-BffPlanTable -Plan @(1..12 | ForEach-Object { New-TestPlan -Action 'Error' -Name "Bad$_.dds" -Error 'no dimensions' })
        $lines = Get-LoggedLine
        $lines | Should -Contain 'Could not be read (12)'
        $lines | Should -Contain '  Bad1.dds: no dimensions'
        @($lines | Where-Object { $_ -like '  Bad*' }).Count | Should -Be 10
    }
}

Describe 'Format-BffTruncate' {
    It 'shortens with a tilde, keeps what fits, and turns nothing into an empty string' -TestCases @(
        @{ Text = 'abcdefgh'; Length = 5; Expected = 'abcd~' }
        @{ Text = 'abcde';    Length = 5; Expected = 'abcde' }
        @{ Text = '';         Length = 5; Expected = '' }
        @{ Text = $null;      Length = 5; Expected = '' }
    ) {
        Format-BffTruncate $Text $Length | Should -Be $Expected
    }
}

Describe 'Write-BffSummary' {
    BeforeEach {
        Clear-BffLog
        $summary = [pscustomobject]@{
            Total = 10; Skipped = 4; Changing = 3; Review = 2; Failed = 1
            BySlot = @([pscustomobject]@{ Slot = 'Specular'; Count = 2 }, [pscustomobject]@{ Slot = 'Diffuse'; Count = 1 })
            ByMod  = @(1..20 | ForEach-Object { [pscustomobject]@{ Mod = "Mod $_"; Count = 1 } })
        }
    }

    It 'counts every outcome, and the work per slot and per mod' {
        Write-BffSummary -Summary $summary
        $lines = Get-LoggedLine
        $lines | Should -Contain '  scanned            : 10'
        $lines | Should -Contain '  already correct    : 4'
        $lines | Should -Contain '  will change        : 3'
        $lines | Should -Contain '  left alone         : 2'
        $lines | Should -Contain '  unreadable         : 1'
        $lines | Should -Contain '    Specular   2'
        $lines | Should -Contain '  changes per mod:'
        @($lines | Where-Object { $_ -like '    Mod *' }).Count | Should -Be 15
    }

    It 'leaves out the lines that would say zero or nothing' {
        $summary.Changing = 0; $summary.Review = 0; $summary.Failed = 0; $summary.BySlot = @(); $summary.ByMod = $null
        Write-BffSummary -Summary $summary
        $lines = Get-LoggedLine
        $lines | Should -Contain '  will change        : 0'
        @($lines | Where-Object { $_ -match 'left alone|unreadable|changes per' }).Count | Should -Be 0
    }

    It 'lists the face textures it found inside archives, per mod' {
        $finding = @(
            [pscustomobject]@{ Texture = [pscustomobject]@{ ModName = 'Packed' } }
            [pscustomobject]@{ Texture = [pscustomobject]@{ ModName = 'Packed' } }
            [pscustomobject]@{ Texture = [pscustomobject]@{ ModName = 'Other' } }
        )
        Write-BffSummary -Summary $summary -ArchiveFinding $finding
        $lines = Get-LoggedLine
        $lines | Should -Contain 'Face textures found inside BA2 archives (3)'
        ($lines | Where-Object { $_ -like '    Packed*' }) | Should -Match '^    Packed\s+2$'
    }

    It 'says nothing about archives when none were found' {
        Write-BffSummary -Summary $summary -ArchiveFinding @()
        @(Get-LoggedLine | Where-Object { $_ -like '*BA2*' }).Count | Should -Be 0
    }
}

Describe 'Export-BffPlanCsv' {
    It 'writes a row per plan with everything needed to audit it, making its folder first' {
        $path = Join-Path $TestDrive 'Logs\nested\plans.csv'
        Export-BffPlanCsv -Plan @((New-TestPlan), (New-TestPlan -Action 'Error' -Error 'bad')) -Path $path | Should -Be $path
        $rows = @(Import-Csv -LiteralPath $path)
        $rows.Count | Should -Be 2
        $r = $rows[0]
        $r.Mod | Should -Be 'Alpha'
        $r.File | Should -Be 'MaleHead_s.dds'
        "$($r.SourceWidth)x$($r.SourceHeight) $($r.SourceFormat) $($r.SourceMips)" | Should -Be '1024x1024 BC5_UNORM 11'
        "$($r.TargetWidth)x$($r.TargetHeight) $($r.TargetFormat)" | Should -Be '512x512 BC5_UNORM'
        $r.SizeOk   | Should -Be 'False'
        $r.FormatOk | Should -Be 'True'
        $r.Action   | Should -Be 'Resize'
        $r.Reason   | Should -Be 'too big'
        $r.Destination | Should -Be 'C:\MO2\mods\Alpha [face-Vanilla]\textures\MaleHead_s.dds'
        $rows[1].Error | Should -Be 'bad'
        @($r.PSObject.Properties.Name) | Should -Be @('Mod', 'File', 'Slot', 'Origin', 'SourceWidth', 'SourceHeight',
            'SourceFormat', 'SourceMips', 'TargetWidth', 'TargetHeight', 'TargetFormat', 'SizeOk', 'FormatOk', 'Action',
            'Reason', 'FullName', 'ArchivePath', 'Destination', 'Error')
    }

    It 'takes a single plan' {
        $path = Join-Path $TestDrive 'one.csv'
        [void] (Export-BffPlanCsv -Plan (New-TestPlan) -Path $path)
        @(Import-Csv -LiteralPath $path).Count | Should -Be 1
    }

    It 'can be written to a bare file name, with no folder to make' {
        Push-Location $TestDrive
        try { Export-BffPlanCsv -Plan (New-TestPlan) -Path 'bare.csv' | Should -Be 'bare.csv' }
        finally { Pop-Location }
    }
}
