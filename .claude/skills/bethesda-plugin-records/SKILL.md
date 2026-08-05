---
name: bethesda-plugin-records
description: Read and search records inside Bethesda plugin files (.esp/.esm/.esl) for Skyrim, Fallout 4 and Starfield. Use when you need to find a record, subrecord, script property or FormID in a plugin, inspect what a patch actually changed, look up which fields a record type has, or verify a generated patch. Covers both a no-build PowerShell binary walker and the Mutagen C# API.
---

# Reading Bethesda plugin records

Two ways in. Pick by whether you already have a compiled Mutagen project.

- **No build available / one-off lookup** → the PowerShell walker below. Works on any
  `.esp`/`.esm`/`.esl` straight off disk, needs nothing installed.
- **Inside a patcher** → the Mutagen API.

## Plugin binary format (all Bethesda games from Skyrim onward)

Everything is a flat stream of two structures.

```
Record          Group (GRUP)
  0  char[4]   type            0  char[4]  "GRUP"
  4  uint32    dataSize        4  uint32   groupSize   <- INCLUDES the 24-byte header
  8  uint32    flags           8  char[4]  label
 12  uint32    formID         12  uint32   groupType
 16  uint32    versionControl 16  uint16   stamp
 20  uint16    formVersion    18  uint16   unknown
 22  uint16    vc2            20  uint16   version
                              22  uint16   unknown
 24  <dataSize bytes>         24  <groupSize - 24 bytes of children>
```

Record header is 24 bytes and `dataSize` does **not** include it, so the next sibling is at
`p + 24 + dataSize`. Group header is 24 bytes and `groupSize` **does** include it, so the next
sibling is at `p + groupSize`.

Inside a record's data, subrecords are:

```
 0  char[4]   type      e.g. EDID, FULL, VMAD, SNDD
 4  uint16    length    of the payload only
 6  <length bytes>
```

Strings in subrecords are zero-terminated, so a `char[]` payload of length `n` holds `n-1`
characters.

Things that will bite you:

- **Compressed records.** Flag `0x00040000` means the data is zlib-compressed, prefixed by a
  uint32 decompressed size. Skip those records unless you decompress them.
- **XXXX overflow.** A subrecord of type `XXXX` carries a uint32 that is the real length of the
  *next* subrecord, whose own length field reads 0. Handle it or you will desync.
- **The file header.** The first record is `TES4`; start walking at `24 + its dataSize`.
- **FormIDs are load-order relative.** The top byte is an index into that plugin's master list
  (`MAST` subrecords in the `TES4` header, in order). The plugin's own records use the index one
  past the last master. So `SNDD=030026D8` means "FormID `0026D8` in master[3]".
- **ESL / light plugins** use `FE` plus a 12-bit slot in the top of the FormID.

### PowerShell walker (no build required)

Drop-in template. Change the `if` in the record branch to select what you want.

```powershell
$f = "C:\path\to\plugin.esp"
$b = [System.IO.File]::ReadAllBytes($f)

# --- masters, in order: FormID top byte indexes into this list ---
$hs = [BitConverter]::ToUInt32($b, 4)      # TES4 dataSize
$q = 24; $i = 0
while ($q -lt 24 + $hs) {
  $st = [System.Text.Encoding]::ASCII.GetString($b, $q, 4)
  $sl = [BitConverter]::ToUInt16($b, $q + 4)
  if ($sl -eq 0) { break }
  if ($st -eq 'MAST') {
    Write-Output ("master[{0}] {1}" -f $i, [System.Text.Encoding]::ASCII.GetString($b, $q + 6, $sl - 1))
    $i++
  }
  $q += 6 + $sl
}

function Walk($start, $end) {
  $p = $start
  while ($p -lt $end) {
    $t = [System.Text.Encoding]::ASCII.GetString($b, $p, 4)
    if ($t -eq 'GRUP') {
      $gs = [BitConverter]::ToUInt32($b, $p + 4)
      Walk ($p + 24) ($p + $gs)
      $p += $gs
    }
    else {
      $ds  = [BitConverter]::ToUInt32($b, $p + 4)
      $fl  = [BitConverter]::ToUInt32($b, $p + 8)
      $fid = [BitConverter]::ToUInt32($b, $p + 12)

      if ($t -eq 'ARMA' -and (($fl -band 0x00040000) -eq 0)) {   # skip compressed
        $q2 = $p + 24; $edid = ''; $sndd = ''
        while ($q2 -lt $p + 24 + $ds) {
          $st = [System.Text.Encoding]::ASCII.GetString($b, $q2, 4)
          $sl = [BitConverter]::ToUInt16($b, $q2 + 4)
          if ($sl -eq 0) { break }
          switch ($st) {
            'EDID' { $edid = [System.Text.Encoding]::ASCII.GetString($b, $q2 + 6, $sl - 1) }
            'SNDD' { $sndd = "{0:X8}" -f [BitConverter]::ToUInt32($b, $q2 + 6) }
          }
          $q2 += 6 + $sl
        }
        Write-Output ("  {0} {1:X8} {2,-34} SNDD={3}" -f $t, $fid, $edid, $sndd)
      }

      $p += 24 + $ds
    }
  }
}

Walk (24 + $hs) $b.Length
```

For a quick "does this string appear at all" check, dumping printable runs is often enough:

```powershell
$b = [System.IO.File]::ReadAllBytes($f)
$s = [System.Text.Encoding]::ASCII.GetString($b)
[regex]::Matches($s, '[ -~]{4,}') | ForEach-Object { $_.Value } | Select-Object -First 100
```

Note that `strings` is not present in Git Bash on Windows, and `rg` on binary files reports the
whole file as one line, so counts are meaningless — use the PowerShell approach.

## Looking up what fields a record type has

**The fastest reference is Mutagen's own record definitions**, not a wiki. Clone the repo and read
the XML — one file per record type, listing every field with its subrecord type:

```
Mutagen.Bethesda.<Game>/Records/Major Records/<RecordType>.xml
Mutagen.Bethesda.<Game>/Enums/*.cs                     <- flag enums
Mutagen.Bethesda.<Game>/Records/Common Subrecords/*.xml <- VMAD, BodyTemplate, Model, ...
```

```bash
git clone -c core.longpaths=true --depth 1 https://github.com/Mutagen-Modding/Mutagen.git
```

Clone to a **short path** (`C:\work\Mutagen`); the default deep paths break checkout on Windows
unless `core.longpaths=true` is set, and even then a long parent directory will fail.

Example: `ArmorAddon.xml` has `<FormLink name="FootstepSound" refName="FootstepSet" recordType="SNDD" />`,
which tells you the C# property name, the target type, and the 4-byte subrecord to look for in a
binary dump — all at once.

## Mutagen API

```csharp
// Iterate the winning version of every record of a type
foreach (var armor in state.LoadOrder.PriorityOrder.Armor().WinningOverrides()) { }

// Resolve a link
if (armature.ArmorAddon.TryResolve(state.LinkCache, out var addon)) { }

// Write: get a mutable override in the patch mod, then change it
state.PatchMod.ArmorAddons.GetOrAddAsOverride(addon).FootstepSound.SetTo(someLink);
```

Namespaces that are easy to miss — both `TryResolve` and `GetOrAddAsOverride` are extension
methods in plain `Mutagen.Bethesda`, not in the `.Plugins.*` sub-namespaces:

```csharp
using Mutagen.Bethesda;                 // TryResolve, GetOrAddAsOverride, IGroupMixIns
using Mutagen.Bethesda.Fallout4;        // record types + LoadOrder.Armor() etc
using Mutagen.Bethesda.Plugins;         // FormKey, ModKey, IFormLinkGetter
using Mutagen.Bethesda.Plugins.Cache;   // ILinkCache
```

Masters are derived automatically from the FormKeys you reference — you never edit a master list.

### Script properties (VMAD)

```csharp
foreach (var script in armor.VirtualMachineAdapter?.Scripts ?? [])
{
    if (!script.Name.Equals("HHSOutfit3", StringComparison.OrdinalIgnoreCase)) continue;
    foreach (var property in script.Properties)
    {
        if (property is IScriptFloatPropertyGetter f && property.Name == "HHSHeight")
            Console.WriteLine(f.Data);
    }
}
```

Property subtypes: `ScriptFloatProperty` / `ScriptIntProperty` / `ScriptBoolProperty` /
`ScriptStringProperty` / `ScriptObjectProperty` (has `.Object`, a FormLink) and the `*ListProperty`
variants. `script.Name` is sometimes stored as `Namespace:Script`, so compare on the part after the
last colon.

In a binary dump a float property looks like: property name string, flags byte, type byte `04`,
status byte `01`, then 4 bytes of IEEE float.

### Gendered fields

`WorldModel`, `SkinTexture` and friends are `IGenderedItemGetter<T>` with `.Male` / `.Female`.
Both can be null independently:

```csharp
var meshPath = addon.WorldModel?.Female?.File;   // string, relative to meshes\
```

### Duplicating records to drop a master

If you need the patch to stop depending on a plugin, duplicate everything it references into the
patch and remap:

```csharp
state.PatchMod.DuplicateFromOnlyReferenced(
    state.LinkCache, ModKey.FromFileName("Source.esm"), out var mapping, typeof(IArmorAddonGetter));
```

It follows links transitively, so a FootstepSet pulls in its Footsteps, their sound descriptors and
so on. The source plugin still has to be *loaded* for this to work.

## Verifying a generated patch

Round-trip it: run the PowerShell walker over the output and check the master list order plus the
FormIDs you expect. `SNDD=030026D8` reads as "`0026D8` in `master[3]`", so cross-check `master[3]`
against the list printed at the top.

Comparing against a hand-made patch for the same mod, if one exists, is the strongest check
available — it tells you not just that records were written but that the *right* ones were.
