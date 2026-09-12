#Requires -Version 7.4
<#
.SYNOPSIS
The architecture answers on a real machine: this pwsh's, and those of pwsh
builds that Windows runs under emulation.

.DESCRIPTION
CI runs it on windows-latest (x64) and windows-11-arm (Arm64). It asks
Get-AvdHostArchitecture and Get-AvdConfig in this (native) pwsh, then fetches
the official PowerShell zips of the other architectures -- pinned to one
release and checked against the SHA-256 that release publishes -- and asks
again inside each, where Windows runs them under emulation: an x64 pwsh on an
Arm64 machine is told PROCESSOR_ARCHITECTURE=AMD64 and must still get Arm64
back, and with it the arm64-v8a default. x86 runs under WOW64 on both
machines, where PROCESSOR_ARCHITEW6432 names the machine.

It also reads the PE header of the programs the pipeline runs (git, uv, uv's
Python 3.13, icloudpd, conhost, schtasks) so the log says which are native
and which are emulated; those are reported, not asserted.

Changes nothing outside a scratch directory (the zips and their unpacked
trees).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('X64', 'Arm64')][string]$Expect,
    [string]$WorkDir
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Test-HostArchitecture.ps1 runs on Windows only' }
$module = Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1'
Import-Module $module -Force
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('arch-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Force -Path $WorkDir

# PowerShell 7.6.6, read from its release's hashes.sha256 on 2026-09-13.
$release = 'v7.6.6'
$zips = @{
    X64 = @{ Name = 'PowerShell-7.6.6-win-x64.zip'; Sha256 = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860' }
    X86 = @{ Name = 'PowerShell-7.6.6-win-x86.zip'; Sha256 = '2b644d9cb695fe221af212e23f1c38d3310655b37760ef7741b0fa453b32011e' }
}

# What a pwsh answers about itself and the machine, as JSON on one line.
$probe = Join-Path $WorkDir 'probe.ps1'
[System.IO.File]::WriteAllText($probe, @"
`$ErrorActionPreference = 'Stop'
Import-Module '$module' -Force
`$h = Get-AvdHostArchitecture
`$c = Get-AvdConfig -NoCreate
[pscustomobject]@{
    Os          = `$h.Os
    Process     = `$h.Process
    Emulated    = `$h.Emulated
    Runtime     = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    PA          = [string]`$env:PROCESSOR_ARCHITECTURE
    W6432       = [string]`$env:PROCESSOR_ARCHITEW6432
    PeOfSelf    = Get-AvdExecutableArchitecture -Path (Get-Process -Id `$PID).Path
    Config      = `$c.ARCHITECTURE
    Abi         = `$c.AVD_ABI
    Pwsh        = `$PSVersionTable.PSVersion.ToString()
} | ConvertTo-Json -Compress
"@)

function Invoke-Probe([string]$PwshPath) {
    $r = Invoke-AvdProcess -FilePath $PwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $probe) -TimeoutSec 300
    if ($r.ExitCode -ne 0) { throw "$PwshPath exited $($r.ExitCode): $($r.StdErr.Trim())" }
    $r.StdOut.Trim() | ConvertFrom-Json
}

$failures = [System.Collections.Generic.List[string]]::new()
$rows = [System.Collections.Generic.List[object]]::new()
function Test-Answer([string]$Label, $Got, [string]$WantProcess) {
    $rows.Add([pscustomobject]@{ Pwsh = $Label; Os = $Got.Os; Process = $Got.Process; Emulated = $Got.Emulated; PROCESSOR_ARCHITECTURE = $Got.PA; PROCESSOR_ARCHITEW6432 = $Got.W6432; OSArchitecture = $Got.Runtime; AVD_ABI = $Got.Abi })
    if ($Got.Os -ne $Expect) { $failures.Add("$Label`: Os $($Got.Os), expected $Expect") }
    if ($Got.Config -ne $Expect) { $failures.Add("$Label`: config ARCHITECTURE $($Got.Config), expected $Expect") }
    if ($Got.Process -ne $WantProcess) { $failures.Add("$Label`: Process $($Got.Process), expected $WantProcess") }
    if ($Got.PeOfSelf -ne $WantProcess) { $failures.Add("$Label`: its pwsh.exe reads as $($Got.PeOfSelf), expected $WantProcess") }
    if ([bool]$Got.Emulated -ne ($WantProcess -ne $Expect)) { $failures.Add("$Label`: Emulated $($Got.Emulated)") }
    $wantAbi = Get-AvdDefaultAbi -Architecture $Expect
    if ($Got.Abi -ne $wantAbi) { $failures.Add("$Label`: AVD_ABI default $($Got.Abi), expected $wantAbi") }
}

# 1. This pwsh, native on both runners.
Test-Answer "native ($((Get-Process -Id $PID).Path))" (Invoke-Probe (Get-Process -Id $PID).Path) $Expect

# 2. The other builds, under emulation: x64 and x86 on Arm64, x86 on x64.
$others = if ($Expect -eq 'Arm64') { @('X64', 'X86') } else { @('X86') }
foreach ($a in $others) {
    $z = $zips[$a]
    $zip = Join-Path $WorkDir $z.Name
    Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/$release/$($z.Name)" -OutFile $zip -TimeoutSec 120
    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -cne $z.Sha256) { throw "$($z.Name): sha256 $sha, the release publishes $($z.Sha256)" }
    $dir = Join-Path $WorkDir "pwsh-$a"
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    Test-Answer "$a build under emulation" (Invoke-Probe (Join-Path $dir 'pwsh.exe')) $a
}

$rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

# 3. What the pipeline's programs are built for, on this machine. Reported only.
$tools = [ordered]@{}
foreach ($n in 'git', 'uv', 'icloudpd') {
    $c = Get-Command -Name $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $tools[$n] = if ($c) { $c.Source } else { '' }
}
$uv = $tools['uv']
if ($uv) {
    $py = (Invoke-AvdProcess -FilePath $uv -ArgumentList @('python', 'find', '3.13') -TimeoutSec 120).StdOut.Trim()
    $tools['python 3.13 (uv)'] = $py
    $toolDir = (Invoke-AvdProcess -FilePath $uv -ArgumentList @('tool', 'dir') -TimeoutSec 60).StdOut.Trim()
    if ($toolDir) { $tools['icloudpd''s Python'] = Join-Path $toolDir 'icloudpd' 'Scripts' 'python.exe' }
}
$tools['conhost'] = Join-Path $env:SystemRoot 'System32' 'conhost.exe'
$tools['schtasks'] = Join-Path $env:SystemRoot 'System32' 'schtasks.exe'
$peRows = foreach ($k in $tools.Keys) {
    $p = $tools[$k]
    $pa = if ($p) { Get-AvdExecutableArchitecture -Path $p } else { '' }
    [pscustomobject]@{ Program = $k; Architecture = $(if ($pa) { $pa } elseif ($p) { '(not a PE file)' } else { '(absent)' }); Native = [bool]($pa -and $pa -eq $Expect); Path = $p }
}
$peRows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

if ($env:GITHUB_ACTIONS -eq 'true') {
    $answers = ($rows | ForEach-Object { "$($_.Pwsh): Os=$($_.Os) Process=$($_.Process) PROCESSOR_ARCHITECTURE=$($_.PROCESSOR_ARCHITECTURE) W6432=$(if ($_.PROCESSOR_ARCHITEW6432) { $_.PROCESSOR_ARCHITEW6432 } else { '(unset)' }) AVD_ABI=$($_.AVD_ABI)" }) -join '; '
    $pe = ($peRows | ForEach-Object { "$($_.Program)=$($_.Architecture)" }) -join ', '
    Write-Host "::notice title=Architecture ($Expect)::$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription): $answers. Programs: $pe"
}
if ($failures.Count) {
    foreach ($f in $failures) { Write-Host "FAILED: $f" }
    exit 1
}
Write-Host "architecture answers: ok ($Expect)"
exit 0
