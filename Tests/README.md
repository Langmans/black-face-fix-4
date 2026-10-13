# Tests

```powershell
.\Tests\Run-All.ps1                  # syntax, the three suites and the unit tests
.\Tests\Run-All.ps1 -Verbose         # plus each suite's own output
.\Tests\Run-All.ps1 -RequirePester   # fail rather than skip without Pester 5 (CI uses this)
```

695 checks, plus a skipped one on a machine without Fallout 4. Nothing touches your
real mods: the suites build a throwaway MO2 instance under
`%TEMP%\BlackFaceFix.Tests\` with a fake `ModOrganizer.ini`, `modlist.txt`, an
empty stand-in for the game folder and a mod full of deliberately awkward textures.

They need neither Fallout 4 nor any mod installed. The source image every test
texture is converted from is painted by the test itself, from a fixed seed, so two
runs build byte-identical textures.

| Script | What it covers |
|--------|----------------|
| `Verify-Console.ps1` | 39 checks. Dry run, apply, and a second apply that must be a no-op. Asserts the specular goes 1024 -> 512 with 10 mips, that BC1/BC3/BC7 diffuses are kept as they are, that a BC6H diffuse is re-encoded, that `_msn` and `Face_Specular.dds` are read correctly, that non-square textures are only flagged, and that body, hair and disabled-mod textures are never scanned. A second dry run with `-VanillaFormats` covers the other format policy: every slot must come out on one format, and skin maps must still be left alone. |
| `Verify-Gui.ps1` | 57 checks. Runs against the sandbox `Verify-Console.ps1` builds - never a real install, so the result does not depend on what happens to be installed. Builds the window and runs the scan under the same `Set-StrictMode` the entry script uses, via `Show-BffGui -BuildOnly -RunScan`. This is what catches empty collections unwrapping to `$null` and variable names colliding with parameter names. It also **paints** the grid through `DrawToBitmap` with a `DataError` handler attached, because a cell can hold a value it cannot format and the failure only surfaces at paint time; and it **raises `CellMouseEnter` by reflection** after `Show-BffGui` has returned, because WinForms raises that event from its own layout code, where a handler reading the function's local variables finds nothing. |
| `Verify-Ba2.ps1` | 35 checks against **real** BA2 archives: header and record layout for versions 1, 7 and 8, the size and format in DX10 file tables, extraction of zlib-compressed entries, and that the slot rules accept everything the game itself ships. Without Fallout 4 installed it reports one skip and nothing else. The reader itself is covered without the game by `Ba2.Tests.ps1`; what only this suite can show is that our picture of the game's own archives is right. |

## Unit tests

Pester 5, under Windows PowerShell 5.1. Windows itself ships Pester 3.4, which
these do not run on:

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -SkipPublisherCheck
```

| File | Covers | Coverage |
|------|--------|----------|
| `Ba2.Tests.ps1` | 52 tests of the archive reader on archives `TestBa2.ps1` writes byte for byte: DX10 and GNRL, versions 1, 7 and 8, zlib-compressed and stored, the versions and types it must refuse, archives and name tables cut short, the DDS header read out of a GNRL file in every format spelling, the header rebuilt for a DX10 texture, and extraction - ending with the real texdiag reading what was extracted. | 100% of `Ba2.ps1` |
| `Config.Tests.ps1` | 33 tests of loading the settings - defaults filled in per section and per key, `Settings.local.psd1` on top - the profiles, by name or by file name, and the slot rules, plus suffixes and slot resolution. The shipped files are loaded once each; how they are read is tested on small ones in TestDrive. | 100% of `Config.ps1` |
| `Convert.Tests.ps1` | 68 tests of the converter, with texconv and texdiag stood in for by a pair of fakes that write and read back small files stating a size and format: the flags per format and per texconv build (the bundled texconv is probed for real), the two-pass resize and the one-pass reformat, every check made before anything is placed, backups, markers, batching by target and by file name, a batch's failures retried one by one, and restoring backups. | 100% of `Convert.ps1` |
| `Discovery.Tests.ps1` | 55 tests of which files count as face textures: the three layers in order (the game's own list, the full-scan folders, the head name), what is never one (outside `actors\character`, hair, eyes, FaceGen, bodies, helper maps, FaceCustomization unless asked), and the walk over a small Mod Organizer install built in TestDrive - game data, mods, overwrite, enabled-only, excluded mods, the tool's own output, priorities, progress. BA2 contents with the archive reader mocked. | 100% of `Discovery.ps1` |
| `Environment.Tests.ps1` | 64 tests of finding the install, on ones built in TestDrive: the ini reader and Mod Organizer's value encoding, the game folder (setting, MO2, registry - mocked), the MO2 instance (setting, walking up, the old `MOInstall.txt`, app data) and the folders its ini moves, including onto a drive that is not plugged in, `modlist.txt`, the HD DLC, which `f4ee.ini` wins, which profile that adds up to, and the warnings when LooksMenu disagrees. | 100% of `Environment.ps1` |
| `GuiComponents.Tests.ps1` | 65 component tests of the window itself: built for real, then driven the way a user drives it - boxes ticked, a profile picked, buttons pressed through their protected `OnClick`, the row tooltip measured, sized and drawn through `OnCellMouseEnter`, `OnPopup` and `OnDraw`. The scan's data sources and the converter are mocked, and so is `Dialogs.ps1`, the one file that puts a dialog on screen: the tests replace the dialog hooks with recorders, so a run never opens a window on the desktop it runs on. | 100% of `Gui.ps1` |
| `GuiLogic.Tests.ps1` | 66 tests of what the window decides: the columns and the values in them, which mods are ticked and which rows that leaves, what the checkboxes mean for the settings, the status line and dialog texts, and how archive textures are sorted into fixed and reported. | 100% of `GuiLogic.ps1` |
| `Planner.Tests.ps1` | 65 tests of what happens to each texture and why, decided against the slot rules the tool ships: the safety rails (no slot rule, no size, not square, below the floor), skip, resize, reformat and both, `-Force`, skin maps keeping their size, BC4 tolerated for masks only, and `ForceVanillaFormats`. Also every reason sentence word for word, where the output goes (output mod, no MO2, in place, archives in place), the 260 character limit, the generated-mod marker, recognising an earlier run's output, and the summary counts. | 100% of `Planner.ps1` |
| `Report.Tests.ps1` | 32 tests of what a run tells you, read back from the log file the way you would read it: the banner, the setup and why that profile, the table of what changes with its row limit, the grouped reasons, what is left alone and what could not be read, the summary, the CSV column by column, and the log's encoding. | 100% of `Report.ps1` |
| `TexInfo.Tests.ps1` | 37 tests of finding texconv and texdiag - `Paths.TexTools`, the bundled copy, PATH, winget's package folder, `PreferSystemTools`, the cache, and the message when there is none - and of reading `texdiag info`: by property name, in batches, with whatever extra lines texdiag prints, and with unreadable files reported. texdiag's output is played back by a fake; the start check runs the real bundled tools. | 100% of `TexInfo.ps1` |
| `Icon.Tests.ps1` | 49 tests of the marks and the window icon: which marks a row gets and which sentence goes beside each, that every mark draws, that resize and reformat differ in shape and not only in colour, and the `.ico` the code assembles by hand, read back and checked field by field. | 100% of `Icon.ps1` |

Each runs on its own the usual way:

```powershell
Invoke-Pester -Path .\Tests\GuiLogic.Tests.ps1 -CodeCoverage '.\Tools\Black Face Fix\PS\Lib\GuiLogic.ps1'
```

`Invoke-UnitTests.ps1` runs them all for `Run-All.ps1`, and treats coverage as a
check rather than a statistic: every file in `PS\Lib` has to stay at 100%, and a
line nothing executes fails the run with its line number. A new library file is on
that list the moment it exists. The one exception is `Dialogs.ps1`: every line in
it waits for a person, so it is kept to one Windows call per function and mocked.

The entry script, `PS\BlackFaceFix.ps1`, is not unit tested; `Verify-Console.ps1`
and `Verify-Gui.ps1` run it end to end.

All take `-Tool <path>` if you want to test a copy somewhere else.
`Verify-Console.ps1` also takes `-SourceSpecular` and `-SourceDiffuse` to convert
from a real face DDS instead of the painted image.

`Run-All.ps1` carries on past a suite that throws and counts it as not finished,
and it shows skips separately: a suite that checked nothing must not read as one
that passed.

## Screenshots

`Build-ReadmeScreenshots.ps1` renders the images in `Tools\Black Face Fix\docs\`
from a demo Mod Organizer setup with invented mods. Not a test - it is there so the
README images can be redone after a UI change rather than going stale.

## Research helpers

Not tests - these are how the shipped data was worked out, kept so it can be
redone or checked.

| Script | Purpose |
|--------|---------|
| `..\Tools\Black Face Fix\Rules\Build-VanillaFaceTextures.ps1` | Regenerates `VanillaFaceTextures.psd1` from the `TXST` records in the game's plugins. Run it after a game update. |
| `Survey-OfficialFaceTextures.ps1` | Buckets every face texture path the official plugins declare by naming convention. This is the evidence that the head name pattern has to be a loose substring: `head_` would miss `headwrinkles_n.dds` and `femaleheadweathered1_*`. |
| `Probe-Ba2Layout.ps1` | Reads a BA2's DX10 record fields at candidate header sizes of 24/28/32/36. Versions 1, 7 and 8 all parse cleanly at 24 and produce nonsense elsewhere, which is why v7/v8 are accepted. |
