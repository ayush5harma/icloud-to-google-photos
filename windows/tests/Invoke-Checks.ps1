#Requires -Version 7.2
<#
.SYNOPSIS
One exit code for every check of the Windows port.

.DESCRIPTION
Every PowerShell file under windows\ parses; PSScriptAnalyzer reports nothing
at Warning or above (with the settings beside this file); the Pester suites in
this directory pass. Suites tagged WindowsOnly run only on Windows. CI runs
this on windows-latest; it runs anywhere pwsh 7 does, which is how the port
was checked on a Mac before any Windows machine saw it.

Needs the Pester (5.x) and PSScriptAnalyzer modules on PSModulePath.

.EXAMPLE
pwsh -NoProfile -File windows/tests/Invoke-Checks.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoAnalyzer,
    [switch]$NoPester,
    # Write a NUnit XML report here (CI uploads it).
    [string]$ResultPath,
    # Run only the suites whose file name matches (for a quick loop).
    [string]$Filter
)
$ErrorActionPreference = 'Stop'
$windowsDir = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $windowsDir -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
        Where-Object { $_.FullName -notmatch '[\\/]\.scratch[\\/]' } |
        Sort-Object FullName)
$failed = 0

Write-Host "== parse ($($files.Count) files)"
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) {
        Write-Host ("  {0}:{1}: {2}" -f $f.FullName, $e.Extent.StartLineNumber, $e.Message)
        $failed++
    }
}

if (-not $NoAnalyzer) {
    Write-Host '== PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $results = @(foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings })
    foreach ($r in $results) {
        Write-Host ("  {0}:{1}: [{2}] {3}: {4}" -f $r.ScriptPath, $r.Line, $r.Severity, $r.RuleName, $r.Message)
    }
    $failed += $results.Count
    Write-Host "  $($results.Count) finding(s)"
}

if (-not $NoPester) {
    Write-Host '== Pester'
    # 5.x only: the suites are written for Pester 5, and a runner image with
    # Pester 6 installed beside it must not pick that one up silently.
    Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -ErrorAction Stop
    $cfg = New-PesterConfiguration
    $paths = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Where-Object { -not $Filter -or $_.Name -match $Filter } | ForEach-Object FullName)
    $cfg.Run.Path = $paths
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    if (-not $IsWindows) { $cfg.Filter.ExcludeTag = @('WindowsOnly') }
    if ($ResultPath) {
        $cfg.TestResult.Enabled = $true
        $cfg.TestResult.OutputPath = $ResultPath
        $cfg.TestResult.OutputFormat = 'NUnitXml'
    }
    $r = Invoke-Pester -Configuration $cfg
    $failed += $r.FailedCount + $r.FailedBlocksCount + $r.FailedContainersCount
}

if ($failed -gt 0) {
    Write-Host "FAILED ($failed)"
    exit 1
}
Write-Host 'all checks passed'
exit 0
