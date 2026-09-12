#Requires -Version 7.2
<#
.SYNOPSIS
The reclaim step's whole invocation path on this OS, with no Apple account.

.DESCRIPTION
Installs icloudpd the way the README says (`uv tool install icloudpd`; on
Windows on Arm `uv tool install --python 3.13 icloudpd`, which takes its
pure-Python wheel, as icloudpd builds Windows executables for amd64 only),
reads its version the way the sync does, pins the library to that version, and
runs bin/avd-photos-reclaim.py -- unchanged, the file macOS runs -- under
`uv run --python 3.13` with PYTHONUTF8=1 and an EMPTY pending list. The script
imports every icloudpd name it uses before it reads that list, and returns
before authenticating when the list is empty, so this proves the tool
install, the version parse, the git+https pin, the managed Python and every
import, and touches nothing but a scratch directory. On Windows it also says
what the tool's Python is built for, from its PE header.

CI runs it on windows-latest, windows-11-arm, ubuntu-latest and macos-latest.
It needs uv and git on PATH and network access.
#>
[CmdletBinding()]
param([string]$WorkDir)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force

if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('reclaim-smoke-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Add-AvdToolPath
$uv = (Get-Command -Name 'uv' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

# The Windows port's per-architecture install; elsewhere the macOS README's.
$arch = if ($IsWindows) { (Get-AvdHostArchitecture).Os } else { '' }
$installArgs = Get-AvdIcloudpdInstallArgument -Architecture $arch
$r = Invoke-AvdProcess -FilePath $uv -ArgumentList $installArgs -TimeoutSec 900
if ($r.ExitCode -ne 0) { throw "uv $($installArgs -join ' ') failed ($($r.ExitCode)): $($r.StdErr)" }
$binDir = (Invoke-AvdProcess -FilePath $uv -ArgumentList @('tool', 'dir', '--bin') -TimeoutSec 60).StdOut.Trim()
$icloudpd = Join-Path $binDir $(if ($IsWindows) { 'icloudpd.exe' } else { 'icloudpd' })
$r = Invoke-AvdProcess -FilePath $icloudpd -ArgumentList @('--version') -TimeoutSec 300
$version = Get-AvdIcloudpdVersion -Text $r.StdOut
if (-not $version) { throw "could not read a version from icloudpd --version: $($r.StdOut) $($r.StdErr)" }
Write-Host "icloudpd $version at $icloudpd (uv $($installArgs -join ' '))"
$toolPython = ''
if ($IsWindows) {
    $toolDir = (Invoke-AvdProcess -FilePath $uv -ArgumentList @('tool', 'dir') -TimeoutSec 60).StdOut.Trim()
    $toolPython = Get-AvdExecutableArchitecture -Path (Join-Path $toolDir 'icloudpd' 'Scripts' 'python.exe')
    Write-Host "icloudpd's Python is the $(if ($toolPython) { $toolPython } else { 'unknown' }) build on a $arch machine"
}

$pending = Join-Path $WorkDir 'pending'
[System.IO.File]::WriteAllText($pending, '')
$out = Join-Path $WorkDir 'out'
$env:PYTHONUTF8 = '1'
# Through the sync's own runner, so what this proves is the invocation a real
# run makes, not a copy of it that could drift.
$reclaimArgs = @(
    '--username', 'nobody@example.invalid', '--staging', $WorkDir,
    '--pending', $pending, '--out', $out, '--cookie-dir', (Join-Path $WorkDir 'cookies')
)
$r = Invoke-AvdReclaimProcess -Spec (Get-AvdIcloudpdSpec -Version $version) -Script (Get-AvdReclaimScript) -ArgumentList $reclaimArgs -TimeoutSec 1200
Write-Host "reclaim exit $($r.ExitCode); stdout: $($r.StdOut.Trim())"
if ($r.StdErr) { Write-Host "stderr (tail):"; ($r.StdErr -split "`n" | Select-Object -Last 20) | ForEach-Object { Write-Host "  $_" } }
if ($r.ExitCode -ne 0) { throw "the reclaim script failed on its empty-list path ($($r.ExitCode))" }
$stats = $r.StdOut.Trim() | ConvertFrom-Json
if ($stats.pending -ne 0 -or $stats.deleted -ne 0 -or $stats.dry_run -ne $false) { throw "unexpected stats: $($r.StdOut)" }
if (Test-Path -LiteralPath $out) { throw 'an empty pending list must not write --out' }
Write-Host 'reclaim import path: ok'
if ($env:GITHUB_ACTIONS -eq 'true') {
    $py = if ($toolPython) { " on a $toolPython Python ($arch machine)" } else { '' }
    Write-Host "::notice title=Reclaim path::$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription): icloudpd $version via uv $($installArgs -join ' ')$py; bin/avd-photos-reclaim.py exit 0 on an empty list; stats $($r.StdOut.Trim())"
}
