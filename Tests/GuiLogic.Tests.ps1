# Unit tests for GuiLogic.ps1 - what the window decides, tested without it.
#
#   Invoke-Pester -Path .\Tests\GuiLogic.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\GuiLogic.ps1'
#
# Pester 5. Every function here takes values and returns values, so no window, no
# sandbox and no texconv are needed, and the whole file runs in a second or two.
#
# Type names are given as strings - New-Object BffPlan rather than [BffPlan]::new()
# - because a type literal in this file is resolved when the file is parsed, which
# is before BeforeAll has loaded the classes.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'Environment', 'Planner', 'Report', 'Icon', 'GuiLogic') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    function New-TestPlan {
        param(
            [string] $Action    = 'Skip',
            [string] $Mod       = 'Mod A',
            [string] $Name      = 'MaleHead_d.dds',
            [string] $Rel       = 'textures\actors\character\BaseHumanMale\MaleHead_d.dds',
            [string] $Origin    = 'Loose',
            [string] $Archive   = '',
            [bool]   $Tint      = $false,
            [string] $MatchedBy = 'head name'
        )
        $t = New-Object BffTexture
        $t.ModName      = $Mod
        $t.Name         = $Name
        $t.RelativePath = $Rel
        $t.FullName     = if ($Origin -eq 'BA2') { $Rel } else { "C:\MO2\mods\$Mod\$Rel" }
        $t.Origin       = $Origin
        $t.ArchivePath  = $Archive
        $t.Width = 1024; $t.Height = 1024; $t.Format = 'BC7_UNORM'; $t.Slot = 'Diffuse'
        $t.IsTintMask   = $Tint
        $t.MatchedBy    = $MatchedBy

        $p = New-Object BffPlan
        $p.Texture = $t
        $p.Action  = $Action
        $p.TargetWidth = 1024; $p.TargetHeight = 1024; $p.TargetFormat = 'BC3_UNORM'
        return $p
    }

    function New-TestProfile {
        $p = New-Object BffProfile
        $p.Name        = 'Vanilla'
        $p.Description = 'Base game'
        $p.Sizes       = @{ Diffuse = 1024; Normal = 1024; Specular = 512; Other = 1024 }
        return $p
    }

    function New-TestSettings {
        return @{
            Scope      = @{ OnlyEnabledMods = $false; IncludeArchives = $false; FixArchives = $false
                            IncludeFaceCustomization = $false; FixGameArchives = $false }
            Conversion = @{ ForceVanillaFormats = $false }
            Output     = @{ Mode = 'OutputMod' }
        }
    }
}

Describe 'Get-BffGridColumn' {
    It 'lists the columns in the order the grid shows them' {
        (Get-BffGridColumn).Name | Should -Be @('Mod', 'Folder', 'File', 'Slot', 'Now', 'Target', 'Action', 'Mark', 'FullPath')
    }

    It 'has exactly one image column, the marks' {
        @(Get-BffGridColumn | Where-Object Image).Name | Should -Be 'Mark'
    }

    It 'starts with only the full path hidden' {
        @(Get-BffGridColumn | Where-Object Hidden).Name | Should -Be 'FullPath'
    }

    It 'gives the full path column a readable header' {
        (Get-BffGridColumn | Where-Object Name -eq 'FullPath').Header | Should -Be 'Full path'
    }
}

Describe 'Get-BffRowFolder' {
    It 'drops the install path, the mod and the texture root' {
        Get-BffRowFolder -Plan (New-TestPlan) | Should -Be 'BaseHumanMale'
    }

    It 'keeps folders below the texture root' {
        $p = New-TestPlan -Rel 'textures\actors\character\Character Assets\FaceDetails\Freckles_d.dds'
        Get-BffRowFolder -Plan $p | Should -Be 'Character Assets\FaceDetails'
    }

    It 'shows a backslash for a file sitting directly in the texture root' {
        Get-BffRowFolder -Plan (New-TestPlan -Rel 'textures\actors\character\Loose_d.dds') | Should -Be '\'
    }

    It 'falls back to the full path when there is no relative one' {
        $p = New-TestPlan
        $p.Texture.RelativePath = ''
        Get-BffRowFolder -Plan $p | Should -Be 'C:\MO2\mods\Mod A\textures\actors\character\BaseHumanMale'
    }

    It 'puts the archive name in front for a BA2 entry' {
        $p = New-TestPlan -Origin 'BA2' -Archive 'C:\MO2\mods\Mod A\Mod A - Textures.ba2'
        Get-BffRowFolder -Plan $p | Should -Be 'Mod A - Textures.ba2 -> BaseHumanMale'
    }

    It 'gives the absolute path with -Full' {
        Get-BffRowFolder -Plan (New-TestPlan) -Full |
            Should -Be 'C:\MO2\mods\Mod A\textures\actors\character\BaseHumanMale\MaleHead_d.dds'
    }

    It 'gives the archive path and the entry with -Full for a BA2 entry' {
        $p = New-TestPlan -Origin 'BA2' -Archive 'C:\x\A.ba2'
        Get-BffRowFolder -Plan $p -Full | Should -Be 'C:\x\A.ba2 -> textures\actors\character\BaseHumanMale\MaleHead_d.dds'
    }
}

Describe 'Get-BffGridRowValue' {
    It 'gives one value per column' {
        # Not @(...): the function hands back one object, the array, so wrapping it
        # makes an array of one.
        (Get-BffGridRowValue -Plan (New-TestPlan)).Count | Should -Be @(Get-BffGridColumn).Count
    }

    It 'comes back as a single array, not unrolled down the pipeline' {
        $v = Get-BffGridRowValue -Plan (New-TestPlan)
        , $v | Should -BeOfType [object[]]
    }

    It 'leaves the mark cell empty for the image to be assigned after' {
        $marks = [array]::IndexOf(@((Get-BffGridColumn).Name), 'Mark')
        (Get-BffGridRowValue -Plan (New-TestPlan))[$marks] | Should -BeNullOrEmpty
    }

    It 'fills the cells in column order' {
        $v = Get-BffGridRowValue -Plan (New-TestPlan -Action 'Reformat')
        $v[0] | Should -Be 'Mod A'
        $v[1] | Should -Be 'BaseHumanMale'
        $v[2] | Should -Be 'MaleHead_d.dds'
        $v[3] | Should -Be 'Diffuse'
        $v[4] | Should -Be '1024x1024 BC7_UNORM'
        $v[5] | Should -Be '1024x1024 BC3_UNORM'
        $v[6] | Should -Be 'Reformat'
        $v[8] | Should -Match '^C:\\MO2\\mods\\'
    }
}

Describe 'Get-BffRowColor' {
    It 'greys out rows that are left alone' {
        (Get-BffRowColor -Action 'Skip').Name | Should -Be 'Gray'
    }

    # Plain numbers, not [System.Drawing.Color]: test cases are built during
    # discovery, before BeforeAll has loaded the assembly. Firebrick is 178,34,34.
    It 'colours <Action> rows' -TestCases @(
        @{ Action = 'Review';            R = 160; G = 90; B = 0 }
        @{ Action = 'Error';             R = 178; G = 34; B = 34 }
        @{ Action = 'Resize';            R = 0;   G = 70; B = 140 }
        @{ Action = 'ResizeAndReformat'; R = 0;   G = 70; B = 140 }
    ) {
        $c = Get-BffRowColor -Action $Action
        @($c.R, $c.G, $c.B) | Should -Be @($R, $G, $B)
    }
}

Describe 'Get-BffModSelection' {
    It 'means no filter while the picker is still empty' {
        Get-BffModSelection -Item @() -Checked @() | Should -BeNullOrEmpty
    }

    It 'holds exactly the ticked mods' {
        $set = Get-BffModSelection -Item @('A', 'B', 'C') -Checked @('A', 'C')
        $set.Keys | Sort-Object | Should -Be @('A', 'C')
    }

    It 'is an empty set, not "no filter", when nothing is ticked' {
        $set = Get-BffModSelection -Item @('A') -Checked @()
        # Tested against $null explicitly: -BeNullOrEmpty counts an empty hashtable
        # as empty too, which is exactly the difference this case is about.
        $null -eq $set | Should -BeFalse -Because 'an empty picker and an untouched one mean different things'
        $set | Should -BeOfType [hashtable]
        $set.Count | Should -Be 0
    }

    It 'ignores empty names' {
        (Get-BffModSelection -Item @('A') -Checked @('A', '')).Keys | Should -Be @('A')
    }
}

Describe 'Get-BffPendingModSelection' {
    It 'adds the box that is being ticked' {
        $set = Get-BffPendingModSelection -Item @('A', 'B', 'C') -Checked @('A') -Index 2 -NowChecked $true
        $set.Keys | Sort-Object | Should -Be @('A', 'C')
    }

    It 'drops the box that is being unticked' {
        $set = Get-BffPendingModSelection -Item @('A', 'B') -Checked @('A', 'B') -Index 0 -NowChecked $false
        $set.Keys | Should -Be @('B')
    }

    It 'does not count a box twice when it is ticked again' {
        $set = Get-BffPendingModSelection -Item @('A') -Checked @('A') -Index 0 -NowChecked $true
        $set.Count | Should -Be 1
    }

    It 'leaves an empty set, not "no filter", when the last box is unticked' {
        $set = Get-BffPendingModSelection -Item @('A') -Checked @('A') -Index 0 -NowChecked $false
        $null -eq $set | Should -BeFalse
        $set.Count | Should -Be 0
    }

    It 'ignores empty names among the ticked' {
        $set = Get-BffPendingModSelection -Item @('A', 'B') -Checked @('', 'A') -Index 1 -NowChecked $true
        $set.Keys | Sort-Object | Should -Be @('A', 'B')
    }
}

Describe 'Get-BffModPickerItem' {
    It 'lists each mod with work once, sorted' {
        $plans = @(
            (New-TestPlan -Action 'Resize' -Mod 'Zed')
            (New-TestPlan -Action 'Reformat' -Mod 'Alpha')
            (New-TestPlan -Action 'Resize' -Mod 'Alpha')
        )
        Get-BffModPickerItem -Plan $plans | Should -Be @('Alpha', 'Zed')
    }

    It 'leaves out mods with nothing to do' {
        $plans = @((New-TestPlan -Action 'Skip' -Mod 'Done'), (New-TestPlan -Action 'Resize' -Mod 'Busy'))
        Get-BffModPickerItem -Plan $plans | Should -Be @('Busy')
    }

    It 'copes with no plans and with empty entries' {
        @(Get-BffModPickerItem -Plan @()).Count | Should -Be 0
        Get-BffModPickerItem -Plan @($null, (New-TestPlan -Action 'Resize' -Mod 'M')) | Should -Be @('M')
    }
}

Describe 'Select-BffGridPlan' {
    BeforeAll {
        $script:plans = @(
            (New-TestPlan -Action 'Skip'   -Mod 'A')
            (New-TestPlan -Action 'Resize' -Mod 'A')
            (New-TestPlan -Action 'Resize' -Mod 'B')
            (New-TestPlan -Action 'Review' -Mod 'B')
        )
    }

    It 'shows everything with no filter at all' {
        @(Select-BffGridPlan -Plan $plans -OnlyChanges $false -Selection $null).Count | Should -Be 4
    }

    It 'hides rows that are left alone when asked to' {
        @(Select-BffGridPlan -Plan $plans -OnlyChanges $true -Selection $null).Action | Should -Not -Contain 'Skip'
    }

    It 'drops work in an unticked mod' {
        $rows = @(Select-BffGridPlan -Plan $plans -OnlyChanges $false -Selection @{ A = $true })
        @($rows | Where-Object { $_.Texture.ModName -eq 'B' -and $_.Action -eq 'Resize' }).Count | Should -Be 0
    }

    It 'keeps rows that claim no work, even in an unticked mod' {
        $rows = @(Select-BffGridPlan -Plan $plans -OnlyChanges $false -Selection @{ A = $true })
        @($rows | Where-Object { $_.Texture.ModName -eq 'B' }).Action | Should -Be @('Review')
    }

    It 'copes with empty entries' {
        @(Select-BffGridPlan -Plan @($null) -OnlyChanges $false -Selection $null).Count | Should -Be 0
    }
}

Describe 'Select-BffPlanToApply' {
    BeforeAll {
        $script:plans = @(
            (New-TestPlan -Action 'Skip'     -Mod 'A')
            (New-TestPlan -Action 'Resize'   -Mod 'A')
            (New-TestPlan -Action 'Reformat' -Mod 'B')
        )
    }

    It 'takes every plan with work when nothing filters' {
        @(Select-BffPlanToApply -Plan $plans -Selection $null).Action | Should -Be @('Resize', 'Reformat')
    }

    It 'takes only work in a ticked mod' {
        @(Select-BffPlanToApply -Plan $plans -Selection @{ B = $true }).Texture.ModName | Should -Be @('B')
    }

    It 'takes nothing when nothing is ticked' {
        @(Select-BffPlanToApply -Plan $plans -Selection @{}).Count | Should -Be 0
    }
}

Describe 'Update-BffSettingsFromChoice' {
    It 'copies every tick into the settings' {
        $s = New-TestSettings
        Update-BffSettingsFromChoice -Settings $s -Choice @{
            OnlyEnabledMods = $true; IncludeArchives = $true; FixArchives = $true
            IncludeFaceCustomization = $true; ForceVanillaFormats = $true; InPlace = $true
        }
        $s.Scope.OnlyEnabledMods          | Should -BeTrue
        $s.Scope.IncludeArchives          | Should -BeTrue
        $s.Scope.FixArchives              | Should -BeTrue
        $s.Scope.IncludeFaceCustomization | Should -BeTrue
        $s.Conversion.ForceVanillaFormats | Should -BeTrue
        $s.Output.Mode                    | Should -Be 'InPlace'
    }

    It 'will not fix archives it is not reading' {
        $s = New-TestSettings
        Update-BffSettingsFromChoice -Settings $s -Choice @{ IncludeArchives = $false; FixArchives = $true }
        $s.Scope.FixArchives | Should -BeFalse
    }

    It 'writes to output mods unless told to work in place' {
        $s = New-TestSettings
        $s.Output.Mode = 'InPlace'
        Update-BffSettingsFromChoice -Settings $s -Choice @{}
        $s.Output.Mode | Should -Be 'OutputMod'
    }

    It 'reads a missing tick as off' {
        $s = New-TestSettings
        $s.Scope.OnlyEnabledMods = $true
        Update-BffSettingsFromChoice -Settings $s -Choice @{}
        $s.Scope.OnlyEnabledMods | Should -BeFalse
    }
}

Describe 'Get-BffProfileInfoText' {
    It 'names the three sizes and the description' {
        Get-BffProfileInfoText -Profile (New-TestProfile) |
            Should -Be 'diffuse 1024 | normal 1024 | specular 512   -   Base game'
    }
}

Describe 'Get-BffProfileWarningText' {
    It 'is empty when the profile fits the installed game' {
        Mock Test-BffProfileConsistency { }
        Get-BffProfileWarningText -Profile (New-TestProfile) | Should -Be ''
    }

    It 'joins every warning onto one line' {
        Mock Test-BffProfileConsistency { 'first.'; 'second.' }
        Get-BffProfileWarningText -Profile (New-TestProfile) | Should -Be 'first.  second.'
    }
}

Describe 'Get-BffScanStatusText' {
    BeforeAll {
        $script:summary = [pscustomobject]@{ Total = 9; Skipped = 3; Changing = 5; Review = 1 }
    }

    It 'counts what was found and points at the report' {
        Get-BffScanStatusText -Summary $summary -ArchiveCount 0 -CsvPath 'Logs\r.csv' |
            Should -Be '9 scanned, 3 already correct, 5 to change, 1 left alone. Report: Logs\r.csv'
    }

    It 'mentions archive textures that were only inspected' {
        Get-BffScanStatusText -Summary $summary -ArchiveCount 2 -CsvPath 'r.csv' |
            Should -Match '2 more sit inside BA2 archives \(inspected only\)\. Report: r\.csv$'
    }
}

Describe 'Get-BffOutputModList' {
    It 'names each output mod once, sorted, and skips plans without one' {
        Mock Get-BffOutputModDisplayName {
            switch ($Plan.Texture.ModName) { 'B' { 'B [face-Vanilla]' } 'A' { 'A [face-Vanilla]' } default { '' } }
        }
        $plans = @((New-TestPlan -Mod 'B'), (New-TestPlan -Mod 'A'), (New-TestPlan -Mod 'A'), (New-TestPlan -Mod 'None'), $null)
        Get-BffOutputModList -Plan $plans | Should -Be @('A [face-Vanilla]', 'B [face-Vanilla]')
    }
}

Describe 'Get-BffApplyConfirmText' {
    It 'lists the output mods it will create' {
        $t = Get-BffApplyConfirmText -Count 3 -Mode 'OutputMod' -OutputMod @('A [face-Vanilla]', 'B [face-Vanilla]')
        $t | Should -Match '^Convert 3 texture\(s\)\?'
        $t | Should -Match '2 new mod folder\(s\):'
        $t | Should -Match 'A \[face-Vanilla\]'
    }

    It 'says the originals are overwritten, with backups, in place' {
        Get-BffApplyConfirmText -Count 1 -Mode 'InPlace' | Should -Match 'the original files \(a \.backup is kept'
    }
}

Describe 'Get-BffApplyResultText' {
    BeforeAll {
        function New-Result {
            param([bool] $Ok, [string] $Name = 'x.dds', [string] $Error = 'boom')
            [pscustomobject]@{ Success = $Ok; Plan = (New-TestPlan -Name $Name); Error = $Error }
        }
    }

    It 'reports a clean run, with what to do next in Mod Organizer' {
        $r = Get-BffApplyResultText -Result @((New-Result $true), (New-Result $true)) -Mode 'OutputMod' -OutputMod @('A [face-Vanilla]')
        $r.Failed | Should -BeFalse
        $r.Text   | Should -Match '^Converted 2 texture\(s\)\.'
        $r.Text   | Should -Match 'drag it directly BELOW'
        $r.Text   | Should -Match 'A \[face-Vanilla\]'
    }

    It 'names what failed and why' {
        $r = Get-BffApplyResultText -Result @((New-Result $true), (New-Result $false 'bad.dds' 'no output')) -Mode 'OutputMod'
        $r.Failed | Should -BeTrue
        $r.Text   | Should -Match '1 failed:'
        $r.Text   | Should -Match 'bad\.dds: no output'
    }

    It 'lists at most ten failures' {
        $many = 1..12 | ForEach-Object { New-Result $false "f$_.dds" }
        $r = Get-BffApplyResultText -Result $many -Mode 'OutputMod'
        $r.Text | Should -Match '12 failed:'
        ([regex]::Matches($r.Text, '\.dds: ')).Count | Should -Be 10
    }

    It 'has no Mod Organizer step after an in-place run' {
        (Get-BffApplyResultText -Result @(New-Result $true) -Mode 'InPlace').Text | Should -Not -Match 'Mod Organizer'
    }

    It 'copes with empty entries' {
        (Get-BffApplyResultText -Result @($null) -Mode 'InPlace').Text | Should -Be 'Converted 0 texture(s).'
    }
}

Describe 'Get-BffRestoreTarget' {
    It 'searches the MO2 mods folder when there is one' {
        Get-BffRestoreTarget -Environment ([pscustomobject]@{ MO2 = [pscustomobject]@{ ModsPath = 'C:\MO2\mods' }; DataPath = 'C:\G\Data' }) |
            Should -Be 'C:\MO2\mods'
    }

    It 'searches the game Data folder without Mod Organizer' {
        Get-BffRestoreTarget -Environment ([pscustomobject]@{ MO2 = $null; DataPath = 'C:\G\Data' }) | Should -Be 'C:\G\Data'
    }
}

Describe 'Get-BffArchivePlanSet' {
    BeforeAll {
        $script:envr = [pscustomobject]@{ Profile = (New-TestProfile) }

        function New-Found {
            param([string] $Kind = 'Mod', [string] $Action = 'Resize', [string] $Path = 'textures\actors\character\BaseHumanMale\MaleHead_s.dds')
            $p = New-TestPlan -Origin 'BA2' -Archive "C:\a\$Kind.ba2" -Rel $Path -Name (Split-Path -Leaf $Path) -Action $Action
            [pscustomobject]@{ Texture = $p.Texture; SourceKind = $Kind; Entry = "entry:$Kind"; WantAction = $Action }
        }
    }

    BeforeEach {
        # New-BffPlan is the planner's business; here only the sorting is under test,
        # so the plan it hands back simply carries the action the case asks for.
        Mock New-BffPlan {
            $p = New-Object BffPlan
            $p.Texture = $Texture
            $p.Action  = $script:nextAction[$Texture.ArchivePath]
            $p
        }
        Mock Get-BffDestination { 'C:\out\' + $Texture.Name }
        $script:nextAction = @{}
    }

    It 'reports archive textures it may not fix, and fixes none of them' {
        $f = New-Found -Kind 'Mod'
        $script:nextAction[$f.Texture.ArchivePath] = 'Resize'
        $s = New-TestSettings

        $r = Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings $s -SlotRules @{}
        @($r.Plans).Count    | Should -Be 0
        @($r.Findings).Count | Should -Be 1
        $r.Entries.Count     | Should -Be 0
    }

    It 'fixes a mod archive once fixing archives is on' {
        $f = New-Found -Kind 'Mod'
        $script:nextAction[$f.Texture.ArchivePath] = 'Resize'
        $s = New-TestSettings; $s.Scope.FixArchives = $true

        $r = Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings $s -SlotRules @{}
        @($r.Plans).Count        | Should -Be 1
        @($r.Plans)[0].Destination | Should -Be 'C:\out\MaleHead_s.dds'
        @($r.Findings).Count     | Should -Be 0
        $r.Entries['C:\a\Mod.ba2::textures\actors\character\BaseHumanMale\MaleHead_s.dds'] | Should -Be 'entry:Mod'
    }

    It 'leaves the game''s own archives alone unless that is allowed too' {
        $f = New-Found -Kind 'GameData'
        $script:nextAction[$f.Texture.ArchivePath] = 'Resize'
        $s = New-TestSettings; $s.Scope.FixArchives = $true

        $r = Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings $s -SlotRules @{}
        @($r.Plans).Count    | Should -Be 0
        @($r.Findings).Count | Should -Be 1
    }

    It 'fixes the game''s own archives when FixGameArchives is on' {
        $f = New-Found -Kind 'GameData'
        $script:nextAction[$f.Texture.ArchivePath] = 'Resize'
        $s = New-TestSettings; $s.Scope.FixArchives = $true; $s.Scope.FixGameArchives = $true

        @((Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings $s -SlotRules @{}).Plans).Count | Should -Be 1
    }

    It 'says nothing about archive textures that are already right' {
        $f = New-Found -Kind 'Mod'
        $script:nextAction[$f.Texture.ArchivePath] = 'Skip'
        $s = New-TestSettings; $s.Scope.FixArchives = $true

        $r = Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings $s -SlotRules @{}
        @($r.Plans).Count + @($r.Findings).Count | Should -Be 0
    }

    It 'skips entries that carry no texture' {
        $r = Get-BffArchivePlanSet -Archive @($null, [pscustomobject]@{ Texture = $null }) `
                                   -Environment $envr -Settings (New-TestSettings) -SlotRules @{}
        @($r.Plans).Count + @($r.Findings).Count | Should -Be 0
        Should -Invoke New-BffPlan -Times 0 -Exactly
    }

    It 'passes -Force on to the planner' {
        $f = New-Found
        $script:nextAction[$f.Texture.ArchivePath] = 'Skip'
        [void] (Get-BffArchivePlanSet -Archive @($f) -Environment $envr -Settings (New-TestSettings) -SlotRules @{} -Force)
        Should -Invoke New-BffPlan -Times 1 -Exactly -ParameterFilter { $Force -eq $true }
    }
}
