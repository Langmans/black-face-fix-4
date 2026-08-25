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
foreach ($f in @('Types','Config','Environment','TexInfo','Ba2','Discovery','Planner','Convert','Report','Gui')) {
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
