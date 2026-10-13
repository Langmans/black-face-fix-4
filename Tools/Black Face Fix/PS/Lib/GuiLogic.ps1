# GuiLogic.ps1 - everything the window decides, without the window.
#
# Which rows to show, what goes in each cell, which settings a set of ticks means,
# what the status line and the dialogs say, which archive textures get fixed.
# None of it touches a control. Gui.ps1 builds the controls and hands their state
# to these functions, and puts what comes back into the controls.
#
# Kept apart so it can be tested on its own, quickly and completely: a function
# here takes values and returns values, so a test needs no window, no message
# loop and no sandbox. System.Drawing is used for colours only.

Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------ the grid

function Get-BffGridColumn {
    <#
    .SYNOPSIS
    The grid's columns, in order. Get-BffGridRowValue fills them in this order.
    #>
    [CmdletBinding()]
    param()

    # Weights are relative widths for the fill-sized text columns.
    return @(
        [pscustomobject]@{ Name = 'Mod';      Header = 'Mod';       Weight = 16; Image = $false; Hidden = $false }
        # Between the mod and the file because that is the order the path itself
        # runs in: which mod, then where in it, then which file.
        [pscustomobject]@{ Name = 'Folder';   Header = 'Folder';    Weight = 20; Image = $false; Hidden = $false }
        [pscustomobject]@{ Name = 'File';     Header = 'File';      Weight = 18; Image = $false; Hidden = $false }
        [pscustomobject]@{ Name = 'Slot';     Header = 'Slot';      Weight = 8;  Image = $false; Hidden = $false }
        [pscustomobject]@{ Name = 'Now';      Header = 'Now';       Weight = 15; Image = $false; Hidden = $false }
        [pscustomobject]@{ Name = 'Target';   Header = 'Target';    Weight = 15; Image = $false; Hidden = $false }
        [pscustomobject]@{ Name = 'Action';   Header = 'Action';    Weight = 10; Image = $false; Hidden = $false }
        # Marks rather than a column of reason text. As a column the reasons are
        # unreadable: every row opens with the same words, the width cuts them off
        # at the same place, and the part that differs is the part that gets cut.
        # Hovering the row spells the reason out.
        [pscustomobject]@{ Name = 'Mark';     Header = '';          Weight = 3;  Image = $true;  Hidden = $false }
        # The absolute path, as its own column so asking for it adds information
        # instead of trading the readable folder away. Off until asked for - it is
        # wider than the rest of the row put together.
        #
        # There is no column for where the result lands: the output mod is the Mod
        # column plus the profile, so it would repeat two others. The row tooltip's
        # "to:" line has the real path.
        [pscustomobject]@{ Name = 'FullPath'; Header = 'Full path'; Weight = 40; Image = $false; Hidden = $true }
    )
}

function Get-BffRowFolder {
    <#
    .SYNOPSIS
    What the Folder column shows: where under the face textures this one sits.

    .NOTES
    Three things are the same on every row and none of them are worth the width:
    the install path, the mod folder - which has its own column - and
    'textures\actors\character\', which is the definition of what this tool scans.
    What is left is the part that differs: 'Character Assets\FaceDetails',
    'BaseHumanMale', 'FaceCustomization\Fallout4.esm'. The file name is dropped too,
    because the File column has it.

    BA2 entries keep the archive name in front: which archive a texture came out
    of is not visible anywhere else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffPlan] $Plan,
        [switch] $Full
    )

    if ($Full) {
        if ($Plan.Texture.Origin -eq 'BA2') {
            return ('{0} -> {1}' -f $Plan.Texture.ArchivePath, $Plan.Texture.FullName)
        }
        return $Plan.Texture.FullName
    }

    $rel = if ($Plan.Texture.RelativePath) { $Plan.Texture.RelativePath } else { $Plan.Texture.FullName }
    $dir = Split-Path -Parent $rel
    $dir = $dir -replace '(?i)^textures\\actors\\character\\?', ''
    if (-not $dir) { $dir = '\' }

    if ($Plan.Texture.Origin -eq 'BA2') {
        return ('{0} -> {1}' -f (Split-Path -Leaf $Plan.Texture.ArchivePath), $dir)
    }
    return $dir
}

function Get-BffGridRowValue {
    <#
    .SYNOPSIS
    One row's cell values, in Get-BffGridColumn order.

    .NOTES
    The Mark cell comes back $null. Its image has to be assigned to the cell after
    the row exists, not passed in with the rest: a value that travels through a
    PowerShell array arrives wrapped in a PSObject, and an image column cannot
    convert that to an Image - it throws at paint time, long after the row was
    added.

    Returned with the comma operator so the caller gets the array itself, $null
    and all, rather than its elements one by one down the pipeline.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffPlan] $Plan)

    return , @(
        $Plan.Texture.ModName
        (Get-BffRowFolder -Plan $Plan)
        $Plan.Texture.Name
        $Plan.Texture.Slot
        $Plan.Texture.Describe()
        $Plan.Describe()
        $Plan.Action
        $null
        (Get-BffRowFolder -Plan $Plan -Full)
    )
}

function Get-BffRowColor {
    <#
    .SYNOPSIS
    The text colour for a row, by what is going to happen to it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Action)

    switch ($Action) {
        'Skip'   { return [System.Drawing.Color]::Gray }
        'Review' { return [System.Drawing.Color]::FromArgb(160, 90, 0) }
        'Error'  { return [System.Drawing.Color]::Firebrick }
        default  { return [System.Drawing.Color]::FromArgb(0, 70, 140) }
    }
}

# --------------------------------------------------------- which mods, which rows

function Get-BffModSelection {
    <#
    .SYNOPSIS
    The mods ticked in the picker, as a set - or $null for "no filter".

    .NOTES
    An empty picker means a scan has not filled it yet, and then every mod counts.
    That is different from a filled picker with nothing ticked, which comes back as
    an empty set and so matches nothing.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Item,
        [string[]] $Checked
    )

    if (@($Item).Count -eq 0) { return $null }
    $set = @{}
    foreach ($m in @($Checked)) { if ($m) { $set[$m] = $true } }
    return $set
}

function Get-BffPendingModSelection {
    <#
    .SYNOPSIS
    The selection as it will be once one box in the picker has changed.

    .NOTES
    A CheckedListBox raises ItemCheck before it changes the box, so its checked
    items still show the old state. Working the new state out from the change -
    which box, and which way - lets the grid follow the click at once, instead of
    deferring the refresh until the list has caught up.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Item,
        [string[]] $Checked,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [bool] $NowChecked
    )

    $after = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Checked)) { if ($c) { $after.Add($c) } }

    $name = @($Item)[$Index]
    if ($NowChecked) { if (-not $after.Contains($name)) { $after.Add($name) } }
    else { [void] $after.Remove($name) }

    return Get-BffModSelection -Item $Item -Checked $after.ToArray()
}

function Get-BffModPickerItem {
    <#
    .SYNOPSIS
    The mods the picker lists: one per source mod that has work to do.

    .NOTES
    Mods where everything is already right are not listed. Unticking one of those
    would change nothing, so offering the tick would only be noise.
    #>
    [CmdletBinding()]
    param([object[]] $Plan)

    return @(@($Plan) | Where-Object { $_ -and $_.NeedsWork() } |
             ForEach-Object { $_.Texture.ModName } | Sort-Object -Unique)
}

function Select-BffGridPlan {
    <#
    .SYNOPSIS
    The plans that become rows.

    .NOTES
    Rows for an unticked mod are dropped only when they would claim work: a row
    that says "already correct" or "left alone" stays true whether or not its mod
    is ticked.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Plan,
        [bool] $OnlyChanges,
        [AllowNull()] [hashtable] $Selection
    )

    $rows = @(@($Plan) | Where-Object { $_ })
    if ($OnlyChanges) { $rows = @($rows | Where-Object { $_.Action -ne 'Skip' }) }
    if ($null -ne $Selection) {
        $rows = @($rows | Where-Object { -not $_.NeedsWork() -or $Selection.ContainsKey($_.Texture.ModName) })
    }
    return $rows
}

function Select-BffPlanToApply {
    <#
    .SYNOPSIS
    The plans Apply converts: those with work to do, in a ticked mod.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Plan,
        [AllowNull()] [hashtable] $Selection
    )

    $work = @(@($Plan) | Where-Object { $_ -and $_.NeedsWork() })
    if ($null -eq $Selection) { return $work }
    return @($work | Where-Object { $Selection.ContainsKey($_.Texture.ModName) })
}

# --------------------------------------------------------------- the settings

function Update-BffSettingsFromChoice {
    <#
    .SYNOPSIS
    Writes what the checkboxes say into the settings a scan reads.

    .PARAMETER Choice
    OnlyEnabledMods, IncludeArchives, FixArchives, IncludeFaceCustomization,
    ForceVanillaFormats and InPlace, each true or false. Missing ones count as false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [hashtable] $Choice
    )

    $Settings.Scope.OnlyEnabledMods          = [bool] $Choice['OnlyEnabledMods']
    $Settings.Scope.IncludeArchives          = [bool] $Choice['IncludeArchives']
    # Fixing what is inside an archive only means something once archives are read
    # at all, so the one switch cannot be on without the other.
    $Settings.Scope.FixArchives              = ([bool] $Choice['IncludeArchives'] -and [bool] $Choice['FixArchives'])
    $Settings.Scope.IncludeFaceCustomization = [bool] $Choice['IncludeFaceCustomization']
    $Settings.Conversion.ForceVanillaFormats = [bool] $Choice['ForceVanillaFormats']
    $Settings.Output.Mode                    = if ($Choice['InPlace']) { 'InPlace' } else { 'OutputMod' }
}

# ------------------------------------------------------------------ the words

function Get-BffProfileInfoText {
    <#
    .SYNOPSIS
    The line beside the profile picker: the three sizes and what the profile is for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffProfile] $Profile)

    return ('diffuse {0} | normal {1} | specular {2}   -   {3}' -f
            $Profile.SizeFor('Diffuse'), $Profile.SizeFor('Normal'), $Profile.SizeFor('Specular'),
            $Profile.Description)
}

function Get-BffProfileWarningText {
    <#
    .SYNOPSIS
    Why the chosen profile may not match the installed game, or '' when it does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffProfile] $Profile,
        [object] $F4ee
    )

    # @(): an empty List unwraps to $null, and Set-StrictMode then throws on .Count.
    $warnings = @(Test-BffProfileConsistency -Profile $Profile -F4ee $F4ee)
    if ($warnings.Count) { return ($warnings -join '  ') }
    return ''
}

function Get-BffScanStatusText {
    <#
    .SYNOPSIS
    The status line once a scan has finished.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Summary,
        [int] $ArchiveCount,
        [string] $CsvPath
    )

    $archives = if ($ArchiveCount) { "$ArchiveCount more sit inside BA2 archives (inspected only). " } else { '' }
    return ('{0} scanned, {1} already correct, {2} to change, {3} left alone. {4}Report: {5}' -f
            $Summary.Total, $Summary.Skipped, $Summary.Changing, $Summary.Review, $archives, $CsvPath)
}

function Get-BffOutputModList {
    <#
    .SYNOPSIS
    The output mod folders a set of plans writes to, each named once.
    #>
    [CmdletBinding()]
    param([object[]] $Plan)

    return @(@($Plan) | Where-Object { $_ } | ForEach-Object { Get-BffOutputModDisplayName -Plan $_ } |
             Where-Object { $_ } | Sort-Object -Unique)
}

function Get-BffApplyConfirmText {
    <#
    .SYNOPSIS
    The question Apply asks before writing anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Count,
        [Parameter(Mandatory)] [string] $Mode,
        [string[]] $OutputMod
    )

    $where = if ($Mode -eq 'InPlace') {
        'the original files (a .backup is kept next to each one)'
    }
    else {
        "{0} new mod folder(s):`n  {1}" -f @($OutputMod).Count, (@($OutputMod) -join "`n  ")
    }
    return ("Convert {0} texture(s)?`n`nResults go to:`n{1}" -f $Count, $where)
}

function Get-BffApplyResultText {
    <#
    .SYNOPSIS
    What Apply says when it is done: how many worked, which failed and why, and
    what to do next in Mod Organizer.

    .OUTPUTS
    An object with Text, and Failed - true when anything went wrong, which the
    window shows as a warning rather than as plain information.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Result,
        [Parameter(Mandatory)] [string] $Mode,
        [string[]] $OutputMod
    )

    $all = @(@($Result) | Where-Object { $_ })
    $ok  = @($all | Where-Object { $_.Success }).Count
    $bad = @($all | Where-Object { -not $_.Success })

    $text = "Converted $ok texture(s)."
    if ($bad.Count) {
        # Ten is enough to see the pattern; the log has every one.
        $text += "`n`n$($bad.Count) failed:`n" + (($bad | Select-Object -First 10 |
            ForEach-Object { '  ' + $_.Plan.Texture.Name + ': ' + $_.Error }) -join "`n")
    }
    if ($Mode -ne 'InPlace') {
        $text += ("`n`nIn Mod Organizer press F5, then enable each of these and drag it directly " +
                  "BELOW the mod it was made from:`n  ") + (@($OutputMod) -join "`n  ")
    }

    return [pscustomobject]@{ Text = $text; Failed = ($bad.Count -gt 0) }
}

function Get-BffRestoreTarget {
    <#
    .SYNOPSIS
    The folder Restore backups searches: the MO2 mods folder, or the game's Data
    folder when there is no Mod Organizer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Environment)

    if ($Environment.MO2) { return $Environment.MO2.ModsPath }
    return $Environment.DataPath
}

# ----------------------------------------------------------------- archives

function Get-BffArchivePlanSet {
    <#
    .SYNOPSIS
    Sorts the face textures found inside BA2 archives into those that get fixed
    and those that are only reported.

    .NOTES
    Archives are never repacked. A texture that may be fixed is extracted,
    converted and written to the output mod as a loose file - loose files win over
    archives in Fallout 4. Whether it may: Scope.FixArchives has to be on, and the
    game's own archives additionally need Scope.FixGameArchives.

    Textures that already match the profile are neither: there is nothing to say
    about them.

    .OUTPUTS
    Plans    - the plans to convert, destinations filled in.
    Findings - what needs work but is left alone, for the report.
    Entries  - the archive entry for each plan, keyed "<archive>::<path>", which
               the converter needs to extract it.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Archive,
        [Parameter(Mandatory)] [object] $Environment,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [object] $SlotRules,
        [switch] $Force
    )

    $plans    = New-Object System.Collections.Generic.List[BffPlan]
    $findings = New-Object System.Collections.Generic.List[object]
    $entries  = @{}

    foreach ($a in @($Archive)) {
        if (-not $a -or -not $a.Texture) { continue }

        $plan = New-BffPlan -Texture $a.Texture -Profile $Environment.Profile `
                            -SlotRules $SlotRules -Settings $Settings -Force:$Force
        if (-not $plan.NeedsWork()) { continue }

        $mayFix = $Settings.Scope.FixArchives -and
                  ($a.SourceKind -ne 'GameData' -or $Settings.Scope.FixGameArchives)

        if ($mayFix) {
            $plan.Destination = Get-BffDestination -Texture $a.Texture -Settings $Settings -Environment $Environment
            $plans.Add($plan)
            $entries[('{0}::{1}' -f $a.Texture.ArchivePath, $a.Texture.FullName)] = $a.Entry
        }
        else {
            $findings.Add($a)
        }
    }

    # ToArray(), not @(): wrapping a generic List in an array subexpression trips
    # PowerShell's enumerable binder with "Argument types do not match".
    return [pscustomobject]@{
        Plans    = $plans.ToArray()
        Findings = $findings.ToArray()
        Entries  = $entries
    }
}
