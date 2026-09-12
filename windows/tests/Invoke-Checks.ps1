#Requires -Version 7.2
<#
.SYNOPSIS
One exit code for every check of the Windows port.

.DESCRIPTION
Every PowerShell file under windows\ parses; PSScriptAnalyzer reports nothing
at Warning or above (with the settings beside this file); the Pester suites in
this directory pass. Suites tagged WindowsOnly run only on Windows. CI runs
this on windows-latest (x64), windows-11-arm (Arm64) and macos-latest; it runs
anywhere pwsh 7 does, which is how the port was checked on a Mac before any
Windows machine saw it.

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
    # The architecture as well: both Windows runners describe themselves as
    # "Microsoft Windows 10.0.26100".
    $pesterLine = "Pester on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) ($([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)): passed $($r.PassedCount), failed $($r.FailedCount), skipped $($r.SkippedCount), not run $($r.NotRunCount)"
}

# In GitHub Actions, the counts as an annotation as well: annotations are
# readable through the public API, job logs are not, and the pull request
# cites these numbers as the evidence of what ran on Windows.
if ($env:GITHUB_ACTIONS -eq 'true') {
    # Workflow-command escaping: % first, then the line breaks.
    $esc = { param([string]$t) $t.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A') }
    $parts = @("parsed $($files.Count) files")
    if (-not $NoAnalyzer) { $parts += "PSScriptAnalyzer findings $($results.Count)" }
    if (-not $NoPester) { $parts += $pesterLine }
    Write-Host "::notice title=Invoke-Checks::$(& $esc ($parts -join '; '))"
    # Each failure with its message, so a failing Windows-only test can be
    # read without the job log.
    if (-not $NoPester) {
        foreach ($t in @($r.Failed) + @($r.FailedBlocks) + @($r.FailedContainers)) {
            if ($null -eq $t) { continue }
            $name = if ($t.PSObject.Properties['ExpandedPath']) { $t.ExpandedPath } elseif ($t.PSObject.Properties['Name']) { $t.Name } else { [string]$t }
            $msg = @($t.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join ' | '
            if ($msg.Length -gt 900) { $msg = $msg.Substring(0, 900) + '...' }
            Write-Host "::error title=Pester failure::$(& $esc "$name -- $msg")"
        }
    }
}

if ($failed -gt 0) {
    Write-Host "FAILED ($failed)"
    exit 1
}
Write-Host 'all checks passed'
exit 0
