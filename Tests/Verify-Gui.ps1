# GUI smoke test.
#
# Runs under the same Set-StrictMode the entry script uses, builds the window
# without showing it, then presses Scan programmatically. That exercises the whole
# scan path - which is where an empty List unwrapping to $null blew up on .Count.

param(
    [string] $Tool    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'),
    # Built by Verify-Console.ps1. Without it the test falls back to the real MO2
    # install, which still exercises the whole scan path.
    [string] $Sandbox = (Join-Path $env:TEMP 'BlackFaceFix.Tests\console')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0            # same as BlackFaceFix.ps1

$lib = Join-Path $Tool 'PS\Lib'
foreach ($f in @('Types','Config','Environment','TexInfo','Ba2','Discovery','Planner','Convert','Report','Icon','Gui')) {
    . (Join-Path $lib "$f.ps1")
}

$pass = 0; $fail = 0
function Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}

function Find-Control {
    param($Parent, [string] $Text, [string] $Type)
    foreach ($c in $Parent.Controls) {
        if ($c.GetType().Name -eq $Type -and $c.Text -eq $Text) { return $c }
        $deep = Find-Control -Parent $c -Text $Text -Type $Type
        if ($deep) { return $deep }
    }
    return $null
}

$sandboxMo2 = Join-Path $Sandbox 'MO2'
$useSandbox = Test-Path (Join-Path $sandboxMo2 'ModOrganizer.ini')

$settings = Import-BffSettings -Root $Tool
$settings.Paths.MO2         = if ($useSandbox) { $sandboxMo2 } else { 'C:\Modding\MO2' }
$settings.Scope.IncludeArchives = $false
if ($useSandbox) { $settings.Scope.IncludeGameData = $false }

Write-Host ("Scanning through: {0}" -f $settings.Paths.MO2)

$environment = Get-BffEnvironment -Settings $settings -Root $Tool
$slotRules   = Import-BffSlotRules -Root $Tool
$vanilla     = Import-BffVanillaFaceTextures -Root $Tool

Write-Host ''
Write-Host 'Building the window and running the scan...'

$errorBefore = $Error.Count
$form = Show-BffGui -Settings $settings -Environment $environment -SlotRules $slotRules `
                    -VanillaFaceTextures $vanilla -Root $Tool -BuildOnly -RunScan
$new = @($Error | Select-Object -First ($Error.Count - $errorBefore))

Check 'window builds and scans under StrictMode' ($null -ne $form)
Check 'no errors raised' ($new.Count -eq 0) (($new | ForEach-Object { $_.ToString() }) -join ' | ')

$scan = Find-Control -Parent $form -Text 'Scan' -Type 'Button'
$grid = $null
foreach ($c in $form.Controls) { if ($c -is [System.Windows.Forms.DataGridView]) { $grid = $c } }

Check 'Scan button found' ($null -ne $scan)
Check 'grid found'        ($null -ne $grid)

# The vanilla-format box sits on a third row, which only exists because the top
# panel was made taller for it. A control placed past the panel's edge is simply
# not drawn, so the bounds are worth asserting rather than eyeballing.
$vanillaBox = Find-Control -Parent $form -Text 'Force vanilla formats' -Type 'CheckBox'
Check 'vanilla format box found' ($null -ne $vanillaBox)
if ($vanillaBox) {
    Check 'vanilla format box fits the panel' `
        ($vanillaBox.Bottom -le $vanillaBox.Parent.Height) `
        ("bottom={0} panel={1}" -f $vanillaBox.Bottom, $vanillaBox.Parent.Height)
    Check 'vanilla format box starts off' `
        ($vanillaBox.Checked -eq [bool] $settings.Conversion.ForceVanillaFormats) `
        ("box={0} setting={1}" -f $vanillaBox.Checked, $settings.Conversion.ForceVanillaFormats)
}

# The icon is assembled byte by byte in Icon.ps1, so a mistake in the header
# shows up as a silently blank icon rather than an error. Ask it for the two
# sizes Windows actually requests and check the frames are really there.
Check 'window icon built' ($null -ne $form.Icon)
if ($form.Icon) {
    foreach ($want in @(16, 32)) {
        $sized = New-Object System.Drawing.Icon($form.Icon, $want, $want)
        Check ("window icon has a {0}px frame" -f $want) `
            ($sized.Width -eq $want -and $sized.Height -eq $want) `
            ("got {0}x{1}" -f $sized.Width, $sized.Height)
        $sized.Dispose()
    }
}

$handles = $form.Tag
Check 'test handles exposed' ($null -ne $handles -and $null -ne $handles.State)

if ($handles) {
    Check 'plans were produced' (@($handles.State.Plans).Count -gt 0) ("plans={0}" -f @($handles.State.Plans).Count)
    # The grid defaults to "only what changes", so an install where everything
    # already matches legitimately shows zero rows. Assert it mirrors the filter
    # rather than assuming there is always something to fix.
    $shown = @($handles.State.Plans | Where-Object { $_.Action -ne 'Skip' }).Count
    Check 'grid matches the filter' ($handles.Grid.Rows.Count -eq $shown) ("rows={0} expected={1}" -f $handles.Grid.Rows.Count, $shown)
    Check 'status was updated'  ($handles.Status.Text -notmatch 'Press Scan to see') $handles.Status.Text

    # One tick per source mod, not per texture, and everything on by default.
    $changing = @($handles.State.Plans | Where-Object { $_.NeedsWork() })
    $mods     = @($changing | ForEach-Object { $_.Texture.ModName } | Sort-Object -Unique)
    Check 'mod picker lists source mods' ($handles.ModList.Items.Count -eq $mods.Count) `
        ("list={0} mods={1}" -f $handles.ModList.Items.Count, $mods.Count)
    Check 'mod picker starts fully ticked' ($handles.ModList.CheckedItems.Count -eq $handles.ModList.Items.Count) `
        ("ticked={0} of {1}" -f $handles.ModList.CheckedItems.Count, $handles.ModList.Items.Count)

    # The output mod name has to be the MO2 folder, not the directory the texture
    # happens to sit in - that would report 'BaseHumanMale', or a plugin name once
    # FaceCustomization is on, because those textures live in a folder per esp.
    foreach ($pl in ($changing | Select-Object -First 5)) {
        $shownName = Get-BffOutputModDisplayName -Plan $pl
        Check ("output mod name for " + $pl.Texture.Name) `
            ($shownName -like ($pl.Texture.ModName + '*')) $shownName
    }

    # Full source and destination paths are available but off by default: handy for
    # checking exactly what is read and where it lands, far too wide to always show.
    Check 'Source column exists'      ($null -ne $handles.Grid.Columns['Source'])
    Check 'Destination column exists' ($null -ne $handles.Grid.Columns['Destination'])
    Check 'path columns start hidden' (-not $handles.Grid.Columns['Source'].Visible -and
                                       -not $handles.Grid.Columns['Destination'].Visible)

    # Rows must not be draggable. The property is the behaviour here - it is the
    # switch WinForms checks before it starts a drag - and it defaults to on, so a
    # row could be stretched to any height by accident and stayed that way.
    Check 'rows cannot be resized by dragging' (-not $handles.Grid.AllowUserToResizeRows)

    # Banding, and it has to actually differ from the plain row or it is not there.
    $band  = $handles.Grid.AlternatingRowsDefaultCellStyle.BackColor
    $plain = $handles.Grid.DefaultCellStyle.BackColor
    Check 'alternating rows are banded' `
        (-not $band.IsEmpty -and $band.ToArgb() -ne $plain.ToArgb()) `
        ("band={0} plain={1}" -f $band, $plain)

    # Faint enough that the marks keep their contrast: anything below about 240 per
    # channel starts competing with them.
    Check 'the band stays faint' `
        ($band.R -ge 240 -and $band.G -ge 240 -and $band.B -ge 240) `
        ("{0},{1},{2}" -f $band.R, $band.G, $band.B)

    # The progress bar and the status line have to grow with the window. Built at
    # a fixed width they stop halfway across a maximised window, and the status
    # line - which carries the path to the report - gets cut off mid-path. Widening
    # the form here is what proves the anchors are doing it, rather than reading
    # the Anchor property back and trusting it.
    $wasWide = $handles.Progress.Width
    $wasText = $handles.Status.Width
    $form.Width = $form.Width + 400
    $form.PerformLayout()
    Check 'progress bar grows with the window' ($handles.Progress.Width -gt $wasWide) `
        ("{0} -> {1}" -f $wasWide, $handles.Progress.Width)
    Check 'status line grows with the window' ($handles.Status.Width -gt $wasText) `
        ("{0} -> {1}" -f $wasText, $handles.Status.Width)
    $form.Width = $form.Width - 400
    $form.PerformLayout()

    # The reason is not a column any more - it is the tooltip, one line per mark
    # with the mark as its bullet. As a column every row opened with the same words
    # and the width cut off the part that differed.
    Check 'no Why column' ($null -eq $handles.Grid.Columns['Why'])
    Check 'built-in cell tooltips are off' (-not $handles.Grid.ShowCellToolTips)

    if ($handles.Grid.Rows.Count -gt 0) {
        $plan  = $handles.Grid.Rows[0].Tag
        $lines = @(Get-BffPlanTipLine -Plan $plan)

        Check 'tooltip has a line per mark' `
            ($lines.Count -eq @(Get-BffPlanMark -Plan $plan).Count) `
            ("{0} lines, {1} marks" -f $lines.Count, @(Get-BffPlanMark -Plan $plan).Count)

        $empty = @($lines | Where-Object { -not $_.Text })
        Check 'every tooltip line says something' ($empty.Count -eq 0) `
            (($empty | ForEach-Object { $_.Kind }) -join ', ')

        # A line must not be the bare mark name: that would mean the fallback fired
        # where a real sentence was expected.
        $bare = @($lines | Where-Object { $_.Text -eq $_.Kind })
        Check 'no tooltip line is just the mark name' ($bare.Count -eq 0) `
            (($bare | ForEach-Object { $_.Kind }) -join ', ')
    }

    # Marks are packed into one column the way MO2 does it: each is one fact, and
    # a row shows as many as apply. Two of them say what happens to the file and
    # compose; the rest are context.
    function Plan-For {
        param([string] $Action, [string] $Origin = 'Loose', [bool] $Tint = $false, [string] $MatchedBy = 'head name')
        $t = [BffTexture]::new()
        $t.Origin = $Origin; $t.IsTintMask = $Tint; $t.MatchedBy = $MatchedBy
        $p = [BffPlan]::new()
        $p.Texture = $t; $p.Action = $Action
        return $p
    }

    $allActions = @('Skip', 'Resize', 'Reformat', 'ResizeAndReformat', 'Review', 'Error')

    Check 'both changes show both marks' `
        ((@(Get-BffPlanMark -Plan (Plan-For 'ResizeAndReformat')) -join ',') -eq 'Resize,Reformat') `
        ((Get-BffPlanMark -Plan (Plan-For 'ResizeAndReformat')) -join ',')

    $notOne = @($allActions | Where-Object {
        $_ -ne 'ResizeAndReformat' -and @(Get-BffPlanMark -Plan (Plan-For $_)).Count -ne 1
    })
    Check 'every other action shows one action mark' ($notOne.Count -eq 0) ($notOne -join ', ')

    # Context marks come from the texture, not the action.
    Check 'a BA2 texture gets the archive mark' `
        ((@(Get-BffPlanMark -Plan (Plan-For 'Resize' 'BA2')) -join ',') -eq 'Resize,Archive') `
        ((Get-BffPlanMark -Plan (Plan-For 'Resize' 'BA2')) -join ',')
    Check 'a tint mask gets the tintmask mark' `
        ((@(Get-BffPlanMark -Plan (Plan-For 'Skip' 'Loose' $true)) -join ',') -eq 'Skip,TintMask') `
        ((Get-BffPlanMark -Plan (Plan-For 'Skip' 'Loose' $true)) -join ',')
    Check 'a record match gets the facerecord mark' `
        ((@(Get-BffPlanMark -Plan (Plan-For 'Skip' 'Loose' $false 'vanilla texture set')) -join ',') -eq 'Skip,FaceRecord') `
        ((Get-BffPlanMark -Plan (Plan-For 'Skip' 'Loose' $false 'vanilla texture set')) -join ',')
    Check 'a plain head-name match gets no context mark' `
        ((@(Get-BffPlanMark -Plan (Plan-For 'Skip')) -join ',') -eq 'Skip') `
        ((Get-BffPlanMark -Plan (Plan-For 'Skip')) -join ',')

    # The image is sized for the worst case, so a mark means the same thing in the
    # same place all the way down the column.
    $worst = Plan-For 'ResizeAndReformat' 'BA2' $true
    Check 'the busiest row still fits the image' `
        (@(Get-BffPlanMark -Plan $worst).Count -le 4) `
        ((Get-BffPlanMark -Plan $worst) -join ',')
    $wide = New-BffPlanGlyph -Plan $worst
    $thin = New-BffPlanGlyph -Plan (Plan-For 'Skip')
    Check 'every glyph is the same width' ($wide.Width -eq $thin.Width) `
        ("{0} vs {1}" -f $wide.Width, $thin.Width)

    # Every mark has to say what it means, or the tooltip shows a bare name.
    $unnamed = @('Resize', 'Reformat', 'Skip', 'Review', 'Error', 'Archive', 'TintMask', 'FaceRecord' |
                 Where-Object { (Get-BffMarkMeaning -Kind $_) -eq $_ })
    Check 'every mark has a meaning' ($unnamed.Count -eq 0) ($unnamed -join ', ')

    # Each half of the reason has to land on the mark it is about, or the tooltip
    # says the same thing twice and the useful half goes missing.
    $split = Plan-For 'ResizeAndReformat'
    $split.SizeReason   = 'THE SIZE HALF'
    $split.FormatReason = 'THE FORMAT HALF'
    $splitLines = @(Get-BffPlanTipLine -Plan $split)
    Check 'the resize line carries the size reason' `
        (($splitLines | Where-Object Kind -eq 'Resize').Text -eq 'THE SIZE HALF') `
        (($splitLines | Where-Object Kind -eq 'Resize').Text)
    Check 'the reformat line carries the format reason' `
        (($splitLines | Where-Object Kind -eq 'Reformat').Text -eq 'THE FORMAT HALF') `
        (($splitLines | Where-Object Kind -eq 'Reformat').Text)

    # A row that is only reported, not changed, has one mark and the whole reason.
    $reviewed = Plan-For 'Review'
    $reviewed.Reason = 'THE WHOLE STORY'
    Check 'a Review row shows its reason' `
        ((@(Get-BffPlanTipLine -Plan $reviewed)[0]).Text -eq 'THE WHOLE STORY') `
        ((@(Get-BffPlanTipLine -Plan $reviewed)[0]).Text)

    $mark = $handles.Grid.Columns['Mark']
    Check 'Mark column exists' ($null -ne $mark)
    if ($mark) {
        Check 'Mark column holds images' ($mark -is [System.Windows.Forms.DataGridViewImageColumn]) $mark.GetType().Name
        Check 'Mark column is wide enough' ($mark.Width -ge $wide.Width) `
            ("column {0}, image {1}" -f $mark.Width, $wide.Width)

        if ($handles.Grid.Rows.Count -gt 0) {
            $missing = @($handles.Grid.Rows | Where-Object { $null -eq $_.Cells['Mark'].Value })
            Check 'every row has a glyph' ($missing.Count -eq 0) ("{0} rows without one" -f $missing.Count)

            # Checking the value is not null is not enough, and this is why: a
            # glyph handed to Rows.Add inside an array arrives wrapped in a
            # PSObject. The cell holds it happily, and the column only fails when
            # it tries to format it - which is at paint time, so the window opens
            # and only then buries itself in error dialogs. Painting the grid here
            # is what makes the test see what the user sees.
            $painted = New-Object System.Drawing.Bitmap($handles.Grid.Width, $handles.Grid.Height)
            $dataErrors = New-Object System.Collections.ArrayList
            $handler = { param($s, $e) [void] $dataErrors.Add($e.Exception.Message) }
            $handles.Grid.Add_DataError($handler)
            try { $handles.Grid.DrawToBitmap($painted, (New-Object System.Drawing.Rectangle(0, 0, $painted.Width, $painted.Height))) }
            finally { $handles.Grid.Remove_DataError($handler); $painted.Dispose() }

            Check 'grid paints without cell errors' ($dataErrors.Count -eq 0) `
                (($dataErrors | Select-Object -First 1) -join '')

            # The owner-drawn tooltip reads the plan off the row, so a row without
            # one would show an empty popup.
            $tagless = @($handles.Grid.Rows | Where-Object { $null -eq $_.Tag })
            Check 'every row carries its plan' ($tagless.Count -eq 0) ("{0} rows without one" -f $tagless.Count)

            # And the built-in tooltip has to stay quiet on that cell, or the two
            # of them fight over the same hover.
            $noisy = @($handles.Grid.Rows | Where-Object { $_.Cells['Mark'].ToolTipText -ne '' })
            Check 'built-in tooltip is off for marks' ($noisy.Count -eq 0) ("{0} rows with one" -f $noisy.Count)
        }
    }

    # The GUI has to write the same log and CSV the console run does. It is easy
    # for it not to: the report functions are called from the console path, so a
    # GUI run that skips them still produces a log file - holding nothing but the
    # banner.
    Check 'CSV written' ($handles.State.LastCsv -and (Test-Path -LiteralPath $handles.State.LastCsv)) $handles.State.LastCsv
    Check 'log written' ($handles.State.LastLog -and (Test-Path -LiteralPath $handles.State.LastLog)) $handles.State.LastLog

    if ($handles.State.LastLog -and (Test-Path -LiteralPath $handles.State.LastLog)) {
        $log = Get-Content -LiteralPath $handles.State.LastLog
        Check 'log has more than the banner' ($log.Count -gt 20) ("lines={0}" -f $log.Count)
        Check 'log contains the summary'     (($log -join "`n") -match 'Summary')
        Check 'log contains the profile'     (($log -join "`n") -match 'Profile: ')
    }
    if ($handles.State.LastCsv -and (Test-Path -LiteralPath $handles.State.LastCsv)) {
        $csvRows = @(Import-Csv -LiteralPath $handles.State.LastCsv)
        Check 'CSV has a row per texture' ($csvRows.Count -eq @($handles.State.Plans).Count) ("csv={0} plans={1}" -f $csvRows.Count, @($handles.State.Plans).Count)
    }

    Write-Host ''
    Write-Host ("  status: {0}" -f $handles.Status.Text) -ForegroundColor DarkGray
    if ($handles.Grid.Rows.Count -gt 0) {
        Write-Host '  grid:' -ForegroundColor DarkGray
        foreach ($r in $handles.Grid.Rows) {
            Write-Host ('    ' + (($r.Cells | ForEach-Object { $_.Value }) -join ' | ')) -ForegroundColor DarkGray
        }
    }
}

$form.Dispose()

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
