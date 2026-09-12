# Core of the Windows port: the config contract, paths, logging, ledger files,
# single-flight locks, the process runner and the adb helpers. The macOS
# equivalents are lib/config.sh, lib/log.sh and lib/proc.sh; every rule those
# files state holds here too, and where Windows forces a difference the comment
# says why. windows/DESIGN.md has the decisions in one place.
#
# Every function is pure or takes its inputs as parameters (the environment
# included), so the tests run on any OS; only the few that touch Task
# Scheduler, CIM or ACLs are Windows-only, and they say so.
#
# A function that returns a list returns it as ONE array object (the unary
# comma), so `$x = F` is an array even when it holds zero or one item -- no
# $null, no scalar, no .Count surprise under StrictMode. Assign it or iterate
# it with foreach; `F | ForEach-Object` would see the whole array as one item.

# This file's directory, captured at load time (windows\lib).
$script:AvdLibDir = $PSScriptRoot

# The keys a config file may set. The SAME list as AP_KEYS in lib/config.sh;
# Repo.Tests.ps1 fails if the two ever differ, because the README documents one
# contract for both platforms.
$script:AvdKeys = @(
    'ICLOUD_USERNAME', 'ICLOUDPD', 'STAGING', 'ICLOUD_DIR', 'SHARED_CACHE_DIR',
    'GOOGLE_ACCOUNT', 'AVD_NAME', 'AVD_SDK_ROOT', 'AVD_ABI', 'AVD_TAG', 'AVD_DEVICE',
    'AVD_RES', 'AVD_DPI', 'AVD_RAM', 'AVD_CORES', 'AVD_DISK', 'AVD_HEAP', 'AVD_GPU', 'AVD_SPOOF',
    'RECENT', 'UNTIL_FOUND', 'PUSH_CAP', 'UPLOAD_WAIT', 'ADB_TIMEOUT', 'RECLAIM_TIMEOUT',
    'DELETE_FROM_ICLOUD', 'KEEP_ICLOUD_DAYS', 'PRUNE_DEVICE_AFTER_UPLOAD',
    'STOP_EMULATOR_WHEN_IDLE', 'DEST_DCIM', 'GITHUB_TOKEN'
)

# The scheduled-task names are the launchd labels: <prefix>.sync, .setup,
# .bootstrap and .tray (the macOS .menubar). One prefix, as in lib/config.sh.
$script:AvdLabelPrefix = 'com.ayushsharma.icloud-to-google-photos'

# Keys whose value must be a whole number. A typo there is reported by
# Get-AvdConfig rather than failing deep inside a comparison, and
# ConvertTo-AvdInt falls back to the documented default.
$script:AvdNumericKeys = @(
    'AVD_DPI', 'AVD_RAM', 'AVD_CORES', 'RECENT', 'UNTIL_FOUND', 'PUSH_CAP', 'UPLOAD_WAIT',
    'ADB_TIMEOUT', 'RECLAIM_TIMEOUT', 'KEEP_ICLOUD_DAYS'
)

# Ledgers, logs and device scripts are UTF-8 WITHOUT a byte-order mark, LF only:
# the device's `read -r` would take a BOM into the first path and a CR into
# every one, and the reclaim script compares these lines byte for byte.
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-AvdPlatform {
    if ($IsWindows) { 'Windows' } else { 'Unix' }
}

function Get-AvdConfigKey {
    , $script:AvdKeys
}

function Get-AvdLabelPrefix {
    $script:AvdLabelPrefix
}

# A snapshot of this process's environment, so `.Contains()` answers "did the
# caller SET this", which is the precedence rule. Case-insensitive, as Windows
# compares variable names.
function Get-AvdEnvironment {
    $h = @{}
    foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $h[[string]$e.Key] = [string]$e.Value
    }
    $h
}

# Join path parts with the TARGET platform's separator, not the host's: the
# Windows defaults are computed and tested on a Mac too, where Join-Path would
# write '/'.
function Join-AvdPath {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Unix')][string]$Platform,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Part
    )
    $sep = if ($Platform -eq 'Windows') { '\' } else { '/' }
    $out = ''
    foreach ($p in $Part) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($out -eq '') { $out = $p; continue }
        $out = $out.TrimEnd('\', '/') + $sep + $p.TrimStart('\', '/')
    }
    $out
}

function Get-AvdHomeDirectory {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Unix')][string]$Platform,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    if ($Platform -eq 'Windows' -and $Environment.Contains('USERPROFILE') -and $Environment['USERPROFILE']) {
        return [string]$Environment['USERPROFILE']
    }
    if ($Environment.Contains('HOME') -and $Environment['HOME']) { return [string]$Environment['HOME'] }
    [System.Environment]::GetFolderPath('UserProfile')
}

function Get-AvdEnvironmentValue {
    param([System.Collections.IDictionary]$Environment, [string]$Name, [string]$Fallback)
    if ($Environment.Contains($Name) -and $Environment[$Name]) { return [string]$Environment[$Name] }
    $Fallback
}

# The three locations that decide where everything else is read from. They are
# environment-only, as on macOS (a config file cannot move the file that
# defines it), and an EMPTY value means the default, as `${VAR:-...}` does.
# Windows: config in %APPDATA% (it is the user's settings), state and logs in
# %LOCALAPPDATA% (machine-local, never roamed to another PC).
function Get-AvdPathSet {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Unix')][string]$Platform,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    $homeDir = Get-AvdHomeDirectory -Platform $Platform -Environment $Environment
    if ($Platform -eq 'Windows') {
        $appData = Get-AvdEnvironmentValue $Environment 'APPDATA' (Join-AvdPath Windows $homeDir, 'AppData\Roaming')
        $localAppData = Get-AvdEnvironmentValue $Environment 'LOCALAPPDATA' (Join-AvdPath Windows $homeDir, 'AppData\Local')
        $configDefault = Join-AvdPath Windows $appData, 'avd-photos'
        $stateDefault = Join-AvdPath Windows $localAppData, 'avd-photos'
    } else {
        $configDefault = Join-AvdPath Unix $homeDir, '.config/avd-photos'
        $stateDefault = Join-AvdPath Unix $homeDir, '.cache/avd-photos'
    }
    $configDir = Get-AvdEnvironmentValue $Environment 'AVD_PHOTOS_CONFIG_DIR' $configDefault
    $stateDir = Get-AvdEnvironmentValue $Environment 'AVD_PHOTOS_STATE_DIR' $stateDefault
    $logDir = Get-AvdEnvironmentValue $Environment 'AVD_PHOTOS_LOG_DIR' (Join-AvdPath $Platform $stateDir, 'logs')
    [pscustomobject]@{
        HOME_DIR    = $homeDir
        CONFIG_DIR  = $configDir
        STATE_DIR   = $stateDir
        LOG_DIR     = $logDir
        CONFIG_FILE = Join-AvdPath $Platform $configDir, 'config'
        # The pipeline is DORMANT until this file exists (avd-photos-arm creates it).
        SENTINEL    = Join-AvdPath $Platform $configDir, 'ENABLED'
    }
}

# Where the emulator looks for AVDs, in the emulator's own order. The macOS
# scripts hardcode ~/.android/avd; Windows needs the override because the
# emulator mishandles non-ASCII characters in that path, and ANDROID_AVD_HOME
# pointing at an ASCII directory is the documented way out.
function Resolve-AvdHome {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Unix')][string]$Platform,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    $avdHome = Get-AvdEnvironmentValue $Environment 'ANDROID_AVD_HOME' ''
    if ($avdHome) { return $avdHome }
    $userHome = Get-AvdEnvironmentValue $Environment 'ANDROID_USER_HOME' ''
    if ($userHome) { return (Join-AvdPath $Platform $userHome, 'avd') }
    # Deprecated by Google but still honoured by the emulator.
    $sdkHome = Get-AvdEnvironmentValue $Environment 'ANDROID_SDK_HOME' ''
    if ($sdkHome) { return (Join-AvdPath $Platform $sdkHome, '.android', 'avd') }
    $homeDir = Get-AvdHomeDirectory -Platform $Platform -Environment $Environment
    Join-AvdPath $Platform $homeDir, '.android', 'avd'
}

# The defaults, per platform. Identical to lib/config.sh's ap_defaults except
# where the platform decides:
#   STAGING, ICLOUD_DIR, AVD_SDK_ROOT  Windows locations (iCloud for Windows
#                                      mounts iCloud Drive at %USERPROFILE%\iCloudDrive)
#   AVD_ABI    x86_64: a Windows host runs x86_64 images under WHPX or AEHD;
#              arm64-v8a images do not boot on an x86 host.
#   AVD_CORES  4, not 8: the macOS value is an M2 Pro's performance-core count,
#              and a guest with as many vCPUs as a laptop has cores starves the
#              host that is also running icloudpd and adb.
function Get-AvdDefault {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Unix')][string]$Platform,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    $homeDir = Get-AvdHomeDirectory -Platform $Platform -Environment $Environment
    if ($Platform -eq 'Windows') {
        $localAppData = Get-AvdEnvironmentValue $Environment 'LOCALAPPDATA' (Join-AvdPath Windows $homeDir, 'AppData\Local')
        $staging = Join-AvdPath Windows $homeDir, 'Pictures\icloud-photos-staging'
        $icloudDir = Join-AvdPath Windows $homeDir, 'iCloudDrive'
        $sdkRoot = Join-AvdPath Windows $localAppData, 'android-avd-sdk'
        $abi = 'x86_64'
        $cores = '4'
    } else {
        $staging = Join-AvdPath Unix $homeDir, 'Pictures/icloud-photos-staging'
        $icloudDir = Join-AvdPath Unix $homeDir, 'Library/Mobile Documents/com~apple~CloudDocs'
        $sdkRoot = Join-AvdPath Unix $homeDir, '.local/share/android-avd-sdk'
        $abi = 'arm64-v8a'
        $cores = '8'
    }
    [ordered]@{
        ICLOUD_USERNAME           = ''
        ICLOUDPD                  = 'icloudpd'
        STAGING                   = $staging
        ICLOUD_DIR                = $icloudDir
        SHARED_CACHE_DIR          = Join-AvdPath $Platform $icloudDir, 'avd-photos'
        GOOGLE_ACCOUNT            = ''
        AVD_NAME                  = 'gphotos-tablet'
        AVD_SDK_ROOT              = $sdkRoot
        AVD_ABI                   = $abi
        AVD_TAG                   = 'google_apis'
        AVD_DEVICE                = 'pixel_tablet'
        AVD_RES                   = '2560x1440'
        AVD_DPI                   = '210'
        AVD_RAM                   = '6144'
        AVD_CORES                 = $cores
        AVD_DISK                  = '16384M'
        AVD_HEAP                  = '512M'
        AVD_GPU                   = 'host'
        AVD_SPOOF                 = 'module'
        RECENT                    = '2000'
        UNTIL_FOUND               = '50'
        PUSH_CAP                  = '1000'
        UPLOAD_WAIT               = '900'
        ADB_TIMEOUT               = '120'
        RECLAIM_TIMEOUT           = '1800'
        DELETE_FROM_ICLOUD        = '1'
        KEEP_ICLOUD_DAYS          = '7'
        PRUNE_DEVICE_AFTER_UPLOAD = '1'
        STOP_EMULATOR_WHEN_IDLE   = '1'
        DEST_DCIM                 = '/sdcard/DCIM/Camera'
        GITHUB_TOKEN              = ''
    }
}

# Expand $NAME, ${NAME}, %NAME% and a leading ~ in a config value.
#   $NAME / ${NAME}  what the file assigned earlier, else a key's resolved value,
#                    else the environment (HOME falls back to the profile
#                    directory); an unknown name is empty, as in the shell.
#   %NAME%           the environment only, and an unknown name is left as
#                    written, as cmd.exe does.
# One pass, so an expanded value is never expanded again.
function Get-AvdConfigVariable {
    param([string]$Name, [System.Collections.IDictionary]$Lookup, [System.Collections.IDictionary]$Environment, [string]$HomeDir)
    if ($null -ne $Lookup -and $Lookup.Contains($Name)) { return [string]$Lookup[$Name] }
    if ($Environment.Contains($Name)) { return [string]$Environment[$Name] }
    if ($Name -eq 'HOME') { return $HomeDir }
    ''
}

function Expand-AvdConfigValue {
    param(
        [AllowEmptyString()][string]$Value,
        [System.Collections.IDictionary]$Lookup,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [string]$HomeDir
    )
    $sb = [System.Text.StringBuilder]::new()
    $n = $Value.Length
    $i = 0
    if ($n -gt 0 -and $Value[0] -eq '~' -and ($n -eq 1 -or $Value[1] -eq '/' -or $Value[1] -eq '\')) {
        [void]$sb.Append($HomeDir)
        $i = 1
    }
    while ($i -lt $n) {
        $c = $Value[$i]
        if ($c -eq '$') {
            if ($i + 1 -lt $n -and $Value[$i + 1] -eq '{') {
                $close = $Value.IndexOf('}', $i + 2)
                if ($close -gt $i + 2) {
                    $name = $Value.Substring($i + 2, $close - $i - 2)
                    if ($name -match '^[A-Za-z_][A-Za-z0-9_]*$') {
                        [void]$sb.Append((Get-AvdConfigVariable -Name $name -Lookup $Lookup -Environment $Environment -HomeDir $HomeDir))
                        $i = $close + 1
                        continue
                    }
                }
            } else {
                $m = [regex]::Match($Value.Substring($i + 1), '^[A-Za-z_][A-Za-z0-9_]*')
                if ($m.Success) {
                    [void]$sb.Append((Get-AvdConfigVariable -Name $m.Value -Lookup $Lookup -Environment $Environment -HomeDir $HomeDir))
                    $i += 1 + $m.Length
                    continue
                }
            }
        } elseif ($c -eq '%') {
            $close = $Value.IndexOf('%', $i + 1)
            if ($close -gt $i + 1) {
                $name = $Value.Substring($i + 1, $close - $i - 1)
                if ($name -match '^[A-Za-z_][A-Za-z0-9_()]*$' -and $Environment.Contains($name)) {
                    [void]$sb.Append([string]$Environment[$name])
                    $i = $close + 1
                    continue
                }
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    $sb.ToString()
}

# Parse the config file. On macOS it is shell syntax and SOURCED; Windows has
# no shell to source it with, so it is read, with rules chosen for Windows
# paths:
#   KEY=value per line (`export ` and spaces around = are accepted); # comments.
#   The value is the REST OF THE LINE, trimmed, minus a ` # comment`: a
#   Windows path with a space in it is the common case, not the trap it is in
#   a shell.
#   Backslashes are always literal. An unquoted shell word would eat them
#   (C:\Users\me -> C:Usersme) and a double-quoted one would turn "D:\" into an
#   unterminated string.
#   '...' is literal; "..." and unquoted values expand (Expand-AvdConfigValue).
#   Every assignment is visible to later $NAME expansions, known key or not,
#   as a sourced file's would be; only known keys are returned.
# A line that is not an assignment is reported, never silently dropped: a
# config value quietly lost is what the macOS config comment warns about.
function ConvertFrom-AvdConfigText {
    param(
        [AllowEmptyString()][string]$Text,
        [System.Collections.IDictionary]$Seed,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [string]$HomeDir
    )
    $vars = @{}
    if ($null -ne $Seed) { foreach ($k in $Seed.Keys) { $vars[$k] = $Seed[$k] } }
    $values = [ordered]@{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    $lines = (ConvertTo-AvdLf $Text).Split("`n")
    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        $line = $lines[$ln]
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $m = [regex]::Match($line, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')
        if (-not $m.Success) {
            $warnings.Add("line $($ln + 1): not a KEY=value assignment, ignored: $trimmed")
            continue
        }
        $name = $m.Groups[1].Value
        $raw = $m.Groups[2].Value.Trim()
        $rest = ''
        if ($raw.StartsWith("'") -or $raw.StartsWith('"')) {
            $q = $raw[0]
            $close = $raw.IndexOf($q, 1)
            if ($close -lt 0) {
                $warnings.Add("line $($ln + 1): unterminated $q quote, $name ignored")
                continue
            }
            $inner = $raw.Substring(1, $close - 1)
            $rest = $raw.Substring($close + 1).Trim()
            if ($q -eq "'") { $val = $inner }
            else { $val = Expand-AvdConfigValue -Value $inner -Lookup $vars -Environment $Environment -HomeDir $HomeDir }
        } elseif ($raw.StartsWith('#')) {
            $val = ''
        } else {
            $bare = ($raw -replace '\s+#.*$', '').TrimEnd()
            $val = Expand-AvdConfigValue -Value $bare -Lookup $vars -Environment $Environment -HomeDir $HomeDir
        }
        if ($rest -ne '' -and -not $rest.StartsWith('#')) {
            $warnings.Add("line $($ln + 1): text after the closing quote of $name ignored: $rest")
        }
        $vars[$name] = $val
        if ($script:AvdKeys -contains $name) { $values[$name] = $val }
    }
    [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
}

# THE CONFIG, resolved: environment > config file > default, decided by
# whether the caller SET a variable rather than whether it is non-empty
# (lib/config.sh's rule, commit 3b71bbc). One Windows limit: cmd and
# PowerShell cannot easily create an EMPTY environment variable (assigning ''
# deletes it), so "no floor for this run" is KEEP_ICLOUD_DAYS=0 there.
#
# SHARED_CACHE_DIR's default follows the FINAL ICLOUD_DIR, so a config that
# moves iCloud Drive moves the cache with it, as the README's table says.
function Get-AvdConfig {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Environment,
        [ValidateSet('Windows', 'Unix')][string]$Platform,
        # Do not create the config, state and log directories (the status reader
        # and the tests use this; everything else creates them, as ap_load_config does).
        [switch]$NoCreate
    )
    if ($null -eq $Environment) { $Environment = Get-AvdEnvironment }
    if (-not $Platform) { $Platform = Get-AvdPlatform }
    $paths = Get-AvdPathSet -Platform $Platform -Environment $Environment
    $defaults = Get-AvdDefault -Platform $Platform -Environment $Environment

    # What a $NAME in the file sees before the file assigns it: the environment
    # value when set, else the default -- what a sourced file sees on macOS.
    $seed = @{}
    foreach ($k in $script:AvdKeys) {
        $seed[$k] = if ($Environment.Contains($k)) { [string]$Environment[$k] } else { $defaults[$k] }
    }
    $fileValues = [ordered]@{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $paths.CONFIG_FILE -PathType Leaf) {
        try {
            $text = [System.IO.File]::ReadAllText($paths.CONFIG_FILE, $script:Utf8NoBom)
            $parsed = ConvertFrom-AvdConfigText -Text $text -Seed $seed -Environment $Environment -HomeDir $paths.HOME_DIR
            $fileValues = $parsed.Values
            foreach ($w in $parsed.Warnings) { $warnings.Add("$($paths.CONFIG_FILE): $w") }
        } catch {
            $warnings.Add("$($paths.CONFIG_FILE): unreadable ($($_.Exception.Message)); using defaults")
        }
    }

    $cfg = [ordered]@{}
    $sources = [ordered]@{}
    foreach ($k in $script:AvdKeys) {
        if ($Environment.Contains($k)) { $cfg[$k] = [string]$Environment[$k]; $sources[$k] = 'environment' }
        elseif ($fileValues.Contains($k)) { $cfg[$k] = [string]$fileValues[$k]; $sources[$k] = 'config' }
        else { $cfg[$k] = [string]$defaults[$k]; $sources[$k] = 'default' }
    }
    if ($sources['SHARED_CACHE_DIR'] -eq 'default') {
        $cfg['SHARED_CACHE_DIR'] = if ($cfg['ICLOUD_DIR']) { Join-AvdPath $Platform $cfg['ICLOUD_DIR'], 'avd-photos' } else { '' }
    }
    foreach ($k in $script:AvdNumericKeys) {
        $v = $cfg[$k]
        if ($v -ne '' -and $v -notmatch '^\d+$') {
            $warnings.Add("$k=$v is not a whole number; the default $($defaults[$k]) is used where a number is needed")
        }
    }

    $cfg['PLATFORM'] = $Platform
    $cfg['HOME_DIR'] = $paths.HOME_DIR
    $cfg['CONFIG_DIR'] = $paths.CONFIG_DIR
    $cfg['STATE_DIR'] = $paths.STATE_DIR
    $cfg['LOG_DIR'] = $paths.LOG_DIR
    $cfg['CONFIG_FILE'] = $paths.CONFIG_FILE
    $cfg['SENTINEL'] = $paths.SENTINEL
    $cfg['LABEL_PREFIX'] = $script:AvdLabelPrefix
    $cfg['AVD_HOME'] = Resolve-AvdHome -Platform $Platform -Environment $Environment
    $cfg['SOURCES'] = $sources
    $cfg['DEFAULTS'] = $defaults
    $cfg['WARNINGS'] = $warnings.ToArray()

    if (-not $NoCreate) {
        foreach ($d in @($paths.CONFIG_DIR, $paths.STATE_DIR, $paths.LOG_DIR)) {
            $null = New-Item -ItemType Directory -Force -Path $d -ErrorAction SilentlyContinue
        }
    }
    [pscustomobject]$cfg
}

# A config value as a number, or the key's default when it is not one. Empty
# counts as 0 for KEEP_ICLOUD_DAYS (lib/config.sh: 0 and empty both mean "no
# floor") and as the default everywhere else.
function ConvertTo-AvdInt {
    param([AllowEmptyString()][AllowNull()][string]$Value, [long]$Default = 0)
    $n = 0L
    if ($null -ne $Value -and $Value -match '^\s*\d+\s*$' -and [long]::TryParse($Value.Trim(), [ref]$n)) { return $n }
    $Default
}

function Get-AvdConfigInt {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Key)
    $v = $Config.$Key
    if ($Key -eq 'KEEP_ICLOUD_DAYS' -and [string]::IsNullOrEmpty($v)) { return 0L }
    ConvertTo-AvdInt -Value $v -Default ([long]$Config.DEFAULTS[$Key])
}

# The commented default config, the ONE definition of that file on Windows.
# Written with the platform's line endings, since it is the one file here a
# person edits by hand (Notepad reads LF too; the parser reads either).
function Get-AvdDefaultConfigText {
    param([ValidateSet('Windows', 'Unix')][string]$Platform = (Get-AvdPlatform))
    $text = @'
# icloud-to-google-photos configuration (Windows). Read, not executed:
# KEY=value, one per line; everything after the = is the value, so a path with
# spaces needs no quotes. Backslashes are literal. $NAME, ${NAME} and %NAME%
# expand (not inside single quotes). Anything left commented out keeps its
# default. The README's "Config and state contract" lists every key.

# -- Required -----------------------------------------------------------------
# The Apple ID icloudpd downloads with. The sync refuses to run without it.
ICLOUD_USERNAME=

# -- Where photos are staged --------------------------------------------------
# Downloaded originals land here and stay until Google Photos has confirmed
# them, so for that window this is the only copy outside iCloud's Recently
# Deleted. Any directory works. Do not use a temp or cache directory. A synced
# folder (Google Drive for desktop in streaming mode) gives the staging tree
# its own backup and lets the bytes leave the local disk once uploaded.
#STAGING=%USERPROFILE%\Pictures\icloud-photos-staging

# -- The emulator -------------------------------------------------------------
#AVD_NAME=gphotos-tablet
# The pipeline's own writable Android SDK (its ANDROID_HOME). It must be
# writable, and ASCII-only: rooting rewrites the system image's ramdisk.img in
# place, and the emulator mishandles non-ASCII paths.
#AVD_SDK_ROOT=%LOCALAPPDATA%\android-avd-sdk
# x86_64 is the only ABI a Windows x86 host can run.
#AVD_ABI=x86_64
# host = the GPU driver, fast. The one-time Google sign-in uses avd-signin
# (software GL) regardless; leave this alone.
#AVD_GPU=host
# Guest tuning. The defaults suit a 4-core, 16 GB machine.
#AVD_RAM=6144
#AVD_CORES=4
#AVD_DISK=16384M
#AVD_HEAP=512M
#AVD_RES=2560x1440
#AVD_DPI=210

# -- Accounts -----------------------------------------------------------------
# The Google account the emulator signs in as. Only ever printed, as a reminder
# of which account to register the device under.
#GOOGLE_ACCOUNT=

# -- Pacing -------------------------------------------------------------------
#RECENT=2000          # newest iCloud items each run walks
#UNTIL_FOUND=50       # stop after this many already-downloaded items
#PUSH_CAP=1000        # files handed to the emulator per run
#UPLOAD_WAIT=900      # floor on the wait for Google Photos, plus 2 s per file

# -- iCloud space reclaim -----------------------------------------------------
# 1 (the default) deletes an asset from iCloud only after Google Photos' own
# database holds its dedup_key AND the last verify pass confirmed cleanly.
# 0 keeps everything in iCloud.
#DELETE_FROM_ICLOUD=1
# Never delete anything created within the last N days, whatever its state.
# The default is 7: a net for the first armed runs, which is when a mis-set
# staging path or a half-finished sign-in shows up. 0 reclaims a photo as soon
# as it is confirmed.
#KEEP_ICLOUD_DAYS=7

# -- Optional -----------------------------------------------------------------
# Raises the GitHub API's 60-per-hour unauthenticated limit for the release
# lookups. The pipeline works without it.
#GITHUB_TOKEN=
'@
    # A final newline, or a line a person appends to the file joins the last
    # comment and is silently lost.
    $text = (ConvertTo-AvdLf $text).TrimEnd("`n") + "`n"
    if ($Platform -eq 'Windows') { $text = $text.Replace("`n", "`r`n") }
    $text
}

# Make a file readable by its owner only: the Windows form of lib/config.sh's
# 0600, for the config (an Apple ID, maybe a GITHUB_TOKEN). Inheritance is cut
# and exactly two entries remain, the current user and SYSTEM (which the OS
# needs; an administrator can take ownership of anything, as root can read a
# 0600 file). Returns 'tightened' when the file was looser, 'already' when not,
# 'missing' when there is no file.
function Protect-AvdFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    if ($IsWindows) {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $current = Get-Acl -LiteralPath $Path
        $rules = @($current.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $others = @($rules | Where-Object { $_.IdentityReference -ne $me -and $_.IdentityReference -ne $system })
        if ($current.AreAccessRulesProtected -and $others.Count -eq 0 -and $rules.Count -gt 0) { return 'already' }
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($me, $system)) {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
        return 'tightened'
    }
    $want = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
    if ([System.IO.File]::GetUnixFileMode($Path) -eq $want) { return 'already' }
    [System.IO.File]::SetUnixFileMode($Path, $want)
    'tightened'
}

function Write-AvdDefaultConfig {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Windows', 'Unix')][string]$Platform = (Get-AvdPlatform))
    $dir = Split-Path -Parent $Path
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [System.IO.File]::WriteAllText($Path, (Get-AvdDefaultConfigText -Platform $Platform), $script:Utf8NoBom)
    $null = Protect-AvdFile -Path $Path
}

# The tool directories every script puts first on PATH. A scheduled task
# inherits the logon environment, not a shell profile, and `uv tool install`
# puts icloudpd in %USERPROFILE%\.local\bin: on macOS five days of scheduled
# runs skipped on "icloudpd missing" for exactly this reason (measured
# 2026-09-05), so the directory is seeded, never assumed.
function Add-AvdToolPath {
    param([string[]]$Directory = @())
    $homeDir = Get-AvdHomeDirectory -Platform (Get-AvdPlatform) -Environment (Get-AvdEnvironment)
    $sep = [System.IO.Path]::PathSeparator
    $front = [System.Collections.Generic.List[string]]::new()
    $front.Add((Join-Path $homeDir '.local' 'bin'))
    if (-not $IsWindows) { $front.Add('/opt/homebrew/bin'); $front.Add('/usr/local/bin') }
    foreach ($d in $Directory) { if ($d) { $front.Add($d) } }
    $existing = @(([string]$env:PATH).Split($sep) | Where-Object { $_ })
    if (-not $IsWindows) { $existing += @('/usr/bin', '/bin', '/usr/sbin', '/sbin') }
    $cmp = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @($front) + $existing) {
        $key = $d.TrimEnd('\', '/')
        if ($key -and $seen.Add($key)) { $out.Add($d) }
    }
    $env:PATH = $out -join $sep
}

# -- Text and ledger files ----------------------------------------------------

function ConvertTo-AvdLf {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

# Write a whole file, UTF-8 without a BOM, through a temp file and a rename,
# so a reader never sees half of it and a crash never leaves a truncated
# ledger. -Lf normalises line endings first (everything the device reads).
function Write-AvdTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Text,
        [switch]$Lf
    )
    if ($Lf) { $Text = ConvertTo-AvdLf $Text }
    $dir = Split-Path -Parent $Path
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    [System.IO.File]::Move($tmp, $Path, $true)
}

# The non-empty lines of a file, CR and a leading BOM removed; nothing for a
# missing file. `grep -c .` semantics: a line counts when it has a character.
function Read-AvdLine {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    $text = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (ConvertTo-AvdLf $text).Split("`n")) { if ($l.Length -gt 0) { $lines.Add($l) } }
    , $lines.ToArray()
}

# Lines in a file, 0 for an empty or missing one (count_lines).
function Measure-AvdLine {
    param([Parameter(Mandatory)][string]$Path)
    (Read-AvdLine -Path $Path).Count
}

# Append lines, each LF-terminated, UTF-8 without a BOM.
function Add-AvdLine {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$Line = @())
    if ($Line.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $Path)) { [System.IO.File]::WriteAllText($Path, '', $script:Utf8NoBom) }
        return
    }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($l in $Line) { [void]$sb.Append($l).Append("`n") }
    [System.IO.File]::AppendAllText($Path, $sb.ToString(), $script:Utf8NoBom)
}

# Replace a file's lines (sorted, deduplicated or filtered by the caller).
function Set-AvdLine {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$Line = @())
    $text = if ($Line.Count) { ($Line -join "`n") + "`n" } else { '' }
    Write-AvdTextFile -Path $Path -Text $text
}

# Sorted, de-duplicated lines, compared byte for byte: the ledgers were written
# and compared by `sort -u` and `comm` under launchd's C locale, so ordinal
# order is the one that matches, never PowerShell's culture-aware sort.
function Get-AvdSortedUnique {
    param([AllowEmptyCollection()][string[]]$Line = @())
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $Line) { if ($l.Length -gt 0) { [void]$set.Add($l) } }
    , ([string[]]@($set))
}

# comm -23: the lines of A that are not in B, in A's order.
function Get-AvdLineDifference {
    param([AllowEmptyCollection()][string[]]$Line = @(), [AllowEmptyCollection()][string[]]$Exclude = @())
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $Exclude) { [void]$skip.Add($e) }
    , ([string[]]@($Line | Where-Object { -not $skip.Contains($_) }))
}

# -- Time ---------------------------------------------------------------------

function Get-AvdEpoch {
    [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# Seconds since a file's mtime, or since the epoch when it does not exist
# (stamp_age), so a caller compares against a threshold without testing first.
function Get-AvdFileAge {
    param([Parameter(Mandatory)][string]$Path)
    $now = Get-AvdEpoch
    if (-not (Test-Path -LiteralPath $Path)) { return $now }
    $m = [System.DateTimeOffset]::new((Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc).ToUnixTimeSeconds()
    $now - $m
}

# -- Logging (lib/log.sh) -----------------------------------------------------

# Create the log's directory and rotate it to <file>.1 past max_bytes (5 MiB).
function Initialize-AvdLog {
    param([Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 5242880)
    $dir = Split-Path -Parent $Path
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt $MaxBytes) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction SilentlyContinue
    }
}

# Append "YYYY-MM-DD HH:MM:SS <message>" (local time, the format the status
# reader parses for the last completed run). Never throws: a reader holding the
# file open without write sharing (an editor) gets three short retries, then the
# line is dropped rather than failing the run that wanted to log it.
function Write-AvdLog {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Message)
    $line = [System.DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) + ' ' + $Message + "`n"
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::AppendAllText($Path, $line, $script:Utf8NoBom); return }
        catch { Start-Sleep -Milliseconds 50 }
    }
}

# -- Single-flight locks (single_flight_lock) ---------------------------------

# The start time of a live process, as UTC ticks, or $null. Split out so the
# tests can play a reused pid.
function Get-AvdProcessStartTick {
    param([Parameter(Mandatory)][int]$Id)
    try { (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().Ticks }
    catch { $null }
}

# Is the process that wrote this lock still the one holding that pid? A pid
# alone is not enough on Windows, which hands pids out again quickly: a stale
# sync.lock whose pid now belongs to a stranger would block every later run.
# When no start time was recorded, the pid alone decides (the macOS rule).
function Test-AvdLockOwnerAlive {
    param([Nullable[int]]$OwnerId, [Nullable[long]]$StartedTick)
    if ($null -eq $OwnerId -or $OwnerId -le 0) { return $false }
    $now = Get-AvdProcessStartTick -Id $OwnerId
    if ($null -eq $now) { return $false }
    if ($null -eq $StartedTick) { return $true }
    [math]::Abs($now - $StartedTick) -le [System.TimeSpan]::TicksPerSecond * 2
}

function Read-AvdLockFile {
    param([Parameter(Mandatory)][string]$Path)
    $pidFile = Join-Path $Path 'pid'
    $startedFile = Join-Path $Path 'started'
    $owner = $null; $started = $null; $age = $null
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        $age = Get-AvdFileAge -Path $pidFile
        $t = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue)
        if ($t -match '(\d+)') { $owner = [int]$Matches[1] }
    }
    if (Test-Path -LiteralPath $startedFile -PathType Leaf) {
        $t = (Get-Content -LiteralPath $startedFile -Raw -ErrorAction SilentlyContinue)
        if ($t -match '(\d+)') { $started = [long]$Matches[1] }
    }
    [pscustomobject]@{ OwnerId = $owner; StartedTick = $started; PidFileAge = $age }
}

# Is a run holding this lock right now? What the status reader asks.
function Test-AvdLockAlive {
    param([Parameter(Mandatory)][string]$Path)
    $l = Read-AvdLockFile -Path $Path
    Test-AvdLockOwnerAlive -OwnerId $l.OwnerId -StartedTick $l.StartedTick
}

# Take <dir> as a lock and record this process in <dir>\pid and <dir>\started.
# The test-and-set is an exclusive create of the pid file (CreateNew is atomic
# on NTFS; PowerShell's New-Item -ItemType Directory checks and then creates).
# Status: held | busy (OwnerId set) | error. A lock whose owner is gone is
# reclaimed, and -Notice hears one line about it. An empty pid file younger
# than five seconds is an owner between its create and its write, not a stale
# lock (the one race mkdir-then-printf also had).
function Enter-AvdLock {
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$Notice)
    $pidFile = Join-Path $Path 'pid'
    $take = {
        $null = New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop
        $fs = [System.IO.File]::Open($pidFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $b = $script:Utf8NoBom.GetBytes("$PID`n")
            $fs.Write($b, 0, $b.Length)
        } finally { $fs.Dispose() }
        $tick = Get-AvdProcessStartTick -Id $PID
        if ($null -ne $tick) { [System.IO.File]::WriteAllText((Join-Path $Path 'started'), "$tick`n", $script:Utf8NoBom) }
    }
    try {
        & $take
        return [pscustomobject]@{ Status = 'held'; OwnerId = $PID }
    } catch [System.IO.IOException] {
        $l = Read-AvdLockFile -Path $Path
        if (Test-AvdLockOwnerAlive -OwnerId $l.OwnerId -StartedTick $l.StartedTick) {
            return [pscustomobject]@{ Status = 'busy'; OwnerId = $l.OwnerId }
        }
        if ($null -eq $l.OwnerId -and $null -ne $l.PidFileAge -and $l.PidFileAge -lt 5) {
            return [pscustomobject]@{ Status = 'busy'; OwnerId = $null }
        }
        if ($Notice) { & $Notice "reclaiming a stale lock (pid $(if ($l.OwnerId) { $l.OwnerId } else { '?' }) is gone)" }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        try {
            & $take
            return [pscustomobject]@{ Status = 'held'; OwnerId = $PID }
        } catch {
            return [pscustomobject]@{ Status = 'error'; OwnerId = $null }
        }
    } catch {
        return [pscustomobject]@{ Status = 'error'; OwnerId = $null }
    }
}

function Exit-AvdLock {
    param([Parameter(Mandatory)][string]$Path)
    $l = Read-AvdLockFile -Path $Path
    # Only the owner releases: a contending run must never touch a lock it did
    # not take (the macOS sync takes the lock BEFORE its exit trap for this).
    if ($l.OwnerId -eq $PID -or $null -eq $l.OwnerId) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -- Processes ----------------------------------------------------------------

# One argument list as a Windows command line, by the rules the C runtime (and
# CommandLineToArgvW) uses to split it again -- the algorithm .NET's
# ArgumentList uses. Needed because Start-Process joins an array with bare
# spaces, and the process runner redirects to files, which only Start-Process
# offers. .NET on Unix splits Arguments by the same rules.
function ConvertTo-AvdCommandLine {
    param([AllowEmptyCollection()][string[]]$ArgumentList = @())
    $parts = foreach ($a in $ArgumentList) {
        if ($null -eq $a) { $a = '' }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $i = 0
        while ($i -lt $a.Length) {
            $c = $a[$i]; $i++
            if ($c -eq '\') {
                $n = 1
                while ($i -lt $a.Length -and $a[$i] -eq '\') { $i++; $n++ }
                if ($i -eq $a.Length) { [void]$sb.Append([char]92, $n * 2) }
                elseif ($a[$i] -eq '"') { [void]$sb.Append([char]92, $n * 2 + 1).Append('"'); $i++ }
                else { [void]$sb.Append([char]92, $n) }
                continue
            }
            if ($c -eq '"') { [void]$sb.Append('\"'); continue }
            [void]$sb.Append($c)
        }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    @($parts) -join ' '
}

# Quote one argument for a command line that cmd.exe reads first: always in
# double quotes, so cmd treats & | < > ^ ( ) ; , = as text; trailing
# backslashes doubled, so the C runtime of the program cmd starts does not
# read the closing quote as escaped. A double quote cannot be expressed
# safely through cmd and is refused. (% still expands; a path with %NAME% in
# it is not supported.)
function ConvertTo-AvdCmdArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Contains('"')) { throw "cannot pass a double quote through cmd.exe: $Value" }
    $m = [regex]::Match($Value, '\\+$')
    if ($m.Success) { $Value = $Value + ('\' * $m.Length) }
    '"' + $Value + '"'
}

# The cmd.exe arguments that run a .bat/.cmd with these arguments. /d skips
# AutoRun, /s makes cmd strip exactly the outer pair of quotes. sdkmanager.bat
# and avdmanager.bat hand %* to java unchanged, so quoting survives to it.
function Get-AvdCmdArgument {
    param([Parameter(Mandatory)][string]$BatchFile, [AllowEmptyCollection()][string[]]$ArgumentList = @(), [string]$Suffix = '')
    $inner = @((ConvertTo-AvdCmdArgument $BatchFile)) + @($ArgumentList | ForEach-Object { ConvertTo-AvdCmdArgument $_ })
    $line = $inner -join ' '
    if ($Suffix) { $line = "$line $Suffix" }
    '/d /s /c "' + $line + '"'
}

function Get-AvdCmdPath {
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    Join-Path $root 'System32\cmd.exe'
}

# Run a program to completion and return @{ ExitCode; TimedOut; StdOut; StdErr }.
# The run_bounded of this port, and it keeps its rules:
#   - a wall-clock bound (0 = none); on expiry the WHOLE process tree is killed
#     and the exit code is 124;
#   - stdin is an empty file (or -StdinText), never the caller's console: adb
#     forwards its stdin to the device, and a CLI that prompts must fail, not
#     wait;
#   - stdout and stderr go to FILES, not pipes, because a grandchild that
#     inherits a pipe (an adb server started on demand) holds it open and a
#     pipe reader would then wait for it forever;
#   - a program that cannot be started at all returns 127, as a shell would.
# For a console host only: from a process with no console (the tray) the child
# would get a console window of its own; the tray uses Start-AvdDetachedProcess.
function Invoke-AvdProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 0,
        [AllowEmptyString()][string]$StdinText = '',
        [string]$WorkingDirectory
    )
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $dir
    $in = Join-Path $dir 'stdin'; $out = Join-Path $dir 'stdout'; $err = Join-Path $dir 'stderr'
    try {
        [System.IO.File]::WriteAllText($in, $StdinText, $script:Utf8NoBom)
        $exe = $FilePath
        if ($IsWindows -and $FilePath -match '\.(bat|cmd)$') {
            $exe = Get-AvdCmdPath
            $argLine = Get-AvdCmdArgument -BatchFile $FilePath -ArgumentList $ArgumentList
        } else {
            $argLine = ConvertTo-AvdCommandLine -ArgumentList $ArgumentList
        }
        $sp = @{
            FilePath               = $exe
            RedirectStandardInput  = $in
            RedirectStandardOutput = $out
            RedirectStandardError  = $err
            PassThru               = $true
            NoNewWindow            = $true
            ErrorAction            = 'Stop'
        }
        if ($argLine) { $sp.ArgumentList = $argLine }
        if ($WorkingDirectory) { $sp.WorkingDirectory = $WorkingDirectory }
        try { $p = Start-Process @sp }
        catch {
            return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = $_.Exception.Message }
        }
        # Touch the handle now: a Start-Process -PassThru object whose handle
        # was never read reports a null ExitCode after the process exits.
        $null = $p.Handle
        $timedOut = $false
        if ($TimeoutSec -gt 0) {
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                $timedOut = $true
                try { $p.Kill($true) } catch { Write-Verbose "kill: $($_.Exception.Message)" }
                $null = $p.WaitForExit(10000)
            }
        } else {
            $p.WaitForExit()
        }
        $code = if ($timedOut) { 124 } else { [int]$p.ExitCode }
        $so = if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllText($out, $script:Utf8NoBom) } else { '' }
        $se = if (Test-Path -LiteralPath $err) { [System.IO.File]::ReadAllText($err, $script:Utf8NoBom) } else { '' }
        [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; StdOut = $so; StdErr = $se }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Start a long-running program (icloudpd) with stdout and stderr to the given
# files and stdin from an empty file, and return the process without waiting.
# The caller polls it, copies the files into its log, and kills the tree if it
# must. Same console caveat as Invoke-AvdProcess.
function Start-AvdProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath,
        [string]$WorkingDirectory
    )
    $in = "$StdoutPath.stdin"
    [System.IO.File]::WriteAllText($in, '', $script:Utf8NoBom)
    $sp = @{
        FilePath               = $FilePath
        RedirectStandardInput  = $in
        RedirectStandardOutput = $StdoutPath
        RedirectStandardError  = $StderrPath
        PassThru               = $true
        NoNewWindow            = $true
        ErrorAction            = 'Stop'
    }
    $argLine = ConvertTo-AvdCommandLine -ArgumentList $ArgumentList
    if ($argLine) { $sp.ArgumentList = $argLine }
    if ($WorkingDirectory) { $sp.WorkingDirectory = $WorkingDirectory }
    $p = Start-Process @sp
    $null = $p.Handle
    $p
}

# Copy the bytes appended to -Source since -Offset onto -Destination and return
# the new offset. Reads with write sharing, so the writer keeps writing; a
# partial last line is held back until its newline arrives.
function Copy-AvdNewByte {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [long]$Offset = 0)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $Offset }
    $fs = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        if ($fs.Length -le $Offset) { return $Offset }
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buf = [byte[]]::new($fs.Length - $Offset)
        $read = 0
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $fs.Dispose() }
    if ($read -le 0) { return $Offset }
    $last = [array]::LastIndexOf($buf, [byte]10, $read - 1)
    if ($last -lt 0) { return $Offset }
    $chunk = [byte[]]::new($last + 1)
    [array]::Copy($buf, $chunk, $last + 1)
    $ds = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $ds.Write($chunk, 0, $chunk.Length) } finally { $ds.Dispose() }
    $Offset + $chunk.Length
}

# Start a program with NO window and NOT attached to this console, and return
# it. Two users: the tray, which has no console (a console child of it would
# open a window of its own), and the emulator, which must not keep a headless
# task console alive -- Task Scheduler tracks the task by that console host,
# so an emulator attached to it would make a finished sync look like a running
# one and every later 15-minute tick would be skipped as a duplicate.
function Start-AvdDetachedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$RawArgument,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($RawArgument) { $psi.Arguments = $RawArgument }
    else { foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) } }
    foreach ($k in $Environment.Keys) { $psi.Environment[[string]$k] = [string]$Environment[$k] }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    [System.Diagnostics.Process]::Start($psi)
}

# Launch the emulator detached, its output appended to -LogPath. On Windows
# through `cmd /d /s /c "... >> log 2>&1"` under CreateNoWindow: cmd supplies
# the append redirection and the window-less console that Start-Process cannot
# give together. ANDROID_HOME and ANDROID_SDK_ROOT name the pipeline's own SDK,
# as the macOS scripts set them for the emulator.
function Start-AvdEmulatorProcess {
    param(
        [Parameter(Mandatory)][string]$EmulatorPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$SdkRoot
    )
    $envs = @{ ANDROID_HOME = $SdkRoot; ANDROID_SDK_ROOT = $SdkRoot }
    $logDir = Split-Path -Parent $LogPath
    if ($logDir) { $null = New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue }
    if ($IsWindows) {
        $raw = Get-AvdCmdArgument -BatchFile $EmulatorPath -ArgumentList $ArgumentList -Suffix ('>> ' + (ConvertTo-AvdCmdArgument $LogPath) + ' 2>&1')
        return Start-AvdDetachedProcess -FilePath (Get-AvdCmdPath) -RawArgument $raw -Environment $envs
    }
    $envs['AVD_EMULATOR_LOG'] = $LogPath
    Start-AvdDetachedProcess -FilePath '/bin/sh' -ArgumentList (@('-c', 'exec "$0" "$@" >>"$AVD_EMULATOR_LOG" 2>&1', $EmulatorPath) + $ArgumentList) -Environment $envs
}

# Does this command line run the AVD named $AvdName? `-avd <name>` or
# `@<name>`, as an exact token: the macOS `pgrep -f "qemu-system.*$AVD_NAME"`
# would also match gphotos-tablet-old, and a Windows port has no reason to copy
# that looseness.
function Test-AvdEmulatorCommandLine {
    param([AllowEmptyString()][AllowNull()][string]$CommandLine, [Parameter(Mandatory)][string]$AvdName)
    if (-not $CommandLine) { return $false }
    $tokens = @([regex]::Matches($CommandLine, '"([^"]*)"|(\S+)') | ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
        })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -eq "@$AvdName") { return $true }
        if ($tokens[$i] -eq '-avd' -and $i + 1 -lt $tokens.Count -and $tokens[$i + 1] -eq $AvdName) { return $true }
    }
    $false
}

# The processes running this AVD: on Windows the emulator's qemu-system-*.exe
# and its emulator.exe launcher, found through CIM (a process's command line
# is readable for the user's own processes without elevation); elsewhere ps.
function Get-AvdEmulatorProcess {
    param([Parameter(Mandatory)][string]$AvdName)
    $found = [System.Collections.Generic.List[int]]::new()
    if ($IsWindows) {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'qemu-system%' OR Name LIKE 'emulator%'" -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            if (Test-AvdEmulatorCommandLine -CommandLine $p.CommandLine -AvdName $AvdName) { $found.Add([int]$p.ProcessId) }
        }
    } else {
        $r = Invoke-AvdProcess -FilePath '/bin/ps' -ArgumentList @('-axo', 'pid=,args=') -TimeoutSec 10
        foreach ($l in (ConvertTo-AvdLf $r.StdOut).Split("`n")) {
            $m = [regex]::Match($l, '^\s*(\d+)\s+(.*)$')
            if ($m.Success -and $m.Groups[2].Value -match 'qemu-system' -and
                (Test-AvdEmulatorCommandLine -CommandLine $m.Groups[2].Value -AvdName $AvdName)) {
                $found.Add([int]$m.Groups[1].Value)
            }
        }
    }
    , $found.ToArray()
}

function Test-AvdEmulatorRunning {
    param([Parameter(Mandatory)][string]$AvdName)
    (Get-AvdEmulatorProcess -AvdName $AvdName).Count -gt 0
}

# The last resort after a graceful `emu kill` did not take (pkill -f).
function Stop-AvdEmulatorProcess {
    param([Parameter(Mandatory)][string]$AvdName)
    foreach ($id in (Get-AvdEmulatorProcess -AvdName $AvdName)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

# -- adb ----------------------------------------------------------------------

$script:AvdAdbPath = $null

function Get-AvdAdbPath {
    if (-not $script:AvdAdbPath) {
        $c = Get-Command -Name 'adb' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $script:AvdAdbPath = $c.Source }
    }
    $script:AvdAdbPath
}

# EVERY adb call goes through here. It is the seam the tests replace with a
# fake device, so nothing else may start adb.
function Invoke-AvdAdb {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSec = 60,
        [AllowEmptyString()][string]$StdinText = ''
    )
    $adb = Get-AvdAdbPath
    if (-not $adb) {
        return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = 'adb not found on PATH' }
    }
    Invoke-AvdProcess -FilePath $adb -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec -StdinText $StdinText
}

# A bounded `adb -s <serial> shell <command...>` (dev_capture): the device
# command's own exit status, its stdout with CRs removed, stderr folded in with
# -MergeStderr. adb joins the command words with spaces and the device's sh
# parses the result, exactly as on macOS, so the same words go to the same
# device command. An empty serial is refused: `adb -s ''` addresses whatever
# single device happens to be attached.
function Invoke-AvdAdbShell {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Serial,
        [Parameter(Mandatory)][string[]]$Command,
        [int]$TimeoutSec = 60,
        [switch]$MergeStderr
    )
    if ([string]::IsNullOrEmpty($Serial)) { throw 'Invoke-AvdAdbShell: no serial (refusing to address an arbitrary device)' }
    $r = Invoke-AvdAdb -ArgumentList (@('-s', $Serial, 'shell') + $Command) -TimeoutSec $TimeoutSec
    $out = $r.StdOut
    if ($MergeStderr) { $out = $out + $r.StdErr }
    [pscustomobject]@{ ExitCode = $r.ExitCode; TimedOut = $r.TimedOut; Output = ($out -replace "`r", '') }
}

# The emulator serials in `adb devices` output, whatever their state: an
# offline one is asked its name like any other and simply does not answer.
function ConvertFrom-AvdAdbDevice {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $serials = foreach ($l in (ConvertTo-AvdLf $Text).Split("`n") | Select-Object -Skip 1) {
        $tok = ($l.Trim() -split '\s+')[0]
        if ($tok -match '^emulator-\d+$') { $tok }
    }
    , ([string[]]@($serials))
}

# The name of the AVD on <serial> (`adb emu avd name` answers "<name>\nOK").
# Bounded, because a half-dead emulator answers that by never answering.
function Get-AvdNameOfSerial {
    param([Parameter(Mandatory)][string]$Serial, [int]$TimeoutSec = 10)
    $r = Invoke-AvdAdb -ArgumentList @('-s', $Serial, 'emu', 'avd', 'name') -TimeoutSec $TimeoutSec
    if ($r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    $first = ((ConvertTo-AvdLf $r.StdOut).Split("`n") | Select-Object -First 1)
    if ($null -eq $first) { return $null }
    $first.Trim()
}

# The serial whose running emulator IS <avd-name>, or $null. NEVER ASSUME
# emulator-5554: it is only the first free console port, so any emulator
# started earlier owns it, and every push, query, prune and `emu kill` here
# would then go to a stranger's device.
function Get-AvdEmulatorSerial {
    param([Parameter(Mandatory)][string]$AvdName)
    $r = Invoke-AvdAdb -ArgumentList @('devices') -TimeoutSec 30
    foreach ($s in (ConvertFrom-AvdAdbDevice -Text $r.StdOut)) {
        if ((Get-AvdNameOfSerial -Serial $s) -eq $AvdName) { return $s }
    }
    $null
}

# Single-quote a value for the device's sh (shq): an apostrophe in a name must
# not end the quote.
function ConvertTo-AvdShellQuoted {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    "'" + $Value.Replace("'", "'\''") + "'"
}

# -- icloudpd -----------------------------------------------------------------

# `icloudpd --version` prints "version:1.32.3, commit sha:..., commit
# timestamp:..."; the version, or $null.
function Get-AvdIcloudpdVersion {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    foreach ($l in (ConvertTo-AvdLf $Text).Split("`n")) {
        $m = [regex]::Match($l, '^version:(\d[\d.]*\d|\d)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    $null
}

# THE LIBRARY, NOT THE TOOL (avd-photos-sync's reclaim_icloud): a `uv tool`
# icloudpd is a self-contained binary with nothing importable in it, so the
# reclaim runs against the source of the SAME version, which shares the
# tool's ~/.pyicloud session unchanged.
function Get-AvdIcloudpdSpec {
    param([Parameter(Mandatory)][string]$Version)
    "icloudpd @ git+https://github.com/icloud-photos-downloader/icloud_photos_downloader@v$Version"
}

# -- Paths inside this checkout ------------------------------------------------

# The repository root: this file is <root>\windows\lib\Core.ps1, and an
# install -Copy keeps that layout.
function Get-AvdRepoRoot {
    Split-Path -Parent (Split-Path -Parent $script:AvdLibDir)
}

# bin/avd-photos-reclaim.py, shared with macOS and run as-is.
function Get-AvdReclaimScript {
    $p = Join-Path (Get-AvdRepoRoot) 'bin' 'avd-photos-reclaim.py'
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null }
}

# The emulator mishandles non-ASCII characters in the AVD and SDK paths; a
# path it will choke on is refused up front, by name, with the fix.
function Test-AvdAsciiPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    -not ($Path -match '[^\x00-\x7F]')
}
