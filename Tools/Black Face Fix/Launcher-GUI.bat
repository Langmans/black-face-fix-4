@echo off
rem Black Face Fix 4 - window launcher.
rem
rem Same engine as Launcher.bat, but shows the scan results in a sortable grid so
rem you can see the old size, the old format and the reason per file before
rem anything is written.

%SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PS\BlackFaceFix.ps1" -Gui -NoPause %*
pause