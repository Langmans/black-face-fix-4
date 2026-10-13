# Black Face Fix 4

A Windows tool for Fallout 4 that resizes and re-encodes face textures so head
textures and tint masks match - which is what the black / dark face bug comes down
to. It scans a Mod Organizer 2 setup, shows per texture what it is now, what it
should be and why, and only writes once you say so - into separate output mods,
never over the originals.

![The window after a scan](Tools/Black%20Face%20Fix/docs/window.png)

## Where things are

| Path | What it is |
|------|------------|
| [`Tools/Black Face Fix/`](Tools/Black%20Face%20Fix/) | The tool itself. Its [README](Tools/Black%20Face%20Fix/README.md) covers installing, using it with MO2, and how sizes and formats are decided. |
| [`Tests/`](Tests/) | The verification suites. Self-contained: they build their own Mod Organizer setup and textures, so they run without Fallout 4 installed. See its [README](Tests/README.md). |
| [`TODO.md`](TODO.md) | What is still open - mostly things only the real game can answer. |

## Quick start

Run `Tools\Black Face Fix\Launcher-GUI.bat`, press **Scan**, check the plan, press
**Apply**. Nothing to install: it runs on the Windows PowerShell that ships with
Windows 10 and 11, and `texconv` / `texdiag` are bundled.

## Credits

Rebuilt from KLMX's [Black Face Fix V3 Alpha 1](https://www.nexusmods.com/fallout4/mods/21907).
Texture-size research by ousnius. `texconv` and `texdiag` are Microsoft's
[DirectXTex](https://github.com/microsoft/DirectXTex) tools, MIT licensed - see
`Tools/Black Face Fix/MSFT/LICENSE`.
