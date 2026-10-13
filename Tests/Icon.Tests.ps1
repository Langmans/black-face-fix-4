# Unit tests for Icon.ps1 - the window icon and the marks in the grid.
#
#   Invoke-Pester -Path .\Tests\Icon.Tests.ps1 `
#                 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\Icon.ps1'
#
# Pester 5. The drawing is checked by looking at pixels and at the bytes of the
# icon file the code assembles by hand, so a wrong header shows up here rather
# than as a blank icon in the title bar.

BeforeAll {
    $tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'
    foreach ($f in 'Types', 'Config', 'Report', 'Icon') {
        . (Join-Path $tool "PS\Lib\$f.ps1")
    }

    function New-TestPlan {
        param(
            [string] $Action    = 'Skip',
            [string] $Origin    = 'Loose',
            [string] $Archive   = '',
            [bool]   $Tint      = $false,
            [string] $MatchedBy = 'head name'
        )
        $t = New-Object BffTexture
        $t.Name = 'MaleHead_d.dds'; $t.Origin = $Origin; $t.ArchivePath = $Archive
        $t.IsTintMask = $Tint; $t.MatchedBy = $MatchedBy
        $p = New-Object BffPlan
        $p.Texture = $t; $p.Action = $Action
        $p.Reason = 'the whole reason'; $p.SizeReason = 'the size part'; $p.FormatReason = 'the format part'
        return $p
    }

    # True when any pixel of the bitmap is not fully transparent.
    function Test-Drawn {
        param($Bitmap)
        for ($y = 0; $y -lt $Bitmap.Height; $y++) {
            for ($x = 0; $x -lt $Bitmap.Width; $x++) {
                if ($Bitmap.GetPixel($x, $y).A -gt 0) { return $true }
            }
        }
        return $false
    }

    $script:kinds = @('Resize', 'Reformat', 'Skip', 'Review', 'Error', 'Archive', 'TintMask', 'FaceRecord')
}

Describe 'Get-BffMarkMeaning' {
    It 'says what <Kind> means in words, not by repeating its name' -TestCases @(
        @{ Kind = 'Resize' }, @{ Kind = 'Reformat' }, @{ Kind = 'Skip' }, @{ Kind = 'Review' }
        @{ Kind = 'Error' }, @{ Kind = 'Archive' }, @{ Kind = 'TintMask' }, @{ Kind = 'FaceRecord' }
    ) {
        $m = Get-BffMarkMeaning -Kind $Kind
        $m | Should -Not -BeNullOrEmpty
        $m | Should -Not -Be $Kind
    }

    It 'falls back to the name for a kind it does not know' {
        Get-BffMarkMeaning -Kind 'Mystery' | Should -Be 'Mystery'
    }
}

Describe 'New-BffMark' {
    It 'draws <Kind> as a 16px mark' -TestCases @(
        @{ Kind = 'Resize' }, @{ Kind = 'Reformat' }, @{ Kind = 'Skip' }, @{ Kind = 'Review' }
        @{ Kind = 'Error' }, @{ Kind = 'Archive' }, @{ Kind = 'TintMask' }, @{ Kind = 'FaceRecord' }
    ) {
        $b = New-BffMark -Kind $Kind
        try {
            $b.Width  | Should -Be 16
            $b.Height | Should -Be 16
            Test-Drawn $b | Should -BeTrue
        }
        finally { $b.Dispose() }
    }

    It 'draws nothing for a kind it does not know' {
        $b = New-BffMark -Kind 'Mystery'
        try { Test-Drawn $b | Should -BeFalse } finally { $b.Dispose() }
    }

    It 'tells resize and reformat apart by shape, not only by colour' {
        # Same pixel, inside the outline in both: the nested square leaves a gap
        # there, the split square fills it.
        $r = New-BffMark -Kind 'Resize'; $f = New-BffMark -Kind 'Reformat'
        try {
            $r.GetPixel(4, 4).A | Should -Be 0
            $f.GetPixel(4, 4).A | Should -BeGreaterThan 0
        }
        finally { $r.Dispose(); $f.Dispose() }
    }
}

Describe 'Get-BffPlanMark' {
    It 'shows <Want> for a <Action> row' -TestCases @(
        @{ Action = 'Resize';            Want = 'Resize' }
        @{ Action = 'Reformat';          Want = 'Reformat' }
        @{ Action = 'ResizeAndReformat'; Want = 'Resize,Reformat' }
        @{ Action = 'Review';            Want = 'Review' }
        @{ Action = 'Error';             Want = 'Error' }
        @{ Action = 'Skip';              Want = 'Skip' }
        @{ Action = 'SomethingNew';      Want = 'Skip' }
    ) {
        (Get-BffPlanMark -Plan (New-TestPlan -Action $Action)) -join ',' | Should -Be $Want
    }

    It 'adds the archive mark after the action for a BA2 entry' {
        (Get-BffPlanMark -Plan (New-TestPlan -Action 'Resize' -Origin 'BA2')) -join ',' | Should -Be 'Resize,Archive'
    }

    It 'adds the tint mask mark for a mask' {
        (Get-BffPlanMark -Plan (New-TestPlan -Tint $true)) -join ',' | Should -Be 'Skip,TintMask'
    }

    It 'adds the record mark for a texture matched from the game''s records' {
        (Get-BffPlanMark -Plan (New-TestPlan -MatchedBy 'vanilla texture set')) -join ',' | Should -Be 'Skip,FaceRecord'
    }

    It 'shows one or the other of tint mask and record, never both' {
        $p = New-TestPlan -Tint $true -MatchedBy 'vanilla texture set'
        (Get-BffPlanMark -Plan $p) -join ',' | Should -Be 'Skip,TintMask'
    }

    It 'never needs more than four slots' {
        $busiest = New-TestPlan -Action 'ResizeAndReformat' -Origin 'BA2' -Tint $true
        @(Get-BffPlanMark -Plan $busiest).Count | Should -BeLessOrEqual $script:BffMarkMax
    }
}

Describe 'Get-BffPlanTipLine' {
    It 'puts each half of the reason beside its own mark' {
        $lines = @(Get-BffPlanTipLine -Plan (New-TestPlan -Action 'ResizeAndReformat'))
        ($lines | Where-Object Kind -eq 'Resize').Text   | Should -Be 'the size part'
        ($lines | Where-Object Kind -eq 'Reformat').Text | Should -Be 'the format part'
    }

    It 'gives a <Action> row the whole reason' -TestCases @(
        @{ Action = 'Skip' }, @{ Action = 'Review' }, @{ Action = 'Error' }
    ) {
        @(Get-BffPlanTipLine -Plan (New-TestPlan -Action $Action))[0].Text | Should -Be 'the whole reason'
    }

    It 'names the archive a BA2 entry comes from' {
        $p = New-TestPlan -Origin 'BA2' -Archive 'C:\x\Mod - Textures.ba2'
        (@(Get-BffPlanTipLine -Plan $p) | Where-Object Kind -eq 'Archive').Text |
            Should -Be 'inside Mod - Textures.ba2, so the fix is written out as a loose file'
    }

    It 'falls back to what the archive mark means when the archive is not known' {
        $p = New-TestPlan -Origin 'BA2'
        (@(Get-BffPlanTipLine -Plan $p) | Where-Object Kind -eq 'Archive').Text | Should -Be (Get-BffMarkMeaning -Kind 'Archive')
    }

    It 'explains the context marks in general terms' {
        $p = New-TestPlan -Tint $true
        (@(Get-BffPlanTipLine -Plan $p) | Where-Object Kind -eq 'TintMask').Text | Should -Be (Get-BffMarkMeaning -Kind 'TintMask')
        $p = New-TestPlan -MatchedBy 'vanilla texture set'
        (@(Get-BffPlanTipLine -Plan $p) | Where-Object Kind -eq 'FaceRecord').Text | Should -Be (Get-BffMarkMeaning -Kind 'FaceRecord')
    }

    It 'falls back to the general meaning when a reason is missing' {
        $p = New-TestPlan -Action 'Resize'
        $p.SizeReason = ''
        @(Get-BffPlanTipLine -Plan $p)[0].Text | Should -Be (Get-BffMarkMeaning -Kind 'Resize')
    }
}

Describe 'New-BffPlanGlyph' {
    It 'is four slots wide whatever it shows, so marks line up down the column' {
        $one  = New-BffPlanGlyph -Plan (New-TestPlan -Action 'Skip')
        $many = New-BffPlanGlyph -Plan (New-TestPlan -Action 'ResizeAndReformat' -Origin 'BA2' -Tint $true)
        $one.Width  | Should -Be (4 * ($script:BffMarkSlot + $script:BffMarkGap) - $script:BffMarkGap)
        $many.Width | Should -Be $one.Width
        $one.Height | Should -Be $script:BffMarkSlot
    }

    It 'draws each mark in its own slot' {
        $g = New-BffPlanGlyph -Plan (New-TestPlan -Action 'ResizeAndReformat')
        $slot2 = $script:BffMarkSlot + $script:BffMarkGap
        # Something in the first two slots, nothing in the last.
        $g.GetPixel(2, 2).A          | Should -BeGreaterThan 0
        $g.GetPixel($slot2 + 2, 2).A | Should -BeGreaterThan 0
        $g.GetPixel($g.Width - 3, 8).A | Should -Be 0
    }

    It 'draws each combination once and hands back the same image after' {
        $a = New-BffPlanGlyph -Plan (New-TestPlan -Action 'Review')
        $b = New-BffPlanGlyph -Plan (New-TestPlan -Action 'Review')
        $c = New-BffPlanGlyph -Plan (New-TestPlan -Action 'Error')
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
        [object]::ReferenceEquals($a, $c) | Should -BeFalse
    }
}

Describe 'New-BffIconFrame' {
    It 'draws a <Size>px frame' -TestCases @(@{ Size = 16 }, @{ Size = 32 }, @{ Size = 64 }) {
        $b = New-BffIconFrame -Size $Size
        try {
            $b.Width  | Should -Be $Size
            $b.Height | Should -Be $Size
            # Rounded: the very corner stays see-through, the middle is drawn.
            $b.GetPixel(0, 0).A | Should -Be 0
            $b.GetPixel([int]($Size / 2), [int]($Size / 2)).A | Should -Be 255
        }
        finally { $b.Dispose() }
    }
}

Describe 'ConvertTo-BffIcon' {
    It 'writes a valid .ico with one entry per frame, at their sizes' {
        $frames = @(16, 32, 48 | ForEach-Object { New-BffIconFrame -Size $_ })
        try {
            $icon = ConvertTo-BffIcon -Frame $frames
            $ms = New-Object System.IO.MemoryStream
            $icon.Save($ms)
            $bytes = $ms.ToArray()

            # ICONDIR: reserved 0, type 1 (icon), then the frame count.
            [BitConverter]::ToUInt16($bytes, 0) | Should -Be 0
            [BitConverter]::ToUInt16($bytes, 2) | Should -Be 1
            [BitConverter]::ToUInt16($bytes, 4) | Should -Be 3

            # Each 16-byte directory entry starts with width and height.
            @(0, 1, 2 | ForEach-Object { $bytes[6 + 16 * $_] }) | Should -Be @(16, 32, 48)
        }
        finally { foreach ($f in $frames) { $f.Dispose() } }
    }

    It 'gives Windows the sizes it asks for' {
        $frames = @(16, 32 | ForEach-Object { New-BffIconFrame -Size $_ })
        try {
            $icon = ConvertTo-BffIcon -Frame $frames
            (New-Object System.Drawing.Icon($icon, 16, 16)).Width | Should -Be 16
            (New-Object System.Drawing.Icon($icon, 32, 32)).Width | Should -Be 32
        }
        finally { foreach ($f in $frames) { $f.Dispose() } }
    }
}

Describe 'New-BffIcon' {
    It 'builds the window icon' {
        New-BffIcon | Should -BeOfType [System.Drawing.Icon]
    }

    It 'carries on without an icon, and says so, when drawing fails' {
        Mock New-BffIconFrame { throw 'no GDI today' }
        Mock Write-BffLine { }

        New-BffIcon | Should -BeNullOrEmpty
        Should -Invoke Write-BffLine -Times 1 -Exactly -ParameterFilter { $Message -match 'no GDI today' }
    }
}
