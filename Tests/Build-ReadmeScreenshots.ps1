# Renders the screenshots the README uses.
#
# Not a test. It exists so the images can be regenerated after a UI change
# instead of being taken by hand and slowly going stale.
#
# Self-contained on purpose. It paints its own source image, converts that into
# every shape it needs, and builds a throwaway MO2 with invented mod names around
# it, so it needs neither Fallout 4 nor any mod installed - and a screenshot in a
# public README carries nobody's actual mod list. Invented mods also get to be
# shaped so that every mark appears.

param(
    [string] $Tool    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'),
    [string] $Sandbox = (Join-Path $env:TEMP 'BlackFaceFix.Shots'),
    [string] $OutDir  = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix') 'docs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$lib = Join-Path $Tool 'PS\Lib'
foreach ($f in 'Types','Config','Environment','TexInfo','Ba2','Discovery','Planner','Convert','Report','Icon','Gui') {
    . (Join-Path $lib "$f.ps1")
}
Add-Type -AssemblyName System.Windows.Forms

$texconv = Join-Path $Tool 'MSFT\texconv.exe'
if (-not (Test-Path -LiteralPath $texconv)) { throw "texconv not found at '$texconv'." }

if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
$mods = Join-Path $Sandbox 'MO2\mods'
$prof = Join-Path $Sandbox 'MO2\profiles\Default'
# The tool identifies a Fallout 4 install by a Data folder next to it. Nothing is
# read out of it here, so an empty one is enough to let the scan start.
$game = Join-Path $Sandbox 'Game'
New-Item -ItemType Directory -Path $mods, $prof, (Join-Path $game 'Data') -Force | Out-Null

# ----------------------------------------------------------- source material
# Painted rather than copied: skin-ish tones with some structure, so the demo
# textures compress to plausible sizes and nothing real has to be installed.
$srcPng = Join-Path $Sandbox 'source.png'
$src = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($src)
$g.Clear([System.Drawing.Color]::FromArgb(255, 208, 170, 142))
$rand = New-Object System.Random(7)
for ($i = 0; $i -lt 900; $i++) {
    $x = $rand.Next(0, 256); $y = $rand.Next(0, 256); $r = $rand.Next(2, 14)
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(
            40, $rand.Next(120, 240), $rand.Next(90, 190), $rand.Next(80, 170)))
    $g.FillEllipse($b, $x, $y, $r, $r)
    $b.Dispose()
}
$g.Dispose()
$src.Save($srcPng, [System.Drawing.Imaging.ImageFormat]::Png)
$src.Dispose()

# The sandbox lives under %TEMP%, which puts the Windows user name into every path
# the window shows. These are display strings only - nothing reads them back - so
# they are rewritten to ordinary-looking install paths before anything is drawn.
function ConvertTo-DemoPath {
    param([string] $Text)
    if (-not $Text) { return $Text }
    $Text = $Text.Replace((Join-Path $Sandbox 'MO2'), 'C:\Modding\MO2')
    $Text = $Text.Replace((Join-Path $Sandbox 'Game'), 'C:\Games\Fallout 4')
    $Text = $Text.Replace($Tool, 'Black Face Fix')
    return $Text
}

function Set-DemoText {
    param($Parent)
    foreach ($c in $Parent.Controls) {
        if ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.Label]) {
            $c.Text = ConvertTo-DemoPath $c.Text
        }
        Set-DemoText $c
    }
}

function New-Texture {
    param([string] $Dest, [int] $W, [int] $H, [string] $Fmt)
    $tmp = Join-Path $env:TEMP ('shot_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        & $texconv -nologo -y -w $W -h $H -m 0 -f $Fmt -ft DDS -o $tmp $srcPng | Out-Null
        $made = Get-ChildItem $tmp -Filter *.dds | Select-Object -First 1
        if (-not $made) { throw "texconv produced nothing for $Dest" }
        Copy-Item $made.FullName $Dest -Force
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------- the demo mods
# MO2 stores paths in @ByteArray() with every backslash doubled.
@"
[General]
gameName=Fallout 4
gamePath=@ByteArray($($game.Replace('\', '\\')))
selected_profile=@ByteArray(Default)
"@ | Set-Content (Join-Path $Sandbox 'MO2\ModOrganizer.ini')

"# generated`n+Example Face Replacer`n+Example Makeup Pack" | Set-Content (Join-Path $prof 'modlist.txt')

$male   = Join-Path $mods 'Example Face Replacer\textures\actors\character\BaseHumanMale'
$female = Join-Path $mods 'Example Face Replacer\textures\actors\character\BaseHumanFemale'
$masks  = Join-Path $mods 'Example Makeup Pack\textures\actors\character\Character Assets\TintMasks'
$detail = Join-Path $mods 'Example Makeup Pack\textures\actors\character\Character Assets\FaceDetails'
New-Item -ItemType Directory -Path $male, $female, $masks, $detail -Force | Out-Null

Write-Host 'Building demo textures...' -ForegroundColor Yellow
# BC4 is a single-channel format, which is wrong for a colour head diffuse - so it
# shows a re-encode without needing Force vanilla formats ticked.
New-Texture (Join-Path $male   'MaleHead_s.dds')    1024 1024 BC5_UNORM   # specular: scaled to 512
New-Texture (Join-Path $male   'MaleHead_d.dds')    1024 1024 BC4_UNORM   # diffuse: re-encoded
New-Texture (Join-Path $male   'MaleHead_n.dds')    1024 1024 BC5_UNORM   # normal: already right
New-Texture (Join-Path $female 'FemaleHead_d.dds')  2048 2048 BC4_UNORM   # both wrong
New-Texture (Join-Path $female 'FemaleHead_s.dds')   512  512 BC5_UNORM   # already right
New-Texture (Join-Path $masks  'Blusher.dds')       2048 2048 BC7_UNORM   # tint mask, scaled down
New-Texture (Join-Path $masks  'Eyeliner.dds')      1024 1024 BC1_UNORM   # tint mask, already right
New-Texture (Join-Path $detail 'Freckles_d.dds')     512  512 BC3_UNORM   # face detail, scaled up
New-Texture (Join-Path $detail 'ColourRamp.dds')      64  128 BC1_UNORM   # not square: Review

# ----------------------------------------------------------------- the window
$settings = Import-BffSettings -Root $Tool
$settings.Paths.MO2             = (Join-Path $Sandbox 'MO2')
$settings.Paths.Fallout4        = $game
$settings.Scope.IncludeArchives = $false
$settings.Scope.IncludeGameData = $false
$settings.Profile               = 'Vanilla'

$environment = Get-BffEnvironment -Settings $settings -Root $Tool
$form = Show-BffGui -Settings $settings -Environment $environment `
                    -SlotRules (Import-BffSlotRules -Root $Tool) `
                    -VanillaFaceTextures (Import-BffVanillaFaceTextures -Root $Tool) `
                    -Root $Tool -BuildOnly -RunScan

if (-not (Test-Path $OutDir)) { [void] (New-Item -ItemType Directory -Path $OutDir) }

# The default view - only what changes - because that is what anyone opening the
# tool sees first. The marks image covers the tick for rows left alone. Toggling
# the checkbox from out here would not work anyway: its handler reads state that
# only exists while Show-BffGui is still running.
# Wide enough that the top row is not cut off by the mod picker. See the note on
# the top panel's layout in TODO.md: at the default width it is.
$form.Size = New-Object System.Drawing.Size(1360, 620)
"rows shown: $($form.Tag.Grid.Rows.Count)"
Set-DemoText $form

# Shown off screen, then drawn. A window that was never shown has never painted
# its children, so drawing it only gives the frame - and drawing the children one
# by one does not help either, because they have no window handles yet.
#
# Showing it is safe here: every handler the window wires is a click, a tick or a
# selection, which nothing does without a user, plus the row tooltip's mouse
# handlers, which carry their own state rather than reading Show-BffGui's.
$form.StartPosition = 'Manual'
$form.Location      = New-Object System.Drawing.Point(-4000, -4000)
$form.ShowInTaskbar = $false
$form.Show()
[System.Windows.Forms.Application]::DoEvents()

# Showing the grid makes its first cell current and highlights that row. In a
# screenshot that reads as "this one is selected", which it is not.
$form.Tag.Grid.ClearSelection()
$form.Tag.Grid.CurrentCell = $null

# With visual styles a progress bar animates towards its value instead of
# jumping there, so it is still near the start straight after Show. Pump messages
# until it has caught up.
$until = (Get-Date).AddMilliseconds(1500)
while ((Get-Date) -lt $until) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 30
}

$shot = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($shot, (New-Object System.Drawing.Rectangle(0, 0, $shot.Width, $shot.Height)))
$shot.Save((Join-Path $OutDir 'window.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$shot.Dispose()
$form.Hide()

# ------------------------------------------------------------------ the marks
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$ink  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 25, 25, 25))
$rule = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 226, 229, 233))

$kinds = @('Resize', 'Reformat', 'Skip', 'Review', 'Error', 'Archive', 'TintMask', 'FaceRecord')
$sheet = New-Object System.Drawing.Bitmap(540, (10 + 28 * $kinds.Count),
                                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::White)
$y = 5
foreach ($k in $kinds) {
    $m = New-BffMark -Kind $k
    $g.DrawImage($m, 14, $y + 5)
    $m.Dispose()
    $g.DrawString(('{0} - {1}' -f $k, (Get-BffMarkMeaning -Kind $k)), $font, $ink, 42, $y + 6)
    $y += 28
    $g.DrawLine($rule, 10, $y, 530, $y)
}
$g.Dispose()
$sheet.Save((Join-Path $OutDir 'marks.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()

# ---------------------------------------------------------------- the tooltip
$pick = @($form.Tag.State.Plans | Where-Object { $_.Texture.IsTintMask -and $_.NeedsWork() })
$plan = if ($pick.Count -gt 0) { $pick[0] } else { @($form.Tag.State.Plans)[0] }

$pad = 8; $bullet = 24; $maxW = 560
$lines = @(Get-BffPlanTipLine -Plan $plan | ForEach-Object {
    [pscustomobject]@{ Kind = $_.Kind; Text = $_.Text; H = 0 } })
$lines += [pscustomobject]@{ Kind = ''; Text = ('from:  ' + (ConvertTo-DemoPath (Get-BffRowFolder -Plan $plan -Full))); H = 0 }
if ($plan.Destination) {
    $lines += [pscustomobject]@{ Kind = ''; Text = ('to:    ' + (ConvertTo-DemoPath $plan.Destination)); H = 0 }
}

$textW = $maxW - $bullet - 2 * $pad
$wide = 0; $high = 2 * $pad
foreach ($l in $lines) {
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($l.Text, $font,
                (New-Object System.Drawing.Size($textW, 0)),
                [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $l.H = [Math]::Max($size.Height, 18)
    if ($size.Width -gt $wide) { $wide = $size.Width }
    $high += $l.H + 4
}
$w = $wide + $bullet + 2 * $pad

$tip = New-Object System.Drawing.Bitmap(($w + 1), ($high + 1), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($tip)
$g.Clear([System.Drawing.Color]::FromArgb(255, 255, 255, 225))
$g.DrawRectangle((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 118, 118, 118))), 0, 0, $w, $high)
$ly = $pad
foreach ($l in $lines) {
    if ($l.Kind) {
        $m = New-BffMark -Kind $l.Kind
        $g.DrawImage($m, $pad, $ly + 1)
        $m.Dispose()
    }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $l.Text, $font,
        (New-Object System.Drawing.Rectangle(($pad + $bullet), $ly, $textW, $l.H)),
        [System.Drawing.Color]::Black, [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $ly += $l.H + 4
}
$g.Dispose()
$tip.Save((Join-Path $OutDir 'tooltip.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$tip.Dispose()

$form.Dispose()
Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue

Get-ChildItem $OutDir -Filter *.png | ForEach-Object { '{0,-14} {1,8:N0} bytes' -f $_.Name, $_.Length }
