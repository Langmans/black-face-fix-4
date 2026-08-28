# Gui.ps1 - WinForms front end.
#
# Same engine as the console run. The grid is the point: it shows the current size
# AND the current format AND the reason per file, so you can see why something is
# about to be touched before anything is written. Scan is always a dry run; Apply
# only becomes available once a scan has happened.
#
# WinForms is Windows-only, which is fine here - so are Fallout 4, Mod Organizer
# and texconv.

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
    $grid.SelectionMode          = 'FullRowSelect'
    $grid.AutoSizeColumnsMode    = 'Fill'
    $grid.RowHeadersVisible      = $false
    $grid.BackgroundColor        = [System.Drawing.Color]::White
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

    foreach ($col in @(
        @{ N = 'Mod';    W = 16 }, @{ N = 'File';   W = 18 }, @{ N = 'Slot';   W = 8 },
        @{ N = 'Now';    W = 15 }, @{ N = 'Target'; W = 15 }, @{ N = 'Action'; W = 10 },
        # A mark per action in front of the reason, so the shape of a scan reads at
        # a glance. The reason text next to it stays the authority.
        @{ N = 'Mark';   W = 3;  Image = $true },
        @{ N = 'Why';    W = 45 },
        # Hidden until "Show full paths" is ticked: useful for checking exactly
        # which file is read and where the result lands, far too wide to always show.
        @{ N = 'Source'; W = 40; Hidden = $true }, @{ N = 'Destination'; W = 40; Hidden = $true })) {

        if ($col.ContainsKey('Image')) {
            $c              = New-Object System.Windows.Forms.DataGridViewImageColumn
            # Normal centres a graphic smaller than its cell. Zoom would scale the
            # 16px glyph up to the row height and blur it.
            $c.ImageLayout  = 'Normal'
            $c.HeaderText   = ''
            # Fixed width: a fill-sized image column stretches with the window and
            # leaves the mark floating in the middle of an empty gap.
            $c.AutoSizeMode = 'None'
            $c.Width        = 40
        }
        else {
            $c            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $c.HeaderText = $col.N
            $c.FillWeight = $col.W
        }

        $c.Name = $col.N
        if ($col.ContainsKey('Hidden')) { $c.Visible = $false }
        [void] $grid.Columns.Add($c)
    }

    # ---------------------------------------------------------------- status bar
    $bottom         = New-Object System.Windows.Forms.Panel
    $bottom.Dock    = 'Bottom'
    $bottom.Height  = 54
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
    $form.Controls.Add($bottom)

    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(12, 6)
    $progressBar.Size     = New-Object System.Drawing.Size(1070, 14)
    $bottom.Controls.Add($progressBar)

    $status           = New-Object System.Windows.Forms.Label
    $status.Location  = New-Object System.Drawing.Point(12, 26)
    $status.Size      = New-Object System.Drawing.Size(1070, 20)
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

        $profileInfo.Text = ('diffuse {0} | normal {1} | specular {2}   -   {3}' -f
            $prof.SizeFor('Diffuse'), $prof.SizeFor('Normal'), $prof.SizeFor('Specular'), $prof.Description)

        # @(): PowerShell unwraps an empty List to $null and Set-StrictMode then
        # throws on .Count.
        $warnings = @(Test-BffProfileConsistency -Profile $prof -F4ee $state.Environment.F4ee)
        $warnLabel.Text = if ($warnings.Count) { ($warnings -join '  ') } else { '' }
    }

    # Mods ticked in the side panel. Everything counts until a scan has filled it.
    $selectedMods = {
        if ($modList.Items.Count -eq 0) { return $null }
        $set = @{}
        foreach ($m in $modList.CheckedItems) { $set[[string] $m] = $true }
        return $set
    }

    $plansToApply = {
        $set = & $selectedMods
        if (-not $set) { return @($state.Plans | Where-Object { $_.NeedsWork() }) }
        return @($state.Plans | Where-Object { $_.NeedsWork() -and $set.ContainsKey($_.Texture.ModName) })
    }

    $fillModList = {
        $mods = @($state.Plans | Where-Object { $_.NeedsWork() } |
                  ForEach-Object { $_.Texture.ModName } | Sort-Object -Unique)
        $state.Populating = $true
        $modList.BeginUpdate()
        $modList.Items.Clear()
        foreach ($m in $mods) { [void] $modList.Items.Add($m, $true) }
        $modList.EndUpdate()
        $state.Populating = $false
    }

    $fillGrid = {
        $grid.Rows.Clear()
        $set  = & $selectedMods
        $rows = if ($chkOnlyChanges.Checked) {
            @($state.Plans | Where-Object { $_.Action -ne 'Skip' })
        } else { @($state.Plans) }

        # A row for an unticked mod would claim work that will not happen.
        if ($set) {
            $rows = @($rows | Where-Object { -not $_.NeedsWork() -or $set.ContainsKey($_.Texture.ModName) })
        }

        $grid.SuspendLayout()
        foreach ($p in $rows) {
            $source = if ($p.Texture.Origin -eq 'BA2') {
                '{0} -> {1}' -f $p.Texture.ArchivePath, $p.Texture.FullName
            } else { $p.Texture.FullName }

            $i = $grid.Rows.Add(@(
                $p.Texture.ModName, $p.Texture.Name, $p.Texture.Slot,
                $p.Texture.Describe(), $p.Describe(), $p.Action,
                $null, $p.Reason,
                $source, $p.Destination))

            # Assigned to the cell rather than passed in the array above: a value
            # going through a PowerShell array arrives wrapped in a PSObject, and
            # the image column cannot convert that to an Image. It throws while
            # painting - long after the row was added - so the window comes up and
            # only then fills with error dialogs. Assigning to the property
            # unwraps it.
            $grid.Rows[$i].Cells['Mark'].Value = New-BffActionGlyph -Action $p.Action

            $grid.Rows[$i].DefaultCellStyle.ForeColor = switch ($p.Action) {
                'Skip'   { [System.Drawing.Color]::Gray }
                'Review' { [System.Drawing.Color]::FromArgb(160, 90, 0) }
                'Error'  { [System.Drawing.Color]::Firebrick }
                default  { [System.Drawing.Color]::FromArgb(0, 70, 140) }
            }
        }
        # The Why column is wider than any sensible window and the paths are
        # hidden by default, so hovering any cell shows all of it.
        foreach ($r in $grid.Rows) {
            $tip = "from: {0}`nto:   {1}`n`n{2}" -f
                   $r.Cells['Source'].Value, $r.Cells['Destination'].Value, $r.Cells['Why'].Value
            foreach ($c in $r.Cells) { $c.ToolTipText = $tip }

            # The mark carries less than the text beside it, so its own tooltip
            # says what the shape means before repeating the reason.
            $act = [string] $r.Cells['Action'].Value
            $r.Cells['Mark'].ToolTipText = "{0}: {1}`n`n{2}" -f
                $act, (Get-BffActionMeaning -Action $act), $r.Cells['Why'].Value
        }

        $grid.ResumeLayout()
        # Otherwise every row comes up highlighted, which reads as "these are
        # selected" when nothing has been chosen yet.
        $grid.ClearSelection()
    }

    $applySettings = {
        $state.Settings.Scope.OnlyEnabledMods          = $chkEnabled.Checked
        $state.Settings.Scope.IncludeArchives          = $chkArchives.Checked
        $state.Settings.Scope.FixArchives               = ($chkArchives.Checked -and $chkFixArchives.Checked)
        $state.Settings.Scope.IncludeFaceCustomization = $chkFaceCust.Checked
        $state.Settings.Conversion.ForceVanillaFormats = $chkVanillaFmt.Checked
        $state.Settings.Output.Mode = if ($outputBox.SelectedIndex -eq 1) { 'InPlace' } else { 'OutputMod' }
    }

    # The GUI writes exactly the same log and CSV the console run does. Without
    # this the log file held nothing but the banner, because the report functions
    # were only ever called from the console path.
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

                $archiveFindings = @()
                $archivePlans    = New-Object System.Collections.Generic.List[BffPlan]

                foreach ($a in $archiveAll) {
                    $ap = New-BffPlan -Texture $a.Texture -Profile $state.Environment.Profile `
                                      -SlotRules $state.SlotRules -Settings $state.Settings -Force:$chkForce.Checked
                    if (-not $ap.NeedsWork()) { continue }
                    $archiveFindings += $a

                    # The game's own archives are reported but not overridden
                    # unless explicitly allowed in Settings.psd1.
                    $mayFix = $state.Settings.Scope.FixArchives -and
                              ($a.SourceKind -ne 'GameData' -or $state.Settings.Scope.FixGameArchives)

                    if ($mayFix) {
                        # Archives are never repacked: the texture is extracted,
                        # converted, and written to the output mod as a loose file.
                        $ap.Destination = Get-BffDestination -Texture $a.Texture -Settings $state.Settings -Environment $state.Environment
                        $archivePlans.Add($ap)
                        $state.ArchiveEntries[('{0}::{1}' -f $a.Texture.ArchivePath, $a.Texture.FullName)] = $a.Entry
                    }
                }

                if ($state.Settings.Scope.FixArchives -and $archivePlans.Count -gt 0) {
                    $merged = @(Update-BffPlanForExistingOutput -Plan $archivePlans `
                                                                -TexDiagPath (Get-BffTexDiagPath -Root $state.Root -Settings $state.Settings))
                    $state.Plans = @($state.Plans) + $merged
                }
                # Whatever is not being fixed stays a "look at this" finding.
                $state.Archives = @($archiveFindings | Where-Object {
                    -not $state.Settings.Scope.FixArchives -or
                    ($_.SourceKind -eq 'GameData' -and -not $state.Settings.Scope.FixGameArchives)
                })
            }
            else { $state.Archives = @() }

            & $fillModList
            & $fillGrid
            $state.Scanned = $true

            $summary = Get-BffPlanSummary -Plan $state.Plans
            $applyButton.Enabled = ($summary.Changing -gt 0)

            & $writeReport $summary
            $progressBar.Value = $progressBar.Maximum

            & $setStatus ("{0} scanned, {1} already correct, {2} to change, {3} left alone. {4}Report: {5}" -f
                $summary.Total, $summary.Skipped, $summary.Changing, $summary.Review,
                $(if ($state.Archives.Count) { "$($state.Archives.Count) more sit inside BA2 archives (inspected only). " } else { '' }),
                $state.LastCsv)
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

        $outputMods = @($todo | ForEach-Object { Get-BffOutputModDisplayName -Plan $_ } |
                          Where-Object { $_ } | Sort-Object -Unique)

        $where = if ($state.Settings.Output.Mode -eq 'InPlace') {
            'the original files (a .backup is kept next to each one)'
        } else {
            "{0} new mod folder(s):`n  {1}" -f $outputMods.Count, ($outputMods -join "`n  ")
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Convert {0} texture(s)?`n`nResults go to:`n{1}" -f $todo.Count, $where),
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

            $message = "Converted $ok texture(s)."
            if ($bad.Count) {
                $message += "`n`n$($bad.Count) failed:`n" + (($bad | Select-Object -First 10 |
                    ForEach-Object { '  ' + $_.Plan.Texture.Name + ': ' + $_.Error }) -join "`n")
            }
            if ($state.Settings.Output.Mode -ne 'InPlace') {
                $message += "`n`nIn Mod Organizer press F5, then enable each of these and drag it directly BELOW the mod it was made from:`n  " +
                            ($outputMods -join "`n  ")
            }

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
                $(if ($bad.Count) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information })) | Out-Null

            & $setStatus "$message  Log: $($state.LastLog)"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Conversion failed',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally { $scanButton.Enabled = $true }
    })

    $restoreButton.Add_Click({
        $target = if ($state.Environment.MO2) { $state.Environment.MO2.ModsPath } else { $state.Environment.DataPath }
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

    $chkFullPaths.Add_CheckedChanged({
        $grid.Columns['Source'].Visible      = $chkFullPaths.Checked
        $grid.Columns['Destination'].Visible = $chkFullPaths.Checked
    })

    & $refreshProfile

    # Handles for tests: the scan can then be driven without a visible window.
    $form.Tag = [pscustomobject]@{
        State   = $state
        Scan    = $doScan
        Grid    = $grid
        Status  = $status
        ModList = $modList
    }

    if ($BuildOnly) {
        if ($RunScan) { & $doScan }
        return $form
    }

    [void] $form.ShowDialog()
    $form.Dispose()
}
