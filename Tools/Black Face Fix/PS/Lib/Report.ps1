# Report.ps1 - console output, CSV and log file.
#
# The point of this file is the "why". Every plan knows its source size, its source
# format and the rule that fired, and all three end up in front of the user before
# anything is written.

$script:BffLogLines = New-Object System.Collections.Generic.List[string]

function Write-BffLine {
    <#
    .SYNOPSIS
    Writes to the console and remembers the line for the log file.
    #>
    [CmdletBinding()]
    param(
        [string] $Message = '',
        [string] $Color   = 'Gray',
        [switch] $NoConsole
    )

    $script:BffLogLines.Add($Message)
    if (-not $NoConsole) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Write-BffBanner {
    [CmdletBinding()]
    param([string] $Version = '4.0')

    Write-BffLine ''
    Write-BffLine '  ####################################################################' 'DarkCyan'
    Write-BffLine '  #                                                                  #' 'DarkCyan'
    Write-BffLine '  #     B L A C K   F A C E   F I X                                  #' 'DarkCyan'
    Write-BffLine ("  #     version {0,-53}#" -f $Version) 'DarkCyan'
    Write-BffLine '  #                                                                  #' 'DarkCyan'
    Write-BffLine '  #     Resizes Fallout 4 face textures to match your setup.         #' 'DarkCyan'
    Write-BffLine '  #     Nothing is written until you have seen what will change.     #' 'DarkCyan'
    Write-BffLine '  #                                                                  #' 'DarkCyan'
    Write-BffLine '  ####################################################################' 'DarkCyan'
    Write-BffLine ''
}

function Write-BffEnvironmentReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Environment)

    $e = $Environment

    Write-BffLine 'Setup' 'White'
    Write-BffLine ('  Fallout 4        : {0}' -f $e.Fallout4Path)

    if ($e.MO2) {
        Write-BffLine ('  Mod Organizer 2  : {0}' -f $e.MO2.Root)
        Write-BffLine ('  MO2 profile      : {0}' -f $e.MO2ProfileName)
        $on = @($e.ModList | Where-Object Enabled).Count
        Write-BffLine ('  Mods             : {0} enabled of {1}' -f $on, $e.ModList.Count)
    }
    else {
        Write-BffLine '  Mod Organizer 2  : not found, scanning the game Data folder only' 'Yellow'
    }

    Write-BffLine ('  HD Texture DLC   : {0}' -f $(if ($e.HasHdDlc) { 'yes' } else { 'no' }))

    if ($e.F4ee) {
        Write-BffLine ('  LooksMenu tints  : {0}x{1}  (from {2})' -f $e.F4ee.TintWidth, $e.F4ee.TintHeight, $e.F4ee.ModName)
    }
    else {
        Write-BffLine '  LooksMenu        : not installed'
    }

    Write-BffLine ''
    $how = if ($e.ProfileAutoDetected) { 'auto-detected' } else { 'set in Settings.psd1 or on the command line' }
    Write-BffLine ('Profile: {0}   ({1})' -f $e.Profile.Name, $how) 'Cyan'
    Write-BffLine ('  {0}' -f $e.Profile.Description)
    if ($e.ProfileAutoDetected) {
        Write-BffLine ('  because: {0}' -f ($e.DetectionReasons -join ', '))
    }
    Write-BffLine ('  targets: diffuse {0}, normal {1}, specular {2}' -f
                   $e.Profile.SizeFor('Diffuse'), $e.Profile.SizeFor('Normal'), $e.Profile.SizeFor('Specular')) 'Cyan'

    foreach ($w in $e.Warnings) {
        Write-BffLine ''
        Write-BffLine ('WARNING: {0}' -f $w) 'Yellow'
    }
    Write-BffLine ''
}

function Write-BffPlanTable {
    <#
    .SYNOPSIS
    Per-file table of everything that will change, followed by a grouped "why".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [int]    $MaxRows = 60,
        [switch] $All
    )

    $changing = @($Plan | Where-Object { $_.NeedsWork() })
    $review   = @($Plan | Where-Object { $_.Action -eq 'Review' })
    $failed   = @($Plan | Where-Object { $_.Action -eq 'Error' })

    if ($changing.Count -eq 0) {
        Write-BffLine 'Nothing needs changing - every face texture already matches the profile.' 'Green'
        Write-BffLine ''
    }
    else {
        Write-BffLine ('Textures that will change ({0})' -f $changing.Count) 'White'
        Write-BffLine ''
        Write-BffLine ('  {0,-28} {1,-30} {2,-9} {3,-22} {4,-22} {5}' -f
                       'MOD', 'FILE', 'SLOT', 'NOW', 'TARGET', 'ACTION')
        Write-BffLine ('  {0}' -f ('-' * 130))

        $show = if ($All) { $changing } else { $changing | Select-Object -First $MaxRows }

        foreach ($p in $show) {
            Write-BffLine ('  {0,-28} {1,-30} {2,-9} {3,-22} {4,-22} {5}' -f
                           (Format-BffTruncate $p.Texture.ModName 28),
                           (Format-BffTruncate $p.Texture.Name 30),
                           $p.Texture.Slot,
                           $p.Texture.Describe(),
                           $p.Describe(),
                           $p.Action) 'Cyan'
        }

        if (-not $All -and $changing.Count -gt $MaxRows) {
            Write-BffLine ('  ... and {0} more, see the CSV for the full list' -f ($changing.Count - $MaxRows)) 'DarkGray'
        }
        Write-BffLine ''

        # The reasons repeat heavily, so group them rather than printing 900 lines.
        Write-BffLine 'Why' 'White'
        foreach ($group in ($changing | Group-Object Reason | Sort-Object Count -Descending)) {
            Write-BffLine ('  {0,5} x  {1}' -f $group.Count, $group.Name) 'Gray'
        }
        Write-BffLine ''
    }

    if ($review.Count -gt 0) {
        Write-BffLine ('Left alone on purpose ({0})' -f $review.Count) 'Yellow'
        foreach ($group in ($review | Group-Object Reason | Sort-Object Count -Descending)) {
            Write-BffLine ('  {0,5} x  {1}' -f $group.Count, $group.Name) 'DarkYellow'
        }
        Write-BffLine ''
    }

    if ($failed.Count -gt 0) {
        Write-BffLine ('Could not be read ({0})' -f $failed.Count) 'Red'
        foreach ($p in ($failed | Select-Object -First 10)) {
            Write-BffLine ('  {0}: {1}' -f $p.Texture.Name, $p.Error) 'Red'
        }
        Write-BffLine ''
    }
}

function Format-BffTruncate {
    param([string] $Text, [int] $Length)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Length) { return $Text }
    return $Text.Substring(0, $Length - 1) + '~'
}

function Write-BffSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Summary,
        [object] $ArchiveFinding
    )

    Write-BffLine 'Summary' 'White'
    Write-BffLine ('  scanned            : {0}' -f $Summary.Total)
    Write-BffLine ('  already correct    : {0}' -f $Summary.Skipped) 'Green'
    Write-BffLine ('  will change        : {0}' -f $Summary.Changing) $(if ($Summary.Changing) { 'Cyan' } else { 'Gray' })
    if ($Summary.Review) { Write-BffLine ('  left alone         : {0}' -f $Summary.Review) 'Yellow' }
    if ($Summary.Failed) { Write-BffLine ('  unreadable         : {0}' -f $Summary.Failed) 'Red' }

    if ($Summary.BySlot) {
        Write-BffLine ''
        Write-BffLine '  changes per slot:'
        foreach ($s in $Summary.BySlot) { Write-BffLine ('    {0,-10} {1}' -f $s.Slot, $s.Count) }
    }

    if ($Summary.ByMod) {
        Write-BffLine ''
        Write-BffLine '  changes per mod:'
        foreach ($m in ($Summary.ByMod | Select-Object -First 15)) {
            Write-BffLine ('    {0,-45} {1}' -f (Format-BffTruncate $m.Mod 45), $m.Count)
        }
    }

    if ($ArchiveFinding -and @($ArchiveFinding).Count -gt 0) {
        Write-BffLine ''
        Write-BffLine ('Face textures found inside BA2 archives ({0})' -f @($ArchiveFinding).Count) 'Yellow'
        Write-BffLine '  These are not loose files, so they were only inspected, not changed.' 'DarkYellow'
        foreach ($g in ($ArchiveFinding | Group-Object { $_.Texture.ModName } | Sort-Object Count -Descending | Select-Object -First 10)) {
            Write-BffLine ('    {0,-45} {1}' -f (Format-BffTruncate $g.Name 45), $g.Count) 'DarkYellow'
        }
    }

    Write-BffLine ''
}

function Export-BffPlanCsv {
    <#
    .SYNOPSIS
    One row per texture with everything needed to audit the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }

    @($Plan) | ForEach-Object {
        [pscustomobject]@{
            Mod            = $_.Texture.ModName
            File           = $_.Texture.Name
            Slot           = $_.Texture.Slot
            Origin         = $_.Texture.Origin
            SourceWidth    = $_.Texture.Width
            SourceHeight   = $_.Texture.Height
            SourceFormat   = $_.Texture.Format
            SourceMips     = $_.Texture.MipLevels
            TargetWidth    = $_.TargetWidth
            TargetHeight   = $_.TargetHeight
            TargetFormat   = $_.TargetFormat
            SizeOk         = $_.SizeOk
            FormatOk       = $_.FormatOk
            Action         = $_.Action
            Reason         = $_.Reason
            FullName       = $_.Texture.FullName
            ArchivePath    = $_.Texture.ArchivePath
            Destination    = $_.Destination
            Error          = $_.Error
        }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8

    return $Path
}

function Save-BffLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }

    [System.IO.File]::WriteAllLines($Path, $script:BffLogLines, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Clear-BffLog {
    $script:BffLogLines.Clear()
}
