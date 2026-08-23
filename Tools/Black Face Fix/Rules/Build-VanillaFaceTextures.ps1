# Bakes the authoritative vanilla face-texture list out of the game's plugins into
# Rules\VanillaFaceTextures.psd1, so the tool never has to parse an ESM at runtime.
#
# Source of truth: TXST (texture set) records whose EditorID starts with 'SkinHead'.
# Those are the face skin texture sets the RACE records point at. Verified against
# Fallout4.esm: 10 sets, 33 paths, zero body/eye/hair contamination.
#
# TX slot semantics for Fallout 4, confirmed empirically against filename suffixes
# across all 685 texture paths in Fallout4.esm:
#   TX00 -> _d  (208/240)   Diffuse
#   TX01 -> _n  (235/235)   Normal
#   TX02 -> _n  (9/9)       wrinkle/detail normal
#   TX04 -> _h  Height      (BlankDetailmap.dds lives here - shared, never resize)
#   TX07 -> _s  (157/160)   Specular

param(
    [Parameter(Mandatory)] [string] $DataPath,
    [Parameter(Mandatory)] [string] $OutFile
)

$slotOfTx = @{ 'TX00' = 'Diffuse'; 'TX01' = 'Normal'; 'TX02' = 'Normal'; 'TX07' = 'Specular' }
$excludeTx = @('TX03', 'TX04', 'TX05', 'TX06')

$textures = [ordered]@{}
$excluded = New-Object System.Collections.Generic.List[string]
$plugins  = New-Object System.Collections.Generic.List[object]

function Normalize-TexPath {
    param([string] $Path)
    $p = $Path.Trim().Replace('/', '\').ToLowerInvariant()
    $p = $p -replace '^textures\\', ''
    return $p
}

foreach ($file in (Get-ChildItem -LiteralPath $DataPath -Filter '*.esm' | Sort-Object Name)) {
    $b = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($b.Length -lt 24) { continue }
    if ([System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'TES4') { continue }

    $headerSize = [BitConverter]::ToUInt32($b, 4)
    $sets = 0
    $paths = 0

    # Iterative walk with an explicit stack; recursion on a 315 MB plugin is slow in PS.
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@{ Start = 24 + $headerSize; End = $b.Length })

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $p = $frame.Start
        $end = $frame.End

        while ($p -lt $end - 24) {
            $type = [System.Text.Encoding]::ASCII.GetString($b, $p, 4)

            if ($type -eq 'GRUP') {
                $groupSize = [int][BitConverter]::ToUInt32($b, $p + 4)
                if ($groupSize -le 24) { break }
                $stack.Push(@{ Start = $p + 24; End = $p + $groupSize })
                $p += $groupSize
                continue
            }

            $dataSize = [int][BitConverter]::ToUInt32($b, $p + 4)
            $flags    = [BitConverter]::ToUInt32($b, $p + 8)

            if ($type -eq 'TXST' -and ($flags -band 0x00040000) -eq 0) {
                $q = $p + 24
                $recEnd = $p + 24 + $dataSize
                $edid = ''
                $found = @{}

                while ($q -lt $recEnd - 6) {
                    $st = [System.Text.Encoding]::ASCII.GetString($b, $q, 4)
                    $sl = [int][BitConverter]::ToUInt16($b, $q + 4)
                    if ($sl -le 0 -or $q + 6 + $sl -gt $recEnd) { break }

                    if ($st -eq 'EDID') {
                        $edid = [System.Text.Encoding]::ASCII.GetString($b, $q + 6, $sl - 1)
                    }
                    elseif ($st -match '^TX0[0-7]$') {
                        $found[$st] = [System.Text.Encoding]::ASCII.GetString($b, $q + 6, $sl - 1)
                    }
                    $q += 6 + $sl
                }

                if ($edid -match '^SkinHead') {
                    $sets++
                    foreach ($tx in $found.Keys) {
                        $raw = $found[$tx]
                        if (-not $raw) { continue }
                        $norm = Normalize-TexPath $raw

                        if ($excludeTx -contains $tx) {
                            if ($excluded -notcontains $norm) { $excluded.Add($norm) }
                            continue
                        }
                        if ($slotOfTx.ContainsKey($tx) -and -not $textures.Contains($norm)) {
                            $textures[$norm] = $slotOfTx[$tx]
                            $paths++
                        }
                    }
                }
            }

            $p += 24 + $dataSize
        }
    }

    if ($sets -gt 0) {
        $plugins.Add([pscustomobject]@{ Name = $file.Name; Sets = $sets; Paths = $paths })
        Write-Host ("  {0,-32} {1,3} SkinHead sets, {2,3} new paths" -f $file.Name, $sets, $paths)
    }
    Remove-Variable b
}

# A path can appear in both lists (BlankDetailmap is only ever a height map);
# anything that got a real slot wins.
$finalExcluded = $excluded | Where-Object { -not $textures.Contains($_) } | Sort-Object -Unique

$sb = New-Object System.Text.StringBuilder
[void] $sb.AppendLine('# VanillaFaceTextures.psd1 - GENERATED, do not edit by hand.')
[void] $sb.AppendLine('#')
[void] $sb.AppendLine('# Built from the TXST records whose EditorID starts with ''SkinHead'' in:')
foreach ($pl in $plugins) {
    [void] $sb.AppendLine(('#   {0,-32} {1} sets' -f $pl.Name, $pl.Sets))
}
[void] $sb.AppendLine('#')
[void] $sb.AppendLine('# These are the face texture paths the game itself declares, which is how the')
[void] $sb.AppendLine('# tool finds head textures whose file name does not contain "head" -')
[void] $sb.AppendLine('# Preston_d.dds, Mayor_s.dds and Piper''s set would all be missed otherwise.')
[void] $sb.AppendLine('#')
[void] $sb.AppendLine('# Paths are lower case, backslash separated and relative to textures\.')
[void] $sb.AppendLine('')
[void] $sb.AppendLine('@{')
[void] $sb.AppendLine('    Textures = @{')
foreach ($key in ($textures.Keys | Sort-Object)) {
    [void] $sb.AppendLine(("        '{0}' = '{1}'" -f $key.Replace("'", "''"), $textures[$key]))
}
[void] $sb.AppendLine('    }')
[void] $sb.AppendLine('')
[void] $sb.AppendLine('    # Shared helper maps referenced by face texture sets that must never be')
[void] $sb.AppendLine('    # resized: they are not per-actor face textures.')
[void] $sb.AppendLine('    Exclude = @(')
foreach ($e in $finalExcluded) {
    [void] $sb.AppendLine(("        '{0}'" -f $e.Replace("'", "''")))
}
[void] $sb.AppendLine('    )')
[void] $sb.AppendLine('}')

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("Textures : {0}" -f $textures.Count)
Write-Host ("Excluded : {0}" -f $finalExcluded.Count)
Write-Host ("Wrote    : {0}" -f $OutFile)
