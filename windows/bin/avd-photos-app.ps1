#Requires -Version 7.4
<#
.SYNOPSIS
"Google Photos (AVD)": boot the rooted emulator if it is not up, open Google
Photos in it, bring its window forward. The Windows twin of bin/avd-photos-app.

.DESCRIPTION
  avd-photos-app          (re)write the Start Menu shortcut "Google Photos (AVD)"
  avd-photos-app -Open    what the shortcut runs: boot, open Photos, focus

On macOS this builds an .app bundle, because only a bundle can sit in the Dock,
and rebuilds it at every login so its icon follows the light/dark appearance.
A Start Menu shortcut needs neither: it is written once (install.ps1 does it)
and can be pinned to Start or the taskbar like any other.

The launcher boots through avd-start rather than invoking the emulator: the
launch flags (the GPU one above all) are load-bearing and have exactly ONE
definition, in the setup's boot function.
#>
[CmdletBinding()]
param([switch]$Open)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
$cfg = Get-AvdConfig
$log = Join-Path $cfg.LOG_DIR 'launcher.log'
Initialize-AvdLog -Path $log
$pkg = 'com.google.android.apps.photos'

if (-not $Open) {
    if (-not $IsWindows) { Write-Host 'the Start Menu shortcut is Windows-only'; exit 2 }
    $lnk = Get-AvdShortcutPath -Which GooglePhotos
    Set-AvdShortcut -Path $lnk -PwshPath (Get-Process -Id $PID).Path -Script $PSCommandPath -ScriptArgument @('-Open') `
        -Description 'Boot the rooted emulator if needed and open Google Photos in it'
    Write-Host "wrote $lnk"
    exit 0
}

Add-AvdToolPath -Directory @((Join-Path $cfg.AVD_SDK_ROOT 'platform-tools'))
if (-not (Test-AvdEmulatorRunning -AvdName $cfg.AVD_NAME)) {
    Write-AvdLog -Path $log -Message "starting $($cfg.AVD_NAME)"
    & (Join-Path $PSScriptRoot 'avd-start.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-AvdLog -Path $log -Message "avd-start failed ($LASTEXITCODE)"
        exit 1
    }
}
# Which attached emulator IS ours: another emulator started earlier owns
# emulator-5554, and this launcher would then open Photos inside a stranger's
# device.
$serial = Get-AvdEmulatorSerial -AvdName $cfg.AVD_NAME
if (-not $serial) {
    Write-AvdLog -Path $log -Message "no attached emulator answers to $($cfg.AVD_NAME)"
    exit 1
}
$r = Invoke-AvdAdbShell -Serial $serial -Command @('monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') -TimeoutSec 30
Write-AvdLog -Path $log -Message "opened Google Photos on $serial (monkey rc=$($r.ExitCode))"
if ($IsWindows) {
    # Best effort: the emulator's window title starts "Android Emulator - <name>".
    try { $null = (New-Object -ComObject WScript.Shell).AppActivate("Android Emulator - $($cfg.AVD_NAME)") }
    catch { Write-AvdLog -Path $log -Message "could not focus the emulator window: $($_.Exception.Message)" }
}
exit 0
