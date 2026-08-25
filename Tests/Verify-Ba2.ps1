# BA2 verification.
#
# Checks that a face texture can be pulled out of a real archive and comes out as
# a DDS that matches what the archive's file table claimed - which is what the
# FixArchives option depends on, since archives are never repacked and the fix is
# written next to them as a loose file.
#
# Uses whatever archives are actually installed rather than a fixture, because
# building a BA2 needs Archive2 or BSArch and neither ships with this tool.

[CmdletBinding()]
param(
    [string] $Tool,
    [string] $MO2Path = 'C:\Modding\MO2',
    [int]    $Sample  = 6
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Resolved here, not as a param default: $PSScriptRoot is not populated in the
# param block when the script is started with powershell.exe -File.
if (-not $Tool) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Tool = Join-Path (Split-Path -Parent $here) 'Tools\Black Face Fix'
}

foreach ($f in 'Types', 'Config', 'Environment', 'TexInfo', 'Ba2', 'Discovery', 'Planner', 'Convert', 'Report') {
    . (Join-Path $Tool "PS\Lib\$f.ps1")
}

$pass = 0; $fail = 0; $skip = 0
function Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}
function Skip {
    param([string] $Name, [string] $Why)
    $script:skip++
    Write-Host ("  SKIP  {0}  {1}" -f $Name, $Why) -ForegroundColor DarkYellow
}

$settings = Import-BffSettings -Root $Tool
$settings.Paths.MO2 = $MO2Path
$environment = Get-BffEnvironment -Settings $settings -Root $Tool
$slotRules   = Import-BffSlotRules -Root $Tool
$vanilla     = Import-BffVanillaFaceTextures -Root $Tool
$texdiag     = Get-BffTexDiagPath -Root $Tool -Settings $settings

Write-Host 'Reading archives...'
$found = @(Get-BffArchiveCandidate -Environment $environment -Settings $settings `
                                   -SlotRules $slotRules -VanillaFaceTextures $vanilla |
           Where-Object { $_.Texture })

Check 'face textures found in archives' ($found.Count -gt 0) ("count={0}" -f $found.Count)
if ($found.Count -eq 0) {
    Write-Host ''
    Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail)
    return
}

# Both container types have to work: DX10 keeps size and format in the file table,
# GNRL stores whole .dds files and needs its header read.
$byType = $found | Group-Object { if ($_.Entry.Chunks) { 'DX10' } else { 'GNRL' } }
Write-Host ('  ' + (($byType | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join '  ')) -ForegroundColor DarkGray

Check 'every entry has size and format' `
    (@($found | Where-Object { $_.Texture.Width -le 0 -or -not $_.Texture.Format }).Count -eq 0) `
    ("bad={0}" -f @($found | Where-Object { $_.Texture.Width -le 0 -or -not $_.Texture.Format }).Count)

Check 'no entry reports a nonsense format' `
    (@($found | Where-Object { $_.Texture.Format -match '^DXGI_\d|^FOURCC_' }).Count -eq 0) `
    (($found | Where-Object { $_.Texture.Format -match '^DXGI_\d|^FOURCC_' } |
        Select-Object -First 3 -Expand Texture | ForEach-Object { $_.Format }) -join ', ')

# --- the rules must accept whatever the game itself ships -------------------
# The safe format for a slot is the one Fallout 4 uses for it. If the slot rules
# ever reject something out of the game's own archives, the rules are wrong, not
# the game.
$gameFaces = New-Object System.Collections.Generic.List[object]
foreach ($ba2 in (Get-ChildItem $environment.DataPath -Filter '*.ba2' -File -ErrorAction SilentlyContinue)) {
    $idx = Read-BffBa2Index -Path $ba2.FullName -PathFilter 'actors\\character'
    if ($idx.Error) { continue }
    foreach ($e in $idx.Entries) {
        $rel = ($e.InternalPath -replace '(?i)^textures\\', '')
        $m = Test-BffFaceTexture -RelativePath $rel -VanillaFaceTextures $vanilla `
                                 -SlotRules $slotRules -Settings $settings
        if ($m) { $gameFaces.Add([pscustomobject]@{ Slot = $m.Slot; Format = $e.Format; Width = $e.Width }) }
    }
}

Check 'game face textures were found' ($gameFaces.Count -gt 0) ("count={0}" -f $gameFaces.Count)

$rejected = @($gameFaces | Where-Object {
    # $PSItem and not $_: the inner Where-Object rebinds $_ to the rule.
    $face = $PSItem
    $rule = $slotRules.Rules | Where-Object { $_.Slot -eq $face.Slot } | Select-Object -First 1
    $rule -and -not $rule.AllowsFormat($face.Format)
})
Check 'slot rules accept every vanilla format' ($rejected.Count -eq 0) `
    (($rejected | Group-Object Slot, Format | ForEach-Object { $_.Name }) -join '; ')

# Every conversion target must itself be a format the game uses for that slot.
foreach ($rule in $slotRules.Rules) {
    $shipped = @($gameFaces | Where-Object { $_.Slot -eq $rule.Slot } | ForEach-Object { $_.Format } | Sort-Object -Unique)
    if ($shipped.Count -eq 0) { continue }
    Check ("default format for " + $rule.Slot + " is one the game uses") `
        ($shipped -contains $rule.DefaultFormat) `
        ("default={0} game uses={1}" -f $rule.DefaultFormat, ($shipped -join ', '))
}

# The vanilla specular really is 512, whatever a mod page may claim.
$spec = @($gameFaces | Where-Object { $_.Slot -eq 'Specular' })
if ($spec.Count -gt 0) {
    Check 'vanilla speculars are all 512' (@($spec | Where-Object { $_.Width -ne 512 }).Count -eq 0) `
        (($spec | Group-Object Width | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' ')
}

# --- extraction ------------------------------------------------------------
$work = Join-Path $env:TEMP ('BlackFaceFix.Tests\ba2_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
[void] (New-Item -ItemType Directory -Path $work -Force)

$extracted = 0
$lz4       = 0

try {
    # One from each container type first, then fill up to -Sample.
    $targets = @()
    foreach ($g in $byType) { $targets += ($g.Group | Select-Object -First 1) }
    $targets += ($found | Select-Object -First $Sample)
    $targets = $targets | Sort-Object { $_.Texture.FullName } -Unique | Select-Object -First $Sample

    foreach ($t in $targets) {
        $name = Split-Path $t.Texture.FullName -Leaf
        $dest = Join-Path $work ("{0}_{1}" -f $extracted, $name)

        try { [void] (Expand-BffBa2Texture -Entry $t.Entry -Destination $dest) }
        catch {
            if ($_.Exception.Message -match 'not zlib') {
                # Next-gen archives may use LZ4; reporting works, extraction does not.
                $lz4++
                Skip ("extract $name") 'archive uses LZ4 compression'
                continue
            }
            Check "extract $name" $false $_.Exception.Message
            continue
        }

        if (-not (Test-Path -LiteralPath $dest)) { Check "extract $name" $false 'no file written'; continue }

        # ReadAllBytes rather than Get-Content -Encoding Byte: that switch was
        # removed in PowerShell 7, and the tests have to run on both.
        $head  = [System.IO.File]::ReadAllBytes($dest)[0..3]
        $magic = [System.Text.Encoding]::ASCII.GetString([byte[]] $head)
        Check "$name is a DDS"  ($magic -eq 'DDS ') "magic='$magic'"

        $info = Get-BffTextureInfo -Path @($dest) -TexDiagPath $texdiag | Select-Object -First 1
        Check "$name is readable by texdiag" $info.Ok $info.Error

        if ($info.Ok) {
            Check "$name matches the file table" `
                ($info.Width  -eq $t.Texture.Width -and
                 $info.Height -eq $t.Texture.Height -and
                 $info.Format -eq $t.Texture.Format) `
                ("table={0}x{1} {2}  extracted={3}x{4} {5}" -f
                 $t.Texture.Width, $t.Texture.Height, $t.Texture.Format,
                 $info.Width, $info.Height, $info.Format)

            Check "$name kept its mip chain" ($info.MipLevels -ge 1) ("mips={0}" -f $info.MipLevels)
        }
        $extracted++
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($skip) { Write-Host ("({0} skipped)" -f $skip) -ForegroundColor DarkYellow }
