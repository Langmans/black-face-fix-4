# Gui.ps1 - WinForms front end.
#
# Same engine as the console run. The grid is the point: it shows the current size
# AND the current format AND the reason per file, so you can see why something is
# about to be touched before anything is written. Scan is always a dry run; Apply
# only becomes available once a scan has happened.
#
# WinForms is Windows-only, which is fine here - so are Fallout 4, Mod Organizer
# and texconv.
#
# What the window decides lives in GuiLogic.ps1, which has to be loaded first.
# This file builds the controls, wires the events, and moves values between the
# controls and those functions.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-BffGui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [object]    $Environment,
        [Parameter(Mandatory)] [object]    $SlotRules,
        [object] $VanillaFaceTextures,
        [string] $Root = (Get-BffRoot),
        # Builds the window and returns it without showing it, so the layout can be
        # smoke-tested without a human clicking anything.
        [switch] $BuildOnly,
        # With -BuildOnly, also runs the scan before returning. The scan has to be
        # driven from in here rather than by invoking the handler from outside:
        # the handlers are plain scriptblocks that resolve their variables through
        # this function's scope, and PerformClick() is ignored on a control that has
        # never been visible.
        [switch] $RunScan
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = [pscustomobject]@{
        Settings    = $Settings
        Environment = $Environment
        SlotRules   = $SlotRules
        Vanilla     = $VanillaFaceTextures
        Root        = $Root
        Plans       = @()
        Archives    = @()
        Scanned     = $false
        LastCsv     = ''
        LastLog     = ''
        ArchiveEntries = @{}
        Populating     = $false
    }

    # The GUI launcher hides the console, so printing would go nowhere. Lines are
    # still collected and end up in the log file.
    Set-BffQuiet $true

    # ---------------------------------------------------------------- shell
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'Black Face Fix 4'
    $form.Size            = New-Object System.Drawing.Size(1120, 720)
    $form.StartPosition   = 'CenterScreen'
    $form.MinimumSize     = New-Object System.Drawing.Size(900, 560)

    # Drawn rather than shipped - see Icon.ps1. $null when it could not be built,
    # and a Form is happy to be assigned that: it falls back to the default.
    $form.Icon = New-BffIcon

    $font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Font = $font

    # ---------------------------------------------------------------- top panel
    $top          = New-Object System.Windows.Forms.Panel
    $top.Dock     = 'Top'
    $top.Height   = 198
    $top.Padding  = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($top)

    function New-Label {
        param([string] $Text, [int] $X, [int] $Y, [int] $W = 120, $Font = $null)
        $l          = New-Object System.Windows.Forms.Label
        $l.Text     = $Text
        $l.Location = New-Object System.Drawing.Point($X, $Y)
        $l.Size     = New-Object System.Drawing.Size($W, 20)
        if ($Font) { $l.Font = $Font }
        return $l
    }

    $top.Controls.Add((New-Label 'Profile' 12 14 60 $fontBold))

    $profileBox               = New-Object System.Windows.Forms.ComboBox
    $profileBox.Location      = New-Object System.Drawing.Point(80, 11)
    $profileBox.Size          = New-Object System.Drawing.Size(180, 24)
    $profileBox.DropDownStyle = 'DropDownList'
    foreach ($p in (Get-BffProfileList -Root $Root)) { [void] $profileBox.Items.Add($p.Name) }
    $profileBox.SelectedItem = $Environment.Profile.Name
    $top.Controls.Add($profileBox)

    $profileInfo      = New-Label '' 275 14 800
    $profileInfo.Size = New-Object System.Drawing.Size(800, 20)
    $top.Controls.Add($profileInfo)

    $warnLabel           = New-Object System.Windows.Forms.Label
    $warnLabel.Location  = New-Object System.Drawing.Point(12, 38)
    $warnLabel.Size      = New-Object System.Drawing.Size(1070, 34)
    $warnLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 90, 0)
    $top.Controls.Add($warnLabel)

    $top.Controls.Add((New-Label 'Fallout 4' 12 78 70))
    $fo4Box            = New-Object System.Windows.Forms.TextBox
    $fo4Box.Location   = New-Object System.Drawing.Point(88, 76)
    $fo4Box.Size       = New-Object System.Drawing.Size(430, 22)
    $fo4Box.ReadOnly   = $true
    $fo4Box.Text       = $Environment.Fallout4Path
    $top.Controls.Add($fo4Box)

    $top.Controls.Add((New-Label 'Mod Organizer' 540 78 90))
    $mo2Box          = New-Object System.Windows.Forms.TextBox
    $mo2Box.Location = New-Object System.Drawing.Point(636, 76)
    $mo2Box.Size     = New-Object System.Drawing.Size(380, 22)
    $mo2Box.ReadOnly = $true
    $mo2Box.Text     = if ($Environment.MO2) { $Environment.MO2.Root } else { '(not found)' }
    $top.Controls.Add($mo2Box)

    $browse          = New-Object System.Windows.Forms.Button
    $browse.Text     = '...'
    $browse.Location = New-Object System.Drawing.Point(1022, 75)
    $browse.Size     = New-Object System.Drawing.Size(34, 24)
    $top.Controls.Add($browse)

    function New-Check {
        param([string] $Text, [int] $X, [int] $Y, [int] $W, [bool] $Checked)
        $c          = New-Object System.Windows.Forms.CheckBox
        $c.Text     = $Text
        $c.Location = New-Object System.Drawing.Point($X, $Y)
        $c.Size     = New-Object System.Drawing.Size($W, 22)
        $c.Checked  = $Checked
        return $c
    }

    $chkEnabled     = New-Check 'Only enabled mods'          12  106 148 ([bool] $Settings.Scope.OnlyEnabledMods)
    $chkArchives    = New-Check 'Inspect BA2 archives'      166 106 156 ([bool] $Settings.Scope.IncludeArchives)
    $chkFixArchives = New-Check 'Fix the ones inside BA2s'  328 106 176 ([bool] $Settings.Scope.FixArchives)
    $chkForce       = New-Check 'Re-encode correct'         510 106 150 $false
    $top.Controls.AddRange(@($chkEnabled, $chkArchives, $chkFixArchives, $chkForce))

    # Fixing archive content only makes sense once the archives are read at all.
    $syncArchiveBoxes = {
        $chkFixArchives.Enabled = $chkArchives.Checked
        if (-not $chkArchives.Checked) { $chkFixArchives.Checked = $false }
    }
    $chkArchives.Add_CheckedChanged($syncArchiveBoxes)
    & $syncArchiveBoxes

    $top.Controls.Add((New-Label 'Write to' 680 108 60))
    $outputBox               = New-Object System.Windows.Forms.ComboBox
    $outputBox.Location      = New-Object System.Drawing.Point(742, 105)
    $outputBox.Size          = New-Object System.Drawing.Size(314, 24)
    $outputBox.DropDownStyle = 'DropDownList'
    [void] $outputBox.Items.Add('One output mod per source mod (sources untouched)')
    [void] $outputBox.Items.Add('In place, keeping a .backup next to each file')
    $outputBox.SelectedIndex = if ($Settings.Output.Mode -eq 'InPlace') { 1 } else { 0 }
    $top.Controls.Add($outputBox)

    $scanButton          = New-Object System.Windows.Forms.Button
    $scanButton.Text     = 'Scan'
    $scanButton.Location = New-Object System.Drawing.Point(12, 134)
    $scanButton.Size     = New-Object System.Drawing.Size(110, 28)
    $scanButton.Font     = $fontBold

    $applyButton          = New-Object System.Windows.Forms.Button
    $applyButton.Text     = 'Apply'
    $applyButton.Location = New-Object System.Drawing.Point(130, 134)
    $applyButton.Size     = New-Object System.Drawing.Size(110, 28)
    $applyButton.Enabled  = $false

    $restoreButton          = New-Object System.Windows.Forms.Button
    $restoreButton.Text     = 'Restore backups'
    $restoreButton.Location = New-Object System.Drawing.Point(248, 134)
    $restoreButton.Size     = New-Object System.Drawing.Size(130, 28)

    $logButton          = New-Object System.Windows.Forms.Button
    $logButton.Text     = 'Open logs'
    $logButton.Location = New-Object System.Drawing.Point(386, 134)
    $logButton.Size     = New-Object System.Drawing.Size(100, 28)

    $chkOnlyChanges = New-Check 'Show only what changes' 500 137 176 $true
    $chkFaceCust    = New-Check 'FaceCustomization'      684 137 152 ([bool] $Settings.Scope.IncludeFaceCustomization)
    $chkFullPaths   = New-Check 'Show full paths'        844 137 150 $false
    $top.Controls.AddRange(@($scanButton, $applyButton, $restoreButton, $logButton,
                             $chkOnlyChanges, $chkFaceCust, $chkFullPaths))

    $chkVanillaFmt = New-Check 'Force vanilla formats' 12 168 176 ([bool] $Settings.Conversion.ForceVanillaFormats)
    $vanillaHint           = New-Label ('re-encodes every texture to the format Fallout 4 ships for its slot, ' +
                                        'so one texture array cannot end up holding two') 194 171 700
    $vanillaHint.ForeColor = [System.Drawing.Color]::DimGray
    $top.Controls.AddRange(@($chkVanillaFmt, $vanillaHint))

    # ---------------------------------------------------------- mod picker
    # One tick per SOURCE mod, so a run can be narrowed without editing settings.
    $side          = New-Object System.Windows.Forms.Panel
    $side.Dock     = 'Right'
    $side.Width    = 270
    $side.Padding  = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $form.Controls.Add($side)

    $sideLabel        = New-Object System.Windows.Forms.Label
    $sideLabel.Text   = 'Mods to fix'
    $sideLabel.Dock   = 'Top'
    $sideLabel.Height = 20
    $sideLabel.Font   = $fontBold

    $sideHint           = New-Object System.Windows.Forms.Label
    $sideHint.Text      = 'Untick a mod to leave it alone this run.'
    $sideHint.Dock      = 'Top'
    $sideHint.Height    = 32
    $sideHint.ForeColor = [System.Drawing.Color]::DimGray

    $modList                = New-Object System.Windows.Forms.CheckedListBox
    $modList.Dock           = 'Fill'
    $modList.CheckOnClick   = $true
    $modList.IntegralHeight = $false

    $modButtons        = New-Object System.Windows.Forms.Panel
    $modButtons.Dock   = 'Bottom'
    $modButtons.Height = 30

    $btnAll          = New-Object System.Windows.Forms.Button
    $btnAll.Text     = 'All'
    $btnAll.Location = New-Object System.Drawing.Point(0, 2)
    $btnAll.Size     = New-Object System.Drawing.Size(70, 24)

    $btnNone          = New-Object System.Windows.Forms.Button
    $btnNone.Text     = 'None'
    $btnNone.Location = New-Object System.Drawing.Point(76, 2)
    $btnNone.Size     = New-Object System.Drawing.Size(70, 24)
    $modButtons.Controls.AddRange(@($btnAll, $btnNone))

    $side.Controls.AddRange(@($modList, $modButtons, $sideHint, $sideLabel))

    # ---------------------------------------------------------------- grid
    $grid                        = New-Object System.Windows.Forms.DataGridView
    $grid.Dock                   = 'Fill'
    $grid.ReadOnly               = $true
    $grid.AllowUserToAddRows     = $false
    $grid.AllowUserToDeleteRows  = $false
    # Defaults to $true, which lets a row be dragged to any height. There is
    # nothing in a row worth more space - the reason moved to the tooltip - and a
    # row stretched by accident stays that way until the next scan.
    $grid.AllowUserToResizeRows  = $false
    $grid.SelectionMode          = 'FullRowSelect'
    $grid.AutoSizeColumnsMode    = 'Fill'
    $grid.RowHeadersVisible      = $false
    $grid.BackgroundColor        = [System.Drawing.Color]::White

    # Banding, kept very faint. Rows are narrow and there are nine columns of
    # near-identical text, so the eye needs help staying on one line - but the
    # marks have to keep their contrast, and a heavier band eats it.
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 250)
    $form.Controls.Add($grid)
    $grid.BringToFront()

    # Without a handler here, a cell that cannot format its value pops a modal
    # dialog - and it does so per repaint, so the window ends up buried under
    # them. Handling the event suppresses the dialog; the failure goes to the log
    # instead, where it can be read after the fact.
    $grid.Add_DataError({
        param($sender, $e)
        $e.ThrowException = $false
        Write-BffLine ("A cell could not be displayed (row {0}, column {1}): {2}" -f
                       $e.RowIndex, $e.ColumnIndex, $e.Exception.Message) 'Yellow'
    })

    # Which columns and in what order is decided in GuiLogic.ps1, where the row
    # values are built in the same order.
    foreach ($col in (Get-BffGridColumn)) {

        if ($col.Image) {
            $c              = New-Object System.Windows.Forms.DataGridViewImageColumn
            # Normal centres a graphic smaller than its cell. Zoom would scale the
            # 16px glyph up to the row height and blur it.
            $c.ImageLayout  = 'Normal'
            $c.HeaderText   = ''
            # Fixed width: a fill-sized image column stretches with the window and
            # leaves the mark floating in the middle of an empty gap.
            $c.AutoSizeMode = 'None'
            $c.Width        = 74
        }
        else {
            $c            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $c.HeaderText = $col.Header
            $c.FillWeight = $col.Weight
        }

        $c.Name = $col.Name
        if ($col.Hidden) { $c.Visible = $false }
        [void] $grid.Columns.Add($c)
    }

    # -------------------------------------------------------------- row tooltip
    # One tooltip for the whole row, laid out the way Mod Organizer explains its
    # Content column: a line per mark, with the mark itself as the bullet. This is
    # where the reason text lives - it is too long for a column and too useful to
    # drop.
    #
    # WinForms will not do this by itself. A DataGridView's own cell tooltips are
    # plain text and cannot be owner drawn, so they are switched off entirely and
    # this one is drawn by hand.
    $grid.ShowCellToolTips = $false

    $rowTip              = New-Object System.Windows.Forms.ToolTip
    $rowTip.OwnerDraw    = $true
    $rowTip.ShowAlways   = $true
    $rowTip.InitialDelay = 350
    $rowTip.ReshowDelay  = 80
    $rowTip.AutoPopDelay = 30000

    # Everything these three handlers need is hung on the controls themselves and
    # reached through $sender, and NOT read out of this function's variables.
    #
    # The other handlers in this file get away with that because they only ever run
    # from a click, with Show-BffGui still on the stack at ShowDialog. CellMouseEnter
    # does not: WinForms raises it from its own layout code - handle creation calls
    # AdjustFillingColumns, which calls UpdateMouseEnteredCell - and there the
    # function is gone, so a local resolves to nothing and the handler dies inside
    # a window that has not finished opening yet.
    $tipState = [pscustomobject]@{
        Tip    = $rowTip
        Lines  = New-Object System.Collections.Generic.List[object]
        Row    = -1
        Width  = 0
        Height = 0
        Font   = $font
        Pad    = 8      # border to content
        Bullet = 24     # mark column inside the tooltip
        MaxW   = 560    # wrap rather than run off the screen
    }
    $rowTip.Tag = $tipState
    $grid.Tag   = $tipState

    # Measured when the tooltip is filled and reused when it is drawn: laying the
    # text out twice risks the two disagreeing and the last line being clipped.
    $rowTip.Add_Popup({
        param($sender, $e)
        $s = $sender.Tag
        if (-not $s) { return }
        $e.ToolTipSize = New-Object System.Drawing.Size($s.Width, $s.Height)
    })

    $rowTip.Add_Draw({
        param($sender, $e)
        $s = $sender.Tag
        if (-not $s) { return }
        $e.DrawBackground()
        $e.DrawBorder()
        $textW = $e.Bounds.Width - $s.Bullet - (2 * $s.Pad)
        $y = $s.Pad
        foreach ($line in $s.Lines) {
            if ($line.Image) { $e.Graphics.DrawImage($line.Image, $s.Pad, $y + 1) }
            [System.Windows.Forms.TextRenderer]::DrawText(
                $e.Graphics, $line.Text, $s.Font,
                (New-Object System.Drawing.Rectangle(($s.Pad + $s.Bullet), $y, $textW, $line.Height)),
                [System.Drawing.SystemColors]::InfoText,
                [System.Windows.Forms.TextFormatFlags]::WordBreak)
            $y += $line.Height + 4
        }
    })

    # Any cell in the row, not just the mark: the tooltip is about the row.
    $grid.Add_CellMouseEnter({
        param($sender, $e)
        $s = $sender.Tag
        if (-not $s) { return }
        # RowIndex can point past the rows while the grid is still laying itself out.
        if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $sender.Rows.Count) { return }
        # Re-showing the same tooltip as the mouse crosses cells makes it flicker.
        if ($s.Row -eq $e.RowIndex) { return }
        $s.Row = $e.RowIndex

        $plan = $sender.Rows[$e.RowIndex].Tag
        if (-not $plan) { return }

        $s.Lines.Clear()
        foreach ($line in (Get-BffPlanTipLine -Plan $plan)) {
            $s.Lines.Add([pscustomobject]@{
                Image = (New-BffMark -Kind $line.Kind); Text = $line.Text; Height = 18
            })
        }

        # Always the absolute paths, whatever the columns are showing. Read off the
        # plan rather than the cells, so shortening a column cannot quietly shorten
        # these too.
        $s.Lines.Add([pscustomobject]@{
            Image = $null; Text = ('from:  ' + (Get-BffRowFolder -Plan $plan -Full)); Height = 18
        })
        if ($plan.Destination) {
            $s.Lines.Add([pscustomobject]@{
                Image = $null; Text = ('to:    ' + $plan.Destination); Height = 18
            })
        }

        $textW = $s.MaxW - $s.Bullet - (2 * $s.Pad)
        $wide  = 0
        $high  = 2 * $s.Pad
        foreach ($line in $s.Lines) {
            $size = [System.Windows.Forms.TextRenderer]::MeasureText(
                        $line.Text, $s.Font,
                        (New-Object System.Drawing.Size($textW, 0)),
                        [System.Windows.Forms.TextFormatFlags]::WordBreak)
            $line.Height = [Math]::Max($size.Height, 18)
            if ($size.Width -gt $wide) { $wide = $size.Width }
            $high += $line.Height + 4
        }
        $s.Width  = $wide + $s.Bullet + (2 * $s.Pad)
        $s.Height = $high

        $cell = $sender.GetCellDisplayRectangle($e.ColumnIndex, $e.RowIndex, $false)
        $s.Tip.Show(' ', $sender, $cell.Left, $cell.Bottom + 2, 30000)
    })

    $grid.Add_MouseLeave({
        param($sender, $e)
        $s = $sender.Tag
        if (-not $s) { return }
        $s.Tip.Hide($sender)
        $s.Row = -1
    })

    # ---------------------------------------------------------------- status bar
    $bottom         = New-Object System.Windows.Forms.Panel
    $bottom.Dock    = 'Bottom'
    $bottom.Height  = 54
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
    $form.Controls.Add($bottom)

    # Anchored left AND right so both grow with the window. Without the right
    # anchor they keep the width they were built at, which leaves the bar stopping
    # halfway across a maximised window and the status line - which carries the
    # path to the report - cut off in the middle.
    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(12, 6)
    $progressBar.Size     = New-Object System.Drawing.Size(1070, 14)
    $progressBar.Anchor   = 'Top, Left, Right'
    $bottom.Controls.Add($progressBar)

    $status           = New-Object System.Windows.Forms.Label
    $status.Location  = New-Object System.Drawing.Point(12, 26)
    $status.Size      = New-Object System.Drawing.Size(1070, 20)
    $status.Anchor    = 'Top, Left, Right'
    $status.Text      = 'Press Scan to see what would change. Nothing is written until you press Apply.'
    $bottom.Controls.Add($status)

    # ---------------------------------------------------------------- helpers
    # These handlers deliberately do NOT use .GetNewClosure(): a closure gets its own
    # session state and can no longer resolve the dot-sourced Bff* functions. They
    # rely on Show-BffGui still being on the stack instead, which is true for the
    # whole lifetime of ShowDialog. Tests therefore drive the scan through
    # -BuildOnly -RunScan rather than by invoking the scriptblock from outside.
    $setStatus = {
        param([string] $Text)
        $status.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }

    $refreshProfile = {
        $prof = Get-BffProfile -Name $profileBox.SelectedItem -Root $state.Root
        $state.Environment.Profile = $prof
        $profileInfo.Text = Get-BffProfileInfoText -Profile $prof
        $warnLabel.Text   = Get-BffProfileWarningText -Profile $prof -F4ee $state.Environment.F4ee
    }

    $selectedMods = {
        Get-BffModSelection -Item @($modList.Items) -Checked @($modList.CheckedItems)
    }

    $plansToApply = {
        Select-BffPlanToApply -Plan $state.Plans -Selection (& $selectedMods)
    }

    $fillModList = {
        $state.Populating = $true
        $modList.BeginUpdate()
        $modList.Items.Clear()
        foreach ($m in (Get-BffModPickerItem -Plan $state.Plans)) { [void] $modList.Items.Add($m, $true) }
        $modList.EndUpdate()
        $state.Populating = $false
    }

    $fillGrid = {
        $grid.Rows.Clear()
        $rows = Select-BffGridPlan -Plan $state.Plans -OnlyChanges $chkOnlyChanges.Checked -Selection (& $selectedMods)

        $grid.SuspendLayout()
        foreach ($p in $rows) {
            $i = $grid.Rows.Add((Get-BffGridRowValue -Plan $p))

            # The image goes onto the cell once the row exists - see
            # Get-BffGridRowValue for why it cannot travel with the other values.
            $grid.Rows[$i].Cells['Mark'].Value = New-BffPlanGlyph -Plan $p

            # The tooltip needs the plan, not the formatted row.
            $grid.Rows[$i].Tag = $p
            $grid.Rows[$i].DefaultCellStyle.ForeColor = Get-BffRowColor -Action $p.Action
        }

        $grid.ResumeLayout()
        # Otherwise every row comes up highlighted, which reads as "these are
        # selected" when nothing has been chosen yet.
        $grid.ClearSelection()
    }

    $applySettings = {
        Update-BffSettingsFromChoice -Settings $state.Settings -Choice @{
            OnlyEnabledMods          = $chkEnabled.Checked
            IncludeArchives          = $chkArchives.Checked
            FixArchives              = $chkFixArchives.Checked
            IncludeFaceCustomization = $chkFaceCust.Checked
            ForceVanillaFormats      = $chkVanillaFmt.Checked
            InPlace                  = ($outputBox.SelectedIndex -eq 1)
        }
    }

    # The GUI writes exactly the same log and CSV the console run does. It has to
    # do so itself: the report functions are called from the console path, so a
    # window that skipped this would still write a log file - holding nothing but
    # the banner.
    $writeReport = {
        param($Summary)

        $stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $logDir = Join-Path $state.Root 'Logs'

        Clear-BffLog
        Write-BffBanner
        Write-BffEnvironmentReport -Environment $state.Environment
        Write-BffPlanTable -Plan $state.Plans -All
        Write-BffSummary -Summary $Summary -ArchiveFinding $state.Archives

        $state.LastCsv = Export-BffPlanCsv -Plan $state.Plans -Path (Join-Path $logDir "BlackFaceFix_$stamp.csv")
        Write-BffLine ('Full per-file detail: {0}' -f $state.LastCsv)
        $state.LastLog = Save-BffLog -Path (Join-Path $logDir "BlackFaceFix_$stamp.log")
    }

    # ---------------------------------------------------------------- actions
    # Kept in a variable rather than written inline, so it can also be invoked from
    # a test without showing the window - Button.PerformClick() is ignored on a
    # control that has never been visible.
    $doScan = {
        try {
            $scanButton.Enabled = $false; $applyButton.Enabled = $false
            & $applySettings
            & $refreshProfile

            & $setStatus 'Scanning for face textures...'
            $progressBar.Style = 'Marquee'

            $candidates = @(Get-BffCandidate -Environment $state.Environment -Settings $state.Settings `
                                             -SlotRules $state.SlotRules -VanillaFaceTextures $state.Vanilla)

            $progressBar.Style = 'Continuous'; $progressBar.Value = 0
            & $setStatus ("Reading metadata for {0} texture(s)..." -f $candidates.Count)

            if ($candidates.Count -eq 0) {
                $state.Plans = @()
                & $fillGrid
                & $setStatus 'No face textures found. Check the Mod Organizer path and the scope checkboxes.'
                return
            }

            $textures = @(Update-BffTextureInfo -Texture $candidates -TexDiagPath (Get-BffTexDiagPath -Root $state.Root -Settings $state.Settings) -Progress {
                param($done, $total)
                $progressBar.Maximum = $total
                $progressBar.Value   = [Math]::Min($done, $total)
                $status.Text      = "Reading metadata: $done / $total"
                [System.Windows.Forms.Application]::DoEvents()
            })

            $state.Plans = @(New-BffPlanSet -Texture $textures -Profile $state.Environment.Profile `
                                            -SlotRules $state.SlotRules -Settings $state.Settings `
                                            -Environment $state.Environment -Force:$chkForce.Checked)
            if (-not $chkForce.Checked) {
                $state.Plans = @(Update-BffPlanForExistingOutput -Plan $state.Plans -TexDiagPath (Get-BffTexDiagPath -Root $state.Root -Settings $state.Settings))
            }

            $state.ArchiveEntries = @{}
            if ($chkArchives.Checked) {
                & $setStatus 'Inspecting BA2 archives...'
                $archiveAll = @(Get-BffArchiveCandidate -Environment $state.Environment -Settings $state.Settings `
                                                        -SlotRules $state.SlotRules -VanillaFaceTextures $state.Vanilla |
                                Where-Object { $_.Texture })

                $sorted = Get-BffArchivePlanSet -Archive $archiveAll -Environment $state.Environment `
                                                -Settings $state.Settings -SlotRules $state.SlotRules `
                                                -Force:$chkForce.Checked
                $state.ArchiveEntries = $sorted.Entries

                if (@($sorted.Plans).Count -gt 0) {
                    $merged = @(Update-BffPlanForExistingOutput -Plan $sorted.Plans `
                                                                -TexDiagPath (Get-BffTexDiagPath -Root $state.Root -Settings $state.Settings))
                    $state.Plans = @($state.Plans) + $merged
                }
                # Whatever is not being fixed stays a "look at this" finding.
                $state.Archives = @($sorted.Findings)
            }
            else { $state.Archives = @() }

            & $fillModList
            & $fillGrid
            $state.Scanned = $true

            $summary = Get-BffPlanSummary -Plan $state.Plans
            $applyButton.Enabled = ($summary.Changing -gt 0)

            & $writeReport $summary
            $progressBar.Value = $progressBar.Maximum

            & $setStatus (Get-BffScanStatusText -Summary $summary -ArchiveCount @($state.Archives).Count `
                                                -CsvPath $state.LastCsv)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scan failed',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            & $setStatus ('Scan failed: ' + $_.Exception.Message)
        }
        finally { $scanButton.Enabled = $true; $progressBar.Style = 'Continuous' }
    }
    $scanButton.Add_Click($doScan)

    $applyButton.Add_Click({
        $todo = @(& $plansToApply)
        if ($todo.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Nothing is ticked under "Mods to fix", so there is nothing to convert.',
                'Nothing to do', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $outputMods = Get-BffOutputModList -Plan $todo

        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-BffApplyConfirmText -Count $todo.Count -Mode $state.Settings.Output.Mode -OutputMod $outputMods),
            'Confirm', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try {
            $applyButton.Enabled = $false; $scanButton.Enabled = $false
            $progressBar.Value = 0

            $results = Invoke-BffPlanSet -Plan $todo -Settings $state.Settings -Root $state.Root `
                                         -ArchiveEntryByPath $state.ArchiveEntries `
                                         -ProfileName $state.Environment.Profile.Name -Progress {
                param($done, $total, $plan)
                $progressBar.Maximum = $total
                $progressBar.Value   = [Math]::Min($done, $total)
                $status.Text      = "Converting $done / $total  -  $($plan.Texture.Name)"
                [System.Windows.Forms.Application]::DoEvents()
            }

            $ok  = @($results | Where-Object Success).Count
            $bad = @($results | Where-Object { -not $_.Success })
            $done = Get-BffApplyResultText -Result $results -Mode $state.Settings.Output.Mode -OutputMod $outputMods
            $message = $done.Text

            # Append what actually happened to the log the scan already wrote.
            Write-BffLine ''
            Write-BffLine ('Converted {0} texture(s).' -f $ok)
            foreach ($b in $bad) {
                Write-BffLine ('  FAILED {0}: {1}' -f $b.Plan.Texture.FullName, $b.Error)
                if ($b.Command) { Write-BffLine ('         {0}' -f $b.Command) }
            }
            foreach ($r in ($results | Where-Object Success)) {
                Write-BffLine ('  wrote {0}' -f $r.Destination)
            }
            if ($state.LastLog) { [void] (Save-BffLog -Path $state.LastLog) }

            [System.Windows.Forms.MessageBox]::Show($message, 'Done',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                $(if ($done.Failed) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null

            & $setStatus "$message  Log: $($state.LastLog)"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Conversion failed',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally { $scanButton.Enabled = $true }
    })

    $restoreButton.Add_Click({
        $target = Get-BffRestoreTarget -Environment $state.Environment
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Restore every .backup file under:`n{0}`n`nThis undoes an in-place run." -f $target),
            'Restore backups', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $restored = Restore-BffBackup -Path $target -BackupSuffix $state.Settings.Output.BackupSuffix
        $good = @($restored | Where-Object Success).Count
        & $setStatus ("Restored {0} file(s)." -f $good)
        [System.Windows.Forms.MessageBox]::Show("Restored $good file(s).", 'Restore',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    })

    $logButton.Add_Click({
        $logs = Join-Path $state.Root 'Logs'
        if (-not (Test-Path -LiteralPath $logs)) { [void] (New-Item -ItemType Directory -Path $logs -Force) }
        Start-Process explorer.exe $logs
    })

    $browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Pick the Mod Organizer 2 folder (the one holding ModOrganizer.ini)'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $state.Settings.Paths.MO2 = $dialog.SelectedPath
            $state.Environment = Get-BffEnvironment -Settings $state.Settings -Root $state.Root -ProfileOverride $profileBox.SelectedItem
            $mo2Box.Text = if ($state.Environment.MO2) { $state.Environment.MO2.Root } else { '(not found)' }
            & $refreshProfile
        }
    })

    $profileBox.Add_SelectedIndexChanged({ & $refreshProfile })
    $chkOnlyChanges.Add_CheckedChanged({ if ($state.Scanned) { & $fillGrid } })
    $btnAll.Add_Click({
        for ($i = 0; $i -lt $modList.Items.Count; $i++) { $modList.SetItemChecked($i, $true) }
        if ($state.Scanned) { & $fillGrid }
    })
    $btnNone.Add_Click({
        for ($i = 0; $i -lt $modList.Items.Count; $i++) { $modList.SetItemChecked($i, $false) }
        if ($state.Scanned) { & $fillGrid }
    })
    # ItemCheck fires before the new state is stored, so the refresh has to be
    # deferred. Two guards: the event also fires while $fillModList is adding the
    # items, and BeginInvoke throws until the window handle exists - which is the
    # case during a -BuildOnly scan and during the very first population.
    $modList.Add_ItemCheck({
        if ($state.Populating -or -not $form.IsHandleCreated) { return }
        [void] $form.BeginInvoke([Action] { if ($state.Scanned) { & $fillGrid } })
    })

    # The full path is a column of its own, so this only has to show it. Every row
    # already carries the value, which is why nothing needs refilling.
    $chkFullPaths.Add_CheckedChanged({
        $grid.Columns['FullPath'].Visible = $chkFullPaths.Checked
    })

    & $refreshProfile

    # Handles for tests: the scan can then be driven without a visible window.
    $form.Tag = [pscustomobject]@{
        State    = $state
        Scan     = $doScan
        Grid     = $grid
        Status   = $status
        ModList  = $modList
        Progress = $progressBar
    }

    if ($BuildOnly) {
        if ($RunScan) { & $doScan }
        return $form
    }

    [void] $form.ShowDialog()
    $form.Dispose()
}
