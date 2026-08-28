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

    if ($handles.Grid.Rows.Count -gt 0) {
        $tip = $handles.Grid.Rows[0].Cells[0].ToolTipText
        Check 'tooltip carries from/to and why' ($tip -match 'from:' -and $tip -match 'to:') $tip
    }

    # A mark per row in front of the reason, with its own tooltip saying what the
    # shape means. An image column that never gets a value renders as an empty
    # gap, which looks like a layout bug rather than a missing value.
    $mark = $handles.Grid.Columns['Mark']
    Check 'Mark column exists' ($null -ne $mark)
    if ($mark) {
        Check 'Mark column holds images' ($mark -is [System.Windows.Forms.DataGridViewImageColumn]) $mark.GetType().Name

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

            $row      = $handles.Grid.Rows[0]
            $markTip  = $row.Cells['Mark'].ToolTipText
            $action   = [string] $row.Cells['Action'].Value
            Check 'glyph tooltip names the action' ($markTip -like ($action + ':*')) $markTip
            Check 'glyph tooltip explains the action' `
                ($markTip -match [regex]::Escape((Get-BffActionMeaning -Action $action))) $markTip
        }
    }

    # The GUI has to write the same log and CSV the console run does. It used to
    # write a log holding nothing but the banner, because the report functions
    # were only ever called from the console path.
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
