# Component tests for the window: Gui.ps1 built for real, then driven the way a
# user drives it - ticking boxes, picking a profile, pressing buttons - with the
# scan's data sources and the converter replaced, so what is under test is the
# window and nothing behind it.
#
#   Invoke-Pester -Path .\Tests\GuiComponents.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Gui.ps1'
#
# Events are raised by changing the control, which raises them the way a user
# would - CheckBox.Checked, CheckedListBox.SetItemChecked, ComboBox.SelectedItem.
# Buttons are pressed through the protected OnClick, because PerformClick is
# ignored on a window that has never been shown. Either way the real handler runs:
# it finds the window's context from the control, and calls the action.
#
# The dialog hooks on the context are swapped for recorders, so Apply and Restore
# can be answered on cue and checked for what they asked.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'Environment', 'TexInfo', 'Ba2', 'Discovery', 'Planner',
                   'Convert', 'Report', 'Icon', 'GuiLogic', 'Gui') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    function New-TestPlan {
        param(
            [string] $Action, [string] $Mod, [string] $Name,
            [string] $Folder = 'BaseHumanMale', [bool] $Tint = $false
        )
        $rel = "textures\actors\character\$Folder\$Name"
        $t = New-Object BffTexture
        $t.ModName = $Mod; $t.Name = $Name; $t.RelativePath = $rel
        $t.FullName = "C:\MO2\mods\$Mod\$rel"; $t.Origin = 'Loose'
        $t.Width = 1024; $t.Height = 1024; $t.Format = 'BC7_UNORM'; $t.Slot = 'Diffuse'
        $t.IsTintMask = $Tint; $t.MatchedBy = 'head name'

        $p = New-Object BffPlan
        $p.Texture = $t; $p.Action = $Action
        $p.TargetWidth = 1024; $p.TargetHeight = 1024; $p.TargetFormat = 'BC3_UNORM'
        $p.Reason = "$Action because"; $p.SizeReason = 'size part'; $p.FormatReason = 'format part'
        $p.Destination = "C:\MO2\mods\$Mod [face-Vanilla]\$rel"
        return $p
    }

    # Two mods with work, one without.
    function New-TestPlanSet {
        return @(
            (New-TestPlan -Action 'Resize'   -Mod 'Alpha' -Name 'MaleHead_s.dds')
            (New-TestPlan -Action 'Skip'     -Mod 'Alpha' -Name 'MaleHead_d.dds')
            (New-TestPlan -Action 'Reformat' -Mod 'Bravo' -Name 'FemaleHead_d.dds' -Folder 'BaseHumanFemale')
            (New-TestPlan -Action 'Resize'   -Mod 'Bravo' -Name 'Blusher.dds' -Folder 'Character Assets\TintMasks' -Tint $true)
            (New-TestPlan -Action 'Skip'     -Mod 'Done'  -Name 'Head_d.dds')
        )
    }

    # Press a button, or raise any other protected On<Event>, the way WinForms
    # does. A typed array, not @(...): a PowerShell array hands reflection a
    # PSObject and the parameters do not bind.
    function Invoke-ControlEvent {
        param($Control, [string] $Method, [object[]] $Arguments = @([System.EventArgs]::Empty))
        $m = $Control.GetType().GetMethod($Method, [System.Reflection.BindingFlags] 'NonPublic,Instance')
        $a = [object[]]::new($Arguments.Count)
        for ($i = 0; $i -lt $Arguments.Count; $i++) { $a[$i] = $Arguments[$i].PSObject.BaseObject }
        [void] $m.Invoke($Control, $a)
    }

    function New-TestEnvironment {
        return [pscustomobject]@{
            Profile      = Get-BffProfile -Name 'Vanilla' -Root $tool
            Fallout4Path = 'C:\Games\Fallout 4'
            DataPath     = 'C:\Games\Fallout 4\Data'
            MO2          = [pscustomobject]@{ Root = 'C:\MO2'; ModsPath = 'C:\MO2\mods' }
            F4ee         = $null
        }
    }

    # Recorders for the four dialog hooks, handed to Show-BffGui so they are in
    # place before anything runs. Closures, so they keep hold of their $rec
    # whoever calls them; they call no Bff function, which a closure could not see.
    function New-TestRecorder {
        $rec = [pscustomobject]@{
            Asked  = New-Object System.Collections.ArrayList
            Told   = New-Object System.Collections.ArrayList
            Opened = New-Object System.Collections.ArrayList
            Answer = $true
            Folder = $null
            Hooks  = $null
        }
        $rec.Hooks = @{
            Ask        = { param($Text, $Title) [void] $rec.Asked.Add([pscustomobject]@{ Text = $Text; Title = $Title }); $rec.Answer }.GetNewClosure()
            Tell       = { param($Text, $Title, $Icon = 'Information') [void] $rec.Told.Add([pscustomobject]@{ Text = $Text; Title = $Title; Icon = $Icon }) }.GetNewClosure()
            PickFolder = { param($Description) $rec.Folder }.GetNewClosure()
            OpenFolder = { param($Path) [void] $rec.Opened.Add($Path) }.GetNewClosure()
        }
        return $rec
    }

    function New-TestWindow {
        param([switch] $RunScan)
        $rec  = New-TestRecorder
        $form = Show-BffGui -Settings (Import-BffSettings -Root $tool) -Environment (New-TestEnvironment) `
                            -SlotRules (Import-BffSlotRules -Root $tool) -Root $tool `
                            -BuildOnly -RunScan:$RunScan -Hooks $rec.Hooks
        return [pscustomobject]@{ Form = $form; Context = $form.Tag; Rec = $rec }
    }

    # What the next scan finds. Only the data: the mocks that serve it are set up
    # in the BeforeEach around every test, because a Mock made inside a helper
    # like this one disappears when the helper returns.
    function Set-TestScanSource {
        param([object[]] $Plan)
        $script:scanPlans = $Plan
    }

    function Get-GridMod {
        param($Context)
        @($Context.Grid.Rows | ForEach-Object { $_.Cells['Mod'].Value })
    }

    # The buttons that are not on the context, found the way a user finds them.
    function Find-Button {
        param($Parent, [string] $Text)
        foreach ($k in $Parent.Controls) {
            if ($k -is [System.Windows.Forms.Button] -and $k.Text -eq $Text) { return $k }
            $deep = Find-Button $k $Text
            if ($deep) { return $deep }
        }
        return $null
    }
}

Describe 'the window, driven' {

BeforeEach {
    # A scan without a file system behind it: candidates, metadata and plans come
    # from $script:scanPlans, and the report is not written to disk.
    $script:scanPlans = @()
    Mock Get-BffCandidate { @($script:scanPlans | ForEach-Object { $_.Texture }) }
    Mock Get-BffTexDiagPath { 'texdiag.exe' }
    Mock Update-BffTextureInfo { $Texture }
    Mock New-BffPlanSet { $script:scanPlans }
    Mock Update-BffPlanForExistingOutput { $Plan }
    Mock Write-BffGuiReport { $Context.State.LastCsv = 'Logs\test.csv'; $Context.State.LastLog = 'Logs\test.log' }
    # "Inspect BA2 archives" is ticked by default, so every scan reads archives
    # too. None unless a test supplies some.
    Mock Get-BffArchiveCandidate { @() }
}

Describe 'the window' {
    BeforeEach { $w = New-TestWindow; $c = $w.Context }
    AfterEach  { $w.Form.Dispose() }

    It 'hangs its context on itself, so actions can find it from any control' {
        Get-BffGuiContext $c.ScanButton | Should -Be $c
        Get-BffGuiContext $c.Grid       | Should -Be $c
    }

    It 'has no context for a control that is not on it, or for nothing' {
        Get-BffGuiContext (New-Object System.Windows.Forms.Button) | Should -BeNullOrEmpty
        Get-BffGuiContext $null | Should -BeNullOrEmpty
    }

    It 'opens with Apply off, since there is nothing to apply yet' {
        $c.ApplyButton.Enabled | Should -BeFalse
    }

    It 'shows the profile''s sizes from the start' {
        $c.ProfileInfo.Text | Should -Match '^diffuse 1024 \| normal 1024 \| specular 512'
    }

    It 'keeps "fix inside BA2s" off and greyed while archives are not read' {
        $c.Archives.Checked = $false
        $c.FixArchives.Enabled | Should -BeFalse
        $c.FixArchives.Checked | Should -BeFalse
    }

    It 'lets "fix inside BA2s" be ticked once archives are read' {
        $c.Archives.Checked = $true
        $c.FixArchives.Enabled | Should -BeTrue
    }

    It 'unticks "fix inside BA2s" when archives are switched off again' {
        $c.Archives.Checked = $true
        $c.FixArchives.Checked = $true
        $c.Archives.Checked = $false
        $c.FixArchives.Checked | Should -BeFalse
    }

    It 'shows another profile''s sizes when one is picked' {
        $c.ProfileBox.SelectedItem = 'HD DLC'
        $c.ProfileInfo.Text | Should -Match 'specular 1024'
        $c.State.Environment.Profile.Name | Should -Be 'HD DLC'
    }
}

Describe 'scanning' {
    BeforeEach { $w = New-TestWindow; $c = $w.Context }
    AfterEach  { $w.Form.Dispose() }

    It 'fills the grid with what changes, and the picker with the mods that have work' {
        Set-TestScanSource (New-TestPlanSet)
        Invoke-ControlEvent $c.ScanButton 'OnClick'

        @($c.Grid.Rows).Count | Should -Be 3
        @($c.ModList.Items) | Should -Be @('Alpha', 'Bravo')
        @($c.ModList.CheckedItems).Count | Should -Be 2
        $c.State.Scanned | Should -BeTrue
    }

    It 'turns Apply on when there is something to change' {
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        $c.ApplyButton.Enabled | Should -BeTrue
        $c.ScanButton.Enabled  | Should -BeTrue
    }

    It 'leaves Apply off when everything is already right' {
        Set-TestScanSource @((New-TestPlan -Action 'Skip' -Mod 'Done' -Name 'Head_d.dds'))
        Invoke-BffGuiScan -Context $c
        $c.ApplyButton.Enabled | Should -BeFalse
    }

    It 'gives every row its plan, its marks and its colour' {
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        foreach ($r in $c.Grid.Rows) {
            $r.Tag | Should -Not -BeNullOrEmpty
            $r.Cells['Mark'].Value | Should -BeOfType [System.Drawing.Image]
            $r.DefaultCellStyle.ForeColor.ToArgb() | Should -Be (Get-BffRowColor -Action $r.Tag.Action).ToArgb()
        }
    }

    It 'puts the counts and the report in the status line' {
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        $c.Status.Text | Should -Match '^5 scanned, 2 already correct, 3 to change'
        $c.Status.Text | Should -Match 'Report: Logs\\test\.csv$'
    }

    It 'writes the report' {
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        Should -Invoke Write-BffGuiReport -Times 1 -Exactly
    }

    It 'reads the checkboxes into the settings before it scans' {
        Set-TestScanSource (New-TestPlanSet)
        $c.VanillaFormats.Checked = $true
        $c.OutputBox.SelectedIndex = 1
        Invoke-BffGuiScan -Context $c
        $c.State.Settings.Conversion.ForceVanillaFormats | Should -BeTrue
        $c.State.Settings.Output.Mode | Should -Be 'InPlace'
    }

    It 'says so when it finds nothing' {
        Set-TestScanSource @()
        Invoke-BffGuiScan -Context $c
        $c.Status.Text | Should -Match '^No face textures found'
        @($c.Grid.Rows).Count | Should -Be 0
        Should -Invoke New-BffPlanSet -Times 0 -Exactly
    }

    It 'says what went wrong when the scan fails, and can be run again' {
        Mock Get-BffCandidate { throw 'the disk fell off' }
        Invoke-BffGuiScan -Context $c

        $w.Rec.Told[0].Title | Should -Be 'Scan failed'
        $w.Rec.Told[0].Icon  | Should -Be 'Error'
        $w.Rec.Told[0].Text  | Should -Be 'the disk fell off'
        $c.Status.Text       | Should -Be 'Scan failed: the disk fell off'
        $c.ScanButton.Enabled | Should -BeTrue
    }

    It 'moves the progress bar while it reads metadata' {
        Set-TestScanSource (New-TestPlanSet)
        Mock Update-BffTextureInfo { & $Progress 3 5; $Texture }
        Invoke-BffGuiScan -Context $c
        $c.Progress.Maximum | Should -Be 5
    }

    It 'sorts archive textures into fixed and reported when archives are read' {
        Set-TestScanSource (New-TestPlanSet)
        $fixed = New-TestPlan -Action 'Resize' -Mod 'Charlie' -Name 'Packed_s.dds'
        $script:archiveSort = [pscustomobject]@{ Plans = @($fixed); Findings = @('one finding'); Entries = @{ k = 'v' } }
        Mock Get-BffArchiveCandidate { @([pscustomobject]@{ Texture = $fixed.Texture }) }
        Mock Get-BffArchivePlanSet { $script:archiveSort }

        $c.Archives.Checked = $true
        Invoke-BffGuiScan -Context $c

        @($c.State.Plans).Count    | Should -Be 6
        @($c.State.Archives).Count | Should -Be 1
        $c.State.ArchiveEntries['k'] | Should -Be 'v'
        $c.Status.Text | Should -Match '1 more sit inside BA2 archives'
    }

    It 'keeps archive findings without adding plans when nothing in them is fixed' {
        Set-TestScanSource (New-TestPlanSet)
        Mock Get-BffArchiveCandidate { @() }
        Mock Get-BffArchivePlanSet { [pscustomobject]@{ Plans = @(); Findings = @(); Entries = @{} } }

        $c.Archives.Checked = $true
        Invoke-BffGuiScan -Context $c
        @($c.State.Plans).Count | Should -Be 5
    }

    It 'leaves textures that already have their output alone unless forced' {
        Set-TestScanSource (New-TestPlanSet)
        $c.Force.Checked = $true
        Invoke-BffGuiScan -Context $c
        Should -Invoke Update-BffPlanForExistingOutput -Times 0 -Exactly
    }
}

Describe 'the grid' {
    BeforeEach {
        $w = New-TestWindow; $c = $w.Context
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
    }
    AfterEach { $w.Form.Dispose() }

    It 'shows the rows left alone once "only what changes" is unticked' {
        $c.OnlyChanges.Checked = $false
        @($c.Grid.Rows).Count | Should -Be 5
    }

    It 'shows the full path column when asked to' {
        $c.FullPaths.Checked = $true
        $c.Grid.Columns['FullPath'].Visible | Should -BeTrue
        $c.FullPaths.Checked = $false
        $c.Grid.Columns['FullPath'].Visible | Should -BeFalse
    }

    It 'drops a mod''s work the moment its box is unticked' {
        $c.ModList.SetItemChecked(0, $false)
        Get-GridMod $c | Should -Not -Contain 'Alpha'
        Get-GridMod $c | Should -Contain 'Bravo'
    }

    It 'brings it back the moment the box is ticked again' {
        $c.ModList.SetItemChecked(0, $false)
        $c.ModList.SetItemChecked(0, $true)
        Get-GridMod $c | Should -Contain 'Alpha'
    }

    It 'empties with None and fills again with All' {
        Invoke-ControlEvent (Find-Button $c.Form 'None') 'OnClick'
        @($c.Grid.Rows).Count | Should -Be 0
        @($c.ModList.CheckedItems).Count | Should -Be 0

        Invoke-ControlEvent (Find-Button $c.Form 'All') 'OnClick'
        @($c.Grid.Rows).Count | Should -Be 3
    }

    It 'refreshes the grid once for All, not once per box' {
        Mock Update-BffGuiGrid { }
        Invoke-ControlEvent (Find-Button $c.Form 'All') 'OnClick'
        Should -Invoke Update-BffGuiGrid -Times 1 -Exactly
    }

    It 'paints without a cell it cannot format' {
        $errors = New-Object System.Collections.ArrayList
        $handler = { param($s, $e) [void] $errors.Add($e.Exception.Message) }
        $c.Grid.Add_DataError($handler)
        $bmp = New-Object System.Drawing.Bitmap(800, 300)
        try { $c.Grid.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 800, 300))) }
        finally { $c.Grid.Remove_DataError($handler); $bmp.Dispose() }
        $errors.Count | Should -Be 0
    }

    It 'logs a cell it cannot format instead of opening a dialog' {
        Mock Write-BffLine { }
        $ev = New-Object System.Windows.Forms.DataGridViewDataErrorEventArgs(
                  (New-Object System.FormatException('cannot show this')), 0, 0, 'Display')
        # OnDataError(displayErrorDialogIfNoHandler, e).
        Invoke-ControlEvent $c.Grid 'OnDataError' @($true, $ev)
        Should -Invoke Write-BffLine -Times 1 -Exactly -ParameterFilter { $Message -match 'cannot show this' }
    }
}

Describe 'the row tooltip' {
    BeforeEach {
        $w = New-TestWindow; $c = $w.Context
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        $tip = $c.Grid.Tag
    }
    AfterEach { $w.Form.Dispose() }

    It 'gets a line per mark, then where the file comes from and goes to' {
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        $plan = $c.Grid.Rows[0].Tag
        $tip.Row | Should -Be 0
        $tip.Lines.Count | Should -Be (@(Get-BffPlanMark -Plan $plan).Count + 2)
        $tip.Lines[$tip.Lines.Count - 2].Text | Should -Match '^from:  C:\\MO2\\mods\\'
        $tip.Lines[$tip.Lines.Count - 1].Text | Should -Match '^to:    '
        $tip.Width  | Should -BeGreaterThan 0
        $tip.Height | Should -BeGreaterThan 0
    }

    It 'leaves out the "to" line for a row that writes nothing' {
        $c.Grid.Rows[0].Tag.Destination = ''
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        $tip.Lines[$tip.Lines.Count - 1].Text | Should -Match '^from:'
    }

    It 'is not rebuilt while the mouse stays on the same row' {
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        $tip.Lines.Clear()
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(1, 0))
        $tip.Lines.Count | Should -Be 0
    }

    It 'is rebuilt for another row' {
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 1))
        $tip.Row | Should -Be 1
    }

    It 'ignores the header row' {
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, -1))
        $tip.Row | Should -Be -1
    }

    It 'forgets the row when the mouse leaves the grid' {
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        Invoke-ControlEvent $c.Grid 'OnMouseLeave'
        $tip.Row | Should -Be -1
    }

    It 'stays quiet on a row without a plan' {
        $c.Grid.Rows[0].Tag = $null
        Invoke-ControlEvent $c.Grid 'OnCellMouseEnter' (New-Object System.Windows.Forms.DataGridViewCellEventArgs(0, 0))
        $tip.Lines.Count | Should -Be 0
    }
}

Describe 'applying' {
    BeforeEach {
        $w = New-TestWindow; $c = $w.Context
        Set-TestScanSource (New-TestPlanSet)
        Invoke-BffGuiScan -Context $c
        Mock Invoke-BffPlanSet {
            @($Plan | ForEach-Object { [pscustomobject]@{ Plan = $_; Success = $true; Destination = $_.Destination; Error = ''; Command = '' } })
        }
        Mock Save-BffLog { $Path }
    }
    AfterEach { $w.Form.Dispose() }

    It 'asks first, and converts nothing when the answer is no' {
        $w.Rec.Answer = $false
        Invoke-ControlEvent $c.ApplyButton 'OnClick'
        $w.Rec.Asked[0].Title | Should -Be 'Confirm'
        $w.Rec.Asked[0].Text  | Should -Match '^Convert 3 texture\(s\)\?'
        Should -Invoke Invoke-BffPlanSet -Times 0 -Exactly
    }

    It 'converts the ticked work when the answer is yes' {
        Invoke-BffGuiApply -Context $c
        Should -Invoke Invoke-BffPlanSet -Times 1 -Exactly -ParameterFilter { @($Plan).Count -eq 3 }
        $w.Rec.Told[-1].Title | Should -Be 'Done'
        $w.Rec.Told[-1].Icon  | Should -Be 'Information'
        $c.Status.Text | Should -Match '^Converted 3 texture\(s\)\.'
    }

    It 'converts only the mods still ticked' {
        $c.ModList.SetItemChecked(1, $false)
        Invoke-BffGuiApply -Context $c
        Should -Invoke Invoke-BffPlanSet -Times 1 -Exactly -ParameterFilter {
            @($Plan | ForEach-Object { $_.Texture.ModName } | Sort-Object -Unique) -join ',' -eq 'Alpha'
        }
    }

    It 'says there is nothing to do when nothing is ticked, without asking' {
        Set-BffGuiAllMods -Context $c -Checked $false
        Invoke-BffGuiApply -Context $c
        $w.Rec.Told[0].Title | Should -Be 'Nothing to do'
        $w.Rec.Asked.Count   | Should -Be 0
    }

    It 'warns, and names what failed, when some conversions fail' {
        Mock Invoke-BffPlanSet {
            @([pscustomobject]@{ Plan = $Plan[0]; Success = $false; Destination = ''; Error = 'texconv said no'; Command = 'texconv x' })
        }
        Mock Write-BffLine { }
        Invoke-BffGuiApply -Context $c
        $w.Rec.Told[-1].Icon | Should -Be 'Warning'
        $w.Rec.Told[-1].Text | Should -Match 'texconv said no'
        Should -Invoke Write-BffLine -ParameterFilter { $Message -match 'FAILED' }
        Should -Invoke Write-BffLine -ParameterFilter { $Message -match 'texconv x' }
    }

    It 'adds what it did to the scan''s log' {
        Invoke-BffGuiApply -Context $c
        Should -Invoke Save-BffLog -Times 1 -Exactly -ParameterFilter { $Path -eq 'Logs\test.log' }
    }

    It 'says what went wrong when converting fails outright, and can be run again' {
        Mock Invoke-BffPlanSet { throw 'out of disk' }
        Invoke-BffGuiApply -Context $c
        $w.Rec.Told[-1].Title | Should -Be 'Conversion failed'
        $w.Rec.Told[-1].Icon  | Should -Be 'Error'
        $c.ScanButton.Enabled | Should -BeTrue
    }

    It 'moves the progress bar while it converts' {
        Mock Invoke-BffPlanSet { & $Progress 2 3 $Plan[0]; @() }
        Invoke-BffGuiApply -Context $c
        $c.Progress.Maximum | Should -Be 3
    }
}

Describe 'the other buttons' {
    BeforeEach { $w = New-TestWindow; $c = $w.Context }
    AfterEach  { $w.Form.Dispose() }

    It 'restores backups once it is told to' {
        Mock Restore-BffBackup { @([pscustomobject]@{ Success = $true }, [pscustomobject]@{ Success = $false }) }
        Invoke-ControlEvent (Find-Button $c.Form 'Restore backups') 'OnClick'
        Should -Invoke Restore-BffBackup -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\MO2\mods' }
        $c.Status.Text | Should -Be 'Restored 1 file(s).'
        $w.Rec.Asked[0].Text | Should -Match 'C:\\MO2\\mods'
    }

    It 'restores nothing when told not to' {
        Mock Restore-BffBackup { }
        $w.Rec.Answer = $false
        Invoke-BffGuiRestore -Context $c
        Should -Invoke Restore-BffBackup -Times 0 -Exactly
    }

    It 'opens the log folder, making it first if it is not there' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*\Logs' }
        Mock New-Item { }
        Invoke-ControlEvent (Find-Button $c.Form 'Open logs') 'OnClick'
        $w.Rec.Opened[0] | Should -BeLike '*\Logs'
        Should -Invoke New-Item -Times 1 -Exactly
    }

    It 'changes nothing when no Mod Organizer folder is picked' {
        Mock Get-BffEnvironment { throw 'should not be called' }
        $w.Rec.Folder = $null
        Select-BffGuiMo2Folder -Context $c
        $c.Mo2Box.Text | Should -Be 'C:\MO2'
    }

    It 'switches to the Mod Organizer folder that is picked' {
        $w.Rec.Folder = 'D:\OtherMO2'
        Mock Get-BffEnvironment {
            [pscustomobject]@{ Profile = $null; MO2 = [pscustomobject]@{ Root = 'D:\OtherMO2'; ModsPath = 'D:\OtherMO2\mods' }; F4ee = $null }
        }
        Invoke-ControlEvent (Find-Button $c.Form '...') 'OnClick'
        $c.State.Settings.Paths.MO2 | Should -Be 'D:\OtherMO2'
        $c.Mo2Box.Text | Should -Be 'D:\OtherMO2'
    }

    It 'says so when the picked folder holds no Mod Organizer' {
        $w.Rec.Folder = 'D:\Nothing'
        Mock Get-BffEnvironment { [pscustomobject]@{ Profile = $null; MO2 = $null; F4ee = $null } }
        Select-BffGuiMo2Folder -Context $c
        $c.Mo2Box.Text | Should -Be '(not found)'
    }

    It 'runs the scan straight away with -RunScan, with the hooks already in place' {
        Set-TestScanSource (New-TestPlanSet)
        $f = New-TestWindow -RunScan
        try {
            $f.Context.State.Scanned | Should -BeTrue
            $f.Rec.Told.Count | Should -Be 0
        }
        finally { $f.Form.Dispose() }
    }
}

Describe 'a window nobody can see' {
    # Built with -BuildOnly and no -Hooks, the way Verify-Gui and the screenshot
    # script build it. A real dialog here would pop up on whatever desktop runs the
    # test and hold the run until someone clicks it.
    BeforeEach {
        $f = Show-BffGui -Settings (Import-BffSettings -Root $tool) -Environment (New-TestEnvironment) `
                         -SlotRules (Import-BffSlotRules -Root $tool) -Root $tool -BuildOnly
        $c = $f.Tag
    }
    AfterEach { $f.Dispose() }

    It 'answers no to every question, so it confirms nothing' {
        & $c.Ask 'Convert?' 'Confirm' | Should -BeFalse
    }

    It 'writes what it would have told to the log instead' {
        Mock Write-BffLine { }
        Mock Get-BffCandidate { throw 'the disk fell off' }
        Invoke-BffGuiScan -Context $c
        Should -Invoke Write-BffLine -Times 1 -Exactly -ParameterFilter { $Message -eq '[Error] Scan failed: the disk fell off' }
    }

    It 'picks no folder and opens none' {
        & $c.PickFolder 'Pick one' | Should -BeNullOrEmpty
        & $c.OpenFolder 'C:\Somewhere' | Should -BeNullOrEmpty
    }

    It 'converts nothing when Apply is pressed' {
        Set-TestScanSource (New-TestPlanSet)
        Mock Invoke-BffPlanSet { throw 'must not convert' }
        Invoke-BffGuiScan -Context $c
        Invoke-BffGuiApply -Context $c
        Should -Invoke Invoke-BffPlanSet -Times 0 -Exactly
    }
}

}
