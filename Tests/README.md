# Tests

```powershell
.\Tests\Run-All.ps1            # syntax + all three suites, one pass/fail line
.\Tests\Run-All.ps1 -Verbose   # plus each suite's own output
```

99 checks, plus a skipped one on a machine without Fallout 4. Nothing touches your
real mods: the suites build a throwaway MO2 instance under
`%TEMP%\BlackFaceFix.Tests\` with a fake `ModOrganizer.ini`, `modlist.txt`, an
empty stand-in for the game folder and a mod full of deliberately awkward textures.

They need neither Fallout 4 nor any mod installed. The source image every test
texture is converted from is painted by the test itself, from a fixed seed, so two
runs build byte-identical textures.

| Script | What it covers |
|--------|----------------|
| `Verify-Console.ps1` | 41 checks. Dry run, apply, and a second apply that must be a no-op. Asserts the specular goes 1024 -> 512 with 10 mips, that BC1/BC3/BC7 diffuses are kept as they are, that a BC6H diffuse is re-encoded, that `_msn` and `Face_Specular.dds` are read correctly, that non-square textures are only flagged, and that body, hair and disabled-mod textures are never scanned. A second dry run with `-VanillaFormats` covers the other format policy: every slot must come out on one format, and skin maps must still be left alone. |
| `Verify-Gui.ps1` | 57 checks. Runs against the sandbox `Verify-Console.ps1` builds - never a real install, so the result does not depend on what happens to be installed. Builds the window and runs the scan under the same `Set-StrictMode` the entry script uses, via `Show-BffGui -BuildOnly -RunScan`. This is what catches empty collections unwrapping to `$null` and variable names colliding with parameter names. It also **paints** the grid through `DrawToBitmap` with a `DataError` handler attached, because a cell can hold a value it cannot format and the failure only surfaces at paint time; and it **raises `CellMouseEnter` by reflection** after `Show-BffGui` has returned, because WinForms raises that event from its own layout code, where a handler reading the function's local variables finds nothing. |
| `Verify-Ba2.ps1` | 35 checks against **real** BA2 archives: header and record layout for versions 1, 7 and 8, the size and format in DX10 file tables, extraction of zlib-compressed entries, and that the slot rules accept everything the game itself ships. Without Fallout 4 installed it reports one skip and nothing else - see `TODO.md` for the simulated archive that will replace that. |

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
