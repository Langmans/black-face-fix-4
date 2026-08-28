# Tests

```powershell
.\Tests\Run-All.ps1            # syntax + all three suites, one pass/fail line
.\Tests\Run-All.ps1 -Verbose   # plus each suite's own output
```

109 checks. Nothing touches your real mods: the suites build a throwaway MO2
instance under `%TEMP%\BlackFaceFix.Tests\` with a fake `ModOrganizer.ini`,
`modlist.txt` and a mod full of deliberately awkward textures.

| Script | What it covers |
|--------|----------------|
| `Verify-Console.ps1` | 41 checks. Dry run, apply, and a second apply that must be a no-op. Asserts the specular goes 1024 -> 512 with 10 mips, that BC1/BC3/BC7 diffuses are kept as they are, that a BC6H diffuse is re-encoded, that `_msn` and `Face_Specular.dds` are read correctly, that non-square textures are only flagged, and that body, hair and disabled-mod textures are never scanned. A second dry run with `-VanillaFormats` covers the other format policy: every slot must come out on one format, and skin maps must still be left alone. |
| `Verify-Gui.ps1` | 32 checks. Builds the window and runs the scan under the same `Set-StrictMode` the entry script uses, via `Show-BffGui -BuildOnly -RunScan`. This is what catches empty collections unwrapping to `$null` and variable names colliding with parameter names. It also **paints** the grid through `DrawToBitmap` with a `DataError` handler attached, because a cell can hold a value it cannot format - the failure then surfaces at paint time, long after the row was added. |
| `Verify-Ba2.ps1` | 35 checks. Reads real BA2 archives: header and record layout for versions 1, 7 and 8, the size and format in DX10 file tables, and extraction of zlib-compressed entries. |

Both take `-Tool <path>` if you want to test a copy somewhere else.
`Verify-Console.ps1` needs one real face `_s` and `_d` DDS as raw material and
re-encodes them into every shape it needs; override with `-SourceSpecular` and
`-SourceDiffuse` if the defaults are not on your machine.

## Research helpers

Not tests - these are how the shipped data was worked out, kept so it can be
redone or checked.

| Script | Purpose |
|--------|---------|
| `..\Tools\Black Face Fix\Rules\Build-VanillaFaceTextures.ps1` | Regenerates `VanillaFaceTextures.psd1` from the `TXST` records in the game's plugins. Run it after a game update. |
| `Survey-OfficialFaceTextures.ps1` | Buckets every face texture path the official plugins declare by naming convention. This is the evidence that the head name pattern has to be a loose substring: `head_` would miss `headwrinkles_n.dds` and `femaleheadweathered1_*`. |
| `Probe-Ba2Layout.ps1` | Reads a BA2's DX10 record fields at candidate header sizes of 24/28/32/36. Versions 1, 7 and 8 all parse cleanly at 24 and produce nonsense elsewhere, which is why v7/v8 are accepted. |
