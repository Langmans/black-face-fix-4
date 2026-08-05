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

    $caps      = Get-BffTexConvCapability -TexConvPath $TexConvPath
    $hasAlpha  = ($Plan.TargetFormat -match '^BC(2|3|7)_') -and $caps.SepAlpha
    $useBcMax  = $Settings.Conversion.UseBcMax -and $Plan.TargetFormat -match '^BC7_' -and $caps.BcMaxFlag
    $resizing  = ($Plan.Texture.Width  -ne $Plan.TargetWidth) -or
                 ($Plan.Texture.Height -ne $Plan.TargetHeight)

    $passes = New-Object System.Collections.Generic.List[object]

    if ($resizing) {
        $stage = Join-Path $Workspace 'stage'

        # Not named $args: that is a PowerShell automatic variable.
        $one = New-Object System.Collections.Generic.List[string]
        $one.AddRange([string[]] @('-nologo', '-y'))
        $one.AddRange([string[]] @('-w', [string] $Plan.TargetWidth))
        $one.AddRange([string[]] @('-h', [string] $Plan.TargetHeight))
        $one.AddRange([string[]] @('-m', '1'))
        $one.AddRange([string[]] @('-f', 'R8G8B8A8_UNORM'))
        if ($Settings.Conversion.Filter) { $one.AddRange([string[]] @('-if', $Settings.Conversion.Filter)) }
        if ($hasAlpha) { $one.Add('-sepalpha') }
        $one.AddRange([string[]] @('-ft', 'DDS', '-o', $stage, $SourcePath))

        $passes.Add([pscustomobject]@{ Arguments = $one; OutputDirectory = $stage })

        $two = New-Object System.Collections.Generic.List[string]
        $two.AddRange([string[]] @('-nologo', '-y'))
        $two.AddRange([string[]] @('-m', '0'))
        $two.AddRange([string[]] @('-f', $Plan.TargetFormat))
        if ($Settings.Conversion.Filter) { $two.AddRange([string[]] @('-if', $Settings.Conversion.Filter)) }
        if ($hasAlpha) { $two.Add('-sepalpha') }
        if ($useBcMax) { $two.AddRange([string[]] $caps.BcMaxFlag) }
        $two.AddRange([string[]] @('-ft', 'DDS', '-o', (Join-Path $Workspace 'out')))
        # The input is filled in once pass 1 has produced it.

        $passes.Add([pscustomobject]@{ Arguments = $two; OutputDirectory = (Join-Path $Workspace 'out'); NeedsInput = $true })
    }
    else {
        $one = New-Object System.Collections.Generic.List[string]
        $one.AddRange([string[]] @('-nologo', '-y'))
        $one.AddRange([string[]] @('-f', $Plan.TargetFormat))
        if ($Settings.Conversion.Filter) { $one.AddRange([string[]] @('-if', $Settings.Conversion.Filter)) }
        if ($hasAlpha) { $one.Add('-sepalpha') }
        if ($useBcMax) { $one.AddRange([string[]] $caps.BcMaxFlag) }
        $one.AddRange([string[]] @('-ft', 'DDS', '-o', (Join-Path $Workspace 'out'), $SourcePath))

        $passes.Add([pscustomobject]@{ Arguments = $one; OutputDirectory = (Join-Path $Workspace 'out') })
    }

    return $passes
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
        [object] $ArchiveEntry
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

        Copy-Item -LiteralPath $produced.FullName -Destination $destination -Force

        Remove-Item -LiteralPath $produced.FullName -Force -ErrorAction SilentlyContinue
        if ($extracted -and (Test-Path -LiteralPath $extracted)) {
            Remove-Item -LiteralPath $extracted -Force -ErrorAction SilentlyContinue
        }

        $result.Destination = $destination
        $result.Success     = $true
        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Invoke-BffPlanSet {
    <#
    .SYNOPSIS
    Runs a whole plan set. Returns one result object per plan that needed work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]    $Plan,
        [Parameter(Mandatory)] [hashtable] $Settings,
        [string] $Root = (Get-BffRoot),
        [hashtable] $ArchiveEntryByPath,
        [scriptblock] $Progress
    )

    $todo = @($Plan | Where-Object { $_.NeedsWork() })
    if ($todo.Count -eq 0) { return @() }

    $texconv   = Get-BffTexConvPath -Root $Root -Settings $Settings
    $texdiag   = Get-BffTexDiagPath -Root $Root -Settings $Settings
    $workspace = New-BffWorkspace
    $results   = New-Object System.Collections.Generic.List[object]

    try {
        $i = 0
        foreach ($p in $todo) {
            $i++
            if ($Progress) { & $Progress $i $todo.Count $p }

            $entry = $null
            if ($ArchiveEntryByPath) {
                $mapKey = '{0}::{1}' -f $p.Texture.ArchivePath, $p.Texture.FullName
                $entry  = $ArchiveEntryByPath[$mapKey]
            }

            $results.Add((Invoke-BffConvert -Plan $p -Settings $Settings -Workspace $workspace `
                                            -TexConvPath $texconv -TexDiagPath $texdiag -ArchiveEntry $entry))
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
