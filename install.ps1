<#
  Install (or remove) the pipeline on Windows: its own tools, the commands on
  PATH, the tray app, and the Task Scheduler tasks. The Windows twin of
  install.sh, and like it, NOTHING IT INSTALLS DOES ANYTHING YET: the sync task
  is registered but every run exits at once until `avd-photos-arm` creates the
  arming sentinel.

  REPRODUCIBLE FROM A FRESH WINDOWS. It needs only what a stock Windows 10/11
  ships (PowerShell 5.1, curl.exe) and no administrator rights, and it uses
  NOTHING already installed: the pipeline's scripts run under its OWN portable
  Git for Windows (the bash they need), Python is uv's managed build, and
  avd-photos-setup later fetches its own JDK and Android SDK. A PC with Android
  Studio, a system Python and Git installed gets exactly the same result as an
  empty one -- which is also the only way to test that.

    .\install.cmd                         (or: powershell -ExecutionPolicy Bypass -File install.ps1)
    .\install.ps1 -ToolsDir D:\avd-tools  its own Git, .NET SDK and NuGet cache there
    .\install.ps1 -Prefix <dir>           commands in <dir>\bin, not ~\.local\bin
    .\install.ps1 -AppDir <dir>           the tray app somewhere other than
                                          %LOCALAPPDATA%\Programs\Photo Sync
    .\install.ps1 -Copy                   a self-contained copy of bin\ and lib\,
                                          so the checkout can be deleted
    .\install.ps1 -UseInstalledGit        use an existing Git for Windows' bash
    .\install.ps1 -NoTasks                no scheduled tasks (run things by hand)
    .\install.ps1 -NoApp                  no tray app (and so no tasks: they run it)
    .\install.ps1 -Uninstall              undo all of the above

  UNINSTALL KEEPS YOUR DATA: the config, the ledgers, the logs, the staging tree,
  the emulator and the SDK stay where they are, and it prints where.
#>
[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:USERPROFILE '.local'),
    [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'Programs\Photo Sync'),
    [string]$ToolsDir = (Join-Path $env:LOCALAPPDATA 'avd-photos\tools'),
    [switch]$Copy,
    [switch]$UseInstalledGit,
    [switch]$NoTasks,
    [switch]$NoApp,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'     # PS 5.1's progress bar slows downloads 10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SrcDir = $PSScriptRoot
$BinDir = Join-Path $Prefix 'bin'
$LibExec = Join-Path $Prefix 'libexec\avd-photos'
$AppExe = Join-Path $AppDir 'PhotoSync.exe'
# Must match AP_TASK_FOLDER in lib/config.sh and TaskFolder in windows/PhotoSync.
$TaskFolder = '\icloud-to-google-photos\'
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$Arch = if (($env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE) -contains 'ARM64') { 'arm64' } else { 'x64' }

function Say([string]$m) { Write-Host "  $m" }
function Head([string]$m) { Write-Host ''; Write-Host "== $m" -ForegroundColor White }
function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# curl.exe, not Invoke-WebRequest: it ships with Windows 10 1803 and later,
# resumes nothing silently, and fails on an HTTP error instead of saving the page.
function Fetch([string]$url, [string]$out) {
    & "$env:WINDIR\System32\curl.exe" -fsSL --retry 3 --connect-timeout 20 -o $out $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "download failed: $url" }
}
function Sha256([string]$file) { (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower() }

# Native programs report progress on stderr, and under 'Stop' PowerShell 5.1
# turns each stderr line into a terminating error ("NativeCommandError") -- uv's
# "Downloading cpython..." included. So they run with that switched off, are
# judged by their exit code alone, and their output is shown (indented) or not.
function Invoke-Native([string]$exe, [string[]]$argv, [switch]$Show) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($Show) { & $exe @argv 2>&1 | ForEach-Object { Say "$_".TrimEnd() } }
        else { & $exe @argv 2>&1 | Out-Null }
    } finally { $ErrorActionPreference = $eap }
    return $LASTEXITCODE
}

# A GitHub release, through the API, once per repo per run. The asset's own
# `digest` field (sha256, recorded by GitHub at upload) is what a download is
# checked against: TLS says the bytes came from GitHub, the digest says they are
# the bytes that release was published with.
$script:Releases = @{}
function Get-Release([string]$repo) {
    if (-not $script:Releases.ContainsKey($repo)) {
        $h = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'avd-photos-install' }
        if ($env:GITHUB_TOKEN) { $h['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
        $script:Releases[$repo] = Invoke-RestMethod -UseBasicParsing -Headers $h "https://api.github.com/repos/$repo/releases/latest"
    }
    $script:Releases[$repo]
}
function Get-VerifiedAsset([string]$repo, [string]$pattern, [string]$out) {
    $rel = Get-Release $repo
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "no asset matching '$pattern' in $repo $($rel.tag_name)" }
    Fetch $asset.browser_download_url $out
    $want = ''
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-f]{64})$') { $want = $Matches[1] }
    if (-not $want) {
        # Older releases predate the digest field; Git for Windows prints its own
        # table of SHA-256s in the release notes.
        $m = [regex]::Match([string]$rel.body, [regex]::Escape($asset.name) + '\s*\|\s*([0-9a-fA-F]{64})')
        if ($m.Success) { $want = $m.Groups[1].Value.ToLower() }
    }
    if (-not $want) { throw "$($asset.name): no published sha256 to check it against -- refusing it" }
    $have = Sha256 $out
    if ($have -ne $want) { Remove-Item $out -Force; throw "$($asset.name) does not match its published sha256 -- refusing it" }
    Say "$($asset.name) ($($rel.tag_name)) sha256 $($have.Substring(0,16))... verified"
    return $rel.tag_name
}

# ToWin/ToMixed: the scripts hold paths as C:/x/y (lib/os.sh explains why);
# Windows tools want C:\x\y.
function ToMixed([string]$p) { $p.Replace('\', '/') }

# -- Git Bash: the pipeline's OWN portable copy --------------------------------
$GitDir = Join-Path $ToolsDir 'git'
function Find-Bash {
    if ($UseInstalledGit) {
        foreach ($root in @('HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows')) {
            $ip = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue).InstallPath
            if ($ip -and (Test-Path (Join-Path $ip 'usr\bin\bash.exe'))) { return (Join-Path $ip 'usr\bin\bash.exe') }
        }
        $p = Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe'
        if (Test-Path $p) { return $p }
        Fail 'no installed Git for Windows found (drop -UseInstalledGit to use the pipeline''s own)'
    }
    $own = Join-Path $GitDir 'usr\bin\bash.exe'
    if (Test-Path $own) { return $own }
    return $null
}
function Install-PortableGit {
    # PortableGit is Git for Windows as a self-extracting archive: no installer,
    # no admin, nothing registered. Unpacked into the tools directory, it runs
    # its own post-install step and is complete.
    $sfx = Join-Path $env:TEMP 'avd-photos-PortableGit.7z.exe'
    $pat = if ($Arch -eq 'arm64') { '^PortableGit-.*-arm64\.7z\.exe$' } else { '^PortableGit-.*-64-bit\.7z\.exe$' }
    $tag = Get-VerifiedAsset 'git-for-windows/git' $pat $sfx
    if (Test-Path $GitDir) { Remove-Item -Recurse -Force $GitDir }
    New-Item -ItemType Directory -Force $GitDir | Out-Null
    $p = Start-Process -FilePath $sfx -ArgumentList @("-o`"$GitDir`"", '-y') -Wait -PassThru
    Remove-Item $sfx -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -or -not (Test-Path (Join-Path $GitDir 'usr\bin\bash.exe'))) { Fail "PortableGit $tag did not unpack into $GitDir" }
    Say "Git for Windows $tag (portable) -> $GitDir"
}

# -- Uninstall -----------------------------------------------------------------
if ($Uninstall) {
    Head 'Tasks'
    foreach ($t in 'sync', 'setup', 'bootstrap', 'tray') {
        if (Get-ScheduledTask -TaskPath $TaskFolder -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskPath $TaskFolder -TaskName $t -Confirm:$false
            Say "removed $TaskFolder$t"
        }
    }
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteFolder($TaskFolder.Trim('\'), 0) } catch { }

    Head 'Tray app'
    Get-Process PhotoSync -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $AppExe } | Stop-Process -Force
    # Only a folder that IS the app is removed; -AppDir pointing at a shared
    # parent must never take that parent with it.
    if (Test-Path $AppExe) { Remove-Item -Recurse -Force $AppDir; Say "removed $AppDir" }
    elseif (Test-Path $AppDir) { Say "left $AppDir (no PhotoSync.exe in it, so not ours)" }
    foreach ($l in 'Photo Sync.lnk', 'Google Photos (AVD).lnk') {
        $f = Join-Path $StartMenu $l
        if (Test-Path $f) { Remove-Item -Force $f; Say "removed Start menu: $l" }
    }

    Head 'Commands'
    # ONLY WHAT WE INSTALLED: a shim this installer wrote names its marker line;
    # anything else in that directory belongs to someone else.
    Get-ChildItem -Path $BinDir -Filter 'avd*.cmd' -ErrorAction SilentlyContinue | ForEach-Object {
        if ((Get-Content $_.FullName -Raw) -match 'Generated by icloud-to-google-photos install\.ps1') {
            Remove-Item -Force $_.FullName; Say "removed $($_.FullName)"
        } else { Say "left $($_.FullName) (not ours)" }
    }
    if (Test-Path $LibExec) { Remove-Item -Recurse -Force $LibExec; Say "removed $LibExec" }
    if (Test-Path $GitDir) { Remove-Item -Recurse -Force $GitDir; Say "removed $GitDir" }
    $dn = Join-Path $ToolsDir 'dotnet'; if (Test-Path $dn) { Remove-Item -Recurse -Force $dn; Say "removed $dn" }
    $ng = Join-Path $ToolsDir 'nuget'; if (Test-Path $ng) { Remove-Item -Recurse -Force $ng; Say "removed $ng" }

    $cfg = Join-Path $env:USERPROFILE '.config\avd-photos'
    $state = Join-Path $env:USERPROFILE '.cache\avd-photos'
    Write-Host @"

Left in place, deliberately -- remove them by hand if you mean to:
  config     $cfg
  state      $state   (ledgers: what was pushed, confirmed and reclaimed)
  logs       $state\logs
  staging, emulator and SDK: the paths in $cfg\config (avd-photos-config --paths
             printed them before this uninstall)
  uv, icloudpd, jq in $env:USERPROFILE\.local\bin (shared tools; 'uv tool uninstall icloudpd')
"@
    exit 0
}

# -- Install -------------------------------------------------------------------
Head "Tools -> $ToolsDir"
New-Item -ItemType Directory -Force $ToolsDir, $BinDir | Out-Null
$Bash = Find-Bash
if (-not $Bash) { Install-PortableGit; $Bash = Find-Bash }
Say "bash: $Bash"
# A bash started straight from Windows has only the Windows PATH, and every
# script resolves its own directory with `dirname` and `readlink` before lib/
# can seed anything -- so whoever starts bash puts Git's own tools first. The
# shims below, the tray app and this installer all do it the same way.
$GitRoot = Split-Path (Split-Path (Split-Path $Bash))
$GitPath = "$(Join-Path $GitRoot 'usr\bin');$(Join-Path $GitRoot 'mingw64\bin')"
$env:Path = "$GitPath;$env:Path"

$LocalBin = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Force $LocalBin | Out-Null
$uv = Join-Path $LocalBin 'uv.exe'
if (-not (Test-Path $uv)) {
    # Astral's own installer: uv and uvx into ~\.local\bin, which it also adds to
    # the user PATH -- where icloudpd.exe and the command shims live too.
    $env:UV_INSTALL_DIR = $LocalBin
    Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://astral.sh/uv/install.ps1 | iex') | Out-Null
    if (-not (Test-Path $uv)) { Fail 'uv did not install' }
}
Say "uv: $((& $uv --version) -join ' ')"
$env:UV_PYTHON_PREFERENCE = 'only-managed'
if ((Invoke-Native $uv @('python', 'install', '3.13')) -ne 0) { Fail 'uv could not install Python 3.13' }
Say 'Python 3.13 (uv-managed)'

$icloudpd = Join-Path $LocalBin 'icloudpd.exe'
if (-not (Test-Path $icloudpd)) {
    Invoke-Native $uv @('tool', 'install', '--python', '3.13', 'icloudpd') | Out-Null
    if (-not (Test-Path $icloudpd)) { Fail 'icloudpd did not install (uv tool install icloudpd)' }
}
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
Say "icloudpd: $((& $icloudpd --version 2>&1 | Select-Object -First 1))"
$ErrorActionPreference = $eap

$jq = Join-Path $LocalBin 'jq.exe'
if (-not (Test-Path $jq)) {
    $jpat = if ($Arch -eq 'arm64') { '^jq-windows-(arm64|amd64)\.exe$' } else { '^jq-windows-amd64\.exe$' }
    Get-VerifiedAsset 'jqlang/jq' $jpat $jq | Out-Null
}
Say "jq: $((& $jq --version) -join ' ')"

# ~\.local\bin and the command directory on the USER path (idempotent).
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); if (-not $userPath) { $userPath = '' }
$added = @()
foreach ($d in @($LocalBin, $BinDir) | Select-Object -Unique) {
    if (($userPath -split ';') -notcontains $d) { $userPath = ($userPath.TrimEnd(';') + ";$d").TrimStart(';'); $added += $d }
}
if ($added) {
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    Say "added to your PATH: $($added -join ', ') (new terminals pick it up)"
}
$env:Path = "$LocalBin;$BinDir;$env:Path"

# -- Commands ------------------------------------------------------------------
Head "Commands -> $BinDir"
$SourceBin = Join-Path $SrcDir 'bin'
if ($Copy) {
    # bin\ and lib\ TOGETHER: every script finds its library as ../lib from its
    # own real path, so the pair must stay adjacent.
    if (Test-Path $LibExec) { Remove-Item -Recurse -Force $LibExec }
    New-Item -ItemType Directory -Force $LibExec | Out-Null
    Copy-Item -Recurse (Join-Path $SrcDir 'bin'), (Join-Path $SrcDir 'lib') $LibExec
    $SourceBin = Join-Path $LibExec 'bin'
    Say "copied bin\ and lib\ to $LibExec"
}
# A .cmd shim per command, so cmd and PowerShell can run them: the scripts are
# bash, and Windows runs nothing without an extension. Each shim names the ONE
# bash this install uses, so a pipeline command never runs under whichever
# `bash` is first on PATH -- on a stock Windows that is WSL's.
$n = 0
Get-ChildItem -File $SourceBin | Where-Object { $_.Extension -eq '' } | ForEach-Object {
    $shim = Join-Path $BinDir ($_.Name + '.cmd')
    Set-Content -Encoding ASCII -Path $shim -Value @(
        '@echo off',
        'rem Generated by icloud-to-google-photos install.ps1 -- re-run it rather than editing this.',
        'setlocal',
        "set `"PATH=$GitPath;%PATH%`"",
        "`"$Bash`" `"$(ToMixed $_.FullName)`" %*"
    )
    $n++
}
Say "wrote $n command shims into $BinDir"

# -- Config --------------------------------------------------------------------
Head 'Config'
if ((Invoke-Native $Bash @((ToMixed (Join-Path $SourceBin 'avd-photos-config')), '--ensure') -Show) -ne 0) { Fail 'could not write the config' }

# -- Tray app ------------------------------------------------------------------
if (-not $NoApp) {
    Head 'Tray app'
    & (Join-Path $SrcDir 'windows\build.ps1') -Dest $AppDir -BinDir $SourceBin -Bash $Bash -ToolsDir $ToolsDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $AppExe)) {
        Say 'the app build failed -- the pipeline still works without it, but the scheduled tasks run it'
        $NoApp = $true
    } else {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $StartMenu 'Photo Sync.lnk'))
        $lnk.TargetPath = $AppExe; $lnk.WorkingDirectory = $AppDir
        $lnk.Description = 'iCloud to Google Photos: the tray status and its actions'
        $lnk.Save()
        Say 'Start menu: Photo Sync'
        Invoke-Native $Bash @((ToMixed (Join-Path $SourceBin 'avd-photos-app'))) -Show | Out-Null
    }
}

# -- Scheduled tasks -----------------------------------------------------------
# The launchd agents' twins. Every action is PhotoSync.exe, a windowless exe,
# because Task Scheduler gives a console program a visible console window: a
# bash started straight from a task would flash one every fifteen minutes.
if (-not $NoTasks -and -not $NoApp) {
    Head "Tasks -> Task Scheduler $TaskFolder"
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $me
    # A laptop is the common case: the defaults refuse to start on battery and
    # kill a run when the charger comes out, and stop any task after 3 days.
    function Settings([int]$priority, [switch]$KeepAlive) {
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority $priority
        if ($KeepAlive) { $s.RestartCount = 3; $s.RestartInterval = 'PT1M' }
        $s
    }
    function Register([string]$name, $trigger, [string]$arguments, $settings, [string]$what) {
        $action = if ($arguments) { New-ScheduledTaskAction -Execute $AppExe -Argument $arguments -WorkingDirectory $AppDir }
                  else { New-ScheduledTaskAction -Execute $AppExe -WorkingDirectory $AppDir }
        Register-ScheduledTask -TaskPath $TaskFolder -TaskName $name -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description $what -Force | Out-Null
        Say "registered $TaskFolder$name"
    }
    # sync: every 15 minutes and at logon. The icloudpd pass IS the "anything
    # new" check; the script is single-flight, so an overlapping tick exits.
    # Below-normal priority (7), the Background band's twin.
    $every15 = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(((Get-Date).Hour * 60) + (Get-Date).Minute + 1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 15)
    Register 'sync' @($every15, $logon) '--sync' (Settings 7) 'iCloud -> Google Photos sync (dormant until avd-photos-arm)'
    # setup: the weekly update, Saturday 05:30, headless.
    Register 'setup' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '05:30') '--setup --headless' (Settings 7) `
        'Update the rooted emulator: SDK, image, Magisk, modules'
    # bootstrap: at logon, build or resume the emulator; a no-op once complete.
    Register 'bootstrap' $logon '--setup --bootstrap' (Settings 7) 'Build or resume the rooted emulator; a no-op once complete'
    # tray: at logon, and again every 5 minutes -- KeepAlive's twin. Task
    # Scheduler's own restart settings only retry a task that fails to START,
    # not one that later dies; a repeating trigger does it: while the tray runs
    # the task is running and the tick is ignored (IgnoreNew), and after a crash
    # the next tick starts it. (A second copy exits at once anyway: --background
    # plus the single-instance mutex.) Normal priority.
    $every5 = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(((Get-Date).Hour * 60) + (Get-Date).Minute + 1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register 'tray' @($logon, $every5) '--background' (Settings 5 -KeepAlive) 'The Photo Sync tray icon'
}

if (-not $NoApp) {
    # Start (or restart) the tray now rather than at the next logon. Only the
    # tray: a PhotoSync.exe running --sync or --setup is a scheduled run.
    Get-CimInstance Win32_Process -Filter "Name = 'PhotoSync.exe'" |
        Where-Object { $_.ExecutablePath -eq $AppExe -and $_.CommandLine -notmatch '--(sync|setup|open-photos)' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $AppExe -WorkingDirectory $AppDir
    Say 'tray app started'
    # Windows 11 files every NEW notification icon under the ^ overflow, keyed
    # by the exe's path -- so a meter installed on purpose would start out of
    # sight, and every reinstall to a new path would hide it again. Its entry
    # appears once the icon has been shown; promote that one entry (and only
    # ours). Settings > Personalization > Taskbar > Other system tray icons
    # hides it again. Windows 10 keeps no such entry, and this does nothing.
    $pinned = $false
    for ($i = 0; $i -lt 30 -and -not $pinned; $i++) {
        Start-Sleep -Milliseconds 500
        Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
            # Matched on the exe's name and its folder's name: the shell records
            # some locations with a known-folder GUID prefix instead of a drive
            # path ({6D809377-...}\Photo Sync\PhotoSync.exe for Program Files).
            $ep = [string](Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ExecutablePath
            if ($ep -eq $AppExe -or $ep -like "*\$(Split-Path $AppDir -Leaf)\PhotoSync.exe") {
                Set-ItemProperty -Path $_.PSPath -Name IsPromoted -Value 1 -Type DWord
                $pinned = $true
            }
        }
    }
    if ($pinned) { Say 'tray icon shown on the taskbar (not in the ^ overflow)' }
}

$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$staging = "$(& $Bash (ToMixed (Join-Path $SourceBin 'avd-photos-config')) --paths 2>$null | Where-Object { $_ -match '^staging' })" -replace '^staging\s+', ''
$ErrorActionPreference = $eap
Write-Host @"

Installed. NOTHING SYNCS YET -- the pipeline is dormant until you arm it.

Next, in a NEW terminal (so PATH has the commands), in order:
  1. avd-photos-config          check the config; set ICLOUD_USERNAME (and, on a
                                small C: drive, AVD_SDK_ROOT and AVD_HOME)
  2. icloudpd --username <your apple id> --directory "$staging" --recent 1
                                the one-time Apple login (two-factor, interactive)
  3. avd-photos-setup           build the rooted emulator (long, downloads GBs)
  4. avd-signin                 boot it in sign-in mode and sign in to Google;
                                register the device id the setup printed at
                                https://www.google.com/android/uncertified/
  5. avd-photos-check           confirm Magisk, Zygisk, the spoof and Photos
  6. avd-photos-arm             ARM IT. From here the sync downloads, uploads,
                                verifies and reclaims iCloud space on its own.

Watch it: the tray icon, 'avd-photos-status', or
  Get-Content -Wait $env:USERPROFILE\.cache\avd-photos\logs\sync.log
"@
