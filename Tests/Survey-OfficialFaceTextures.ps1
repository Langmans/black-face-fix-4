# Survey every texture path the OFFICIAL plugins declare under actors\character,
# with the TXST slot and the owning texture set, and bucket the file names by how
# well they follow the '<something>Head_<slot>.dds' convention.
#
# Purpose: find every naming shape a face-texture detector has to cope with, using
# the game's own data rather than guesses.

param(
    [string] $DataPath = 'C:\Steam\steamapps\common\Fallout 4\Data',
    [string] $OutCsv
)

$official = @(
    'Fallout4.esm', 'DLCRobot.esm', 'DLCworkshop01.esm', 'DLCCoast.esm',
    'DLCworkshop02.esm', 'DLCworkshop03.esm', 'DLCNukaWorld.esm',
    'DLCUltraHighResolution.esm'
)

$slotOfTx = @{
    'TX00' = 'Diffuse'; 'TX01' = 'Normal'; 'TX02' = 'WrinkleNormal'; 'TX03' = 'Glow'
    'TX04' = 'Height';  'TX05' = 'Environment'; 'TX06' = 'Multilayer'; 'TX07' = 'Specular'
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($name in $official) {
    $path = Join-Path $DataPath $name
    if (-not (Test-Path -LiteralPath $path)) { Write-Host "  (missing) $name"; continue }

    $b = [System.IO.File]::ReadAllBytes($path)
    if ([System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'TES4') { Remove-Variable b; continue }

    $headerSize = [BitConverter]::ToUInt32($b, 4)
    $before = $rows.Count

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@{ Start = 24 + $headerSize; End = $b.Length })

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $p = $frame.Start; $end = $frame.End

        while ($p -lt $end - 24) {
            $type = [System.Text.Encoding]::ASCII.GetString($b, $p, 4)

            if ($type -eq 'GRUP') {
                $gs = [int][BitConverter]::ToUInt32($b, $p + 4)
                if ($gs -le 24) { break }
                $stack.Push(@{ Start = $p + 24; End = $p + $gs })
                $p += $gs
                continue
            }

            $ds = [int][BitConverter]::ToUInt32($b, $p + 4)
            $fl = [BitConverter]::ToUInt32($b, $p + 8)

            if ($type -eq 'TXST' -and ($fl -band 0x00040000) -eq 0) {
                $q = $p + 24; $recEnd = $p + 24 + $ds
                $edid = ''; $found = @{}

                while ($q -lt $recEnd - 6) {
                    $st = [System.Text.Encoding]::ASCII.GetString($b, $q, 4)
                    $sl = [int][BitConverter]::ToUInt16($b, $q + 4)
                    if ($sl -le 0 -or $q + 6 + $sl -gt $recEnd) { break }
                    if ($st -eq 'EDID') { $edid = [System.Text.Encoding]::ASCII.GetString($b, $q + 6, $sl - 1) }
                    elseif ($st -match '^TX0[0-7]$') { $found[$st] = [System.Text.Encoding]::ASCII.GetString($b, $q + 6, $sl - 1) }
                    $q += 6 + $sl
                }

                foreach ($tx in $found.Keys) {
                    $raw = $found[$tx]
                    if (-not $raw) { continue }
                    $norm = ($raw.Trim().Replace('/', '\').ToLowerInvariant()) -replace '^textures\\', ''
                    if ($norm -notmatch '^actors\\character\\') { continue }

                    $rows.Add([pscustomobject]@{
                        Plugin = $name; EditorID = $edid; SlotCode = $tx; Slot = $slotOfTx[$tx]
                        Path = $norm; File = (Split-Path $norm -Leaf)
                        Folder = ((Split-Path $norm -Parent) -replace '^actors\\character\\?', '')
                        IsSkinHead = ($edid -match '^SkinHead')
                    })
                }
            }

            $p += 24 + $ds
        }
    }

    Write-Host ("  {0,-30} {1,4} character texture paths" -f $name, ($rows.Count - $before))
    Remove-Variable b
    [GC]::Collect()
}

$unique = $rows | Sort-Object Path, SlotCode -Unique
Write-Host ''
Write-Host ("Unique path/slot pairs under actors\character : {0}" -f $unique.Count)
Write-Host ("Unique files                                  : {0}" -f (($unique | Select-Object -Expand Path -Unique).Count))

# --- naming buckets -------------------------------------------------------
$faceish = $unique | Where-Object { $_.Folder -notmatch '^(eyes|hair)' }

Write-Host ''
Write-Host '=== Naming shape of every non-eye, non-hair character texture ==='
$buckets = $faceish | ForEach-Object {
    $stem = [IO.Path]::GetFileNameWithoutExtension($_.File)
    $low  = $stem.ToLowerInvariant()
    $bucket =
        if     ($low -match 'head_[a-z]+$')  { 'A  ...head_<slot>       (clean)' }
        elseif ($low -match 'head[a-z]+_')   { 'B  ...head<word>_<slot> (ODD DUCK)' }
        elseif ($low -match 'head')          { 'C  ...head, other shape (ODD DUCK)' }
        else                                 { 'D  no "head" at all     (ODD DUCK)' }
    [pscustomobject]@{ Bucket = $bucket; File = $_.File; Folder = $_.Folder; Slot = $_.Slot; EditorID = $_.EditorID; IsSkinHead = $_.IsSkinHead }
}

$buckets | Group-Object Bucket | Sort-Object Name | ForEach-Object { '{0,5}  {1}' -f $_.Count, $_.Name }

foreach ($b in @('B', 'C', 'D')) {
    Write-Host ''
    Write-Host ("=== BUCKET {0} ===" -f $b)
    $buckets | Where-Object { $_.Bucket.StartsWith($b) } | Sort-Object File -Unique |
        ForEach-Object { '  {0,-38} {1,-22} {2,-14} skinhead={3}' -f $_.File, $_.Folder, $_.Slot, $_.IsSkinHead }
}

if ($OutCsv) { $unique | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8; Write-Host "`nWrote $OutCsv" }
