# Planner.ps1 - deciding what happens to each texture, and why.
#
# Every plan carries a Reason string that names the source size, the source format
# and the rule that fired, because "it got resized" without a why is useless when
# you are trying to work out which mod broke your face.
#
# Two rules the V3 script got wrong:
#   * a texture that already matches is SKIPPED. V3's filter was
#     'Height -ne 1024 -or Height -ne 1024 -or Height -ne 512 -or ...', which is
#     true for every possible value, so nothing was ever skipped and 867 of 1020
#     already-correct files were re-encoded anyway.
#   * the target format is derived from the SOURCE format, not from channel
#     averages. Guessing from averages is what turned every alpha-less BC1 texture
#     into BC6H_SF16, a floating point HDR format.

function New-BffPlan {
    <#
    .SYNOPSIS
    Builds one BffPlan for one texture.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffTexture] $Texture,
        [Parameter(Mandatory)] [BffProfile] $Profile,
        [Parameter(Mandatory)] [object]     $SlotRules,
        [Parameter(Mandatory)] [hashtable]  $Settings,
        [switch] $Force
    )

    $plan         = [BffPlan]::new()
    $plan.Texture = $Texture

    $rule = $null
    foreach ($r in $SlotRules.Rules) {
        if ($r.Slot -eq $Texture.Slot) { $rule = $r; break }
    }
    if (-not $rule) {
        $plan.Action = 'Error'
        $plan.Error  = "no slot rule for slot '$($Texture.Slot)'"
        $plan.Reason = $plan.Error
        return $plan
    }

    $target = $Profile.SizeFor($Texture.Slot)

    # --- safety rails ---------------------------------------------------------
    # Anything that trips these is almost certainly not a face texture: colour LUTs
    # and lookup strips are small and non-square (LMCC ships 64x128 hair palettes).
    # Forcing those to a square power of two destroys them, so they are reported
    # and left alone.
    if ($Texture.Width -le 0 -or $Texture.Height -le 0) {
        $plan.Action = 'Error'
        $plan.Error  = 'no dimensions could be read'
        $plan.Reason = $plan.Error
        return $plan
    }

    if ($Settings.Conversion.RequireSquare -and $Texture.Width -ne $Texture.Height) {
        $plan.TargetWidth  = $Texture.Width
        $plan.TargetHeight = $Texture.Height
        $plan.TargetFormat = $Texture.Format
        $plan.Action       = 'Review'
        # The concatenation needs its own parentheses: -f binds tighter than +, so
        # without them only the last fragment gets formatted and the rest keeps its
        # literal {0} placeholders.
        $plan.Reason       = (("{0}: {1} is not square, so it is left alone. Face textures are square; " +
                               "this is probably a lookup table or a palette strip.") -f
                              $Texture.Slot, $Texture.Describe())
        return $plan
    }

    if ($Texture.Width -lt $Settings.Conversion.MinSize) {
        $plan.TargetWidth  = $Texture.Width
        $plan.TargetHeight = $Texture.Height
        $plan.TargetFormat = $Texture.Format
        $plan.Action       = 'Review'
        $plan.Reason       = ("{0}: {1} is below the {2}px safety floor, so it is left alone." -f
                              $Texture.Slot, $Texture.Describe(), $Settings.Conversion.MinSize)
        return $plan
    }

    # --- size -----------------------------------------------------------------
    # Slots that opt out of size enforcement (skin/subsurface maps) keep whatever
    # they already are: they take no part in the head/tint matching, so resizing
    # them is pure quality loss.
    if (-not $rule.EnforceSize) {
        $plan.TargetWidth  = $Texture.Width
        $plan.TargetHeight = $Texture.Height
        $plan.SizeOk       = $true
    }
    else {
        $plan.TargetWidth  = $target
        $plan.TargetHeight = $target
        $plan.SizeOk       = ($Texture.Width -eq $target -and $Texture.Height -eq $target)
    }

    # --- format ---------------------------------------------------------------
    # Keep whatever the source already is when it is legal for this slot. Bethesda
    # ships BC7 face diffuses, the CK wiki asks for BC1 and mods use BC3 for alpha;
    # all three are fine, and re-encoding a valid texture only loses quality.
    $plan.FormatOk = $rule.AllowsFormat($Texture.Format)
    $plan.TargetFormat = if ($plan.FormatOk) { $Texture.Format } else { $rule.DefaultFormat }

    # --- action + reason ------------------------------------------------------
    $sizeReason   = $null
    $formatReason = $null

    if (-not $plan.SizeOk) {
        $verb = if ($Texture.Width -gt $target) { 'down to' } else { 'up to' }
        $sizeReason = ("profile '{0}' wants {1} at {2}x{2}, this is {3}x{4}, so it is scaled {5} {2}x{2}" -f
                       $Profile.Name, $Texture.Slot.ToLower(), $target, $Texture.Width, $Texture.Height, $verb)
    }

    if (-not $plan.FormatOk) {
        $allowed = ($rule.AllowedFormats -join ', ')
        $formatReason = ("{0} is not valid for a {1} map (allowed: {2}), so it is re-encoded as {3}" -f
                         $Texture.Format, $Texture.Slot.ToLower(), $allowed, $rule.DefaultFormat)
    }

    if ($plan.SizeOk -and $plan.FormatOk -and -not $Force) {
        $plan.Action = 'Skip'
        $plan.Reason = if (-not $rule.EnforceSize) {
            ("{0}: {1} left as is - {2} maps take no part in the head/tint matching" -f
             $Texture.Slot, $Texture.Describe(), $Texture.Slot.ToLower())
        }
        else {
            ("already correct: {0} matches profile '{1}'" -f $Texture.Describe(), $Profile.Name)
        }
    }
    elseif ($plan.SizeOk -and $plan.FormatOk -and $Force) {
        $plan.Action = 'Reformat'
        $plan.Reason = ("already correct ({0}), but -Force was given" -f $Texture.Describe())
    }
    elseif (-not $plan.SizeOk -and -not $plan.FormatOk) {
        $plan.Action = 'ResizeAndReformat'
        $plan.Reason = "$sizeReason; $formatReason"
    }
    elseif (-not $plan.SizeOk) {
        $plan.Action = 'Resize'
        $plan.Reason = "$sizeReason; format $($Texture.Format) is already valid and is kept"
    }
    else {
        $plan.Action = 'Reformat'
        $plan.Reason = "size $($Texture.Width)x$($Texture.Height) is already correct; $formatReason"
    }

    return $plan
}

function New-BffPlanSet {
    <#
    .SYNOPSIS
    Plans a whole list of textures and works out where each result must be written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]     $Texture,
        [Parameter(Mandatory)] [BffProfile] $Profile,
        [Parameter(Mandatory)] [object]     $SlotRules,
        [Parameter(Mandatory)] [hashtable]  $Settings,
        [Parameter(Mandatory)] [object]     $Environment,
        [switch] $Force
    )

    $plans = New-Object System.Collections.Generic.List[BffPlan]

    foreach ($t in @($Texture)) {
        $plan = New-BffPlan -Texture $t -Profile $Profile -SlotRules $SlotRules -Settings $Settings -Force:$Force
        $plan.Destination = Get-BffDestination -Texture $t -Settings $Settings -Environment $Environment
        $plans.Add($plan)
    }

    return $plans
}

function Get-BffOutputModName {
    <#
    .SYNOPSIS
    The MO2 mod folder that holds the fixed copies of one source mod's textures.

    .EXAMPLE
    'Extra Textures for V3 Alpha 1' + 'Vanilla'
      -> 'Extra Textures for V3 Alpha 1 - face textures resized for Vanilla'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]     $ModName,
        [Parameter(Mandatory)] [string]     $ProfileName,
        [Parameter(Mandatory)] [hashtable]  $Settings
    )

    # Discovery labels sources that are not mods; those placeholders are not legal
    # folder names, so they get a readable one.
    $source = switch ($ModName) {
        '(game data)' { $Settings.Output.GameDataModName }
        '(overwrite)' { $Settings.Output.OverwriteModName }
        default       { $ModName }
    }

    $name = $Settings.Output.OutputModNameFormat -f $source, $ProfileName

    # A profile name may contain characters Windows will not take in a folder.
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string] $c, '')
    }
    return $name.Trim()
}

function Get-BffOutputModPattern {
    <#
    .SYNOPSIS
    Regex that matches any folder this tool produces, so its own output is never
    picked up as a source on the next run.

    Derived from OutputModNameFormat rather than hard-coded, so it keeps working
    if the format is edited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Settings)

    $marker = $Settings.Output.OutputModNameFormat -f "`u{1}", "`u{2}"
    $parts  = $marker -split "[`u{1}`u{2}]"
    $middle = ($parts | Where-Object { $_ -ne '' } | Select-Object -First 1)

    if (-not $middle) { return $null }
    return [regex]::Escape($middle)
}

function Get-BffDestination {
    <#
    .SYNOPSIS
    Where the converted texture ends up.

    OutputMod mode writes into one MO2 mod per source mod, so no source mod is
    ever touched and MO2 keeps deciding conflicts exactly as it did before: put
    each output directly below the mod it came from. It is also the only way to
    fix a texture that lives inside a BA2, because loose files win over archives
    in Fallout 4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffTexture] $Texture,
        [Parameter(Mandatory)] [hashtable]  $Settings,
        [Parameter(Mandatory)] [object]     $Environment
    )

    if ($Settings.Output.Mode -eq 'InPlace' -and $Texture.Origin -ne 'BA2') {
        return $Texture.FullName
    }

    $outputMod = Get-BffOutputModName -ModName $Texture.ModName `
                                      -ProfileName $Environment.Profile.Name `
                                      -Settings $Settings

    $modsPath = if ($Environment.MO2) { $Environment.MO2.ModsPath } else { $null }
    if (-not $modsPath) {
        # No MO2: keep the same per-source layout next to the tool rather than
        # writing into the game's Data folder.
        $modsPath = Join-Path $Environment.Root 'Output'
    }

    return Join-Path (Join-Path $modsPath $outputMod) $Texture.RelativePath
}

function Update-BffPlanForExistingOutput {
    <#
    .SYNOPSIS
    Downgrades plans to Skip when the output mod already holds a correct copy.

    .NOTES
    In OutputMod mode the source mod is deliberately never modified, so on the next
    run the source still looks "wrong" and the same work gets planned again. Without
    this check a second run would re-encode everything it did the first time, which
    is exactly the pointless quality loss this tool exists to avoid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [string] $TexDiagPath = (Get-BffTexDiagPath)
    )

    $todo = @($Plan | Where-Object {
        $_.NeedsWork() -and $_.Destination -and
        $_.Destination -ne $_.Texture.FullName -and
        (Test-Path -LiteralPath $_.Destination)
    })
    if ($todo.Count -eq 0) { return $Plan }

    $info   = Get-BffTextureInfo -Path @($todo.Destination) -TexDiagPath $TexDiagPath
    $byPath = @{}
    foreach ($i in $info) { $byPath[(ConvertTo-BffPathKey $i.Path)] = $i }

    foreach ($p in $todo) {
        $existing = $byPath[(ConvertTo-BffPathKey $p.Destination)]
        if (-not $existing -or -not $existing.Ok) { continue }

        if ($existing.Width  -eq $p.TargetWidth -and
            $existing.Height -eq $p.TargetHeight -and
            $existing.Format -eq $p.TargetFormat) {

            $p.Action = 'Skip'
            $p.Reason = ("an earlier run already produced this: the output mod holds a {0}x{1} {2} copy" -f
                         $p.TargetWidth, $p.TargetHeight, $p.TargetFormat)
        }
    }

    return $Plan
}

function Get-BffPlanSummary {
    <#
    .SYNOPSIS
    Counts per action, per slot and per mod, for the console footer and the GUI.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Plan)

    $all = @($Plan)

    return [pscustomobject]@{
        Total      = $all.Count
        ByAction   = ($all | Group-Object Action | Sort-Object Count -Descending |
                        ForEach-Object { [pscustomobject]@{ Action = $_.Name; Count = $_.Count } })
        BySlot     = ($all | Where-Object { $_.NeedsWork() } | Group-Object { $_.Texture.Slot } |
                        Sort-Object Count -Descending |
                        ForEach-Object { [pscustomobject]@{ Slot = $_.Name; Count = $_.Count } })
        ByMod      = ($all | Where-Object { $_.NeedsWork() } | Group-Object { $_.Texture.ModName } |
                        Sort-Object Count -Descending |
                        ForEach-Object { [pscustomobject]@{ Mod = $_.Name; Count = $_.Count } })
        Changing   = @($all | Where-Object { $_.NeedsWork() }).Count
        Skipped    = @($all | Where-Object { $_.Action -eq 'Skip' }).Count
        Review     = @($all | Where-Object { $_.Action -eq 'Review' }).Count
        Failed     = @($all | Where-Object { $_.Action -eq 'Error' }).Count
    }
}
