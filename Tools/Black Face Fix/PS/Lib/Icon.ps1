# Icon.ps1 - the window icon, drawn rather than shipped.
#
# The mark is two nested squares: a large outline with a small solid block inside
# it, which is what the tool does to a texture. Deliberately abstract - nothing
# figurative, nothing to do with faces or skin.
#
# It is built at run time instead of committed as a .ico so the repo stays plain
# text and the shape can be edited in the same place it is described. Rendering
# seven frames takes a few milliseconds and happens once, when the window opens.

Add-Type -AssemblyName System.Drawing

# Sizes Windows asks a Form for: 16 in the title bar, 32 and 48 for Alt-Tab and
# the taskbar, the rest for display scaling above 100%. A Form never needs 256,
# so that frame is left out.
$script:BffIconSizes = @(16, 20, 24, 32, 40, 48, 64)

function New-BffIconFrame {
    <#
    .SYNOPSIS
    Draws the mark at one size and returns it as a 32-bit ARGB bitmap.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $Size)

    $back   = [System.Drawing.Color]::FromArgb(255, 20, 32, 46)   # dark slate
    $stroke = [System.Drawing.Color]::FromArgb(255, 143, 184, 216) # pale blue
    $block  = [System.Drawing.Color]::FromArgb(255, 232, 163,  61) # amber

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)

        # Rounded background. Kept fairly tight: at 16px a larger radius eats so
        # much of the edge that the whole thing reads as a blob in the title bar.
        $radius = [Math]::Max(2, [int] [Math]::Round($Size * 0.17))
        $path   = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d      = $radius * 2
        $last   = $Size - 1
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($last - $d, 0, $d, $d, 270, 90)
        $path.AddArc($last - $d, $last - $d, $d, $d, 0, 90)
        $path.AddArc(0, $last - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $brush = New-Object System.Drawing.SolidBrush($back)
        $g.FillPath($brush, $path)
        $brush.Dispose()
        $path.Dispose()

        # The outer square: the source texture. Its stroke has to stay a whole
        # number of pixels or antialiasing turns it into grey mush at 16px.
        $penWidth = [Math]::Max(1, [int] [Math]::Round($Size / 13))
        $outer    = [int] [Math]::Round($Size * 0.20)
        $outerLen = $Size - (2 * $outer) - $penWidth
        $pen      = New-Object System.Drawing.Pen($stroke, $penWidth)
        $pen.Alignment = 'Inset'
        $g.DrawRectangle($pen, $outer, $outer, $outerLen, $outerLen)
        $pen.Dispose()

        # The inner block: the same texture after the tool is done with it.
        $innerLen = [Math]::Max(2, [int] [Math]::Round($Size * 0.30))
        $inner    = [int] [Math]::Round(($Size - $innerLen) / 2)
        $fill     = New-Object System.Drawing.SolidBrush($block)
        $g.FillRectangle($fill, $inner, $inner, $innerLen, $innerLen)
        $fill.Dispose()
    }
    finally { $g.Dispose() }

    return $bmp
}

function ConvertTo-BffIcon {
    <#
    .SYNOPSIS
    Packs bitmaps into a multi-size .ico and returns it as a System.Drawing.Icon.

    .NOTES
    Every frame is written as an uncompressed DIB rather than a PNG. Windows
    itself reads PNG frames, but System.Drawing.Icon on .NET Framework - which is
    what Windows PowerShell runs on - does not reliably, and a PNG frame it
    cannot parse comes back as a blank icon rather than an error.

    An icon DIB is two images stacked: the colour data, then a 1-bit AND mask.
    biHeight covers both, so it is twice the real height. The mask is left at
    zero throughout because 32-bit frames carry their own alpha; it still has to
    be present and correctly sized or the icon is rejected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Drawing.Bitmap[]] $Frame)

    $payloads = New-Object System.Collections.Generic.List[byte[]]

    foreach ($bmp in $Frame) {
        $w = $bmp.Width
        $h = $bmp.Height

        # 32 bits per pixel, so the colour rows are already 4-byte aligned. The
        # mask is 1 bit per pixel and has to be padded up to 4 bytes per row.
        $maskStride = [int] ([Math]::Floor(($w + 31) / 32) * 4)
        $xorSize    = $w * $h * 4
        $andSize    = $maskStride * $h

        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        try {
            $bw.Write([uint32] 40)          # biSize
            $bw.Write([int32]  $w)          # biWidth
            $bw.Write([int32]  ($h * 2))    # biHeight: colour data plus mask
            $bw.Write([uint16] 1)           # biPlanes
            $bw.Write([uint16] 32)          # biBitCount
            $bw.Write([uint32] 0)           # biCompression = BI_RGB
            $bw.Write([uint32] ($xorSize + $andSize))
            $bw.Write([int32]  0)           # biXPelsPerMeter
            $bw.Write([int32]  0)           # biYPelsPerMeter
            $bw.Write([uint32] 0)           # biClrUsed
            $bw.Write([uint32] 0)           # biClrImportant

            # Bottom-up, BGRA. These are at most 64x64, so GetPixel is quick
            # enough and avoids pinning the bitmap.
            for ($y = $h - 1; $y -ge 0; $y--) {
                for ($x = 0; $x -lt $w; $x++) {
                    $c = $bmp.GetPixel($x, $y)
                    $bw.Write([byte] $c.B)
                    $bw.Write([byte] $c.G)
                    $bw.Write([byte] $c.R)
                    $bw.Write([byte] $c.A)
                }
            }

            $bw.Write((New-Object byte[] $andSize))
            $bw.Flush()
            $payloads.Add($ms.ToArray())
        }
        finally { $bw.Dispose(); $ms.Dispose() }
    }

    $out = New-Object System.IO.MemoryStream
    $w2  = New-Object System.IO.BinaryWriter($out)
    try {
        $w2.Write([uint16] 0)                 # reserved
        $w2.Write([uint16] 1)                 # type: 1 = icon
        $w2.Write([uint16] $Frame.Count)

        # Directory entries are fixed width, so the first payload starts right
        # after all of them.
        $offset = 6 + (16 * $Frame.Count)
        for ($i = 0; $i -lt $Frame.Count; $i++) {
            $bmp = $Frame[$i]
            # 0 means 256 in this field; nothing here is that large, but the
            # cast keeps it honest if a bigger frame is ever added.
            $w2.Write([byte] ($bmp.Width  % 256))
            $w2.Write([byte] ($bmp.Height % 256))
            $w2.Write([byte] 0)               # palette size: none, it is 32-bit
            $w2.Write([byte] 0)               # reserved
            $w2.Write([uint16] 1)             # colour planes
            $w2.Write([uint16] 32)            # bits per pixel
            $w2.Write([uint32] $payloads[$i].Length)
            $w2.Write([uint32] $offset)
            $offset += $payloads[$i].Length
        }

        foreach ($p in $payloads) { $w2.Write($p) }
        $w2.Flush()

        $out.Position = 0
        return New-Object System.Drawing.Icon($out)
    }
    finally { $w2.Dispose(); $out.Dispose() }
}

# ---------------------------------------------------------------- row marks
#
# Small marks packed side by side in one column, the way Mod Organizer's Flags
# and Content columns work: each mark is one fact, and a row shows as many as
# apply. The reason text beside them stays the authority; these are for reading
# the shape of a scan without reading it.
#
# Two of them say what is about to happen, and they compose:
#
#   resize    blue nested squares - the picture is redrawn at another size
#   reformat  amber split square  - same picture, different encoding
#
# Skip, Review and Error replace those with a single mark of their own. The rest
# are context - facts about the file that no column in the grid shows:
#
#   archive     slate parcel  - it lives inside a BA2, not on disk as a file
#   tintmask    violet layers - a mask or face detail rather than a head texture
#   facerecord  teal card     - matched from the game's own texture set records,
#                               so it is a face texture even though nothing in
#                               its name says so: Preston_d.dds, Mayor_s.dds
#
# Colours carry meaning rather than severity, and are weighted for the white row
# they sit on: at 16px a light tone on white reads as a smudge rather than as a
# shape, so these are darker than they look right on their own.
$script:BffMarkCache = @{}

# 16px a slot, packed tight the way MO2 does. Four is the most any row can show:
# an action, a reformat, an archive, and one of tintmask/facerecord.
$script:BffMarkSlot = 16
$script:BffMarkGap  = 1
$script:BffMarkMax  = 4

function New-BffMark {
    <#
    .SYNOPSIS
    One 16x16 mark. Kinds: Resize, Reformat, Skip, Review, Error, Archive,
    TintMask, FaceRecord.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Kind)

    $grey   = [System.Drawing.Color]::FromArgb(255, 120, 130, 142)
    $blue   = [System.Drawing.Color]::FromArgb(255,  40, 118, 190)
    $amber  = [System.Drawing.Color]::FromArgb(255, 208, 132,  16)
    $orange = [System.Drawing.Color]::FromArgb(255, 214,  99,  20)
    $red    = [System.Drawing.Color]::FromArgb(255, 190,  54,  54)
    $slate  = [System.Drawing.Color]::FromArgb(255,  92, 104, 120)
    $violet = [System.Drawing.Color]::FromArgb(255, 132,  84, 178)
    $teal   = [System.Drawing.Color]::FromArgb(255,  22, 134, 128)

    $n   = $script:BffMarkSlot
    $bmp = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)

        switch ($Kind) {
            'Resize' {
                # Nested squares: the same picture, drawn at another size.
                $pen = New-Object System.Drawing.Pen($blue, 2)
                $pen.Alignment = 'Inset'
                $g.DrawRectangle($pen, 1, 1, 13, 13)
                $pen.Dispose()
                $b = New-Object System.Drawing.SolidBrush($blue)
                $g.FillRectangle($b, 5, 5, 6, 6)
                $b.Dispose()
            }
            'Reformat' {
                # One square split corner to corner: same picture, encoded
                # differently. Deliberately not a nested shape - the two action
                # marks have to be told apart by outline, not only by colour.
                $b = New-Object System.Drawing.SolidBrush($amber)
                $g.FillPolygon($b, [System.Drawing.Point[]] @(
                    (New-Object System.Drawing.Point(2, 2)),
                    (New-Object System.Drawing.Point(14, 2)),
                    (New-Object System.Drawing.Point(2, 14))))
                $b.Dispose()

                $pen = New-Object System.Drawing.Pen($amber, 2)
                $pen.Alignment = 'Inset'
                $g.DrawRectangle($pen, 1, 1, 13, 13)
                $pen.Dispose()
            }
            'Skip' {
                # A tick: nothing to do here.
                $pen = New-Object System.Drawing.Pen($grey, 2)
                $g.DrawLines($pen, [System.Drawing.Point[]] @(
                    (New-Object System.Drawing.Point(3, 8)),
                    (New-Object System.Drawing.Point(6, 12)),
                    (New-Object System.Drawing.Point(13, 4))))
                $pen.Dispose()
            }
            'Review' {
                # A bar and a dot: look at this one yourself.
                $b = New-Object System.Drawing.SolidBrush($orange)
                $g.FillRectangle($b, 7, 3, 2, 7)
                $g.FillRectangle($b, 7, 11, 2, 2)
                $b.Dispose()
            }
            'Error' {
                # A cross: this one did not work.
                $pen = New-Object System.Drawing.Pen($red, 2)
                $g.DrawLine($pen, 4, 4, 12, 12)
                $g.DrawLine($pen, 12, 4, 4, 12)
                $pen.Dispose()
            }
            'Archive' {
                # A parcel: a box with a band round it, so it reads as packed
                # rather than as yet another square.
                $pen = New-Object System.Drawing.Pen($slate, 2)
                $pen.Alignment = 'Inset'
                $g.DrawRectangle($pen, 1, 3, 13, 10)
                $pen.Dispose()
                $b = New-Object System.Drawing.SolidBrush($slate)
                $g.FillRectangle($b, 6, 4, 3, 8)
                $b.Dispose()
            }
            'TintMask' {
                # Stacked bars: layers painted onto a face rather than the face.
                $b = New-Object System.Drawing.SolidBrush($violet)
                $g.FillRectangle($b, 2,  3, 12, 3)
                $g.FillRectangle($b, 2,  8,  9, 3)
                $g.FillRectangle($b, 2, 12,  6, 2)
                $b.Dispose()
            }
            'FaceRecord' {
                # A card with two lines: this came out of the game's own records.
                $pen = New-Object System.Drawing.Pen($teal, 2)
                $pen.Alignment = 'Inset'
                $g.DrawRectangle($pen, 1, 2, 13, 12)
                $pen.Dispose()
                $b = New-Object System.Drawing.SolidBrush($teal)
                $g.FillRectangle($b, 4, 6, 8, 2)
                $g.FillRectangle($b, 4, 10, 5, 2)
                $b.Dispose()
            }
        }
    }
    finally { $g.Dispose() }

    return $bmp
}

function Get-BffMarkMeaning {
    <#
    .SYNOPSIS
    One line saying what a mark means, for the tooltip.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Kind)

    switch ($Kind) {
        'Resize'     { 'the size is wrong, so the texture is redrawn' }
        'Reformat'   { 'the format is wrong, so the texture is re-encoded' }
        'Skip'       { 'already matches the profile, nothing is written' }
        'Review'     { 'left alone on purpose - look at this one yourself' }
        'Error'      { 'this one could not be read or planned' }
        'Archive'    { 'inside a BA2, so the fix is written out as a loose file' }
        'TintMask'   { 'a mask or face detail, not a head texture' }
        'FaceRecord' { 'matched from the game''s own texture set records, not by name' }
        default      { $Kind }
    }
}

function Get-BffPlanMark {
    <#
    .SYNOPSIS
    Which marks a plan shows, in order: what happens to it first, then what it is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Plan)

    $marks = New-Object System.Collections.Generic.List[string]

    switch ($Plan.Action) {
        'Resize'            { $marks.Add('Resize') }
        'Reformat'          { $marks.Add('Reformat') }
        'ResizeAndReformat' { $marks.Add('Resize'); $marks.Add('Reformat') }
        'Review'            { $marks.Add('Review') }
        'Error'             { $marks.Add('Error') }
        default             { $marks.Add('Skip') }
    }

    $t = $Plan.Texture
    if ($t.Origin -eq 'BA2') { $marks.Add('Archive') }

    # A file is at most one of the two: IsTintMask is set only for the FaceDetails
    # and TintMasks folders, never for a match from the vanilla record list.
    if ($t.IsTintMask) { $marks.Add('TintMask') }
    elseif ($t.MatchedBy -eq 'vanilla texture set') { $marks.Add('FaceRecord') }

    return $marks.ToArray()
}

function Get-BffPlanTipLine {
    <#
    .SYNOPSIS
    The tooltip for one row: a mark and the sentence that mark is about, in order.

    .NOTES
    This is where the reason text lives. A column of it is unreadable - every row
    opens with the same words, cut off at the same width, so the part that differs
    is the part that is lost. Split across the marks it is one short line each, and
    the mark is its bullet.

    A mark with nothing specific to say about this row falls back to what the
    mark means in general.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Plan)

    $lines = New-Object System.Collections.Generic.List[object]

    foreach ($kind in (Get-BffPlanMark -Plan $Plan)) {
        $text = switch ($kind) {
            'Resize'   { $Plan.SizeReason }
            'Reformat' { $Plan.FormatReason }
            'Archive'  {
                if ($Plan.Texture.ArchivePath) {
                    'inside {0}, so the fix is written out as a loose file' -f
                        [IO.Path]::GetFileName($Plan.Texture.ArchivePath)
                }
                else { '' }
            }
            # Skip, Review and Error each stand for the whole row, so they carry
            # the whole reason.
            'Skip'     { $Plan.Reason }
            'Review'   { $Plan.Reason }
            'Error'    { $Plan.Reason }
            default    { '' }
        }

        if (-not $text) { $text = Get-BffMarkMeaning -Kind $kind }
        $lines.Add([pscustomobject]@{ Kind = $kind; Text = $text })
    }

    return $lines.ToArray()
}

function New-BffPlanGlyph {
    <#
    .SYNOPSIS
    The image for one plan: its marks packed side by side, left aligned.

    .NOTES
    Cached on the combination rather than per row. A scan draws thousands of
    rows and there are only a couple of dozen combinations between them.

    Every image is the full four slots wide even when fewer marks are drawn, so
    a mark means the same thing in the same place down the whole column.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Plan)

    $kinds = @(Get-BffPlanMark -Plan $Plan)
    $key   = $kinds -join '+'
    if ($script:BffMarkCache.ContainsKey($key)) { return $script:BffMarkCache[$key] }

    $n     = $script:BffMarkSlot
    $step  = $n + $script:BffMarkGap
    $width = ($step * $script:BffMarkMax) - $script:BffMarkGap

    $bmp = New-Object System.Drawing.Bitmap($width, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $x = 0
        foreach ($k in $kinds) {
            $mark = New-BffMark -Kind $k
            $g.DrawImage($mark, $x, 0)
            $mark.Dispose()
            $x += $step
        }
    }
    finally { $g.Dispose() }

    $script:BffMarkCache[$key] = $bmp
    return $bmp
}

function New-BffIcon {
    <#
    .SYNOPSIS
    The window icon, or $null if it could not be built.

    .NOTES
    Returns $null rather than throwing. An icon is decoration; failing to draw
    one must never be the reason the tool does not start.
    #>
    [CmdletBinding()]
    param()

    $frames = @()
    try {
        $frames = @(foreach ($s in $script:BffIconSizes) { New-BffIconFrame -Size $s })
        return (ConvertTo-BffIcon -Frame $frames)
    }
    catch {
        Write-BffLine ("The window icon could not be built, carrying on without one: {0}" -f $_.Exception.Message) 'Yellow'
        return $null
    }
    finally {
        foreach ($f in $frames) { if ($f) { $f.Dispose() } }
    }
}
