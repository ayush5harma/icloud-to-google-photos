<#
  Build the tray app -- windows\PhotoSync, WinUI 3 on the Windows App SDK -- and
  install it into -Dest (default %LOCALAPPDATA%\Programs\Photo Sync). The
  Windows twin of build.sh.

  ITS OWN .NET SDK, ON PURPOSE. A fresh Windows has none, and a machine with
  one has whichever version it has; so the SDK is installed by Microsoft's own
  dotnet-install.ps1 into -ToolsDir (no admin, nothing registered), and NuGet's
  cache goes there too. The app is published SELF-CONTAINED -- .NET and the
  Windows App SDK runtime travel inside its folder -- so the PC it runs on needs
  neither installed.

  IDEMPOTENT: it rebuilds only when something under windows\PhotoSync or this
  script is newer than the installed exe, or the recorded settings changed.

    .\windows\build.ps1 -BinDir <repo>\bin -Bash <git>\usr\bin\bash.exe
    .\windows\build.ps1 ... -Dest <dir> -ToolsDir <dir> -Force
#>
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:LOCALAPPDATA 'Programs\Photo Sync'),
    [Parameter(Mandatory = $true)][string]$BinDir,
    [Parameter(Mandatory = $true)][string]$Bash,
    [string]$ToolsDir = (Join-Path $env:LOCALAPPDATA 'avd-photos\tools'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Proj = Join-Path $PSScriptRoot 'PhotoSync\PhotoSync.csproj'
$Exe = Join-Path $Dest 'PhotoSync.exe'
$SettingsName = 'PhotoSync.settings.json'
$Rid = if (($env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE) -contains 'ARM64') { 'win-arm64' } else { 'win-x64' }
# The .NET channel the app targets (PhotoSync.csproj's TargetFramework).
$Channel = '10.0'

function Say([string]$m) { Write-Host "  $m" }

# -Dest IS REPLACED WHOLESALE on every build (renamed aside, then deleted), so it
# must be this app's own folder and nothing else. A folder that exists without
# PhotoSync.exe in it is someone else's -- `-AppDir D:\Apps` meaning "put it IN
# D:\Apps" would otherwise have taken all of D:\Apps with it.
if ((Test-Path $Dest) -and -not (Test-Path (Join-Path $Dest 'PhotoSync.exe')) -and
    (Get-ChildItem -Force $Dest | Select-Object -First 1)) {
    Say "REFUSING to build into $Dest -- it exists and is not a Photo Sync folder."
    Say "Pass the app's OWN folder (e.g. $(Join-Path $Dest 'Photo Sync'))."
    exit 1
}

# WHERE THE APP FINDS THE PIPELINE, recorded beside the exe by the installer and
# nowhere else. The app ignores the environment for that decision, as the macOS
# app does: whatever decides WHAT the tray runs decides what runs every fifteen
# minutes, so it is written by an installer, not inherited from a caller.
$settings = [ordered]@{
    binDir = (Resolve-Path $BinDir).Path.Replace('\', '/')
    bash   = (Resolve-Path $Bash).Path
} | ConvertTo-Json

$installedSettings = ''
if (Test-Path (Join-Path $Dest $SettingsName)) { $installedSettings = Get-Content -Raw (Join-Path $Dest $SettingsName) }
if (-not $Force -and (Test-Path $Exe) -and $installedSettings.Trim() -eq $settings.Trim()) {
    $exeTime = (Get-Item $Exe).LastWriteTimeUtc
    $newer = Get-ChildItem -Recurse -File (Join-Path $PSScriptRoot 'PhotoSync'), $PSCommandPath |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.LastWriteTimeUtc -gt $exeTime } | Select-Object -First 1
    if (-not $newer) { Say 'Photo Sync is up to date'; exit 0 }
}

# -- The .NET SDK ------------------------------------------------------------
$DotnetDir = Join-Path $ToolsDir 'dotnet'
$Dotnet = Join-Path $DotnetDir 'dotnet.exe'
$haveSdk = $false
if (Test-Path $Dotnet) { $haveSdk = [bool](& $Dotnet --list-sdks 2>$null | Where-Object { $_ -like "$Channel.*" }) }
if (-not $haveSdk) {
    Say ".NET $Channel SDK -> $DotnetDir (one time)"
    $script = Join-Path $env:TEMP 'avd-photos-dotnet-install.ps1'
    & "$env:WINDIR\System32\curl.exe" -fsSL --retry 3 -o $script 'https://dot.net/v1/dotnet-install.ps1'
    if ($LASTEXITCODE -ne 0) { Say 'could not download dotnet-install.ps1'; exit 1 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Channel $Channel -InstallDir $DotnetDir -NoPath | Out-Null
    Remove-Item $script -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $Dotnet)) { Say '.NET SDK install failed'; exit 1 }
}
$env:DOTNET_ROOT = $DotnetDir
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = Join-Path $ToolsDir 'nuget'
Say ".NET SDK $((& $Dotnet --version) -join '')"

# -- Build -------------------------------------------------------------------
# Published beside the destination and swapped in by rename: the running tray
# holds its exe and DLLs open, and Windows lets a running image be RENAMED but
# not overwritten -- the same reason build.sh renames rather than writing over
# the installed binary.
$staging = "$Dest.new"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
$buildLog = Join-Path $env:TEMP 'avd-photos-build.log'
Say "compiling ($Rid, self-contained)"
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$Platform = if ($Rid -eq 'win-arm64') { 'ARM64' } else { 'x64' }   # WinUI refuses AnyCPU
& $Dotnet publish $Proj -c Release -r $Rid -p:Platform=$Platform --self-contained true -o $staging -nologo 2>&1 | Out-File -Encoding utf8 $buildLog
$rc = $LASTEXITCODE
$ErrorActionPreference = $eap
if ($rc -ne 0 -or -not (Test-Path (Join-Path $staging 'PhotoSync.exe'))) {
    Say "BUILD FAILED -- see $buildLog"
    Get-Content $buildLog | Select-String -Pattern 'error' | Select-Object -First 15 | ForEach-Object { Say "    $_" }
    exit 1
}
Set-Content -Encoding UTF8 -Path (Join-Path $staging $SettingsName) -Value $settings

# -- Install -----------------------------------------------------------------
# Only the TRAY is stopped for the swap. A PhotoSync.exe running --sync or
# --setup is a scheduled run's launcher, waiting on its bash; killing it would
# orphan that run and fail the task, so the build waits for the next quiet
# moment instead.
$mine = @(Get-CimInstance Win32_Process -Filter "Name = 'PhotoSync.exe'" | Where-Object { $_.ExecutablePath -eq $Exe })
$launchers = @($mine | Where-Object { $_.CommandLine -match '--(sync|setup|open-photos)' })
if ($launchers) {
    Say "a scheduled run is using $Exe right now ($($launchers[0].CommandLine.Trim())) -- run the build again when it finishes"
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    exit 1
}
$trays = @($mine | Where-Object { $_.CommandLine -notmatch '--(sync|setup|open-photos)' })
foreach ($t in $trays) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
if ($trays) { Start-Sleep -Milliseconds 700 }
$old = "$Dest.old"
try {
    if (Test-Path $old) { Remove-Item -Recurse -Force $old }
    if (Test-Path $Dest) { Rename-Item $Dest (Split-Path $old -Leaf) }
    Rename-Item $staging (Split-Path $Dest -Leaf)
} catch {
    Say "could not swap the new build into $Dest -- $($_.Exception.Message)"
    exit 1
}
if (Test-Path $old) { Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue }
Say "built $Dest"
# Back as it was: the logon task's way, without opening the flyout.
if ($trays) { Start-Process -FilePath $Exe -ArgumentList '--background' -WorkingDirectory $Dest; Say 'restarted the tray app' }
exit 0
