# Open

Things the test suite cannot settle. Everything here needs the real game, the real
mod list, or a judgement call - not more code.

## Needs the game running

- **Does `-VanillaFormats` actually fix a face?** The switch is built and measured
  (234 of 890 loose face textures on this load order, all Diffuse: 218 BC1 -> BC3,
  16 BC7 -> BC3) but nothing has been loaded in Fallout 4 with it applied. Until a
  face that was black comes up right, the whole array-consistency argument is
  reasoning from the vanilla measurements, not a result.
- **Start with the 25 that are not LMCC.** Eye Liner Masks (9), Appealing Moles -
  EXTRA Moles (8), Extra Textures for V3 Alpha 1 (7), Lip Liner Mask (1). Use the
  mod picker so the other 209 stay untouched, and see whether that alone changes
  anything.
- **Then decide about LMCC.** Its 209 overlays sit under `FaceDetails` as BC1 with a
  single mip - the TintMasks profile, not the FaceDetails one - and those faces are
  not black today. That is the evidence they live in an array of their own, in which
  case forcing them to BC3 makes them the odd one out. Only trying it settles it.
- **The `[face-...]` output mods are still disabled in MO2.** Nothing generated has
  ever been loaded.
- **The owner-drawn tooltip on the mark column has never been hovered.** The tests
  check the data behind it - the marks, their order, the plan on each row - but a
  tooltip needs a real window and a real mouse. Worth one look at a row with three
  or four marks on it.

## Known gaps

- **Mip counts are read but not enforced.** `SourceMips` is in the CSV and
  `BffTexture.MipLevels` is populated; the planner ignores both. Vanilla is strict
  about it - every tint mask has exactly 1 mip, every face detail diffuse 11 - and
  on this load order one mod ships 20 tint masks with 11 mips where vanilla has
  1. Nothing currently reports that as wrong.
- **Array membership is guessed from the folder.** Which textures actually share a
  texture array is decided by the tint records in the plugin. Reading those instead
  would make the format and mip rules exact rather than approximate, and would
  answer the LMCC question without trial and error.
- **The oddities sweep was written but never run.** It looks for head DDS files with
  implausible dimensions, formats or channel content across the whole mod list.
