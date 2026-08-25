# End-to-end verification for Black Face Fix 4.
#
# Builds a throwaway MO2 instance with deliberately awkward textures, runs the real
# tool against it, and checks every claim made in the plan.

param(
    [string] $Tool    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix'),
    [string] $Sandbox = (Join-Path $env:TEMP 'BlackFaceFix.Tests\console'),

    # Any real face specular and diffuse are fine as raw material; the test
    # re-encodes them into every shape it needs. Defaults point at textures the
    # V3 "Extra Textures" download ships.
    [string] $SourceSpecular = 'C:\Modding\MO2\mods\Extra Textures for V3 Alpha 1\Textures\actors\Character\GhoulMale\GhoulMaleHead_s.DDS',
    [string] $SourceDiffuse  = 'C:\Modding\MO2\mods\Extra Textures for V3 Alpha 1\Textures\actors\Character\GhoulMale\GhoulMaleHead_d.DDS'
)

$ErrorActionPreference = 'Stop'
$texconv = Join-Path $Tool 'MSFT\texconv.exe'
$texdiag = Join-Path $Tool 'MSFT\texdiag.exe'

foreach ($p in @($SourceSpecular, $SourceDiffuse)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw ("Source texture not found: '$p'. Pass -SourceSpecular and -SourceDiffuse " +
               "pointing at any face _s and _d DDS on this machine.")
    }
}

$pass = 0; $fail = 0
function Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}

# ---------------------------------------------------------------- build sandbox
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
$mods = Join-Path $Sandbox 'MO2\mods'
$prof = Join-Path $Sandbox 'MO2\profiles\Test'
New-Item -ItemType Directory -Path $mods, $prof -Force | Out-Null

@"
[General]
gameName=Fallout 4
gamePath=@ByteArray(C:\\Steam\\steamapps\\common\\Fallout 4)
selected_profile=@ByteArray(Test)
"@ | Set-Content (Join-Path $Sandbox 'MO2\ModOrganizer.ini')

"# generated`n+TestMod`n+HairMod`n-DisabledMod" | Set-Content (Join-Path $prof 'modlist.txt')

$char = Join-Path $mods 'TestMod\textures\actors\character'
$face = Join-Path $char 'Character Assets\FaceDetails'
$base = Join-Path $char 'BaseHumanMale'
$hair = Join-Path $mods 'HairMod\textures\actors\character\Hair\Test'
$dis  = Join-Path $mods 'DisabledMod\textures\actors\character\BaseHumanMale'
New-Item -ItemType Directory -Path $face, $base, $hair, $dis -Force | Out-Null

# Source material: a real BC5 specular and a BC7 diffuse.
$srcS = $SourceSpecular
$srcD = $SourceDiffuse

function Make {
    param([string] $Source, [string] $Dest, [int] $W, [int] $H, [string] $Fmt)
    # Same two-pass dance the tool uses: this texconv build cannot resize a DDS
    # that already has a mip chain.
    $t1 = Join-Path $env:TEMP ('bffv1_' + [Guid]::NewGuid().ToString('N').Substring(0,6))
    $t2 = Join-Path $env:TEMP ('bffv2_' + [Guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $t1, $t2 -Force | Out-Null

    $out1 = & $texconv -nologo -y -w $W -h $H -m 1 -f R8G8B8A8_UNORM -ft DDS -o $t1 $Source 2>&1
    $mid  = Get-ChildItem $t1 -Filter *.dds | Select-Object -First 1
    if (-not $mid) {
        Remove-Item $t1, $t2 -Recurse -Force
        throw ("pass 1 failed for {0}: {1}" -f (Split-Path $Dest -Leaf), (($out1 | Where-Object { $_ -match '\S' }) -join ' | '))
    }

    $out2 = & $texconv -nologo -y -m 0 -f $Fmt -ft DDS -o $t2 $mid.FullName 2>&1
    $made = Get-ChildItem $t2 -Filter *.dds | Select-Object -First 1
    if (-not $made) {
        Remove-Item $t1, $t2 -Recurse -Force
        throw ("pass 2 failed for {0} ({1}): {2}" -f (Split-Path $Dest -Leaf), $Fmt, (($out2 | Where-Object { $_ -match '\S' }) -join ' | '))
    }

    Copy-Item $made.FullName $Dest -Force
    Remove-Item $t1, $t2 -Recurse -Force
}

Write-Host 'Building sandbox textures...' -ForegroundColor Yellow
Make $srcS (Join-Path $base 'TestMaleHead_s.dds')        1024 1024 BC5_UNORM   # must shrink to 512
Make $srcS (Join-Path $base 'GoodMaleHead_s.dds')          512  512 BC5_UNORM   # must be skipped
Make $srcD (Join-Path $base 'TestMaleHead_d.dds')        1024 1024 BC1_UNORM   # must be skipped
Make $srcD (Join-Path $base 'AlphaMaleHead_d.dds')       1024 1024 BC3_UNORM   # must be skipped
Make $srcD (Join-Path $base 'SevenMaleHead_d.dds')       1024 1024 BC7_UNORM   # must be skipped
Make $srcD (Join-Path $base 'BrokenMaleHead_d.dds')      1024 1024 BC6H_SF16   # must be re-encoded
Make $srcS (Join-Path $base 'TestMaleHead_msn.dds')      1024 1024 BC1_UNORM   # msn: BC1 is legal, skip
Make $srcD (Join-Path $base 'TestMaleBody_d.dds')        4096 4096 BC7_UNORM   # body: must be ignored
Make $srcD (Join-Path $face 'Face_Specular.dds')           512  512 BC5_UNORM   # word suffix: skip
Make $srcD (Join-Path $face 'TintMaskBC4_d.dds')          1024 1024 BC4_UNORM   # mask: single channel is fine
Make $srcD (Join-Path $base 'BC4MaleHead_d.dds')          1024 1024 BC4_UNORM   # head diffuse: not fine
Make $srcD (Join-Path $face 'ColourStrip.dds')              64  128 BC1_UNORM   # non-square: Review
Make $srcD (Join-Path $hair 'Headgear01_d.dds')          2048 2048 BC1_UNORM   # hair: must be ignored
Make $srcD (Join-Path $dis  'DisabledHead_d.dds')         512  512 BC1_UNORM   # disabled mod: ignored

# ------------------------------------------------------------------ settings
$settings = Join-Path $Tool 'Config\Settings.psd1'
$backup   = "$settings.verifybak"
Copy-Item $settings $backup -Force
(Get-Content $settings -Raw).Replace('IncludeGameData          = $true', 'IncludeGameData          = $false') |
    Set-Content $settings

try {
    $baseCountBefore = (Get-ChildItem -LiteralPath $base -Filter *.dds).Count

    Write-Host ''
    Write-Host 'RUN 1 - dry run' -ForegroundColor Cyan
    $logsBefore = @(Get-ChildItem (Join-Path $Tool 'Logs') -Filter *.csv -EA SilentlyContinue).Name

    & (Join-Path $Tool 'PS\BlackFaceFix.ps1') -DryRun -NoPause -MO2Path (Join-Path $Sandbox 'MO2') -NoArchives -All | Out-Null

    $csv = Get-ChildItem (Join-Path $Tool 'Logs') -Filter *.csv | Where-Object { $_.Name -notin $logsBefore } |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $rows = Import-Csv $csv.FullName
    $by = @{}; foreach ($r in $rows) { $by[$r.File] = $r }

    # Settings.local.psd1 keeps personal tweaks out of what gets shipped. Checked
    # read-only against whatever is actually there - the live config is not touched.
    $localPath = Join-Path $Tool 'Config\Settings.local.psd1'
    if (Test-Path -LiteralPath $localPath) {
        # This suite drives the tool as a subprocess, so the library is not loaded
        # here; the two files the merge needs are pulled in just for this check.
        . (Join-Path $Tool 'PS\Lib\Types.ps1')
        . (Join-Path $Tool 'PS\Lib\Config.ps1')

        $shipped = Import-PowerShellDataFile -LiteralPath (Join-Path $Tool 'Config\Settings.psd1')
        $local   = Import-PowerShellDataFile -LiteralPath $localPath
        $merged  = Import-BffSettings -Root $Tool

        $wrong = @()
        foreach ($section in $local.Keys) {
            if ($local[$section] -isnot [hashtable]) { continue }
            foreach ($k in $local[$section].Keys) {
                if ("$($merged[$section][$k])" -ne "$($local[$section][$k])") {
                    $wrong += "$section.$k"
                }
            }
        }
        Check 'local settings override the shipped ones' ($wrong.Count -eq 0) ($wrong -join ', ')

        # Anything the local file does not mention must still come from Settings.psd1.
        Check 'unmentioned settings keep their shipped value' `
            ("$($merged.Conversion.MinSize)" -eq "$($shipped.Conversion.MinSize)") `
            ("merged={0} shipped={1}" -f $merged.Conversion.MinSize, $shipped.Conversion.MinSize)
    }

    Write-Host ''
    Write-Host 'Checks' -ForegroundColor Cyan

    Check 'specular 1024 -> 512'          ($by['TestMaleHead_s.dds'].Action -eq 'Resize' -and $by['TestMaleHead_s.dds'].TargetWidth -eq '512') $by['TestMaleHead_s.dds'].Action
    Check 'specular already 512 skipped'  ($by['GoodMaleHead_s.dds'].Action -eq 'Skip') $by['GoodMaleHead_s.dds'].Action
    Check 'BC1 diffuse kept as BC1'       ($by['TestMaleHead_d.dds'].Action -eq 'Skip') $by['TestMaleHead_d.dds'].Action
    Check 'BC3 diffuse kept as BC3'       ($by['AlphaMaleHead_d.dds'].Action -eq 'Skip') $by['AlphaMaleHead_d.dds'].Action
    Check 'BC7 diffuse kept as BC7'       ($by['SevenMaleHead_d.dds'].Action -eq 'Skip') $by['SevenMaleHead_d.dds'].Action
    Check 'BC6H diffuse re-encoded'       ($by['BrokenMaleHead_d.dds'].Action -eq 'Reformat' -and $by['BrokenMaleHead_d.dds'].TargetFormat -eq 'BC3_UNORM') "$($by['BrokenMaleHead_d.dds'].Action)/$($by['BrokenMaleHead_d.dds'].TargetFormat)"
    Check '_msn BC1 left alone'           ($by['TestMaleHead_msn.dds'].Action -eq 'Skip') $by['TestMaleHead_msn.dds'].Action
    Check 'Face_Specular read as specular'($by['Face_Specular.dds'].Slot -eq 'Specular' -and $by['Face_Specular.dds'].Action -eq 'Skip') "$($by['Face_Specular.dds'].Slot)/$($by['Face_Specular.dds'].Action)"
    Check 'non-square flagged Review'     ($by['ColourStrip.dds'].Action -eq 'Review') $by['ColourStrip.dds'].Action
    Check 'body texture not scanned'      (-not $by.ContainsKey('TestMaleBody_d.dds'))
    Check 'hair texture not scanned'      (-not $by.ContainsKey('Headgear01_d.dds'))
    Check 'disabled mod not scanned'      (-not $by.ContainsKey('DisabledHead_d.dds'))
    Check 'no BC6H anywhere in targets'   (@($rows | Where-Object { $_.TargetFormat -eq 'BC6H_SF16' }).Count -eq 0)

    # Tint masks and face details are masks, not colour maps, so a single channel
    # BC4 is a deliberate choice there and must be left alone. On the head itself
    # a BC4 diffuse really is wrong and still gets fixed.
    Check 'BC4 tint mask kept'            ($by['TintMaskBC4_d.dds'].Action -eq 'Skip') $by['TintMaskBC4_d.dds'].Action
    Check 'BC4 head diffuse re-encoded'   ($by['BC4MaleHead_d.dds'].Action -eq 'Reformat' -and
                                           $by['BC4MaleHead_d.dds'].TargetFormat -eq 'BC3_UNORM') `
                                          ("{0}/{1}" -f $by['BC4MaleHead_d.dds'].Action, $by['BC4MaleHead_d.dds'].TargetFormat)

    # Naming output after its source makes paths ~50 characters longer than a
    # shared folder would, so anything that would cross the Windows limit has to
    # be reported rather than fail halfway through a copy.
    $tooLong = @($rows | Where-Object { $_.Destination -and $_.Destination.Length -ge 260 -and $_.Action -ne 'Error' })
    Check 'over-long paths are refused'   ($tooLong.Count -eq 0) ("{0} planned past 260 chars" -f $tooLong.Count)

    # ------------------------------------------------------------- run 2: apply
    Write-Host ''
    Write-Host 'RUN 2 - apply (OutputMod)' -ForegroundColor Cyan
    & (Join-Path $Tool 'PS\BlackFaceFix.ps1') -NoPause -Yes -MO2Path (Join-Path $Sandbox 'MO2') -NoArchives | Out-Null

    # One output mod per SOURCE mod, named after it, so MO2 keeps deciding
    # conflicts: '<source> [<profile>]'.
    # -LiteralPath everywhere below: square brackets are wildcards to Test-Path, so
    # a folder called 'TestMod [face-Vanilla]' is invisible without it. Real mod
    # names hit this too ('Some Armour [2K]').
    $outMod = Join-Path $mods 'TestMod [face-Vanilla]'
    $outS   = Join-Path $outMod 'textures\actors\character\BaseHumanMale\TestMaleHead_s.dds'
    $outB   = Join-Path $outMod 'textures\actors\character\BaseHumanMale\BrokenMaleHead_d.dds'

    Check 'per-mod output folder created' (Test-Path -LiteralPath $outMod) $outMod
    Check 'converted specular exists'     (Test-Path -LiteralPath $outS)
    Check 'no shared output folder'       (-not (Test-Path -LiteralPath (Join-Path $mods 'BlackFaceFix Output')))
    # Generated folders are identified by a marker file, not by their name: a real
    # mod called 'Something [2K]' must still be scanned as input.
    Check 'output folder is marked'       (Test-Path -LiteralPath (Join-Path $outMod 'BlackFaceFix-generated.txt'))
    Check 'nothing written for HairMod'   (-not (Test-Path -LiteralPath (Join-Path $mods 'HairMod [face-Vanilla]')))

    if (Test-Path -LiteralPath $outS) {
        $i = & $texdiag info -nologo $outS 2>$null
        $w = ($i | Select-String 'width'     | ForEach-Object { ($_ -split '=')[1].Trim() })
        $f = ($i | Select-String 'format'    | ForEach-Object { ($_ -split '=')[1].Trim() })
        $m = ($i | Select-String 'mipLevels' | ForEach-Object { ($_ -split '=')[1].Trim() })
        Check 'specular output is 512'     ($w -eq '512') "width=$w"
        Check 'specular output is BC5'     ($f -eq 'BC5_UNORM') "format=$f"
        Check 'specular has 10 mips'       ($m -eq '10') "mips=$m"
    }
    if (Test-Path -LiteralPath $outB) {
        $f = (& $texdiag info -nologo $outB 2>$null | Select-String 'format' | ForEach-Object { ($_ -split '=')[1].Trim() })
        Check 'BC6H output is now BC3'     ($f -eq 'BC3_UNORM') "format=$f"
    }

    # Counted rather than hard-coded, so adding a fixture does not break this.
    Check 'source mod untouched'          ((Get-ChildItem -LiteralPath $base -Filter *.dds).Count -eq $baseCountBefore) `
                                          ("now {0}, was {1}" -f (Get-ChildItem -LiteralPath $base -Filter *.dds).Count, $baseCountBefore)
    $srcInfo = & $texdiag info -nologo (Join-Path $base 'TestMaleHead_s.dds') 2>$null
    $srcW = ($srcInfo | Select-String 'width' | ForEach-Object { ($_ -split '=')[1].Trim() })
    Check 'source specular still 1024'    ($srcW -eq '1024') "width=$srcW"

    # ------------------------------------------------- run 3: idempotence check
    Write-Host ''
    Write-Host 'RUN 3 - second apply must be a no-op' -ForegroundColor Cyan
    & (Join-Path $Tool 'PS\BlackFaceFix.ps1') -NoPause -Yes -MO2Path (Join-Path $Sandbox 'MO2') -NoArchives | Out-Null
    # Log names are timestamped to the second, so two runs inside one second share a
    # file. Just take the newest: it is whatever the last run wrote.
    $csv2 = Get-ChildItem (Join-Path $Tool 'Logs') -Filter *.csv |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $rows2 = Import-Csv $csv2.FullName

    # The output mod is itself scanned on the second run; everything must be Skip
    # or Review, nothing may need converting again.
    $again = @($rows2 | Where-Object { $_.Action -in @('Resize','Reformat','ResizeAndReformat') })
    Check 'second run converts nothing'   ($again.Count -eq 0) ("still {0}: {1}" -f $again.Count, (($again | Select-Object -First 3 -Expand File) -join ', '))
}
finally {
    Move-Item $backup $settings -Force
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
