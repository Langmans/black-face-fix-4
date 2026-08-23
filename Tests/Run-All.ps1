# Runs both verification suites and reports a single pass/fail.
#
#   .\Tests\Run-All.ps1
#   .\Tests\Run-All.ps1 -Verbose      also prints each suite's own output

[CmdletBinding()]
param(
    [string] $Tool = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Tools\Black Face Fix')
)

$ErrorActionPreference = 'Continue'
$total = 0
$bad   = 0

# --- syntax ---------------------------------------------------------------
Write-Host 'Parsing every script...' -ForegroundColor Cyan
$syntaxErrors = 0
foreach ($f in (Get-ChildItem (Join-Path $Tool 'PS') -Recurse -Filter *.ps1)) {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref] $null, [ref] $e)
    if ($e) {
        $syntaxErrors++
        Write-Host ("  FAIL  {0}: {1}" -f $f.Name, $e[0].Message) -ForegroundColor Red
    }
}
foreach ($f in (Get-ChildItem $Tool -Recurse -Filter *.psd1)) {
    try { [void](Import-PowerShellDataFile -LiteralPath $f.FullName) }
    catch { $syntaxErrors++; Write-Host ("  FAIL  {0}: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor Red }
}
if ($syntaxErrors -eq 0) { Write-Host '  PASS  everything parses' -ForegroundColor Green }
$bad += $syntaxErrors
$total++

# --- suites ---------------------------------------------------------------
foreach ($suite in @('Verify-Console.ps1', 'Verify-Gui.ps1', 'Verify-Ba2.ps1')) {
    Write-Host ''
    Write-Host ("Running {0}..." -f $suite) -ForegroundColor Cyan

    # *>&1 and not 2>&1: the suites report through Write-Host, which goes to the
    # Information stream, so redirecting stderr alone captures nothing.
    $output = & (Join-Path $PSScriptRoot $suite) -Tool $Tool *>&1
    if ($VerbosePreference -ne 'SilentlyContinue') { $output | ForEach-Object { Write-Host "  $_" } }

    $result = $output | Where-Object { $_ -match '^RESULT: (\d+) passed, (\d+) failed' } | Select-Object -Last 1
    if (-not $result) {
        Write-Host ('  FAIL  {0} did not finish' -f $suite) -ForegroundColor Red
        $output | Select-Object -Last 5 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        $bad++
    }
    else {
        $null = "$result" -match 'RESULT: (\d+) passed, (\d+) failed'
        $passed = [int] $Matches[1]; $failed = [int] $Matches[2]
        $total += $passed + $failed
        $bad   += $failed

        $colour = if ($failed) { 'Red' } else { 'Green' }
        Write-Host ("  {0}  {1}: {2} passed, {3} failed" -f $(if ($failed) { 'FAIL' } else { 'PASS' }), $suite, $passed, $failed) -ForegroundColor $colour
        if ($failed) { $output | Where-Object { $_ -match '^\s+FAIL' } | ForEach-Object { Write-Host "        $_" -ForegroundColor Red } }
    }
}

Write-Host ''
if ($bad) {
    Write-Host ("FAILED: {0} of {1} checks" -f $bad, $total) -ForegroundColor Red
    exit 1
}
Write-Host ("ALL GREEN: {0} checks" -f $total) -ForegroundColor Green
