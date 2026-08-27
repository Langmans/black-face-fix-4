# Convert.ps1 - running texconv and putting the result somewhere safe.
#
# Differences from V3, which did DDS -> TGA -> delete the original -> re-encode:
#   * texconv reads and writes DDS directly, so the lossy TGA round trip is gone.
#   * nothing is deleted before the replacement exists and has been verified with
#     texdiag. V3 removed the source between the two texconv calls, so a failure
#     there lost the texture outright.
#   * in OutputMod mode the source is not touched at all.

function New-BffWorkspace {
    <#
    .SYNOPSIS
    Creates the temp folder texconv writes into. Call Remove-BffWorkspace when done.
    #>
    [CmdletBinding()]
    param()

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("BlackFaceFix_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void] (New-Item -ItemType Directory -Path $path -Force)
    return $path
}

function Remove-BffWorkspace {
    [CmdletBinding()]
    param([string] $Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$script:BffTexConvCaps = $null

function Get-BffTexConvCapability {
    <#
    .SYNOPSIS
    Works out which flag spelling this texconv build understands, once per session.

    .NOTES
    The exhaustive BC7 compression switch was renamed between builds:
        2017 build : -bcmax
        2026 build : -bc x        ('options must be one or more of d, u, q, x')
    Passing the wrong one is a hard error ("Unknown option: `bcmax`"), so it is
    probed rather than assumed. The help switch moved too: the old build prints
    usage for any invalid argument, the new one wants --help.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TexConvPath)

    if ($script:BffTexConvCaps -and $script:BffTexConvCaps.Path -eq $TexConvPath) {
        return $script:BffTexConvCaps
    }

    $text = ''
    foreach ($probe in @('--help', '-h')) {
        try { $text = (& $TexConvPath $probe 2>&1 | Out-String) } catch { $text = '' }
        if ($text -match '-f <format>') { break }
    }

    $bcMax = $null
    if     ($text -match '-bcmax')       { $bcMax = @('-bcmax') }
    elseif ($text -match '-bc <options>'){ $bcMax = @('-bc', 'x') }

    $script:BffTexConvCaps = [pscustomobject]@{
        Path      = $TexConvPath
        BcMaxFlag = $bcMax
        SepAlpha  = ($text -match '-sepalpha')
        Probed    = ($text -match '-f <format>')
    }
    return $script:BffTexConvCaps
}

function Test-BffPlanResizes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffPlan] $Plan)
    return ($Plan.Texture.Width -ne $Plan.TargetWidth) -or ($Plan.Texture.Height -ne $Plan.TargetHeight)
}

function Get-BffResizePassFlags {
    <#
    .SYNOPSIS
    Pass 1 of a resize: down to a single uncompressed level at the target size.
    Everything but -o and the input files, so a batch can append many.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffPlan] $Plan, [object] $Flags)

    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]] @('-nologo', '-y'))
    $a.AddRange([string[]] @('-w', [string] $Plan.TargetWidth))
    $a.AddRange([string[]] @('-h', [string] $Plan.TargetHeight))
    $a.AddRange([string[]] @('-m', '1'))
    $a.AddRange([string[]] @('-f', 'R8G8B8A8_UNORM'))
    foreach ($f in @($Flags)) { if ($f -ne '-bcmax' -and $f -notmatch '^(x|-bc)$') { $a.Add($f) } }
    $a.AddRange([string[]] @('-ft', 'DDS'))
    return $a
}

function Get-BffEncodePassFlags {
    <#
    .SYNOPSIS
    The encoding pass: target format, mip chain rebuilt unless -KeepMips says the
    source chain is being carried over (a reformat that does not resize).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [BffPlan] $Plan, [object] $Flags, [switch] $KeepMips)

    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]] @('-nologo', '-y'))
    if (-not $KeepMips) { $a.AddRange([string[]] @('-m', '0')) }
    $a.AddRange([string[]] @('-f', $Plan.TargetFormat))
    $a.AddRange([string[]] @($Flags))
    $a.AddRange([string[]] @('-ft', 'DDS'))
    return $a
}

function Get-BffFormatFlags {
    <#
    .SYNOPSIS
    The format dependent texconv switches, shared by the single file and the
    batched path so the two cannot drift apart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffPlan]   $Plan,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [string]    $TexConvPath
    )

    $caps  = Get-BffTexConvCapability -TexConvPath $TexConvPath
    $flags = New-Object System.Collections.Generic.List[string]

    if ($Settings.Conversion.Filter) { $flags.AddRange([string[]] @('-if', $Settings.Conversion.Filter)) }
    if (($Plan.TargetFormat -match '^BC(2|3|7)_') -and $caps.SepAlpha) { $flags.Add('-sepalpha') }
    if ($Settings.Conversion.UseBcMax -and $Plan.TargetFormat -match '^BC7_' -and $caps.BcMaxFlag) {
        $flags.AddRange([string[]] $caps.BcMaxFlag)
    }
    return $flags
}

function Get-BffConversionPass {
    <#
    .SYNOPSIS
    Builds the texconv pass (or passes) needed for one plan.

    .NOTES
    The shipped texconv build cannot resize a DDS that already carries a mip chain:
    it aborts with "FAILED [mipmaps] (80070057)". Since practically every face
    texture ships with mips, a single-pass resize fails on all of them. Verified:

        -w 512 -h 512 -f BC5_UNORM          -> FAILED [mipmaps]
        -w 512 -h 512 -f BC5_UNORM -m 0     -> FAILED [mipmaps]
        -w 512 -h 512 -f BC5_UNORM -m 1     -> works, but no mips at all

    So a resize is split in two:
      pass 1  resize to a single uncompressed level (-m 1 -f R8G8B8A8_UNORM)
      pass 2  rebuild the mip chain and encode to the target format (-m 0)

    That also happens to give better quality than a single pass would: the source
    is decoded once and block-compressed once, instead of being recompressed on
    top of an already lossy decode. No sRGB flags are passed, so pixel values go
    through untouched and a BC1_UNORM_SRGB source comes back out as
    BC1_UNORM_SRGB with identical data.

    A reformat that does not change the size stays a single pass, which keeps the
    original mip chain rather than regenerating it.

    -bcmax is BC7 only ("Use exhaustive compression (BC7 only)" per texconv -h).
    -sepalpha resizes and mips the alpha channel separately from colour, which
    matters for tint masks where alpha carries the mask itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]    $SourcePath,
        [Parameter(Mandatory)] [BffPlan]   $Plan,
        [Parameter(Mandatory)] [string]    $Workspace,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [string] $TexConvPath = (Get-BffTexConvPath)
    )

    $flags     = @(Get-BffFormatFlags -Plan $Plan -Settings $Settings -TexConvPath $TexConvPath)
    $resizing  = Test-BffPlanResizes -Plan $Plan

    $passes = New-Object System.Collections.Generic.List[object]

    if ($resizing) {
        $stage = Join-Path $Workspace 'stage'

        # Not named $args: that is a PowerShell automatic variable.
        $one = New-Object System.Collections.Generic.List[string]
        $one.AddRange([string[]] (Get-BffResizePassFlags -Plan $Plan -Flags $flags))
        $one.AddRange([string[]] @('-o', $stage, $SourcePath))

        $passes.Add([pscustomobject]@{ Arguments = $one; OutputDirectory = $stage })

        $two = New-Object System.Collections.Generic.List[string]
        $two.AddRange([string[]] (Get-BffEncodePassFlags -Plan $Plan -Flags $flags))
        $two.AddRange([string[]] @('-o', (Join-Path $Workspace 'out')))
        # The input is filled in once pass 1 has produced it.

        $passes.Add([pscustomobject]@{ Arguments = $two; OutputDirectory = (Join-Path $Workspace 'out'); NeedsInput = $true })
    }
    else {
        $one = New-Object System.Collections.Generic.List[string]
        $one.AddRange([string[]] (Get-BffEncodePassFlags -Plan $Plan -Flags $flags -KeepMips))
        $one.AddRange([string[]] @('-o', (Join-Path $Workspace 'out'), $SourcePath))

        $passes.Add([pscustomobject]@{ Arguments = $one; OutputDirectory = (Join-Path $Workspace 'out') })
    }

    return $passes
}

function Save-BffConverted {
    <#
    .SYNOPSIS
    Puts one finished texture where the plan says it goes: backup first in place
    mode, marker file in output mod mode, then the copy. Shared by the single file
    and the batched paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffPlan]   $Plan,
        [Parameter(Mandatory)] [string]    $ProducedPath,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [string] $ProfileName = ''
    )

    $texture     = $Plan.Texture
    $destination = $Plan.Destination

    if ($Settings.Output.Mode -eq 'InPlace' -and $texture.Origin -ne 'BA2') {
        $backup = $texture.FullName + $Settings.Output.BackupSuffix
        # Only ever back up the pristine original: on a second run the existing
        # .backup is the real original and must not be overwritten.
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $texture.FullName -Destination $backup -Force
        }
    }

    $destDir = Split-Path -Parent $destination
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        [void] (New-Item -ItemType Directory -Path $destDir -Force)
    }

    if ($Settings.Output.Mode -ne 'InPlace') {
        $modRoot = Get-BffOutputModRoot -Plan $Plan
        if ($modRoot) {
            [void] (New-BffOutputMarker -ModRoot $modRoot -SourceMod $texture.ModName -ProfileName $ProfileName)
        }
    }

    Copy-Item -LiteralPath $ProducedPath -Destination $destination -Force
    Remove-Item -LiteralPath $ProducedPath -Force -ErrorAction SilentlyContinue
}

function Invoke-BffConvert {
    <#
    .SYNOPSIS
    Executes one plan: convert, verify, then place the result.

    .OUTPUTS
    [pscustomobject] Plan, Success, Destination, Error, Command
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [BffPlan]   $Plan,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [string]    $Workspace,
        [string] $TexConvPath = (Get-BffTexConvPath),
        [string] $TexDiagPath = (Get-BffTexDiagPath),
        [object] $ArchiveEntry,
        [string] $ProfileName = ''
    )

    $result = [pscustomobject]@{
        Plan = $Plan; Success = $false; Destination = $Plan.Destination; Error = ''; Command = ''
    }

    if (-not $Plan.NeedsWork()) {
        $result.Success = $true
        return $result
    }

    $texture   = $Plan.Texture
    $sourceDds = $null
    $extracted = $null

    try {
        # --- 1. get a real file on disk to feed texconv ------------------------
        if ($texture.Origin -eq 'BA2') {
            if (-not $ArchiveEntry) {
                $result.Error = 'no archive entry supplied for a BA2 texture'
                return $result
            }
            $extracted = Join-Path $Workspace ('extracted_' + [IO.Path]::GetFileName($texture.Name))
            $sourceDds = Expand-BffBa2Texture -Entry $ArchiveEntry -Destination $extracted
        }
        else {
            $sourceDds = $texture.FullName
            if (-not (Test-Path -LiteralPath $sourceDds)) {
                $result.Error = 'source file disappeared'
                return $result
            }
        }

        # --- 2. convert into the workspace -------------------------------------
        $outDir = Join-Path $Workspace 'out'
        $stage  = Join-Path $Workspace 'stage'
        foreach ($d in @($outDir, $stage)) {
            if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -File | Remove-Item -Force -ErrorAction SilentlyContinue }
            else { [void] (New-Item -ItemType Directory -Path $d -Force) }
        }

        $passes   = Get-BffConversionPass -SourcePath $sourceDds -Plan $Plan -Workspace $Workspace `
                                          -Settings $Settings -TexConvPath $TexConvPath
        $stem     = [IO.Path]::GetFileNameWithoutExtension($sourceDds)
        $produced = $null
        $commands = New-Object System.Collections.Generic.List[string]

        foreach ($pass in $passes) {
            $argList = New-Object System.Collections.Generic.List[string]
            $argList.AddRange([string[]] $pass.Arguments)

            # Pass 2 of a resize consumes whatever pass 1 wrote.
            if ($pass.PSObject.Properties['NeedsInput'] -and $pass.NeedsInput) {
                if (-not $produced) {
                    $result.Error = 'the resize pass produced no intermediate file'
                    return $result
                }
                $argList.Add($produced.FullName)
            }

            # The -f expression must be parenthesised: inside a method call the
            # comma would otherwise be read as another argument to .Add().
            $quoted = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
            $commands.Add(('"{0}" {1}' -f $TexConvPath, $quoted))

            $stdout = & $TexConvPath @argList 2>&1
            $exit   = $LASTEXITCODE

            # texconv names its output after the source stem; casing varies by version.
            $produced = Get-ChildItem -LiteralPath $pass.OutputDirectory -Filter "$stem.*" -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Extension -match '(?i)^\.dds$' } |
                            Select-Object -First 1

            if ($exit -ne 0 -or -not $produced) {
                $result.Command = $commands -join '  &&  '
                $result.Error = "texconv failed (exit $exit): " + (($stdout | Where-Object { $_ -match '\S' }) -join ' | ')
                return $result
            }
        }

        $result.Command = $commands -join '  &&  '

        # --- 3. verify before anything is overwritten ---------------------------
        $check = Get-BffTextureInfo -Path @($produced.FullName) -TexDiagPath $TexDiagPath | Select-Object -First 1

        if (-not $check.Ok) {
            $result.Error = 'texconv produced a file texdiag cannot read'
            return $result
        }
        if ($check.Width -ne $Plan.TargetWidth -or $check.Height -ne $Plan.TargetHeight) {
            $result.Error = ("expected {0}x{1} but texconv produced {2}x{3}" -f
                             $Plan.TargetWidth, $Plan.TargetHeight, $check.Width, $check.Height)
            return $result
        }
        if ($check.Format -ne $Plan.TargetFormat) {
            $result.Error = ("expected format {0} but texconv produced {1}" -f $Plan.TargetFormat, $check.Format)
            return $result
        }

        # --- 4. place it --------------------------------------------------------
        Save-BffConverted -Plan $Plan -ProducedPath $produced.FullName -Settings $Settings -ProfileName $ProfileName

        if ($extracted -and (Test-Path -LiteralPath $extracted)) {
            Remove-Item -LiteralPath $extracted -Force -ErrorAction SilentlyContinue
        }

        $result.Destination = $Plan.Destination
        $result.Success     = $true
        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Get-BffConversionBatch {
    <#
    .SYNOPSIS
    Groups plans that can share a single texconv invocation.

    .NOTES
    texconv takes many input files at once, and doing so is markedly faster than
    one process per file: measured at 294 ms for 8 separate calls against 90 ms
    for one call with 8 inputs. The per-process startup disappears and texconv
    threads the compression itself. Running several texconv processes in parallel
    instead tops out around 1.7x on 20 cores and gets worse past 4 lanes.

    Plans can share a call when the target size, the target format, and whether
    they resize all match. Two further limits split a group into batches:

      * texconv names its output after the input file stem, so two sources with
        the same file name in one call would overwrite each other in -o.
      * the command line has to stay under the Windows limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [int] $MaxCommandLine = 28000
    )

    # Note the plain pipe and the ToArray() calls below. Wrapping a generic List
    # in an array subexpression - @($list) - trips PowerShell's enumerable binder
    # with "Argument types do not match", so this function never does that.
    $batches = New-Object System.Collections.Generic.List[object]

    # Items are wrappers of { Plan; SourcePath }, not plans. Adding the source
    # path onto the plan with Add-Member would wrap the class instance in a
    # PSObject, and that no longer binds to a [BffPlan] typed parameter.
    $groups = $Plan | Group-Object {
        '{0}x{1}|{2}|{3}' -f $_.Plan.TargetWidth, $_.Plan.TargetHeight, $_.Plan.TargetFormat,
                             (Test-BffPlanResizes -Plan $_.Plan)
    }

    foreach ($g in $groups) {
        $current = New-Object System.Collections.Generic.List[object]
        $stems   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $length  = 0

        foreach ($p in $g.Group) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($p.SourcePath)
            $cost = $p.SourcePath.Length + 3

            if ($current.Count -gt 0 -and ($stems.Contains($stem) -or ($length + $cost) -gt $MaxCommandLine)) {
                $batches.Add([pscustomobject]@{ Key = $g.Name; Plans = $current.ToArray() })
                $current = New-Object System.Collections.Generic.List[object]
                $stems   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                $length  = 0
            }

            [void] $stems.Add($stem)
            $length += $cost
            $current.Add($p)
        }

        if ($current.Count -gt 0) { $batches.Add([pscustomobject]@{ Key = $g.Name; Plans = $current.ToArray() }) }
    }

    return $batches
}

function Invoke-BffConversionBatch {
    <#
    .SYNOPSIS
    Converts one batch in a single texconv call per pass, verifies every result in
    one texdiag pass, and places the ones that check out.

    .OUTPUTS
    One result object per plan. A plan whose output is missing or fails
    verification comes back with Retry = $true, so the caller can convert it on
    its own and attribute the error to the file that actually caused it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Batch,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [Parameter(Mandatory)] [string]    $Workspace,
        [Parameter(Mandatory)] [string]    $TexConvPath,
        [Parameter(Mandatory)] [string]    $TexDiagPath,
        [string] $ProfileName = ''
    )

    $items   = @($Batch.Plans)          # wrappers of { Plan; SourcePath }
    $first   = $items[0].Plan
    $flags   = @(Get-BffFormatFlags -Plan $first -Settings $Settings -TexConvPath $TexConvPath)
    $resizes = Test-BffPlanResizes -Plan $first

    $stage = Join-Path $Workspace 'stage'
    $out   = Join-Path $Workspace 'out'
    foreach ($d in @($stage, $out)) {
        if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -File | Remove-Item -Force -ErrorAction SilentlyContinue }
        else { [void] (New-Item -ItemType Directory -Path $d -Force) }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        $results.Add([pscustomobject]@{
            Plan = $it.Plan; SourcePath = $it.SourcePath; Success = $false
            Destination = $it.Plan.Destination; Error = ''; Command = ''; Retry = $false
        })
    }

    $commands = New-Object System.Collections.Generic.List[string]
    $inputs   = @($items | ForEach-Object { $_.SourcePath })

    if ($resizes) {
        $a1 = New-Object System.Collections.Generic.List[string]
        $a1.AddRange([string[]] (Get-BffResizePassFlags -Plan $first -Flags $flags))
        $a1.AddRange([string[]] @('-o', $stage))
        $a1.AddRange([string[]] $inputs)
        $commands.Add(($a1 -join ' '))
        $null = & $TexConvPath @a1 2>&1

        $inputs = @($items | ForEach-Object {
            $stem = [IO.Path]::GetFileNameWithoutExtension($_.SourcePath)
            Get-ChildItem -LiteralPath $stage -Filter "$stem.*" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '(?i)^\.dds$' } |
                Select-Object -First 1 -ExpandProperty FullName
        } | Where-Object { $_ })

        if ($inputs.Count -eq 0) {
            foreach ($r in $results) { $r.Error = 'the resize pass produced nothing'; $r.Retry = $true }
            return $results
        }
    }

    $a2 = New-Object System.Collections.Generic.List[string]
    $a2.AddRange([string[]] (Get-BffEncodePassFlags -Plan $first -Flags $flags -KeepMips:(-not $resizes)))
    $a2.AddRange([string[]] @('-o', $out))
    $a2.AddRange([string[]] $inputs)
    $commands.Add(($a2 -join ' '))
    $null = & $TexConvPath @a2 2>&1

    # --- verify the whole batch in one texdiag pass, then place what is good --
    $produced = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $out -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -match '(?i)^\.dds$' })) {
        $produced[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
    }

    $info = @{}
    if ($produced.Count -gt 0) {
        foreach ($rec in (Get-BffTextureInfo -Path @($produced.Values) -TexDiagPath $TexDiagPath)) {
            $info[(ConvertTo-BffPathKey $rec.Path)] = $rec
        }
    }

    foreach ($r in $results) {
        $r.Command = $commands -join '  &&  '
        $stem = [IO.Path]::GetFileNameWithoutExtension($r.SourcePath)
        $path = $produced[$stem]

        if (-not $path) { $r.Error = 'texconv produced no output for this file'; $r.Retry = $true; continue }

        $check = $info[(ConvertTo-BffPathKey $path)]
        if (-not $check -or -not $check.Ok) { $r.Error = 'output could not be read back'; $r.Retry = $true; continue }

        if ($check.Width  -ne $r.Plan.TargetWidth -or $check.Height -ne $r.Plan.TargetHeight -or
            $check.Format -ne $r.Plan.TargetFormat) {
            $r.Error = ('expected {0}x{1} {2}, got {3}x{4} {5}' -f
                        $r.Plan.TargetWidth, $r.Plan.TargetHeight, $r.Plan.TargetFormat,
                        $check.Width, $check.Height, $check.Format)
            $r.Retry = $true
            continue
        }

        try {
            Save-BffConverted -Plan $r.Plan -ProducedPath $path -Settings $Settings -ProfileName $ProfileName
            $r.Success = $true
        }
        catch { $r.Error = $_.Exception.Message }
    }

    return $results
}

function Invoke-BffPlanSet {
    <#
    .SYNOPSIS
    Runs a whole plan set. Returns one result object per plan that needed work.

    Plans sharing a target size and format go through texconv together, which is
    several times faster than one process per file. Anything a batch could not
    produce or verify is retried on its own so the error lands on the right file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Plan,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [string] $Root = (Get-BffRoot),
        [hashtable] $ArchiveEntryByPath,
        [string] $ProfileName = '',
        [scriptblock] $Progress
    )

    $todo = @($Plan | Where-Object { $_.NeedsWork() })
    if ($todo.Count -eq 0) { return @() }

    $texconv   = Get-BffTexConvPath -Root $Root -Settings $Settings
    $texdiag   = Get-BffTexDiagPath -Root $Root -Settings $Settings
    $workspace = New-BffWorkspace
    $results   = New-Object System.Collections.Generic.List[object]

    function New-Failure {
        param($P, [string] $Why)
        [pscustomobject]@{ Plan = $P; Success = $false; Destination = $P.Destination; Error = $Why; Command = '' }
    }

    try {
        # --- give every plan a real file on disk to feed texconv ------------
        $src = Join-Path $workspace 'src'
        [void] (New-Item -ItemType Directory -Path $src -Force)

        $ready = New-Object System.Collections.Generic.List[object]
        $n = 0

        foreach ($p in $todo) {
            if ($p.Texture.Origin -eq 'BA2') {
                $entry = $null
                if ($ArchiveEntryByPath) {
                    $entry = $ArchiveEntryByPath[('{0}::{1}' -f $p.Texture.ArchivePath, $p.Texture.FullName)]
                }
                if (-not $entry) { $results.Add((New-Failure $p 'no archive entry supplied for a BA2 texture')); continue }

                # Its own folder, so a name shared with another archive entry does
                # not collide before it even reaches texconv.
                $n++
                $dir = Join-Path $src $n
                [void] (New-Item -ItemType Directory -Path $dir -Force)
                $path = Join-Path $dir $p.Texture.Name
                try { [void] (Expand-BffBa2Texture -Entry $entry -Destination $path) }
                catch { $results.Add((New-Failure $p $_.Exception.Message)); continue }
            }
            else {
                $path = $p.Texture.FullName
                if (-not (Test-Path -LiteralPath $path)) { $results.Add((New-Failure $p 'source file disappeared')); continue }
            }

            $ready.Add([pscustomobject]@{ Plan = $p; SourcePath = $path })
        }

        # --- batched conversion ---------------------------------------------
        $done = 0
        foreach ($batch in (Get-BffConversionBatch -Plan $ready.ToArray())) {
            $batchResults = @(Invoke-BffConversionBatch -Batch $batch -Settings $Settings -Workspace $workspace `
                                                        -TexConvPath $texconv -TexDiagPath $texdiag `
                                                        -ProfileName $ProfileName)

            foreach ($r in $batchResults) {
                $done++
                if ($Progress) { & $Progress $done $ready.Count $r.Plan }

                if ($r.Success -or -not $r.Retry) { $results.Add($r); continue }

                # Convert this one on its own, so the failure is attributed to the
                # file that actually caused it rather than to the whole batch.
                $entry = $null
                if ($ArchiveEntryByPath) {
                    $entry = $ArchiveEntryByPath[('{0}::{1}' -f $r.Plan.Texture.ArchivePath, $r.Plan.Texture.FullName)]
                }
                $results.Add((Invoke-BffConvert -Plan $r.Plan -Settings $Settings -Workspace $workspace `
                                                -TexConvPath $texconv -TexDiagPath $texdiag `
                                                -ArchiveEntry $entry -ProfileName $ProfileName))
            }
        }
    }
    finally {
        Remove-BffWorkspace -Path $workspace
    }

    return $results
}

function Restore-BffBackup {
    <#
    .SYNOPSIS
    Puts every <name.ext>.backup left by an in-place run back over its original.

    .PARAMETER Path
    Folder to search. Usually the MO2 mods folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $BackupSuffix = '.backup',
        [switch] $KeepBackup
    )

    $restored = New-Object System.Collections.Generic.List[object]

    foreach ($backup in (Get-ChildItem -LiteralPath $Path -Recurse -Filter "*$BackupSuffix" -File -ErrorAction SilentlyContinue)) {
        $original = $backup.FullName.Substring(0, $backup.FullName.Length - $BackupSuffix.Length)

        if ($PSCmdlet.ShouldProcess($original, 'restore from backup')) {
            try {
                Copy-Item -LiteralPath $backup.FullName -Destination $original -Force
                if (-not $KeepBackup) { Remove-Item -LiteralPath $backup.FullName -Force }
                $restored.Add([pscustomobject]@{ Path = $original; Success = $true; Error = '' })
            }
            catch {
                $restored.Add([pscustomobject]@{ Path = $original; Success = $false; Error = $_.Exception.Message })
            }
        }
    }

    return $restored
}
