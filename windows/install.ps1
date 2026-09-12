#Requires -Version 7.4
<#
.SYNOPSIS
Install (or remove) the pipeline on Windows: the commands on PATH, the config,
the scheduled tasks and the Start Menu shortcuts. The Windows twin of
install.sh.

.DESCRIPTION
NOTHING IT INSTALLS DOES ANYTHING YET. The sync task is registered, but the
sync itself is dormant until `avd-photos-arm -Yes` creates the arming
sentinel, so a freshly installed machine downloads nothing and deletes
nothing.

  .\windows\install.ps1                  put windows\bin on your PATH, write the
                                         config, register the tasks, start the tray
  .\windows\install.ps1 -Copy            install a self-contained copy under
                                         %LOCALAPPDATA%\avd-photos\app, so the
                                         checkout can be deleted afterwards
  .\windows\install.ps1 -NoTasks         no scheduled tasks (run things by hand)
  .\windows\install.ps1 -NoTray          no tray task and no Photo Sync shortcut
  .\windows\install.ps1 -VisibleConsole  register the background tasks as plain
                                         `pwsh -WindowStyle Hidden` (a brief
                                         console flash per run) instead of under
                                         `conhost --headless`
  .\windows\install.ps1 -Uninstall       undo all of the above

UNINSTALL KEEPS YOUR DATA: the config, the ledgers, the logs, the staging tree,
the emulator and its SDK stay exactly where they are, and it prints where they
live so you can remove them deliberately.

Run it from PowerShell 7 (pwsh) as yourself, not as administrator: the tasks
run as the user who registers them.
#>
[CmdletBinding()]
param(
    [switch]$Copy,
    [switch]$NoTasks,
    [switch]$NoTray,
    [switch]$VisibleConsole,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Continue'
if (-not $IsWindows) {
    Write-Host 'install.ps1 is for Windows; on macOS run ./install.sh.'
    exit 2
}
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib' 'AvdPhotos.psm1') -Force
$cfg = Get-AvdConfig
# The machine's architecture, not this pwsh's (an x64 pwsh on an Arm64 PC is
# told AMD64): Get-AvdHostArchitecture, through the config.
$arch = $cfg.ARCHITECTURE
$taskPwsh = Resolve-AvdTaskPwsh -Path (Get-Process -Id $PID).Path -ProgramFiles $env:ProgramFiles -Architecture $arch
$pwsh = $taskPwsh.Path
$layoutLink = Get-AvdInstallLayout -RepoRoot $repoRoot -LocalAppData $env:LOCALAPPDATA
$layoutCopy = Get-AvdInstallLayout -RepoRoot $repoRoot -LocalAppData $env:LOCALAPPDATA -Copy
$layout = if ($Copy) { $layoutCopy } else { $layoutLink }

function Write-Head([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor White }
function Write-Say([string]$Text) { Write-Host "  $Text" }

# -- Uninstall ------------------------------------------------------------------
if ($Uninstall) {
    Write-Head 'Tasks'
    foreach ($d in (Get-AvdTaskDefinition -BinDir $layout.BinDir)) {
        if (Unregister-AvdTask -Name $d.Name) { Write-Say "removed $($d.Name)" } else { Write-Say "$($d.Name) was not registered" }
    }
    if (Stop-AvdTray) { Write-Say 'asked the running tray to quit' }

    Write-Head 'Commands'
    # ONLY WHAT WE ADDED: the two directories an install can have put on the
    # user PATH, compared exactly. Any other entry is someone else's.
    $p = Get-AvdUserPath
    $new = $p.Value
    foreach ($dir in @($layoutLink.BinDir, $layoutCopy.BinDir)) { $new = Remove-AvdPathEntry -PathValue $new -Entry $dir }
    if ($new -ne $p.Value) { Set-AvdUserPath -Value $new -Kind $p.Kind; Write-Say 'removed the commands from your PATH' }
    else { Write-Say 'the commands were not on your PATH' }
    if (Test-Path -LiteralPath $layoutCopy.Root) {
        Remove-Item -LiteralPath $layoutCopy.Root -Recurse -Force
        Write-Say "removed $($layoutCopy.Root)"
    }

    Write-Head 'Shortcuts'
    foreach ($w in 'PhotoSync', 'GooglePhotos') {
        $lnk = Get-AvdShortcutPath -Which $w
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Say "removed $lnk" }
    }

    @"

Left in place, deliberately -- remove them by hand if you mean to:
  config     $($cfg.CONFIG_DIR)
  state      $($cfg.STATE_DIR)   (ledgers: what was pushed, confirmed and reclaimed)
  logs       $($cfg.LOG_DIR)
  staging    $($cfg.STAGING)
  emulator   $(Join-Path $cfg.AVD_HOME "$($cfg.AVD_NAME).avd")
  SDK        $($cfg.AVD_SDK_ROOT)
"@ | Write-Host
    exit 0
}

# -- Install --------------------------------------------------------------------
Write-Head 'Requirements'
if ($taskPwsh.Problem) {
    Write-Say "STOPPED: $($taskPwsh.Problem)"
    exit 1
}
if ($pwsh -ne (Get-Process -Id $PID).Path) { Write-Say "the tasks and shortcuts will run $pwsh (not the Microsoft Store PowerShell running this)" }
$me = Get-AvdHostArchitecture
Write-Say "architecture: $arch$(if ($me.Emulated) { " (this PowerShell is the $($me.Process) build, under emulation)" })"
$pwshNote = Get-AvdTaskPwshNote -PwshArchitecture (Get-AvdExecutableArchitecture -Path $pwsh) -Architecture $arch
if ($pwshNote) { Write-Say "NOTE: $pwshNote" }
Add-AvdToolPath -Directory @((Join-Path $cfg.AVD_SDK_ROOT 'platform-tools'))
$missing = [System.Collections.Generic.List[string]]::new()
# Java serves only the Android SDK tools, which is to say the emulator; on
# Windows on Arm there is none to build (the note below), so it is not asked
# for there.
$tools = if ($arch -eq 'Arm64') { @('git', 'uv') } else { @('java', 'git', 'uv') }
foreach ($t in $tools) {
    if (-not (Get-Command -Name $t -CommandType Application -ErrorAction SilentlyContinue)) { $missing.Add($t) }
}
if (-not (Get-Command -Name $cfg.ICLOUDPD -CommandType Application -ErrorAction SilentlyContinue)) { $missing.Add('icloudpd') }
if ($missing.Count) {
    Write-Say "MISSING: $($missing -join ' ')"
    foreach ($m in $missing) { Write-Say "  $m`: $(Get-AvdInstallHint -Tool $m -Architecture $arch)" }
    Write-Say "See 'Windows > Requirements' in the README. Install them and re-run; nothing below needs them yet."
} else {
    Write-Say 'all present'
}
if ($arch -eq 'Arm64') {
    Write-Say ''
    foreach ($l in (Get-AvdWindowsOnArmNote)) { Write-Say $l }
}
# adb.exe is not long-path aware, and a staged path past 260 characters then
# fails to push; say so now rather than in a sync log weeks later.
$lp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue
if (-not $lp -or $lp.LongPathsEnabled -ne 1) {
    Write-Say 'NOTE: long paths are off (LongPathsEnabled=0). Keep STAGING short, or see "Windows > Troubleshooting" in the README.'
}

Write-Head "Commands -> $($layout.BinDir)"
if ($Copy) {
    if (Test-Path -LiteralPath $layoutCopy.Root) { Remove-Item -LiteralPath $layoutCopy.Root -Recurse -Force }
    foreach ($item in $layoutCopy.Items) {
        $src = Join-Path $repoRoot $item
        $dst = Join-Path $layoutCopy.Root $item
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    Write-Say "copied $($layoutCopy.Items -join ', ') to $($layoutCopy.Root)"
}
$p = Get-AvdUserPath
$new = $p.Value
# One install at a time on PATH: switching between the checkout and -Copy
# must not leave both.
foreach ($dir in @($layoutLink.BinDir, $layoutCopy.BinDir)) {
    if ($dir -ne $layout.BinDir) { $new = Remove-AvdPathEntry -PathValue $new -Entry $dir }
}
$new = Add-AvdPathEntry -PathValue $new -Entry $layout.BinDir
if ($new -ne $p.Value) {
    Set-AvdUserPath -Value $new -Kind $p.Kind
    Write-Say 'added to your user PATH; open a new terminal for it to take effect'
} else {
    Write-Say 'already on your user PATH'
}

Write-Head 'Config'
if (Test-Path -LiteralPath $cfg.CONFIG_FILE) {
    Write-Say "keeping $($cfg.CONFIG_FILE)"
} else {
    Write-AvdDefaultConfig -Path $cfg.CONFIG_FILE -Architecture $arch
    Write-Say "wrote $($cfg.CONFIG_FILE)"
}
# It holds an Apple ID and may hold a GITHUB_TOKEN, whoever wrote it.
if ((Protect-AvdFile -Path $cfg.CONFIG_FILE) -eq 'tightened') {
    Write-Say "restricted $($cfg.CONFIG_FILE) to you and SYSTEM (it holds an Apple ID)"
}
if (-not $cfg.ICLOUD_USERNAME) { Write-Say "SET ICLOUD_USERNAME in $($cfg.CONFIG_FILE) before arming." }
foreach ($w in $cfg.WARNINGS) { Write-Say "config: $w" }

Write-Head 'Shortcuts'
$gp = Get-AvdShortcutPath -Which GooglePhotos
Set-AvdShortcut -Path $gp -PwshPath $pwsh -Script (Join-Path $layout.BinDir 'avd-photos-app.ps1') -ScriptArgument @('-Open') `
    -Description 'Boot the rooted emulator if needed and open Google Photos in it'
Write-Say "wrote $gp"
if (-not $NoTray) {
    $ps = Get-AvdShortcutPath -Which PhotoSync
    Set-AvdShortcut -Path $ps -PwshPath $pwsh -Script (Join-Path $layout.BinDir 'avd-photos-tray.ps1') -Sta `
        -Description 'Photo Sync: the iCloud -> Google Photos ring'
    Write-Say "wrote $ps"
}

if (-not $NoTasks) {
    Write-Head 'Scheduled tasks'
    $defs = Get-AvdTaskDefinition -BinDir $layout.BinDir -NoTray:$NoTray
    foreach ($d in $defs) {
        try {
            $null = Register-AvdTask -Definition $d -PwshPath $pwsh -WorkingDirectory $cfg.STATE_DIR -VisibleConsole:$VisibleConsole -ErrorAction Stop
            Write-Say "registered $($d.Name)"
        } catch {
            Write-Say "could not register $($d.Name): $($_.Exception.Message)"
        }
    }
    if ($NoTray) { $null = Unregister-AvdTask -Name "$(Get-AvdLabelPrefix).tray" }
    if (-not $NoTray) {
        # Newest wins: ask an older tray to go, then start this one.
        if (Stop-AvdTray) { Start-Sleep -Seconds 2 }
        Start-ScheduledTask -TaskName "$(Get-AvdLabelPrefix).tray" -TaskPath '\' -ErrorAction SilentlyContinue
        Write-Say 'started the tray (Photo Sync)'
    }
    # The bootstrap task is NOT started now, unlike launchd's RunAtLoad: step
    # 3 below runs the same setup in front of you, and a background copy would
    # only hold the setup lock against it. It resumes an unfinished setup at
    # each later logon.
}

@"

Installed. NOTHING SYNCS YET -- the pipeline is dormant until you arm it.

Next, in a NEW PowerShell 7 window, in order:
  1. avd-photos-config          check the config; set ICLOUD_USERNAME
  2. icloudpd --username <your apple id> --directory "$($cfg.STAGING)" --recent 1
                                the one-time Apple login (two-factor, interactive)
  3. avd-photos-setup           build the rooted emulator (long, downloads GBs)
  4. avd-signin                 boot it in software GL and sign in to Google;
                                register the device id the setup printed at
                                https://www.google.com/android/uncertified/
  5. avd-photos-check           confirm Magisk, Zygisk, the spoof and Photos
  6. avd-photos-offload -DryRun see which photos the reclaim would match
  7. avd-photos-arm             ARM IT (-Yes). From here the sync downloads,
                                uploads, verifies and reclaims iCloud space on its own.

Watch it: the tray ring, ``avd-photos-status | ConvertFrom-Json``, or
  Get-Content -Wait "$(Join-Path $cfg.LOG_DIR 'sync.log')"
"@ | Write-Host
if ($arch -eq 'Arm64') {
    Write-Host 'On Windows on Arm, steps 1 and 2 work now; steps 3 to 7 need the emulator, which'
    Write-Host 'Google does not publish for Windows on Arm (the note under Requirements above).'
}
exit 0
