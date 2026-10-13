# Open

## Needs the game running

Nothing in this section can be settled by more code - only by loading Fallout 4.

- **Does `-VanillaFormats` actually fix a face?** The switch is built and measured -
  on the load order it was developed against it re-encodes 234 of 890 loose face
  textures, all of them diffuse: 218 BC1 -> BC3 and 16 BC7 -> BC3 - but nothing has
  been loaded in the game with it applied. Until a face that was black comes up
  right, the array-consistency argument is reasoning from the vanilla measurements,
  not a result.
- **Try it on everything except Looks Menu Customization Compendium first.** Use the
  mod picker to leave LMCC unticked and see whether that alone changes anything.
- **Then decide about LMCC.** Its 209 overlays sit under `FaceDetails` as BC1 with a
  single mip - the TintMasks profile, not the FaceDetails one - and those faces are
  not black. That is the evidence they live in an array of their own, in which case
  forcing them to BC3 makes them the odd one out. Only trying it settles it.
- **No generated `[face-...]` output mod has ever been loaded in the game.**

## Known gaps

- **The top panel clips at the default window size.** Its controls are placed at
  fixed positions out to x = 1056, but the mod picker docks 270px to the right of it,
  so below a window width of about 1330 the Mod Organizer box, the **...** button and
  the "Write to" box disappear under the picker. Nobody notices maximised. Anchoring
  those controls to the right - as the progress bar already is - fixes it.
- **Mip counts are read but not enforced.** `SourceMips` is in the CSV and
  `BffTexture.MipLevels` is populated; the planner ignores both. Vanilla is strict
  about it - every tint mask has exactly 1 mip, every face detail diffuse 11 - and
  mods that ship tint masks with a full mip chain exist. Nothing reports that as
  wrong yet.
- **Array membership is guessed from the folder.** Which textures share a texture
  array is decided by the tint records in the plugin. Reading those would make the
  format and mip rules exact instead of approximate, and would answer the LMCC
  question without trial and error.
- **An oddities sweep was sketched but never run**, and is not in the repo: head DDS
  files with implausible dimensions, formats or channel content across a whole mod
  list.

## Testing

- **`Verify-Ba2.ps1` needs the real game.** Without it the suite skips. The fix is a
  simulated `Fallout4 - Textures1.ba2` built by the test: face textures at the paths,
  sizes, formats and mip counts measured from the real archives, written by a small
  BA2 writer for DX10 and GNRL with zlib chunks, in versions 1, 7 and 8. That covers
  the reader completely. It cannot prove our picture of vanilla is right - only the
  real archives can - so the real-archive run stays as an extra on a machine that
  has the game.
- **CI.** GitHub Actions on `windows-latest` has Windows PowerShell 5.1 and the .NET
  Framework, `texconv` is bundled in the repo, and every suite is self-contained
  except the one above. So it can run on every push once that one is.
- **Coverage.** Measure it before choosing a target: Pester 5 can instrument the
  `PS\Lib` files while the existing suites run, which gives a real number rather than
  a guess. Expect the GUI's event handlers and the texconv failure paths to be the
  hard part.
