@echo off
rem Black Face Fix 4 - window launcher.
rem
rem Same engine as Launcher.bat, but shows the scan results in a sortable grid so
rem you can see the old size, the old format and the reason per file before
rem anything is written.
rem
rem Started detached with 'start' so this console closes straight away instead of
rem sitting behind the window for as long as the tool is open. -WindowStyle Hidden
rem keeps PowerShell's own console from flashing up behind the form, and -NoPause
rem stops the script waiting for a keypress on a console nobody is looking at.

start "" %SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PS\BlackFaceFix.ps1" -Gui -NoPause %*
