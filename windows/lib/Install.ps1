# What install.ps1 does, as functions: the scheduled tasks that stand in for
# the five launchd agents, the user PATH entry, the Start Menu shortcuts. The
# definitions are plain data built by pure functions (tested on any OS); only
# the Register-/Unregister-/Set- functions touch Task Scheduler, the registry
# or the shell, and they are Windows-only.
#
# launchd -> Task Scheduler, agent by agent:
#   .sync       every 900 s + at load  -> every 15 minutes + at logon
#   .setup      Saturday 05:30         -> weekly, Saturday 05:30
#   .bootstrap  at load                -> at logon
#   .menubar    at load, KeepAlive     -> .tray at logon, restart-on-failure set
#   .app        at load                -> no task: it rebuilt the Dock icon for
#                                         the light/dark appearance at each login;
#                                         a Start Menu shortcut has no such need
#                                         and is written once, at install.

# The four tasks, in registration order. -BinDir is where the commands live.
function Get-AvdTaskDefinition {
    param(
        [Parameter(Mandatory)][string]$BinDir,
        [string]$LabelPrefix = (Get-AvdLabelPrefix),
        [switch]$NoTray
    )
    $sep = if ($BinDir.Contains('\')) { '\' } else { [System.IO.Path]::DirectorySeparatorChar }
    $inBin = { param($name) $BinDir.TrimEnd('\', '/') + $sep + $name }
    $defs = @(
        [pscustomobject]@{
            Suffix      = 'sync'
            Name        = "$LabelPrefix.sync"
            Description = 'icloud-to-google-photos: the sync (iCloud -> emulator -> Google Photos -> verify -> reclaim). Dormant until avd-photos-arm -Yes.'
            Script      = & $inBin 'avd-photos-sync.ps1'
            Arguments   = @()
            # At logon as well as every 15 minutes: the icloudpd incremental
            # pass IS the "anything new in iCloud" check, and a laptop that is
            # shut down most nights would rarely reach a clock-only trigger
            # (the launchd RunAtLoad reasoning).
            Triggers    = @([pscustomobject]@{ Kind = 'Logon' }, [pscustomobject]@{ Kind = 'Repeat'; Minutes = 15 })
            Headless    = $true
            Tray        = $false
            # Below normal, as launchd's Background band with Nice 5: runs
            # missed while the machine slept all start together at wake, so
            # priority, not scheduling, keeps them out of the way.
            Priority    = 7
        },
        [pscustomobject]@{
            Suffix      = 'setup'
            Name        = "$LabelPrefix.setup"
            Description = 'icloud-to-google-photos: the weekly re-run of the setup, which IS the update. Never recreates the emulator or re-roots it; it reports those.'
            Script      = & $inBin 'avd-photos-setup.ps1'
            Arguments   = @('-Headless')
            Triggers    = @([pscustomobject]@{ Kind = 'Weekly'; Day = 'Saturday'; At = '05:30' })
            Headless    = $true
            Tray        = $false
            Priority    = 7
        },
        [pscustomobject]@{
            Suffix      = 'bootstrap'
            Name        = "$LabelPrefix.bootstrap"
            Description = 'icloud-to-google-photos: resumes an unfinished setup at logon; returns at once when setup has completed.'
            Script      = & $inBin 'avd-photos-setup.ps1'
            Arguments   = @('-Bootstrap')
            Triggers    = @([pscustomobject]@{ Kind = 'Logon' })
            Headless    = $true
            Tray        = $false
            Priority    = 7
        }
    )
    if (-not $NoTray) {
        $defs += [pscustomobject]@{
            Suffix      = 'tray'
            Name        = "$LabelPrefix.tray"
            Description = 'icloud-to-google-photos: Photo Sync, the tray ring.'
            Script      = & $inBin 'avd-photos-tray.ps1'
            Arguments   = @()
            Triggers    = @([pscustomobject]@{ Kind = 'Logon' })
            Headless    = $false
            Tray        = $true
            # Normal, not the background band: a person is looking at it
            # (launchd's Interactive ProcessType for the menu bar).
            Priority    = 5
        }
    }
    , $defs
}

# What a task runs. A 15-minute job must not flash a console window at the
# person using the machine, so the background tasks run pwsh inside
# `conhost.exe --headless`, which gives it a console with no window.
# (Undocumented but present on every Windows 11 build; -VisibleConsole
# registers plain `pwsh -WindowStyle Hidden` instead, which flashes briefly.)
# Their long-lived child, the emulator, is started detached from that console
# (Start-AvdEmulatorProcess), or the headless console -- the process Task
# Scheduler tracks -- would outlive the run and every later tick would be
# skipped as a second instance.
# The tray runs plain pwsh hidden, never under conhost: restart-on-failure
# reads the exit code of the process it started, and that must be the tray's.
function Get-AvdTaskAction {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$PwshPath,
        [string]$SystemRoot = $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }),
        [switch]$VisibleConsole
    )
    $pwshArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
    if ($Definition.Tray) { $pwshArgs += @('-WindowStyle', 'Hidden', '-STA') }
    elseif ($VisibleConsole) { $pwshArgs += @('-WindowStyle', 'Hidden') }
    $pwshArgs += @('-File', $Definition.Script) + @($Definition.Arguments)
    if ($Definition.Headless -and -not $VisibleConsole) {
        return [pscustomobject]@{
            Execute  = $SystemRoot.TrimEnd('\') + '\System32\conhost.exe'
            Argument = '--headless ' + (ConvertTo-AvdCommandLine -ArgumentList (@($PwshPath) + $pwshArgs))
        }
    }
    [pscustomobject]@{ Execute = $PwshPath; Argument = (ConvertTo-AvdCommandLine -ArgumentList $pwshArgs) }
}

# A tool in System32 (schtasks.exe), by the Windows directory rather than
# PATH, so a stray schtasks.exe earlier on PATH is never the one run.
function Get-AvdSystemToolPath {
    param([Parameter(Mandatory)][string]$Name)
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $root.TrimEnd('\') + '\System32\' + $Name
}

# The pwsh the tasks and shortcuts name. A Microsoft Store (MSIX) install runs
# from a versioned folder under WindowsApps that the next Store update
# replaces, so a task naming it stops starting after that update: the whole
# pipeline off, with nothing on screen. The MSI install (winget's default
# source) keeps one path across updates, so it is used when it is there;
# otherwise the install stops and says how to get it. The Store's app
# execution alias would be the other way out, but whether Task Scheduler
# starts an alias has not been tested here, so it is not relied on.
function Resolve-AvdTaskPwsh {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ProgramFiles,
        [AllowEmptyString()][string]$Architecture = (Get-AvdHostArchitecture).Os
    )
    if ($Path -notmatch '[\\/]WindowsApps[\\/]') { return [pscustomobject]@{ Path = $Path; Problem = $null } }
    if ($ProgramFiles) {
        $msi = Join-Path $ProgramFiles 'PowerShell' '7' 'pwsh.exe'
        if (Test-Path -LiteralPath $msi -PathType Leaf) { return [pscustomobject]@{ Path = $msi; Problem = $null } }
    }
    [pscustomobject]@{
        Path    = $null
        Problem = "this is the Microsoft Store PowerShell ($Path); its folder changes with every Store update, which would leave the scheduled tasks pointing at nothing. Install the MSI build ($(Get-AvdInstallHint -Tool pwsh -Architecture $Architecture)) and run install.ps1 again"
    }
}

# Whether the pwsh the tasks will run is the machine's own build. On Windows on
# Arm an x64 pwsh works -- Windows runs it under emulation -- but every task and
# the tray then run emulated too, so the installer says so and names the arm64
# build. Asked of the file (its PE header), because the tasks may name a
# different pwsh.exe from the one running the installer (Resolve-AvdTaskPwsh).
# $null when there is nothing to say.
function Get-AvdTaskPwshNote {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PwshArchitecture,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Architecture
    )
    if ($Architecture -ne 'Arm64' -or -not $PwshArchitecture -or $PwshArchitecture -eq 'Arm64') { return $null }
    "the tasks and the tray will run the $PwshArchitecture build of PowerShell, which Windows on Arm runs under emulation. It works; the native build is faster: $(Get-AvdInstallHint -Tool pwsh -Architecture Arm64), then run install.ps1 again from it"
}

# The current user as Task Scheduler names a principal.
function Get-AvdTaskUser {
    $domain = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME }
    "$domain\$env:USERNAME"
}

# Register (or re-register, replacing) one task. Windows-only.
# Interactive logon, the current user, limited rights: the launchd gui/<uid>
# domain's equivalent. An S4U or "run whether logged on or not" task runs in
# session 0, where the user's Google Drive and iCloud Drive mounts and the
# Credential Manager entry icloudpd re-authenticates with are not visible.
# Battery: the defaults would never start a sync on a laptop on battery and
# would kill a run mid-push when it is unplugged, so both are turned off. No
# time limit: a first run against a real library is hours long (2 h 41 min in
# icloudpd alone, measured on macOS). One instance: launchd's behaviour, and
# the scripts are single-flight as well.
function Register-AvdTask {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$VisibleConsole
    )
    $user = Get-AvdTaskUser
    $a = Get-AvdTaskAction -Definition $Definition -PwshPath $PwshPath -VisibleConsole:$VisibleConsole
    $action = New-ScheduledTaskAction -Execute $a.Execute -Argument $a.Argument -WorkingDirectory $WorkingDirectory
    $triggers = foreach ($t in $Definition.Triggers) {
        switch ($t.Kind) {
            'Logon' { New-ScheduledTaskTrigger -AtLogOn -User $user }
            # -Once with a repetition interval and no duration repeats
            # indefinitely (a duration of [TimeSpan]::MaxValue is rejected by
            # current Task Scheduler as an invalid value).
            'Repeat' { New-ScheduledTaskTrigger -Once -At ([datetime]::Now.Date) -RepetitionInterval (New-TimeSpan -Minutes $t.Minutes) }
            'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $t.Day -At $t.At }
        }
    }
    $settingsArgs = @{
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = [TimeSpan]::Zero
        StartWhenAvailable         = $true
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        Priority                   = $Definition.Priority
    }
    if ($Definition.Tray) {
        # The nearest thing to launchd's KeepAlive: restart a minute later
        # (the shortest interval Task Scheduler accepts) when the task fails.
        # Whether Task Scheduler counts a tray that crashes after it started
        # as a failure has not been observed, so the README promises only the
        # next logon. A deliberate Quit exits 0 and stays quit until then,
        # where KeepAlive on macOS would relaunch it at once.
        $settingsArgs.RestartCount = 999
        $settingsArgs.RestartInterval = New-TimeSpan -Minutes 1
    }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Definition.Name -TaskPath '\' -Action $action -Trigger @($triggers) `
        -Settings $settings -Principal $principal -Description $Definition.Description -Force
}

function Unregister-AvdTask {
    param([Parameter(Mandatory)][string]$Name)
    $t = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    Stop-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false
    $true
}

# -- The user PATH --------------------------------------------------------------

# A PATH value with -Entry appended once (compared case-insensitively and
# without a trailing backslash, as Windows compares directories). Appended,
# never prepended: the pipeline's commands must not shadow anything.
function Add-AvdPathEntry {
    param([AllowEmptyString()][AllowNull()][string]$PathValue, [Parameter(Mandatory)][string]$Entry)
    $parts = @(([string]$PathValue).Split(';') | Where-Object { $_ -ne '' })
    $norm = $Entry.TrimEnd('\')
    foreach ($p in $parts) { if ($p.TrimEnd('\') -ieq $norm) { return ($parts -join ';') } }
    (@($parts) + $Entry) -join ';'
}

# A PATH value without -Entry; every other entry, %VARIABLES% included, as it was.
function Remove-AvdPathEntry {
    param([AllowEmptyString()][AllowNull()][string]$PathValue, [Parameter(Mandatory)][string]$Entry)
    $norm = $Entry.TrimEnd('\')
    @(([string]$PathValue).Split(';') | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $norm }) -join ';'
}

# The user PATH exactly as stored. Windows-only. NOT through
# [Environment]::GetEnvironmentVariable('Path','User'): that expands a
# REG_EXPAND_SZ value, and writing it back through SetEnvironmentVariable
# stores REG_SZ, which silently freezes every %VARIABLE% entry in the user's
# PATH -- the classic way an installer breaks a machine.
function Get-AvdUserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($null -ne $key.GetValue('Path')) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        [pscustomobject]@{ Value = [string]$value; Kind = $kind }
    } finally { $key.Dispose() }
}

# Write the user PATH keeping its registry type, then have .NET broadcast
# WM_SETTINGCHANGE (it does so after any user-scope variable change; deleting
# a variable that does not exist is the side-effect-free way to ask for it),
# so a terminal opened from Explorer afterwards sees the new PATH.
# [NullString]::Value, never $null: PowerShell turns $null into '' for a .NET
# string parameter, and '' would CREATE an empty variable (measured on pwsh
# 7.6.5, 2026-09-13) -- here, a stray empty value in HKCU\Environment.
function Set-AvdUserPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = 'ExpandString')
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('Path', $Value, $Kind) } finally { $key.Dispose() }
    [System.Environment]::SetEnvironmentVariable('AVD_PHOTOS_SETTINGCHANGE', [NullString]::Value, 'User')
}

# -- Where things are installed -------------------------------------------------

# -Copy installs a self-contained copy under %LOCALAPPDATA%\avd-photos\app,
# keeping the checkout's layout (windows\bin, windows\lib, windows\device and
# bin\avd-photos-reclaim.py), because every script finds its module and the
# shared reclaim script relative to itself.
function Get-AvdInstallLayout {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$LocalAppData,
        [switch]$Copy
    )
    $root = if ($Copy) { Join-AvdPath Windows $LocalAppData, 'avd-photos', 'app' } else { $RepoRoot }
    [pscustomobject]@{
        Root   = $root
        BinDir = Join-AvdPath Windows $root, 'windows', 'bin'
        Copy   = [bool]$Copy
        # Copied with -Copy; relative to the root.
        Items  = @('windows\bin', 'windows\lib', 'windows\device', 'bin\avd-photos-reclaim.py')
    }
}

# -- Start Menu shortcuts ---------------------------------------------------------

function Get-AvdShortcutPath {
    param([Parameter(Mandatory)][ValidateSet('PhotoSync', 'GooglePhotos')][string]$Which)
    $programs = [System.Environment]::GetFolderPath('Programs')
    $name = if ($Which -eq 'PhotoSync') { 'Photo Sync.lnk' } else { 'Google Photos (AVD).lnk' }
    Join-Path $programs $name
}

# A Start Menu shortcut that runs a pipeline script with pwsh, hidden.
# Windows-only (WScript.Shell is the Windows Script Host object model, not the
# VBScript engine that Windows 11 is retiring).
function Set-AvdShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$ScriptArgument = @(),
        [switch]$Sta,
        [string]$Description = ''
    )
    $pwshArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden')
    if ($Sta) { $pwshArgs += '-STA' }
    $pwshArgs += @('-File', $Script) + $ScriptArgument
    $dir = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Force -Path $dir
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($Path)
        $lnk.TargetPath = $PwshPath
        $lnk.Arguments = ConvertTo-AvdCommandLine -ArgumentList $pwshArgs
        $lnk.WorkingDirectory = Split-Path -Parent $Script
        $lnk.WindowStyle = 7
        $lnk.Description = $Description
        $lnk.Save()
    } finally {
        $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# Ask a running tray to quit (the newest-wins event avd-photos-tray.ps1
# listens for), so a reinstall or an uninstall never leaves a stale ring.
function Stop-AvdTray {
    $name = 'Local\icloud-to-google-photos.tray.quit'
    $ev = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($name, [ref]$ev)) {
        try { $null = $ev.Set() } finally { $ev.Dispose() }
        return $true
    }
    $false
}
