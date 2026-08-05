<#
.SYNOPSIS
Black Face Fix 4 - resizes Fallout 4 face textures so head textures and tint masks
match, which is what the black/dark face bug actually comes down to.

.DESCRIPTION
Scans loose face textures (and, read-only, the contents of BA2 archives), compares
them against a resolution profile, and shows exactly what would change and why
before writing anything.

Profiles live in Profiles\*.psd1, slot format rules in Rules\SlotRules.psd1, and
everything else in Config\Settings.psd1.

.PARAMETER ProfileName
Vanilla, HD DLC, 2K or 4K. Omit to use Settings.psd1, which defaults to auto-detect
from the HD DLC archive and the LooksMenu tint resolution.

.PARAMETER DryRun
Scan and report, never write. The report is identical either way.

.PARAMETER Force
Re-encode textures that already match the profile. Off by default, because
re-encoding a correct texture only costs quality.

.PARAMETER Yes
Skip the confirmation prompt.

.PARAMETER Restore
Put every <name.ext>.backup left by an in-place run back over its original, then exit.

.PARAMETER OutputMode
OutputMod (default) writes results into a separate MO2 mod and never touches the
source. InPlace overwrites the original and leaves a .backup next to it.

.EXAMPLE
.\BlackFaceFix.ps1 -DryRun
Show what would change, write nothing.

.EXAMPLE
.\BlackFaceFix.ps1 -ProfileName Vanilla -Yes
Force the vanilla profile and apply without prompting.
#>

[CmdletBinding()]
param(
    [string] $ProfileName,
    [switch] $DryRun,
    [switch] $Force,
    [switch] $Yes,
    [switch] $Restore,
    [ValidateSet('OutputMod', 'InPlace')] [string] $OutputMode,
    [switch] $NoArchives,
    [switch] $FixArchives,
    [switch] $Gui,
    [string] $MO2Path,
    [switch] $All,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$libPath = Join-Path $PSScriptRoot 'Lib'
foreach ($file in @('Types', 'Config', 'Environment', 'TexInfo', 'Ba2', 'Discovery', 'Planner', 'Convert', 'Report')) {
    . (Join-Path $libPath "$file.ps1")
}

$root      = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logDir    = Join-Path $root 'Logs'

function Invoke-Main {
    Clear-BffLog
    Write-BffBanner

    # ---- configuration ------------------------------------------------------
    $settings = Import-BffSettings -Root $root
    if ($MO2Path)    { $settings.Paths.MO2   = $MO2Path }
    if ($OutputMode) { $settings.Output.Mode = $OutputMode }
    if ($NoArchives) { $settings.Scope.IncludeArchives = $false }
    if ($FixArchives){ $settings.Scope.FixArchives     = $true }

    # This is also the first call that resolves texconv/texdiag, and the resolver
    # caches, so passing $settings here fixes the choice for the whole run.
    # @() everywhere a helper returns a collection: PowerShell unwraps an empty
    # List to $null, and Set-StrictMode then throws on .Count.
    $toolCheck = Test-BffToolchain -Root $root -Settings $settings
    if (@($toolCheck.Problems).Count -gt 0) {
        foreach ($p in $toolCheck.Problems) { Write-BffLine ("ERROR: {0}" -f $p) 'Red' }
        return
    }
    foreach ($p in $toolCheck.Paths) { Write-Verbose ("using {0}" -f $p) }

    $environment = Get-BffEnvironment -Settings $settings -Root $root -ProfileOverride $ProfileName
    $slotRules   = Import-BffSlotRules -Root $root
    $vanilla     = Import-BffVanillaFaceTextures -Root $root

    # ---- restore mode -------------------------------------------------------
    if ($Restore) {
        $target = if ($environment.MO2) { $environment.MO2.ModsPath } else { $environment.DataPath }
        Write-BffLine ("Restoring backups under {0}" -f $target) 'Yellow'

        $restored = Restore-BffBackup -Path $target -BackupSuffix $settings.Output.BackupSuffix
        $good = @($restored | Where-Object Success).Count
        $bad  = @($restored | Where-Object { -not $_.Success }).Count

        Write-BffLine ("Restored {0} file(s), {1} failure(s)." -f $good, $bad) $(if ($bad) { 'Red' } else { 'Green' })
        return
    }

    # ---- GUI ----------------------------------------------------------------
    if ($Gui) {
        . (Join-Path $libPath 'Gui.ps1')
        try {
            Show-BffGui -Settings $settings -Environment $environment -SlotRules $slotRules `
                        -VanillaFaceTextures $vanilla -Root $root
        }
        catch {
            # The GUI launcher hides the console, so an exception here would
            # otherwise be completely invisible.
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                ("{0}`n`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace),
                'Black Face Fix failed to start',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            throw
        }
        return
    }

    Write-BffEnvironmentReport -Environment $environment

    # ---- discovery ----------------------------------------------------------
    Write-BffLine 'Scanning for face textures...' 'Yellow'
    $candidates = @(Get-BffCandidate -Environment $environment -Settings $settings `
                                     -SlotRules $slotRules -VanillaFaceTextures $vanilla)
    Write-BffLine ('  found {0} candidate texture(s)' -f $candidates.Count)

    if ($candidates.Count -eq 0) {
        Write-BffLine 'No face textures found. If that seems wrong, check Paths and Scope in Config\Settings.psd1.' 'Yellow'
        return
    }

    # ---- metadata -----------------------------------------------------------
    Write-BffLine 'Reading texture metadata...' 'Yellow'
    $failed = @()
    $textures = @(Update-BffTextureInfo -Texture $candidates -TexDiagPath (Get-BffTexDiagPath -Root $root -Settings $settings) `
                                        -FailedVariable 'failed' `
                                        -Progress {
                                            param($done, $total)
                                            Write-Progress -Activity 'Reading texture metadata' `
                                                           -Status "$done / $total" `
                                                           -PercentComplete ([int](100 * $done / $total))
                                        })
    Write-Progress -Activity 'Reading texture metadata' -Completed

    if ($failed -and $failed.Count -gt 0) {
        Write-BffLine ('  {0} file(s) could not be read by texdiag and were skipped' -f $failed.Count) 'Yellow'
    }
    Write-BffLine ''

    # ---- plan ---------------------------------------------------------------
    $plans = New-BffPlanSet -Texture $textures -Profile $environment.Profile -SlotRules $slotRules `
                            -Settings $settings -Environment $environment -Force:$Force

    # In OutputMod mode the source stays untouched by design, so without this a
    # second run would redo everything the first run already did.
    if (-not $Force) {
        $plans = Update-BffPlanForExistingOutput -Plan $plans -TexDiagPath (Get-BffTexDiagPath -Root $root -Settings $settings)
    }

    # ---- archives (read-only unless FixArchives) ----------------------------
    $archiveFindings = @()
    if ($settings.Scope.IncludeArchives) {
        Write-BffLine 'Inspecting BA2 archives...' 'Yellow'
        $archiveAll = Get-BffArchiveCandidate -Environment $environment -Settings $settings `
                                              -SlotRules $slotRules -VanillaFaceTextures $vanilla
        $archiveAll = @($archiveAll | Where-Object { $_.Texture })

        foreach ($a in $archiveAll) {
            $p = New-BffPlan -Texture $a.Texture -Profile $environment.Profile `
                             -SlotRules $slotRules -Settings $settings -Force:$Force
            if ($p.NeedsWork()) { $archiveFindings += $a }
        }
        Write-BffLine ('  {0} face texture(s) in archives, {1} do not match the profile' -f
                       $archiveAll.Count, $archiveFindings.Count)
        Write-BffLine ''
    }

    # ---- report -------------------------------------------------------------
    Write-BffPlanTable -Plan $plans -All:$All
    $summary = Get-BffPlanSummary -Plan $plans
    Write-BffSummary -Summary $summary -ArchiveFinding $archiveFindings

    $csvPath = Join-Path $logDir ("BlackFaceFix_{0}.csv" -f $timestamp)
    [void] (Export-BffPlanCsv -Plan $plans -Path $csvPath)
    Write-BffLine ('Full per-file detail: {0}' -f $csvPath) 'DarkGray'

    # ---- apply --------------------------------------------------------------
    if ($DryRun) {
        Write-BffLine ''
        Write-BffLine 'Dry run: nothing was written.' 'Green'
    }
    elseif ($summary.Changing -eq 0) {
        Write-BffLine ''
        Write-BffLine 'Nothing to do.' 'Green'
    }
    else {
        $destination = if ($settings.Output.Mode -eq 'InPlace') {
            'the original files, with a .backup next to each one'
        } else {
            Join-Path $(if ($environment.MO2) { $environment.MO2.ModsPath } else { $root }) $settings.Output.OutputModName
        }

        Write-BffLine ''
        Write-BffLine ('About to convert {0} texture(s).' -f $summary.Changing) 'White'
        Write-BffLine ('Results go to: {0}' -f $destination) 'White'

        $go = $Yes
        if (-not $go) {
            Write-Host ''
            $answer = Read-Host 'Continue? [y/N]'
            $go = ($answer -match '^(y|yes)$')
        }

        if (-not $go) {
            Write-BffLine 'Cancelled, nothing was written.' 'Yellow'
        }
        else {
            Write-BffLine ''
            Write-BffLine 'Converting...' 'Yellow'

            $results = Invoke-BffPlanSet -Plan $plans -Settings $settings -Root $root -Progress {
                param($done, $total, $plan)
                Write-Progress -Activity 'Converting' -Status "$done / $total - $($plan.Texture.Name)" `
                               -PercentComplete ([int](100 * $done / $total))
            }
            Write-Progress -Activity 'Converting' -Completed

            $ok  = @($results | Where-Object Success).Count
            $bad = @($results | Where-Object { -not $_.Success })

            Write-BffLine ''
            Write-BffLine ('Converted {0} texture(s).' -f $ok) 'Green'

            if ($bad.Count -gt 0) {
                Write-BffLine ('{0} failure(s):' -f $bad.Count) 'Red'
                foreach ($b in ($bad | Select-Object -First 15)) {
                    Write-BffLine ('  {0}: {1}' -f $b.Plan.Texture.Name, $b.Error) 'Red'
                }
            }

            if ($settings.Output.Mode -ne 'InPlace' -and $environment.MO2) {
                Write-BffLine ''
                Write-BffLine ("Enable '{0}' in Mod Organizer and put it at the BOTTOM of the load order." -f
                               $settings.Output.OutputModName) 'Cyan'
                Write-BffLine 'To undo everything, just disable that one mod.' 'Cyan'
            }
        }
    }
}

try {
    Invoke-Main
}
catch {
    Write-BffLine ''
    Write-BffLine ('ERROR: {0}' -f $_.Exception.Message) 'Red'
    Write-BffLine ($_.ScriptStackTrace) 'DarkGray'
}
finally {
    $logPath = Join-Path $logDir ("BlackFaceFix_{0}.log" -f $timestamp)
    try { [void] (Save-BffLog -Path $logPath); Write-Host ("Log: {0}" -f $logPath) -ForegroundColor DarkGray }
    catch { Write-Host "Could not write the log file: $($_.Exception.Message)" -ForegroundColor Red }

    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Press any key to exit...'
        [void] $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}
