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
- **FaceCustomization textures are flagged as tint masks.** Discovery sets
  `IsTintMask` for everything that was not matched by the vanilla list or the head
  name, and that includes FaceCustomization - per-NPC baked face maps, not masks.
  It means those rows get the tint mask mark in the window and are allowed BC4,
  which only masks should be. `BffTexture.IsTintMask` itself says "anything under
  FaceDetails or TintMasks". Probably a one-line fix (only the full-scan folders
  count as masks); not changed yet because it changes what a FaceCustomization run
  converts, and only matters with that box ticked.
- **An oddities sweep was sketched but never run**, and is not in the repo: head DDS
  files with implausible dimensions, formats or channel content across a whole mod
  list.

## Testing

- **`Verify-Ba2.ps1` needs the real game.** Without it the suite skips. The reader
  is covered without it now - `Ba2.Tests.ps1` runs it to 100% on archives
  `TestBa2.ps1` writes - so what is left for this suite is our picture of vanilla:
  that the game's own face textures have the paths, sizes and formats the rules
  assume. Only the real archives can show that, so it stays a run for a machine
  with Fallout 4 installed. **Needs Ruben, after reinstalling the game:** run
  `.\Tests\Verify-Ba2.ps1` once.
- **`Dialogs.ps1` is only ever mocked.** Every function in it opens something on
  screen - the confirm box, the folder picker, Explorer, the window itself - so no
  test runs it. After a change there, open the window by hand and press Apply,
  Restore backups, **...** and Open logs once each.
