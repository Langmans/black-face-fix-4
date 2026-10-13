# Runs the Pester unit tests (*.Tests.ps1) with code coverage, and reports in the
# same "RESULT:" form as the Verify-*.ps1 suites so Run-All.ps1 can count it.
#
#   .\Tests\Invoke-UnitTests.ps1
#   .\Tests\Invoke-UnitTests.ps1 -RequirePester     fail rather than skip without Pester 5
#
# Coverage is a check, not a statistic: every library file has to stay at 100%,
# and a change that adds an untested line fails the run, naming the line.

[CmdletBinding()]
param(
    [string] $Tool,
    [switch] $RequirePester
)

$ErrorActionPreference = 'Stop'

# Resolved here, not as a param default: $PSScriptRoot is not populated in the
# param block when the script is started with powershell.exe -File.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Tool) { $Tool = Join-Path (Split-Path -Parent $here) 'Tools\Black Face Fix' }

# Held to 100%: every file in PS\Lib, so a new one cannot arrive without tests.
# The one exception is Dialogs.ps1, where every line waits for a person; it is
# kept to one Windows call per function and mocked by the tests instead.
$NotCovered   = @('Dialogs.ps1')
$FullyCovered = @(Get-ChildItem -LiteralPath (Join-Path $Tool 'PS\Lib') -Filter '*.ps1' -File |
                  Where-Object { $NotCovered -notcontains $_.Name } | Sort-Object Name | ForEach-Object Name)

# Pester 3.4 ships with Windows and is on the module path too, so the version is
# pinned: these tests are written for 5 and 5 alone.
$pester = Get-Module -ListAvailable Pester |
          Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    $why = 'Pester 5 is not installed - Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser'
    if ($RequirePester) {
        Write-Host "  FAIL  unit tests  $why"
        Write-Host ''
        Write-Host 'RESULT: 0 passed, 1 failed'
        return
    }
    Write-Host "  SKIP  unit tests  $why"
    Write-Host ''
    Write-Host 'RESULT: 0 passed, 0 failed'
    Write-Host '(1 skipped)'
    return
}
Import-Module $pester -Force

$config = New-PesterConfiguration
$config.Run.Path             = @(Get-ChildItem -LiteralPath $here -Filter '*.Tests.ps1' | ForEach-Object FullName)
$config.Run.PassThru         = $true
$config.Output.Verbosity     = if ($VerbosePreference -ne 'SilentlyContinue') { 'Detailed' } else { 'None' }
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path    = @($FullyCovered | ForEach-Object { Join-Path $Tool "PS\Lib\$_" })
# Written where CI can pick it up; JaCoCo is what most coverage viewers read.
$config.CodeCoverage.OutputPath   = Join-Path $here 'coverage.xml'
$config.CodeCoverage.OutputFormat = 'JaCoCo'

$run = Invoke-Pester -Configuration $config

$passed = $run.PassedCount
$failed = $run.FailedCount + $run.FailedBlocksCount + $run.FailedContainersCount

foreach ($t in $run.Failed) {
    Write-Host ("  FAIL  {0}  {1}" -f $t.ExpandedPath, ($t.ErrorRecord | Select-Object -First 1))
}
foreach ($c in @($run.Containers | Where-Object { $_.Result -eq 'Failed' -and $_.ErrorRecord })) {
    Write-Host ("  FAIL  {0} did not load  {1}" -f (Split-Path -Leaf $c.Item), ($c.ErrorRecord | Select-Object -First 1))
}

# --- coverage, per file -----------------------------------------------------
$missedByFile = @{}
foreach ($m in @($run.CodeCoverage.CommandsMissed)) {
    $leaf = Split-Path -Leaf $m.File
    if (-not $missedByFile.ContainsKey($leaf)) { $missedByFile[$leaf] = New-Object System.Collections.Generic.List[object] }
    $missedByFile[$leaf].Add($m)
}
$analysedByFile = @{}
foreach ($c in @($run.CodeCoverage.CommandsExecuted) + @($run.CodeCoverage.CommandsMissed)) {
    if (-not $c) { continue }
    $leaf = Split-Path -Leaf $c.File
    $analysedByFile[$leaf] = 1 + $(if ($analysedByFile.ContainsKey($leaf)) { $analysedByFile[$leaf] } else { 0 })
}

foreach ($f in $FullyCovered) {
    $all    = if ($analysedByFile.ContainsKey($f)) { $analysedByFile[$f] } else { 0 }
    $missed = if ($missedByFile.ContainsKey($f)) { $missedByFile[$f].Count } else { 0 }
    $pct    = if ($all) { 100 * ($all - $missed) / $all } else { 0 }

    if ($all -gt 0 -and $missed -eq 0) {
        $passed++
        Write-Host ("  PASS  coverage of {0}: 100% ({1} commands)" -f $f, $all)
    }
    else {
        $failed++
        Write-Host ("  FAIL  coverage of {0}: {1:N1}% ({2} of {3} commands untested)" -f $f, $pct, $missed, $all)
        foreach ($m in @($missedByFile[$f] | Select-Object -First 15)) {
            Write-Host ("          line {0}: {1}" -f $m.Line, ($m.Command -split "`n")[0].Trim())
        }
    }
}

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $passed, $failed)
