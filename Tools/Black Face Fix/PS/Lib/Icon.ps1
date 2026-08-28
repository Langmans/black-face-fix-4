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

# ---------------------------------------------------------------- row glyphs
#
# One small mark per action, shown next to the reason in the grid. The reason
# text is the authority; these only let you see the shape of a scan at a glance -
# which rows are being left alone, which are being rewritten, which want a human.
#
# Colours match the meaning rather than the severity: blue moves pixels, amber
# rewrites bytes, grey does nothing, orange wants a look, red failed.
$script:BffGlyphCache = @{}

function New-BffActionGlyph {
    <#
    .SYNOPSIS
    A 16x16 mark for one plan action. Cached, since a scan draws thousands of rows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Action)

    if ($script:BffGlyphCache.ContainsKey($Action)) { return $script:BffGlyphCache[$Action] }

    $grey   = [System.Drawing.Color]::FromArgb(255, 150, 158, 168)
    $blue   = [System.Drawing.Color]::FromArgb(255,  58, 132, 200)
    $amber  = [System.Drawing.Color]::FromArgb(255, 214, 146,  38)
    $orange = [System.Drawing.Color]::FromArgb(255, 214,  99,  20)
    $red    = [System.Drawing.Color]::FromArgb(255, 190,  54,  54)

    $size = 16
    $bmp  = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)

        switch ($Action) {
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
            default {
                # Resize, Reformat and both: the same nested squares as the window
                # icon. The outline says the size changes, the fill says the format
                # does, and a row doing both gets both.
                $resizes    = ($Action -eq 'Resize'   -or $Action -eq 'ResizeAndReformat')
                $reformats  = ($Action -eq 'Reformat' -or $Action -eq 'ResizeAndReformat')

                if ($resizes) {
                    $pen = New-Object System.Drawing.Pen($blue, 2)
                    $pen.Alignment = 'Inset'
                    $g.DrawRectangle($pen, 2, 2, 11, 11)
                    $pen.Dispose()
                }
                else {
                    # Format-only: keep the outline, but muted, so the eye reads
                    # the fill as the thing that changed.
                    $pen = New-Object System.Drawing.Pen($grey, 1)
                    $pen.Alignment = 'Inset'
                    $g.DrawRectangle($pen, 2, 2, 11, 11)
                    $pen.Dispose()
                }

                $fillColour = if ($reformats) { $amber } else { $blue }
                $b = New-Object System.Drawing.SolidBrush($fillColour)
                $g.FillRectangle($b, 6, 6, 4, 4)
                $b.Dispose()
            }
        }
    }
    finally { $g.Dispose() }

    $script:BffGlyphCache[$Action] = $bmp
    return $bmp
}

function Get-BffActionMeaning {
    <#
    .SYNOPSIS
    One line saying what a mark means, for the tooltip on the glyph.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Action)

    switch ($Action) {
        'Skip'              { 'already matches the profile, nothing is written' }
        'Resize'            { 'the size is wrong; the format is kept' }
        'Reformat'          { 'the size is right; the format is re-encoded' }
        'ResizeAndReformat' { 'both the size and the format are wrong' }
        'Review'            { 'left alone on purpose - look at this one yourself' }
        'Error'             { 'this one could not be read or planned' }
        default             { $Action }
    }
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
