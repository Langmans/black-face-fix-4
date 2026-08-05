@echo off
rem Black Face Fix 4 - console launcher.
rem
rem Scans, shows what would change and why, then asks before writing anything.
rem Pass -DryRun to never write, -Gui for the window, -ProfileName to override the
rem detected profile, or -Restore to undo an in-place run.
rem
rem Examples:
rem   Launcher.bat -DryRun
rem   Launcher.bat -ProfileName "HD DLC"
rem   Launcher.bat -Restore

%SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PS\BlackFaceFix.ps1" %*
