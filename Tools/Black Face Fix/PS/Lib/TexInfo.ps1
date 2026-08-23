# TexInfo.ps1 - reading texture metadata with texdiag.exe.
#
# Two things the V3 script got wrong are fixed here:
#   * properties are read by NAME, not by line index. Line indexes break the moment
#     texdiag emits an extra line (cube maps, volume textures, newer builds).
#   * texdiag is called with many files at once instead of one process per file.
#     Process startup dominated the old runtime: ~1000 files meant ~1000 spawns.
#
# The channel-average pass (texdiag analyze) is gone entirely. The source DXGI
# format already says whether there is alpha, and guessing from averages is what
# turned every BC1 texture into BC6H_SF16.

$script:BffToolPathCache = @{}

function Resolve-BffTexTool {
    <#
    .SYNOPSIS
    Finds texconv.exe / texdiag.exe.

    .DESCRIPTION
    Looked for in this order, so a shipped copy stays predictable for people who
    just unpack the mod, while anyone who keeps their own build up to date can use
    that instead:

      1. Paths.TexTools in Settings.psd1, if set
      2. the bundled MSFT folder                (skipped when PreferSystemTools)
      3. anything on PATH
      4. winget's package folder, since
         'winget install Microsoft.DirectXTex.Texconv' drops the exe in
         %LOCALAPPDATA%\Microsoft\WinGet\Packages\Microsoft.DirectXTex.Texconv_*\
         and only adds it to PATH for shells started afterwards

    With PreferSystemTools = $true the order becomes 1, 3, 4, 2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('texconv', 'texdiag', 'texassemble')] [string] $Name,
        [string]    $Root = (Get-BffRoot),
        [hashtable] $Settings
    )

    $exe      = "$Name.exe"
    $cacheKey = '{0}|{1}' -f $Name, $Root
    if ($script:BffToolPathCache.ContainsKey($cacheKey)) { return $script:BffToolPathCache[$cacheKey] }

    $preferSystem = $false
    $explicit     = ''
    if ($Settings) {
        if ($Settings.Conversion.ContainsKey('PreferSystemTools')) { $preferSystem = [bool] $Settings.Conversion.PreferSystemTools }
        if ($Settings.Paths.ContainsKey('TexTools'))               { $explicit     = [string] $Settings.Paths.TexTools }
    }

    $bundled = { Join-Path $Root "MSFT\$exe" }

    $onPath = {
        # -ErrorAction Ignore rather than SilentlyContinue: SilentlyContinue still
        # appends to $Error, which is noise when the tool simply is not on PATH.
        $cmd = Get-Command $exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if ($cmd) { $cmd.Source } else { $null }
    }

    $fromWinget = {
        $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (-not (Test-Path -LiteralPath $packages)) { return $null }
        Get-ChildItem -LiteralPath $packages -Directory -Filter "Microsoft.DirectXTex.$Name*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName $exe } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
    }

    $order = if ($preferSystem) { @($onPath, $fromWinget, $bundled) } else { @($bundled, $onPath, $fromWinget) }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($explicit) { $candidates.Add((Join-Path $explicit $exe)) }
    foreach ($probe in $order) {
        $found = & $probe
        if ($found) { $candidates.Add($found) }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $script:BffToolPathCache[$cacheKey] = $c
            return $c
        }
    }

    throw ("$exe not found. Looked in the MSFT folder next to the tool, on PATH, and in " +
           "winget's package folder. Either put $exe in '$(Join-Path $Root 'MSFT')' or run " +
           "'winget install Microsoft.DirectXTex.$Name'.")
}

function Get-BffTexDiagPath {
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot), [hashtable] $Settings)
    return Resolve-BffTexTool -Name 'texdiag' -Root $Root -Settings $Settings
}

function Get-BffTexConvPath {
    [CmdletBinding()]
    param([string] $Root = (Get-BffRoot), [hashtable] $Settings)
    return Resolve-BffTexTool -Name 'texconv' -Root $Root -Settings $Settings
}

function Test-BffToolchain {
    <#
    .SYNOPSIS
    Checks that texconv and texdiag actually start, and explains it clearly when
    they do not.

    .NOTES
    Both tools are dynamically linked against a Visual C++ runtime - the 2026 build
    wants msvcp140/vcruntime140 (VC++ 2015-2022), the old 2017 build wanted
    msvcp120/msvcr120 (VC++ 2013). Fallout 4 installs both through Steam, so in
    practice they are always there, but a missing DLL otherwise produces a silent
    failure on every single texture instead of one clear message.
    #>
    [CmdletBinding()]
    param(
        [string]    $Root = (Get-BffRoot),
        [hashtable] $Settings
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($name in @('texdiag', 'texconv')) {
        try { $path = Resolve-BffTexTool -Name $name -Root $Root -Settings $Settings }
        catch { $problems.Add($_.Exception.Message); continue }

        $resolved.Add($path)
        $output = ''
        try { $output = (& $path '--help' 2>&1 | Out-String) } catch { $output = '' }
        if ($output -notmatch 'DirectX Texture') {
            try { $output = (& $path 2>&1 | Out-String) } catch { $output = $_.Exception.Message }
        }

        if ($output -notmatch 'DirectX Texture') {
            $problems.Add(
                "$path will not start. This normally means the Visual C++ Redistributable is missing; " +
                "install the x64 'Visual C++ 2015-2022 Redistributable' from Microsoft and try again. " +
                "(Output was: " + (($output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)) + ")")
        }
    }

    return [pscustomobject]@{
        Problems = $problems
        Paths    = $resolved
    }
}

function ConvertTo-BffPathKey {
    <#
    .SYNOPSIS
    Normalises a path for comparison. texdiag echoes the path back, sometimes with
    forward slashes, so both sides go through this.
    #>
    param([string] $Path)
    if (-not $Path) { return '' }
    return $Path.Trim().Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Get-BffTextureInfo {
    <#
    .SYNOPSIS
    Runs 'texdiag info' over a list of files and returns one record per file.

    .OUTPUTS
    [pscustomobject] Path, Width, Height, Format, MipLevels, Depth, ArraySize,
                     Dimension, AlphaMode, SizeKB, Ok, Error

    .NOTES
    Output of 'texdiag info' looks like:

        C:\path\to\Head_s.DDS
                width = 1024
               height = 1024
                depth = 1
            mipLevels = 11
            arraySize = 1
               format = BC5_UNORM
            dimension = 2D
           alpha mode = Unknown
               images = 11
           pixel size = 1365 (KB)

    A line that is not 'key = value' and that matches one of the requested paths
    starts a new record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [string] $TexDiagPath = (Get-BffTexDiagPath),
        [int]    $BatchSize   = 40,
        [scriptblock] $Progress
    )

    $results = New-Object System.Collections.Generic.List[object]
    $total   = $Path.Count
    if ($total -eq 0) { return $results }

    for ($offset = 0; $offset -lt $total; $offset += $BatchSize) {
        $last  = [Math]::Min($offset + $BatchSize - 1, $total - 1)
        $batch = @($Path[$offset..$last])

        # Map normalised path -> original path so we can echo the caller's casing back.
        $lookup = @{}
        foreach ($p in $batch) { $lookup[(ConvertTo-BffPathKey $p)] = $p }

        $raw = & $TexDiagPath info -nologo @batch 2>&1

        $found   = @{}
        $current = $null

        foreach ($line in $raw) {
            $text = [string] $line

            if ($text -match '^\s*([A-Za-z][A-Za-z ]*?)\s*=\s*(.+?)\s*$') {
                if ($current) { $found[$current][$Matches[1]] = $Matches[2] }
                continue
            }

            $key = ConvertTo-BffPathKey $text
            if ($lookup.ContainsKey($key)) {
                $current = $key
                if (-not $found.ContainsKey($key)) { $found[$key] = @{} }
            }
            # Anything else (ERROR:/FAILED lines, blank lines) is ignored here; the
            # file simply ends up without properties and is reported as failed below.
        }

        foreach ($p in $batch) {
            $key  = ConvertTo-BffPathKey $p
            $prop = $found[$key]

            if (-not $prop -or -not $prop['width'] -or -not $prop['format']) {
                $results.Add([pscustomobject]@{
                    Path = $p; Width = 0; Height = 0; Format = ''; MipLevels = 0
                    Depth = 0; ArraySize = 0; Dimension = ''; AlphaMode = ''; SizeKB = 0
                    Ok = $false; Error = 'texdiag could not read this file'
                })
                continue
            }

            $sizeKb = 0
            if ($prop['pixel size'] -match '^(\d+)') { $sizeKb = [int] $Matches[1] }

            # texdiag omits some keys for certain resource types, so read defensively.
            $asInt = {
                param($value)
                $n = 0
                if ($value -and [int]::TryParse([string] $value, [ref] $n)) { return $n }
                return 0
            }

            $results.Add([pscustomobject]@{
                Path      = $p
                Width     = & $asInt $prop['width']
                Height    = & $asInt $prop['height']
                Format    = [string] $prop['format']
                MipLevels = & $asInt $prop['mipLevels']
                Depth     = & $asInt $prop['depth']
                ArraySize = & $asInt $prop['arraySize']
                Dimension = [string] $prop['dimension']
                AlphaMode = [string] $prop['alpha mode']
                SizeKB    = $sizeKb
                Ok        = $true
                Error     = ''
            })
        }

        if ($Progress) { & $Progress ([Math]::Min($last + 1, $total)) $total }
    }

    return $results
}

function Update-BffTextureInfo {
    <#
    .SYNOPSIS
    Fills Width/Height/Format/MipLevels on a list of BffTexture objects.
    Textures texdiag cannot read are dropped from the returned list and reported
    through -FailedVariable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Texture,
        [string] $TexDiagPath = (Get-BffTexDiagPath),
        [scriptblock] $Progress,
        [string] $FailedVariable
    )

    $list = @($Texture)
    if ($list.Count -eq 0) { return @() }

    $byPath = @{}
    foreach ($t in $list) { $byPath[(ConvertTo-BffPathKey $t.FullName)] = $t }

    $info   = Get-BffTextureInfo -Path @($list.FullName) -TexDiagPath $TexDiagPath -Progress $Progress
    $ok     = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]

    foreach ($rec in $info) {
        $t = $byPath[(ConvertTo-BffPathKey $rec.Path)]
        if (-not $t) { continue }

        if (-not $rec.Ok) {
            $failed.Add([pscustomobject]@{ Path = $rec.Path; Error = $rec.Error })
            continue
        }

        $t.Width     = $rec.Width
        $t.Height    = $rec.Height
        $t.Format    = $rec.Format
        $t.MipLevels = $rec.MipLevels
        $ok.Add($t)
    }

    if ($FailedVariable) {
        Set-Variable -Name $FailedVariable -Value $failed -Scope 1
    }

    return $ok
}
