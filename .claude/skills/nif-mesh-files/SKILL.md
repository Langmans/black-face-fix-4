---
name: nif-mesh-files
description: Read and inspect .nif mesh files (NetImmerse/Gamebryo) from Skyrim, Fallout 4 and related games. Use when you need to find extra data attached to a mesh (heel heights, HH_OFFSET, SDTA transform overrides), list block types or node names, check what shapes a mesh contains, or parse meshes from C#. Covers a fast header-only scan and the NiflySharp library.
---

# Reading .nif mesh files

Two levels. Use the cheapest one that answers the question.

- **"Does this mesh mention X at all?"** → parse the header only. It sits in the first few KB and
  already contains every block *type* name and every *string* the file uses. A one-megabyte outfit
  mesh can be rejected without reading past the header.
- **"What is the value of X?"** → parse fully with NiflySharp.

## Header layout (Fallout 4 / Skyrim SE, file version 20.2.0.7)

Verified against real Fallout 4 meshes. All integers little-endian.

```
char[]    header string, terminated by \n     "Gamebryo File Format, Version 20.2.0.7"
uint32    version                              0x14020007
uint8     endianness                           1 = little
uint32    user version                         12 for FO4/SSE
uint32    block count
uint32    BS version                           130 = FO4, 132 = FO4 VR, 100 = SSE

  export strings, each: uint8 length, then that many bytes INCLUDING a terminator
uint8+    author
uint32    unknown            <- only when BS version > 130
uint8+    process script
uint8+    export script
uint8+    max filepath       <- only when BS version == 130

uint16    block type count
  { uint32 length, that many chars, NO terminator } x block type count
uint16    block type index    x block count
uint32    block size          x block count      <- present from version 20.2.0.5 onward
uint32    string count
uint32    max string length
  { uint32 length, that many chars, NO terminator } x string count
uint32    group count
uint32    group               x group count

... then the block data, in order, each block size bytes long
```

Two different string encodings in one header — export strings are byte-length-prefixed *and*
zero-terminated; header/block-type strings are uint32-length-prefixed with no terminator. Mixing
them up desyncs the parse.

A real FO4 header decodes to something like:

```
headerString  = "Gamebryo File Format, Version 20.2.0.7"
version       = 0x14020007, userVersion = 12, blockCount = 145, bsVersion = 130
blockTypes    = NiNode, BSSubIndexTriShape, BSSkin::Instance, BSSkin::BoneData,
                BSLightingShaderProperty, BSShaderTextureSet, NiAlphaProperty, NiStringExtraData
strings       = Scene Root, LLeg_Foot, RLeg_Foot, ..., Shoes
```

Node names, shape names, bone names and extra-data names all live in that one string table. So
"is there a `NiFloatExtraData` named `HHS` in here" is answerable from the header alone: check the
block type table for `NiFloatExtraData` and the string table for `HHS`. Both present is a
*maybe*; either missing is a definite no, which is the cheap and common case.

Be lenient on failure: if the header does not parse, fall through to the full parser rather than
reporting "no". Unusual but valid meshes exist.

## Full parsing: NiflySharp

NuGet package id is **`Nifly`** (the assembly and namespace are `NiflySharp`). Pure managed,
targets `net8.0` and `net10.0`, supports Fallout 3/NV/4/4VR/76 and the Skyrim line.

Do not confuse it with the NuGet package `niflysharp` (lowercase id), which is a SWIG binding over
the C++ `nifly` library with a native x64 DLL and a completely different API (`BlockCache`,
`niflycpp`, `IDisposable` string handles). The Skyrim patcher `TokcDK/SynHeelsSoundAdd` uses that
older one; its code does not port over directly.

```xml
<PackageReference Include="Nifly" Version="1.1.0" />
```

```csharp
using NiflySharp;
using NiflySharp.Blocks;

var nif = new NifFile();
if (nif.Load(stream) != 0) return;      // 0 = success, non-zero = failed

// Every block, typed
foreach (var extra in nif.Blocks.OfType<NiFloatExtraData>())
    Console.WriteLine($"{extra.Name?.String} = {extra.FloatData}");

foreach (var extra in nif.Blocks.OfType<NiStringExtraData>())
    Console.WriteLine($"{extra.Name?.String} = {extra.StringData?.String}");
```

Useful API surface:

| Member | Notes |
|---|---|
| `Load(string)` / `Load(Stream)` | returns 0 on success. The `Stream` overload is what you want for BA2/BSA entries |
| `Blocks` | `List<INiObject>`; `OfType<T>()` is the simplest way to find anything |
| `GetBlock<T>(int)` / `GetBlock<T>(INiRef)` | resolve a block reference, null on type mismatch |
| `FindBlockByName<T>(string)` | first block of type T with that name |
| `GetRootNode()` / `GetRootNodes()` | the `NiNode` at index 0, or the first one found |
| `GetShapes()` | `IEnumerable<INiShape>` — trishapes only, not plain NiNodes |
| `GetParentNode(block)` | walk upward |
| `INiNamed.Name` | a `NiStringRef`; read the text via `.String` |

Field naming: nif.xml names with spaces lose them and get PascalCased, so `Float Data` becomes
`FloatData` and `String Data` becomes `StringData`. `::` in a type name becomes `_`
(`BSSkin::Instance` → `BSSkin_Instance`).

There is no header-only load option — `Load` parses every block and runs `PrepareData()`. That is
why the header prescan is worth doing, and why results should be cached per path when several
records share one mesh.

Streams from archives are not necessarily seekable. Copy to a `MemoryStream` first if you want to
both prescan and fully parse.

## Where high-heel data lives, per framework

| Framework | Game | Block | Name | Value |
|---|---|---|---|---|
| HHS (Fallout 4 High Heels System) | FO4 | `NiFloatExtraData` | `HHS` | `FloatData` = height |
| RaceMenu / hdtHighHeels | Skyrim | `NiFloatExtraData` | `HH_OFFSET` | `FloatData` = offset |
| NiOverride High Heels (NIOVHH) | Skyrim | `NiStringExtraData` | `SDTA` | JSON: `[{"name":"NPC","pos":[0,0,<Z>]}]`, Z is the offset |

For the `SDTA` payload, parse the JSON properly rather than regexing it — the array can hold
multiple entries and `rot`/`scale` keys, and Z can be negative. Parse floats with
`CultureInfo.InvariantCulture`; these strings are authored on machines with any decimal separator.

Extra data can hang off a shape *or* off the root `NiNode` or a bone node. Scanning
`nif.Blocks.OfType<T>()` covers all of them; walking only `shape.ExtraData` misses meshes that put
it on the root, which is common.

**The block has to be attached to something.** HHS (`Skeleton::Reader::Visit` in
[P-K-0/HHS](https://github.com/P-K-0/HHS)) walks the node tree from the root objects and only reads
extra data hanging off each `NiAVObject`. A block that exists in the file but is not referenced from
any node's extra data list is invisible to it — and that is exactly what NifSkope's "insert block"
leaves behind if the user forgets to link it. Verify with `nif.GetBlockIndex(block, out var i)` plus
`nif.IsBlockReferenced(i)` before trusting a value.

### HHS lookup order (Fallout 4)

Reading the plugin source is the only reliable way to get this right. `Cache::Map::Find` tries the
nif extra data first and only falls back to the txt file when that returns zero — but the json
entries are pre-seeded into the same cache at load time and the first write wins, so the effective
order is:

1. **json** — `Data\F4SE\Plugins\HHS\*.json`
2. **nif** — `NiFloatExtraData` named `HHS`
3. **txt** — `<mesh>.txt`, then a flat fallback at `Data\F4SE\Plugins\HHS\<basename>.txt`

A height of exactly `0` means "no heel" everywhere in HHS, not "zero height".

The txt parser is `regex_search` on `height\s*=\s*(-?(?:\d*\.\d+|\d+))`, case insensitive — so
negatives are allowed and the key can sit anywhere in the file.

In the json form, an entry with a non-empty `key` is a mesh path; otherwise `formid` is looked up
as an **ArmorAddon** (`TESObjectARMA`, not an Armor) and its world model path is used, so both
forms end up keyed on a mesh path. `gender` picks the model: 0 male, 1 female, 2 both, 3 an object
modification's material swap model.

Mesh paths are normalised by `File::GetRelativeDir`: keep a leading `meshes\`, strip a leading
`data\`, otherwise prepend `meshes\`.

## Quick inspection without C#

Dumping the printable strings near the start of the file shows the block type table and string
table, which is usually enough to answer "what is in this mesh":

```powershell
$b = [System.IO.File]::ReadAllBytes("mesh.nif")
$s = [System.Text.Encoding]::ASCII.GetString($b, 0, [Math]::Min(4000, $b.Length))
[regex]::Matches($s, '[ -~]{4,}') | ForEach-Object { $_.Value } | Select-Object -First 40
```

`rg` is a poor tool here: on a binary file the whole thing counts as one line, so `-c` always
reports 1 and `-l` is all-or-nothing.

## Finding meshes on disk

Mesh paths on records are relative to `meshes\`, but some mods store the prefix in the record
anyway — prepend it only when it is missing, and normalise `/` to `\` before comparing.

Meshes may be loose or inside a BA2/BSA. In Mutagen:

```csharp
foreach (var path in Archive.GetApplicableArchivePaths(GameRelease.Fallout4, dataFolder))
{
    var reader = Archive.CreateReader(GameRelease.Fallout4, path);
    foreach (var file in reader.Files) { /* file.Path, file.AsStream() */ }
}
```

Mutagen's built-in `ArchiveAssetProvider` re-opens every applicable archive on every lookup, which
is far too slow for hundreds of meshes — build one path→entry index up front and reuse it.

Under a virtual file system (MO2), the data folder only shows mod files when the process is
launched through the manager.
