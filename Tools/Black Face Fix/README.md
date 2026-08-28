# Black Face Fix 4

Resizes Fallout 4 face textures so head textures and tint masks line up, which is
what the black/dark face bug actually comes down to.

Rebuilt from KLMX's V3 Alpha 1 ([Nexus 21907](https://www.nexusmods.com/fallout4/mods/21907)).
The original tool did not resize specular maps at all, and re-encoded correct
textures on every run.

---

## Requirements

Nothing to install. Everything it needs is already on any machine that runs
Fallout 4:

* **Windows 10 (1607 or newer) or Windows 11.** Windows PowerShell 5.1 ships with
  both and is what the launchers use, so the tool works even if you have never
  touched PowerShell. Windows 8.1 and older will not work: the code uses PowerShell
  classes, which need 5.0+.
* **.NET Framework 4.x** for the window. Built into Windows 10 and 11.
* **Visual C++ 2015-2022 Redistributable (x64)** for `texconv`/`texdiag`. Fallout 4
  installs this itself through Steam, so it is effectively always present. If it is
  not, the tool says so in one clear message instead of failing on every texture.

Mod Organizer 2 is optional - without it the game's own Data folder is scanned. The
tool does not have to be run through MO2; it reads `ModOrganizer.ini` and
`modlist.txt` directly.

`texconv.exe` and `texdiag.exe` are bundled, so there is nothing to fetch. If you
would rather keep your own copies current:

```
winget install Microsoft.DirectXTex.Texconv
winget install Microsoft.DirectXTex.Texdiag
```

They are picked up automatically when the `MSFT` folder is empty, and set
`Conversion.PreferSystemTools = $true` in `Config\Settings.psd1` to prefer them over
the bundled copies. Winget installs into
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\Microsoft.DirectXTex.*`, which is searched
directly - so it works even in a shell that started before the install and does not
have the new PATH yet.

Do not run it as administrator. It does not need it.

## Quick start

1. Run `Launcher-GUI.bat` (window) or `Launcher.bat` (console).
2. Press **Scan**. Nothing is written yet - you get a table of every texture with its
   current size, its current format, the target, and the reason.
3. Press **Apply** if the plan looks right.
4. In Mod Organizer press **F5**, tick each new `[face-...]` mod, and drag each one
   directly below the mod it was made from.

To undo everything: disable the `[face-...]` mods.

### Reading the table

Every row carries a mark in front of its reason. They are a system rather than six
unrelated pictures: **the outline says the size changes, the fill says the format
does**, and a row doing both gets both.

| Mark | Meaning |
|------|---------|
| grey tick | already matches the profile, nothing is written |
| blue outline, blue block | the size is wrong; the format is kept |
| grey outline, amber block | the size is right; the format is re-encoded |
| blue outline, amber block | both are wrong |
| orange bar | left alone on purpose - look at this one yourself |
| red cross | could not be read or planned |

Hovering a mark says what it means and why that row got it. Hovering any other cell
shows the full source path, destination and reason, which is how you read the two
path columns without turning them on.

---

## Using it with Mod Organizer 2

**You do not launch this through MO2.** It is not a game plugin - it reads
`ModOrganizer.ini` and `modlist.txt` off disk and works on the mod folders directly.
Running it from MO2's executable list works too, but it changes nothing.

### Where to put it

Either is fine:

* **Anywhere on disk** (Desktop, a tools folder). It finds MO2 by itself.
* **As a mod**, so it travels with your setup: install the archive so you get
  `<MO2>\mods\BlackFaceFix\Tools\Black Face Fix\...`, then run the launcher from
  that folder. When it lives under `<MO2>\mods\...` it recognises the MO2 instance
  from its own location. The mod itself can stay **disabled** in the mod list -
  it contains no game assets.

If it cannot find MO2, use the **...** button next to "Mod Organizer" and pick the
folder that holds `ModOrganizer.ini`, or set `Paths.MO2` in `Config\Settings.psd1`.

### Which mods get scanned

The **active MO2 profile** decides. The tool reads `selected_profile` from
`ModOrganizer.ini` and then that profile's `modlist.txt`, and by default only scans
mods enabled with `+`. Switching profiles in MO2 changes what the tool sees, so run
it again after switching. `overwrite\` is included as well.

Untick **Only enabled mods** to scan every folder under `mods\`, including disabled
ones. Set `Paths.MO2Profile` in `Config\Settings.psd1` to pin a specific profile.

### After a run

You get **one output mod per source mod**, named after it:

```
Botox for Fallout 4
Botox for Fallout 4 [face-Vanilla]
```

One folder per source mod, not one per texture: a run that fixes three files in
two mods creates two folders.

1. In MO2 press **F5** (or the refresh arrows) - the new mods appear as unmanaged.
2. Tick each of them.
3. Drag each one **directly below the mod it was made from**.
4. They need no plugin and no entry in the load order on the right.

Typing `[face-` in MO2's search box filters the list down to exactly these folders,
which beats scrolling a load order of several hundred mods looking for them. It is
also the quickest way to find them all again later - to tick them, to disable a
profile you have stopped using, or to delete the lot and start over.

That last step is the whole point of splitting them up. A single shared output mod
has to sit at the bottom to work, which means it also overrides mods that have
nothing to do with it - and when two mods ship the same face texture, whichever the
scan reached last would win regardless of your MO2 priority. Per-mod folders keep
the conflict resolution you already have.

Because the fixes live beside their sources, those sources are still exactly as you
installed them. Reinstalling or updating one does not undo the fix and does not
fight with it - just run the tool again afterwards.

**To undo everything:** disable or delete the `[face-...]` mods.

Each generated folder gets a `BlackFaceFix-generated.txt` at its root saying which
mod and profile it came from, and that is how the tool recognises its own output -
not the folder name. Name matching would be wrong here: with `[face-Vanilla]` as
the decoration, a rule loose enough to catch it also catches real mods called
`Some Armour [2K]`, which would then be silently skipped. Delete that marker and
the folder gets scanned as a normal mod again.

The profile is part of the name so switching profiles gives you a second folder
(`[face-Vanilla]` and `[face-HD DLC]`) rather than a silent overwrite. Disable the
one you are not using.

If you would rather have the originals overwritten, switch **Write to** to
*In place*. Every changed file then gets a `<name>.dds.backup` next to it, and
**Restore backups** puts them all back.

---

## What decides the sizes

Profiles live in `Profiles\*.psd1` and hold nothing but sizes:

| Profile | diffuse | normal | specular | f4ee.ini uTintWidth/Height |
|---------|---------|--------|----------|----------------------------|
| Vanilla | 1024    | 1024   | **512**  | 1024 |
| HD DLC  | 1024    | 1024   | 1024     | 1024 |
| 2K      | 2048    | 2048   | 2048     | 2048 |
| 4K      | 4096    | 4096   | 4096     | 4096 |

The specular being 512 while diffuse and normal are 1024 is not a mistake - that is
what the base game ships. Since patch 1.9.4 the engine forces head speculars to 1024
as soon as `DLCUltraHighResolution` is an enabled plugin, and a mod that still has a
512 specular then mismatches the 1024 tint specular.

`Profile = 'Auto'` in `Config\Settings.psd1` picks the profile from two signals:

* whether `DLCUltraHighResolution` is present and enabled, and
* LooksMenu's `[CharGen] uTintWidth`, which is the resolution tint masks are
  actually rendered at.

If those two disagree with the profile you picked, you get a warning rather than a
silent mismatch. When several mods ship an `f4ee.ini`, the winner is resolved by MO2
priority and named in the report.

---

## What decides the formats

`Rules\SlotRules.psd1`, shared by all profiles. The rule is: **keep the source format
when it is valid for the slot**, and only convert when it is not.

| Slot | Suffixes | Valid formats |
|------|----------|---------------|
| Diffuse | `_d`, `_diffuse`, none | BC1 / BC3 / BC7, with or without `_SRGB` |
| Normal | `_n`, `_normal` | BC5 |
| ModelSpaceNormal | `_msn` | BC1 / BC3 / BC7 - an `_msn` map stores all three axes, so BC5 would throw the blue one away |
| Specular | `_s`, `_spec`, `_specular` | BC5 |
| Skin | `_sk`, `_sss`, `_c` | anything, and the size is left alone too - these take no part in the head/tint matching |

Bethesda ships BC7 face diffuses, the CK wiki asks for BC1, and mods use BC3 when
they need alpha. All three are correct, so all three are kept.

### Forcing the formats the game ships

Tick **Force vanilla formats**, pass `-VanillaFormats`, or set
`Conversion.ForceVanillaFormats = $true`, and the "keep any valid format" rule is
narrowed to the single format Fallout 4 itself uses for that slot.

The engine builds a face from four texture arrays, and a texture array needs every
slice at the same size, format and mip count. Measured against the game's own
archives, vanilla holds to that without a single exception:

| Array | Where it lives | Size | Format | Mips |
|-------|----------------|------|--------|------|
| Mask | `Character Assets\TintMasks` (57 files) | 1024 | BC1 | 1 |
| Diffuse | `Character Assets\FaceDetails\*_d` (146) | 1024 | BC3 | 11 |
| Normal | `…\FaceDetails\*_n` (89) | 1024 | BC5 | 11 |
| Specular | `…\FaceDetails\*_s` (80) | 512 | BC5 | 10 |

So keeping a mod's own valid-but-different format can leave an array holding BC1
next to BC7, which is the thing that cannot work.

It is **off by default**, and should stay off unless you are chasing a specific
face. Which textures actually share an array is decided by the tint records in the
plugin, not by the folder a file sits in. Looks Menu Customization Compendium ships
209 overlays under `FaceDetails` as BC1 with a single mip - the TintMasks profile
rather than the FaceDetails one - and those faces are not black, so those overlays
evidently live in an array of their own. Forcing them to BC3 would make them the odd
one out instead of fixing anything.

Slots whose valid-format list is `*` - skin and subsurface maps - are never touched
by this. They take no part in the matching.

Mip counts are reported (`SourceMips` in the CSV) but not enforced.

---

## What counts as a face texture

Three layers, in order:

1. **`Rules\VanillaFaceTextures.psd1`** - the exact paths the game's own `TXST`
   records declare as face texture sets, baked out of `Fallout4.esm`. This is what
   catches `Preston_d.dds`, `Mayor_s.dds` and Piper's set, none of which have "head"
   in the file name.
2. **`FaceDetails` and `TintMasks`** - everything underneath counts.
3. **file name contains `head`** - anywhere else under `textures\actors\character`.

`Hair\` and `Eyes\` are excluded. Hair because `Headgear01_d.dds` matches the head
pattern and hair colour lookup tables live there; eyes because they are a separate
texture set in the game's records and `HumanEyesRedHead.dds` matches "head" by
accident.

Body, hands, brows and mouth textures sit in the same folders as head textures and
run up to 8192px. None of them contain "head", so none of them are ever matched.

Anything non-square, or smaller than 256px, is reported as **Review** and never
touched - those are lookup tables and palette strips, not faces.

---

## BA2 archives

Archives are read but **never repacked**. For `DX10` archives the size and format sit
in the file table, so a mismatch is reported without unpacking anything.

Tick **Fix the ones inside BA2s** in the window, pass `-FixArchives`, or set
`Scope.FixArchives = $true`, and the mismatching textures are extracted, converted,
and written into that mod's output folder as loose files. Loose files win over
archives in Fallout 4, so the archive and the mod it belongs to are left completely
alone.

BA2 versions 1, 7 and 8 are supported (7 and 8 are the next-gen update; they use the
same 24-byte header and the same record layout as version 1). Next-gen archives that
use LZ4 chunk compression can be reported but not extracted.

---

## Command line

```
Launcher.bat -DryRun                    scan and report, write nothing
Launcher.bat -ProfileName "HD DLC"      override the detected profile
Launcher.bat -Yes                       skip the confirmation prompt
Launcher.bat -Force                     re-encode even correct textures
Launcher.bat -VanillaFormats            use the format the game ships, not any valid one
Launcher.bat -OutputMode InPlace        overwrite originals, keep <name>.backup
Launcher.bat -Restore                   put every .backup back
Launcher.bat -All                       print every row, not just the first 60
Launcher.bat -NoArchives                skip the BA2 pass
Launcher.bat -FixArchives               also fix face textures found inside BA2s
Launcher.bat -Gui                       open the window
```

Every run writes `Logs\BlackFaceFix_<timestamp>.csv` with one row per texture:
source size, source format, target, action, and the reason.

---

## Notes on the tools

`MSFT\texconv.exe` and `MSFT\texdiag.exe` are Microsoft's
[DirectXTex](https://github.com/microsoft/DirectXTex) command line tools, MIT
licensed.

Resizing is done in two texconv passes - resize to a single uncompressed level, then
rebuild the mip chain and encode. The 2017-era texconv that shipped with V3 cannot
resize a DDS that already has mipmaps (`FAILED [mipmaps] (80070057)`), and nearly
every face texture has them. The two-pass route works on any texconv build and costs
nothing in quality: the source is decoded once and block-compressed once either way.

The flag for exhaustive BC7 compression was renamed between builds (`-bcmax` became
`-bc x`), so the tool probes `texconv --help` once per run and uses whichever it
finds.

texconv takes many input files per call, and doing so is far faster than one process
per file: eight files took 294 ms as eight calls against 90 ms as one. So textures
sharing a target size and format go through together, and each batch is verified in
a single texdiag pass. Anything a batch could not produce or verify is retried on its
own, so an error lands on the file that caused it rather than on the whole group.
Running several texconv processes in parallel instead tops out around 1.7x on 20
cores and gets worse past four, which is why batching is the lever and concurrency
is not.

The window icon and the row marks are drawn at run time rather than shipped as image
files, so the repository stays plain text. See `PS\Lib\Icon.ps1` - the shape is
defined in the same place it is described.

---

## Credits

Original tool by KLMX. Texture-size research by ousnius. `texconv` / `texdiag` by
Microsoft. Size and format reference: the
[CK wiki Dark Face Bug page](https://fallout.wiki/wiki/Resource:Creation_Kit/Actor/Dark_Face_Bug).
