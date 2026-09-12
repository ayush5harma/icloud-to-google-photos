#Requires -Version 7.4
<#
.SYNOPSIS
What the setup fetches from Google, on a real machine of each architecture, up
to the emulator and never including it.

.DESCRIPTION
CI runs it on windows-latest (x64) and windows-11-arm (Arm64), in a scratch
config, state, SDK root and Android user home.

  1. The gate. On Arm64, avd-photos-setup.ps1 -Check runs as a child process
     and must stop with the Windows on Arm message (exit 1) having downloaded
     nothing: an empty SDK root, no command-line tools archive. On x64 the gate
     must not even read Google's index.
  2. The command-line tools, installed by the setup's own downloader (size and
     SHA-1 from Google's manifest, the archive chosen for this machine's
     architecture).
  3. Their sdkmanager, run through the setup's own runner on this machine's JDK
     (JAVA_HOME; on Arm64 the setup refuses a JDK that is not arm64): what it
     offers this host as "emulator" and "platform-tools", then platform-tools
     installed.
  4. adb.exe run (`adb version`), with the PE architecture of it and of
     java.exe: Google ships one Windows platform-tools, and on Arm64 whatever
     it is built for runs under emulation unless it is arm64.

Needs network access and a JDK 17 or newer. Touches nothing outside WorkDir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('X64', 'Arm64')][string]$Expect,
    [string]$WorkDir
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Test-SdkHost.ps1 runs on Windows only' }
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sdkhost-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Force -Path $WorkDir

# Everything the setup reads or writes, under WorkDir; children inherit it.
$env:AVD_PHOTOS_CONFIG_DIR = Join-Path $WorkDir 'config'
$env:AVD_PHOTOS_STATE_DIR = Join-Path $WorkDir 'state'
$env:AVD_PHOTOS_LOG_DIR = Join-Path $WorkDir 'logs'
$env:AVD_SDK_ROOT = Join-Path $WorkDir 'sdk'
$env:ANDROID_AVD_HOME = Join-Path $WorkDir 'avd'
$env:ANDROID_USER_HOME = Join-Path $WorkDir 'android-user-home'
$notes = [System.Collections.Generic.List[string]]::new()
function Stop-Smoke([string]$Message) {
    Write-Host "FAILED: $Message"
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error title=SDK host ($Expect)::$Message" }
    exit 1
}

# -- 1. The gate -----------------------------------------------------------------
$cfg = Get-AvdConfig
if ($cfg.ARCHITECTURE -ne $Expect) { Stop-Smoke "config ARCHITECTURE is $($cfg.ARCHITECTURE), expected $Expect" }
if ($Expect -eq 'Arm64') {
    $setup = Join-Path $PSScriptRoot '..' 'bin' 'avd-photos-setup.ps1'
    $r = Invoke-AvdProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $setup, '-Check') -TimeoutSec 300
    Write-Host $r.StdOut
    if ($r.StdErr) { Write-Host $r.StdErr }
    if ($r.ExitCode -ne 1) { Stop-Smoke "avd-photos-setup -Check exited $($r.ExitCode), expected 1" }
    if ($r.StdOut -notmatch 'Windows on Arm: no Android Emulator') { Stop-Smoke 'avd-photos-setup -Check did not print the Windows on Arm message' }
    $left = @(Get-ChildItem -LiteralPath $env:AVD_SDK_ROOT -Recurse -File -ErrorAction SilentlyContinue)
    if ($left.Count) { Stop-Smoke "the stopped setup left $($left.Count) file(s) in the SDK root" }
    if (Test-Path -LiteralPath (Join-Path $env:AVD_PHOTOS_STATE_DIR 'cmdline-tools-download.zip')) { Stop-Smoke 'the stopped setup downloaded the command-line tools' }
    $notes.Add('avd-photos-setup -Check stopped with the Windows on Arm message, exit 1, nothing downloaded')
}
$s = Initialize-AvdSetupState -Config $cfg -Environment (Get-AvdEnvironment) -Mode Full -Headless
$null = New-Item -ItemType Directory -Force -Path $s.Stamps
if ($Expect -eq 'X64') {
    if ($null -ne (Get-AvdSetupEmulatorBlocker)) { Stop-Smoke 'the Windows on Arm gate answered on an x64 machine' }
    # The manifest is cached only by a fetch, so an empty cache means no request.
    if ($s.SdkManifest) { Stop-Smoke 'the gate read Google''s index on an x64 machine' }
    $notes.Add('the Windows on Arm gate did not read Google''s index')
}

# -- 2. The command-line tools, by the setup's own downloader --------------------
Install-AvdSetupCmdlineTool
if (-not (Test-Path -LiteralPath $s.SdkManager -PathType Leaf)) { Stop-Smoke "no sdkmanager at $($s.SdkManager)" }
$tools = ConvertFrom-AvdSdkRepositoryXml -Xml (Get-AvdSetupSdkManifest) -HostOs windows -HostArch (ConvertTo-AvdSdkHostArch $Expect) -Channel channel-0
$notes.Add("cmdline-tools $($tools.Revision) ($(Split-Path -Leaf $tools.Url), host-arch $(if ($tools.HostArch) { $tools.HostArch } else { 'none: every architecture' })) verified by size and SHA-1 and unpacked")

# -- 3. sdkmanager on this machine's JDK -------------------------------------------
$java = Get-AvdSetupJavaPath
$javaArch = Get-AvdExecutableArchitecture -Path $java
$null = Invoke-AvdSetupSdkManager -ArgumentList @('--licenses') -StdinText ("y`n" * 100) -TimeoutSec 600
$list = Invoke-AvdSetupSdkManager -ArgumentList @('--list') -TimeoutSec 900
if ($list.ExitCode -ne 0) { Stop-Smoke "sdkmanager --list exited $($list.ExitCode): $($list.StdErr.Trim())" }
$available = $false
$offered = @{}
foreach ($line in (ConvertTo-AvdLf $list.StdOut).Split("`n")) {
    if ($line -match '^\s*Available (Packages|Updates):') { $available = $Matches[1] -eq 'Packages'; continue }
    if ($available -and $line -match '^\s*(emulator|platform-tools)\s*\|\s*([^|]+?)\s*\|') { $offered[$Matches[1]] = $Matches[2] }
}
foreach ($p in 'emulator', 'platform-tools') {
    $notes.Add("sdkmanager on java.exe ($javaArch) offers $p`: $(if ($offered.Contains($p)) { $offered[$p] } else { 'nothing' })")
}
$r = Invoke-AvdSetupSdkManager -ArgumentList @('--install', 'platform-tools') -TimeoutSec 900
if ($r.ExitCode -ne 0) { Stop-Smoke "sdkmanager --install platform-tools exited $($r.ExitCode): $($r.StdErr.Trim())" }

# -- 4. adb ----------------------------------------------------------------------
$adb = Get-AvdSdkToolPath -SdkRoot $s.SdkRoot -Name adb -Platform Windows
if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) { Stop-Smoke "no adb.exe at $adb after installing platform-tools" }
$adbArch = Get-AvdExecutableArchitecture -Path $adb
$v = Invoke-AvdProcess -FilePath $adb -ArgumentList @('version') -TimeoutSec 120
if ($v.ExitCode -ne 0) { Stop-Smoke "adb version exited $($v.ExitCode): $($v.StdErr.Trim())" }
$first = ((ConvertTo-AvdLf $v.StdOut).Split("`n") | Where-Object { $_ } | Select-Object -First 1)
$how = if ($adbArch -eq $Expect) { 'native' } else { 'under emulation' }
$notes.Add("adb.exe ($adbArch, $how) runs: $first")

foreach ($n in $notes) { Write-Host "  $n" }
if ($env:GITHUB_ACTIONS -eq 'true') {
    Write-Host "::notice title=SDK host ($Expect)::$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription): $($notes -join '; ')"
}
Write-Host "SDK host: ok ($Expect)"
exit 0
