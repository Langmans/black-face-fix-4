---
name: bethesda-savegames
description: Read Fallout 4 and Skyrim savegames (.fos/.ess) without loading the game - the plugin list a save was made with, its change forms, and which forms carry which change flags. Use when you need to know whether a save has recorded changes for a form (NPC face edits, moved references, deleted objects), which plugins a save expects, what the save was made with, or why a mod behaves differently on an old save than a new one.
---

# Reading Bethesda savegames

A Fallout 4 `.fos` is **not compressed** and can be walked straight off disk. Skyrim
SE `.ess` uses the same layout but with a `uint16 compressionType` after the header
(0 none, 1 zlib, 2 lz4) covering everything past the screenshot.

The interesting part for most questions is the **change form** table: every form the
game has recorded a runtime change for, with a bitmask saying what changed.

## Layout (Fallout 4, save version 15)

```
char[12]  "FO4_SAVEGAME"
uint32    headerSize
Header    header            <- exactly headerSize bytes; trust this, do not sum fields
uint8[]   screenshot        <- shotWidth * shotHeight * 4, RGBA
uint8     formVersion
wstring   gameVersion       <- e.g. "1.10.163.0"
uint32    pluginInfoSize
  uint8   fullCount
  wstring fullNames[fullCount]
  uint16  lightCount        <- STILL INSIDE pluginInfoSize
  wstring lightNames[lightCount]
FileLocationTable           <- 10 uint32 offsets/counts, then 15 unused uint32
...
```

`Header` ends with `uint32 shotWidth` and `uint32 shotHeight`, so read those from
`headerStart + headerSize - 8`.

`wstring` is `uint16 length` followed by that many bytes, **not** null terminated.

### File location table

```
uint32 formIDArrayCountOffset
uint32 unknownTable3Offset
uint32 globalDataTable1Offset
uint32 globalDataTable2Offset
uint32 changeFormsOffset
uint32 globalDataTable3Offset
uint32 globalDataTable1Count
uint32 globalDataTable2Count
uint32 globalDataTable3Count
uint32 changeFormCount
uint32 unused[15]
```

### Change forms

At `changeFormsOffset`, `changeFormCount` records of:

```
uint8[3] refID
uint32   changeFlags
uint8    type          <- low 6 bits form type, top 2 bits length field size
uint8    version
len1, len2             <- uint8/uint16/uint32 depending on type >> 6
uint8[len1] data
```

`refID` is 3 bytes whose top 2 bits are documented as picking how to read the
remaining 22:

| top 2 bits | meaning |
|---|---|
| 0 | index into the FormID array (at `formIDArrayCountOffset`: `uint32 count` then `count` uint32s) |
| 1 | FormID with mod index 0x00 |
| 2 | created in game, OR with 0xFF000000 |
| 3 | unknown |

**This does not actually work on Fallout 4 and the correct decoding is still open.**
Measured on a real save: of 681 `NPC_` change forms, the scheme above resolves 2 to
an existing `NPC_` record in the plugin, and reversing the byte order resolves the
same 2. Whatever the layout is, it is not this. Treat any FormID you get out of a
refID as unverified until you have run the check below.

Everything that does *not* depend on refID is reliable: the record count, the form
type, the change flags, and therefore any question of the form "how many X have
flag Y set".

### Validating a decoding before trusting it

Decode the refIDs for one change form type, then check how many land on records of
that type in the plugin. A correct decoding resolves nearly all of them; anything
near zero means the decoding is wrong, not that the save is unusual.

```powershell
# collect every NPC_ FormID in the plugin, then:
$hit = @($decoded | Where-Object { $npcIDs.Contains([uint32] $_) }).Count
"$hit of $($decoded.Count) resolve to an NPC_ record"
```

## Things that will bite you

- **`pluginInfoSize` covers the ESL list too.** Read the full names, then the
  `uint16` light count and its names, and only then jump to `start + pluginInfoSize`.
  Jumping straight after the full names lands you mid-ESL-list and every offset
  afterwards is garbage - the symptom is `changeFormCount` reading as 0 or an
  offset past the end of the file.
- **`changeFlags` is interpreted per form type.** The same bit means different
  things on an `NPC_` than on an `ACHR`. Always filter by type before reading a
  flag. On one real save, 109 records had bit 11 set but only 3 were `NPC_`.
- **Length is `len1`, not `len2`.** `len2` is the uncompressed size when the record
  data is compressed; skip `len1` bytes to reach the next record.
- **Do not sum the header fields.** Use `headerSize`; field layout varies by save
  version and getting it wrong silently shifts everything.

## Change form types

Low 6 bits of the type byte:

```
 0 REFR   1 ACHR   2 PMIS   3 PGRE   4 PBEA   5 PFLA   6 CELL   7 INFO
 8 QUST   9 NPC_  10 ACTI  11 TACT  12 ARMO  13 BOOK  14 CONT  15 DOOR
16 INGR  17 LIGH  18 MISC  19 APPA  20 STAT  21 MSTT  22 FURN  23 WEAP
24 AMMO  25 KEYM  26 ALCH  27 IDLM  28 NOTE  29 ECZN  30 CLAS  31 FACT
32 PACK  33 NAVM  34 WOOP  35 MGEF  36 SMQN  37 SCEN  38 LCTN  39 RELA
40 PHZD  41 PBAR  42 PCON  43 FLST  44 LVLN  45 LVLI  46 IDLM  47 PROJ
```

A typical mid-game save is mostly `REFR`, then `ACHR`, `INFO` and `QUST`.

## Change flags

The authoritative list is `CHANGE_TYPES` in CommonLibF4,
`CommonLibF4/include/RE/Bethesda/TESForms.h`. Fetch the current values rather than
trusting a wiki:

```bash
gh api repos/Ryan-rsm-McKenzie/CommonLibF4/contents/CommonLibF4/include/RE/Bethesda/TESForms.h \
  --jq '.content' | tr -d '\n' | base64 -d | grep -n -A90 'struct CHANGE_TYPES'
```

xEdit is the better source, because it lists the flags **per change form type** -
which is the thing that actually matters, since bit 11 means something different on
an `ACHR` than on an `NPC_`. `Core/wbDefinitionsFO4Saves.pas` has `wbChangeTypes`
(the type enum, confirming `09 = NPC_`) and a `wbChangeFlagsNNN` block per type:

```bash
gh api repos/TES5Edit/TES5Edit/contents/Core/wbDefinitionsFO4Saves.pas --jq '.content' | tr -d '\n' | base64 -d > fo4saves.pas
grep -n 'wbChangeTypes :=' -A 55 fo4saves.pas      # type enum
grep -n 'wbChangeFlags009 :=' -A 22 fo4saves.pas   # flags for NPC_
```

The one people ask about most: `kNPCFace = 1u << 11` (0x800) on an `NPC_` record
means the face was edited in game and baked into the save. Addictol's `bFacegen`
refuses to use pre-generated FaceGen for such an NPC, and LooksMenu/`slm` is what
sets it - so "fixing" a dark face with `slm` permanently opts that NPC out of
whatever FaceGen you baked.

## Walker

Reports the plugin list and every `NPC_` carrying a given change flag. Change the
filter for other questions.

```powershell
param([Parameter(Mandatory)][string] $Path, [int] $Flag = 0x800, [int] $Type = 9)

$b = [System.IO.File]::ReadAllBytes($Path)
$script:p = 0
function Take([int]$n) { $s = $script:p; $script:p += $n; $s }
function U8   { $b[(Take 1)] }
function U16  { [BitConverter]::ToUInt16($b, (Take 2)) }
function U32  { [BitConverter]::ToUInt32($b, (Take 4)) }
function WStr { $n = U16; $o = Take $n; [Text.Encoding]::UTF8.GetString($b, $o, $n) }

if ([Text.Encoding]::ASCII.GetString($b, (Take 12), 12) -ne 'FO4_SAVEGAME') { throw 'not a FO4 save' }
$hs = U32; $start = $script:p
$shotW = [BitConverter]::ToUInt32($b, $start + $hs - 8)
$shotH = [BitConverter]::ToUInt32($b, $start + $hs - 4)
$script:p = $start + $hs + $shotW * $shotH * 4

$null = U8; $gameVersion = WStr
$size = U32; $after = $script:p + $size
$full = @(1..(U8) | ForEach-Object { WStr })
$lc = U16; if ($lc -gt 0 -and $lc -lt 4096) { $null = @(1..$lc | ForEach-Object { WStr }) }
$script:p = $after                      # pluginInfoSize includes the ESL list

$formIDArrayOffset = U32
$null = U32; $null = U32; $null = U32
$changeFormsOffset = U32
$null = U32; $null = U32; $null = U32; $null = U32
$changeFormCount = U32

$script:p = [int] $formIDArrayOffset
$n = U32
$formIDs = New-Object uint32[] $n
for ($i = 0; $i -lt $n; $i++) { $formIDs[$i] = [BitConverter]::ToUInt32($b, (Take 4)) }

$script:p = [int] $changeFormsOffset
"$($full.Count) full plugins, $lc light, game $gameVersion, $changeFormCount change forms"

for ($i = 0; $i -lt $changeFormCount -and $script:p + 10 -lt $b.Length; $i++) {
    $b0 = $b[(Take 1)]; $b1 = $b[(Take 1)]; $b2 = $b[(Take 1)]
    $v = ((($b0 -band 0x3F) -shl 16) -bor ($b1 -shl 8) -bor $b2)
    $id = switch ($b0 -shr 6) {
        0 { if ($v -lt $n) { $formIDs[$v] } else { 0 } }
        1 { $v }
        2 { 0xFF000000 -bor $v }
        default { $v }
    }
    $flags = U32
    $tb = $b[(Take 1)]; $null = $b[(Take 1)]
    switch ($tb -shr 6) {
        0 { $l1 = $b[(Take 1)]; $null = $b[(Take 1)] }
        1 { $l1 = U16; $null = U16 }
        default { $l1 = U32; $null = U32 }
    }
    $script:p += $l1

    if (($tb -band 0x3F) -eq $Type -and ($flags -band $Flag)) {
        $mi = $id -shr 24
        $src = if ($id -eq 7) { 'THE PLAYER' } elseif ($mi -lt $full.Count) { $full[$mi] } else { "modindex 0x{0:X2}" -f $mi }
        '{0:X8}  flags 0x{1:X8}  {2}' -f $id, $flags, $src
    }
}
```

## Cross-checking

The plugin list in the save is the load order the save was made with. Comparing it
with the current `plugins.txt` explains a lot of "it worked yesterday": a plugin
that moved changes every FormID whose mod index points past it.

`gameVersion` in the save is the build that wrote it. A save written by a different
build than the exe currently in the game folder is worth flagging - after a
downgrade, old saves still carry the old string.
