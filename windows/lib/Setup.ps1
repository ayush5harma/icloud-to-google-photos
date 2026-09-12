# The setup of the Windows port: bin/avd-photos-setup, phase for phase. A
# rooted Android TABLET emulator -- Magisk + NeoZygisk + the Google Photos spoof
# module -- set up and KEPT CURRENT entirely from the command line, zero taps.
# The reasoning, the measurements and the traps are in the README ("How it
# works") and in bin/avd-photos-setup's comments; where a comment here ports
# one of those it keeps its substance, and where Windows forces a difference it
# says so. windows/DESIGN.md has the port's decisions in one place.
#
# MODES (Invoke-AvdSetup -Mode):
#   Full       set up and update            Check      report versions, change nothing
#   Start      boot the emulator and leave it running (avd-start)
#   Stop       graceful shutdown (avd-stop)
#   Bootstrap  resume an unfinished setup; a no-op once setup completed
#   -Headless  no emulator window (what the weekly task uses)
#
# THE SDK ROOT IS DELIBERATELY ITS OWN: rooting rewrites ramdisk.img in place,
# so a read-only or package-managed SDK can never be rooted.
#
# NOTHING IS VERSION-PINNED -- a re-run IS the update (SDK tools, system image,
# Magisk, NeoZygisk, the modules all resolve to newest on each run). Two updates
# stay OPT-IN because both destroy a working signed-in instance and no scheduled
# job could undo them: recreating the emulator onto a newer API (AVD_RECREATE=1,
# old instance kept as .bak) and re-patching the ramdisk for a newer Magisk
# (AVD_REROOT=1, can leave it unbootable). Both are REPORTED.
#
# HONEST CEILING: the Pixel free-original-quality perk is a spoof of a 2016
# device and Google can withdraw or detect it at any time. This automates the
# setup, not the outcome.
#
# The run's state (the bash script's globals: the serial, whether we started
# the emulator, whether adb is root, ...) lives in $script:AvdSetup, set by
# Initialize-AvdSetupState. Function and variable names carry "Setup" because
# every part of the port is dot-sourced into ONE module scope, where a second
# definition of the same name would silently replace the first.

$script:AvdSetup = $null

$script:SetupGphotosPkg = 'com.google.android.apps.photos'
$script:SetupPixelifyRepo = 'Xposed-Modules-Repo/io.github.samson910022.pixelifyphotos'
$script:SetupPixelifyPkg = 'io.github.samson910022.pixelifyphotos'
$script:SetupVectorRepo = 'JingMatrix/Vector'
$script:SetupNeoZygiskRepo = 'JingMatrix/NeoZygisk'
$script:SetupMagiskRepo = 'topjohnwu/Magisk'
# -- Magisk modules flashed from GitHub releases, in order ---------------------
# "repo|module-id|asset-regex|note", stamp-tracked by release tag so a re-run
# re-flashes ONLY when upstream moves. NeoZygisk provides Zygisk and has its own
# phase before these. GPhotosUnlimited spoofs Build fields, native properties
# AND PackageManager.hasSystemFeature(), which is what Photos reads to pick the
# backup tier; it SUPERSEDES PixelifyPhotos (Build fields only), so Pixelify is
# disabled when it is installed. The same list as bin/avd-photos-setup.
$script:SetupMagiskModules = @(
    'Rev4N1/GPhotosUnlimited|unlimitedphotos|\.zip$|Google Photos Unlimited Backup'
)
# DELIBERATELY NOT FLASHED, each for a measured reason (bin/avd-photos-setup):
#   5ec1cff/TrickyStore -- keystore attestation spoofing, added while the spoof
#     was still broken on the theory that Photos gates the perk on Play
#     Integrity. It does not: the working configuration is NeoZygisk +
#     GPhotosUnlimited and nothing else.
#   MeowDump/Integrity-Box (playintegrityfix) -- its default profile claims
#     RELEASE=CANARY and api_level=32 on an API-37 device, so Android resolves
#     NULL Resources and the process dies in handleBindApplication: Play Store
#     crashed on every launch and Photos lost its account after any force-stop.
#     Revisiting means editing custom.pif.prop to the device's real API level
#     FIRST, never flashing it as shipped.
#   KernelSU-Modules-Repo/magic_mount_rs -- a metamodule supplying Magic Mount
#     to KernelSU variants; Magisk has it natively.
$script:SetupVcli = '/data/adb/modules/zygisk_vector/cli'
$script:SetupMagisk = '/debug_ramdisk/magisk'
$script:SetupPatchDir = '/data/local/tmp/magiskpatch'
$script:SetupSepolMemfd = 'allow zygote magisk memfd_file { read write map open getattr execute }'
# Google's own SDK repository manifest, the source sdkmanager itself reads;
# archive URLs in it are relative to its directory.
$script:SetupSdkRepositoryBase = 'https://dl.google.com/android/repository/'
$script:SetupSdkManifestUri = 'https://dl.google.com/android/repository/repository2-3.xml'

# ============================================================================
# Pure helpers (no state, no I/O): what the tests pin.
# ============================================================================

# Where a tool of the pipeline's own SDK lives. On Windows sdkmanager and
# avdmanager are .bat files (Invoke-AvdProcess runs those through cmd.exe) and
# the rest are .exe; elsewhere the names are extensionless, which is what the
# tests on a Mac exercise.
function Get-AvdSdkToolPath {
    param(
        [Parameter(Mandatory)][string]$SdkRoot,
        [Parameter(Mandatory)][ValidateSet('emulator', 'sdkmanager', 'avdmanager', 'adb')][string]$Name,
        [ValidateSet('Windows', 'Unix')][string]$Platform = (Get-AvdPlatform)
    )
    $win = $Platform -eq 'Windows'
    switch ($Name) {
        'emulator' { Join-AvdPath $Platform $SdkRoot, 'emulator', $(if ($win) { 'emulator.exe' } else { 'emulator' }) }
        'sdkmanager' { Join-AvdPath $Platform $SdkRoot, 'cmdline-tools', 'latest', 'bin', $(if ($win) { 'sdkmanager.bat' } else { 'sdkmanager' }) }
        'avdmanager' { Join-AvdPath $Platform $SdkRoot, 'cmdline-tools', 'latest', 'bin', $(if ($win) { 'avdmanager.bat' } else { 'avdmanager' }) }
        'adb' { Join-AvdPath $Platform $SdkRoot, 'platform-tools', $(if ($win) { 'adb.exe' } else { 'adb' }) }
    }
}

# The archive of one package for one host OS in Google's SDK repository
# manifest: @{ Url; Sha1; Size; Revision }, or $null. Matched by local name, so
# the manifest's namespaces do not matter, and by the EXACT package path: the
# manifest also carries cmdline-tools;2.1, an obsolete cmdline-tools;2.0 and a
# dozen more, and any prefix match takes the wrong one.
function ConvertFrom-AvdSdkRepositoryXml {
    param(
        [Parameter(Mandatory)][string]$Xml,
        [string]$PackagePath = 'cmdline-tools;latest',
        [string]$HostOs = 'windows',
        [string]$BaseUri = $script:SetupSdkRepositoryBase
    )
    $doc = [System.Xml.XmlDocument]::new()
    $doc.XmlResolver = $null
    $doc.LoadXml($Xml)
    foreach ($pkg in $doc.SelectNodes("//*[local-name()='remotePackage']")) {
        if ($pkg.GetAttribute('path') -cne $PackagePath) { continue }
        $rev = ''
        $major = $pkg.SelectSingleNode("*[local-name()='revision']/*[local-name()='major']")
        $minor = $pkg.SelectSingleNode("*[local-name()='revision']/*[local-name()='minor']")
        if ($major) { $rev = $major.InnerText.Trim(); if ($minor) { $rev += '.' + $minor.InnerText.Trim() } }
        foreach ($a in $pkg.SelectNodes("*[local-name()='archives']/*[local-name()='archive']")) {
            $os = $a.SelectSingleNode("*[local-name()='host-os']")
            if (-not $os -or $os.InnerText.Trim() -cne $HostOs) { continue }
            $url = $a.SelectSingleNode("*[local-name()='complete']/*[local-name()='url']")
            $sum = $a.SelectSingleNode("*[local-name()='complete']/*[local-name()='checksum'][@type='sha1']")
            $size = $a.SelectSingleNode("*[local-name()='complete']/*[local-name()='size']")
            if (-not $url -or -not $sum -or -not $size) { continue }
            $u = $url.InnerText.Trim()
            if ($u -notmatch '^https?://') { $u = $BaseUri + $u }
            return [pscustomobject]@{
                Url      = $u
                Sha1     = $sum.InnerText.Trim().ToLowerInvariant()
                Size     = [long]$size.InnerText.Trim()
                Revision = $rev
            }
        }
    }
    $null
}

# API levels, newest first, de-duplicated. Google names API levels as POINT
# RELEASES now (android-37.0), so this is sort -Vr, not a numeric sort:
# 37.0 > 36.1 > 36.0 > 36.
function Get-AvdSortedApi {
    param([AllowEmptyCollection()][string[]]$Version = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $Version) {
        if ($null -eq $v) { continue }
        $m = [regex]::Match($v, '^([0-9]+)(?:\.([0-9]+))?$')
        if (-not $m.Success -or -not $seen.Add($v)) { continue }
        $minor = if ($m.Groups[2].Success) { [long]$m.Groups[2].Value } else { -1L }
        $items.Add([pscustomobject]@{ V = $v; Major = [long]$m.Groups[1].Value; Minor = $minor })
    }
    $sorted = @($items | Sort-Object -Property @{ Expression = 'Major'; Descending = $true }, @{ Expression = 'Minor'; Descending = $true })
    , ([string[]]@($sorted | ForEach-Object { $_.V }))
}

# The API levels `sdkmanager --list` offers for this tag and ABI, newest first.
# The version must be followed immediately by `;`, which with the exact
# `;<tag>;` match excludes the -beta/-rc/CANARY builds and the 16 KB `_ps16k`
# variants -- those resist ramdisk patching. The ABI must end there too, so
# AVD_ABI=x86 cannot pick up an x86_64 image (the macOS grep has no such end).
function Get-AvdSystemImageApi {
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Abi
    )
    $re = 'system-images;android-([0-9]+(?:\.[0-9]+)?);' + [regex]::Escape($Tag) + ';' + [regex]::Escape($Abi) + '(?![A-Za-z0-9_-])'
    $found = [System.Collections.Generic.List[string]]::new()
    if ($Text) { foreach ($m in [regex]::Matches($Text, $re)) { $found.Add($m.Groups[1].Value) } }
    Get-AvdSortedApi -Version $found.ToArray()
}

# The API level an existing emulator was created on, from its config.ini, or
# ''. Anchor on the separator AFTER the version, never a greedy digit run:
# `image.sysdir.1=system-images/android-37.0/...` read with a bare `([0-9]+)`
# yields "37", which never equals the resolved "37.0" (so it warns about a
# newer API forever) and builds a system-images/android-37 ramdisk path that
# does not exist (so the root phase dies). avdmanager on Windows writes that
# line with BACKSLASHES (system-images\android-37.0\google_apis\x86_64\), so
# both separators count.
function Get-AvdSysdirApi {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    foreach ($line in (ConvertTo-AvdLf $Text).Split("`n")) {
        if (-not $line.StartsWith('image.sysdir.1=')) { continue }
        $m = [regex]::Match($line, '^.*android-([0-9]+(?:\.[0-9]+)?)[\\/]')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }
    ''
}

# The emulator's config.ini, tuned: the macOS inline Python, rule for rule.
# Lines without '=' or starting with '#' are dropped, keys and values stripped,
# the last duplicate wins, the tuned keys overwrite, and the result is sorted
# ORDINALLY by key (Python's sorted()) and written "k=v" with LF and a final LF.
# Values are copied verbatim, so a Windows path in one keeps its backslashes.
function ConvertTo-AvdTunedConfigIni {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Width, [Parameter(Mandatory)][string]$Height,
        [Parameter(Mandatory)][string]$Dpi, [Parameter(Mandatory)][string]$Ram,
        [Parameter(Mandatory)][string]$Cores, [Parameter(Mandatory)][string]$Disk,
        [Parameter(Mandatory)][string]$Heap, [Parameter(Mandatory)][string]$Gpu
    )
    $kv = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in (ConvertTo-AvdLf $Text).Split("`n")) {
        if (-not $line.Contains('=') -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        $kv[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
    $tuned = [ordered]@{
        'hw.lcd.width' = $Width; 'hw.lcd.height' = $Height; 'hw.lcd.density' = $Dpi
        'hw.ramSize' = $Ram; 'hw.cpu.ncore' = $Cores; 'disk.dataPartition.size' = $Disk
        'hw.gpu.enabled' = 'yes'; 'hw.gpu.mode' = $Gpu; 'vm.heapSize' = $Heap
        'hw.keyboard' = 'yes'; 'showDeviceFrame' = 'no'
    }
    foreach ($k in $tuned.Keys) { $kv[$k] = $tuned[$k] }
    $keys = [string[]]@($kv.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($k in $keys) { [void]$sb.Append($k).Append('=').Append($kv[$k]).Append("`n") }
    $sb.ToString()
}

# `emulator -accel-check` prints a block:
#   accel:
#   0
#   WHPX(10.0.26100) is installed and usable.
#   accel
# The number is the emulator's acceleration status; only 0 means usable, and
# the text names the hypervisor or what is missing. Returns @{ Status (int or
# $null when there is no block); Message }.
function ConvertFrom-AvdAccelCheck {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $lines = @((ConvertTo-AvdLf $Text).Split("`n") | ForEach-Object { $_.Trim() })
    $start = [array]::IndexOf($lines, 'accel:')
    if ($start -ge 0 -and $start + 1 -lt $lines.Count) {
        $n = 0
        if ([int]::TryParse($lines[$start + 1], [ref]$n)) {
            $msg = [System.Collections.Generic.List[string]]::new()
            for ($i = $start + 2; $i -lt $lines.Count -and $lines[$i] -ne 'accel'; $i++) {
                if ($lines[$i]) { $msg.Add($lines[$i]) }
            }
            return [pscustomobject]@{ Status = $n; Message = ($msg -join ' ') }
        }
    }
    [pscustomobject]@{ Status = $null; Message = (@($lines | Where-Object { $_ }) -join ' ') }
}

# The major version in `java -version` output ('openjdk version "21.0.4"' ->
# 21, 'java version "1.8.0_401"' -> 8), or $null.
function Get-AvdJavaMajorVersion {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, 'version "([0-9]+)(?:\.([0-9]+))?')
    if (-not $m.Success) { return $null }
    $major = [int]$m.Groups[1].Value
    if ($major -eq 1 -and $m.Groups[2].Success) { $major = [int]$m.Groups[2].Value }
    $major
}

# The android_id in GMS's Checkin.xml shared preferences, or ''.
function ConvertFrom-AvdCheckinXml {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, 'name="android_id">([0-9]+)<')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

# A GitHub release object's tag (`.tag_name // empty`).
function Get-AvdReleaseTag {
    param($Release)
    if ($null -eq $Release) { return '' }
    $p = $Release.PSObject.Properties['tag_name']
    if ($p -and $null -ne $p.Value) { [string]$p.Value } else { '' }
}

# The first asset of a release whose NAME matches -Pattern, case-sensitively
# as jq's test() does (PowerShell's -match would not be).
function Get-AvdReleaseAssetUrl {
    param($Release, [Parameter(Mandatory)][string]$Pattern)
    if ($null -eq $Release) { return '' }
    $assets = $Release.PSObject.Properties['assets']
    if (-not $assets -or $null -eq $assets.Value) { return '' }
    foreach ($a in @($assets.Value)) {
        if ($null -eq $a) { continue }
        $n = $a.PSObject.Properties['name']
        $u = $a.PSObject.Properties['browser_download_url']
        if ($n -and $u -and $n.Value -and $u.Value -and [regex]::IsMatch([string]$n.Value, $Pattern)) { return [string]$u.Value }
    }
    ''
}

# `head -N` / `tail -N` of command output, as an array of lines.
function Select-AvdLine {
    param([AllowEmptyString()][AllowNull()][string]$Text, [int]$First = 0, [int]$Last = 0)
    $t = (ConvertTo-AvdLf $Text).TrimEnd("`n")
    if ($t -eq '') { return , @() }
    $lines = $t.Split("`n")
    if ($First -gt 0) { return , ([string[]]@($lines | Select-Object -First $First)) }
    if ($Last -gt 0) { return , ([string[]]@($lines | Select-Object -Last $Last)) }
    , ([string[]]$lines)
}

# `grep -q '^ok$'`: a line that is exactly "ok".
function Test-AvdOkLine {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    @((ConvertTo-AvdLf $Text).Split("`n")) -ccontains 'ok'
}

# `[ -s file ]`
function Test-AvdNonEmptyFile {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path -Force).Length -gt 0
}

function Get-AvdShortHash {
    param([AllowEmptyString()][string]$Hash)
    if ($Hash.Length -gt 16) { $Hash.Substring(0, 16) } else { $Hash }
}

# The on-device ramdisk patch, windows\device\patch-ramdisk.sh: byte-identical
# to the heredoc in bin/avd-photos-setup (Setup.Tests.ps1 fails if they drift).
# Returned LF-only whatever the checkout did to it, because Android's sh reads
# a CR as part of the command and the script's first line would fail.
function Get-AvdOnDevicePatchScript {
    $p = Join-Path (Split-Path -Parent $script:AvdLibDir) 'device' 'patch-ramdisk.sh'
    $t = [System.IO.File]::ReadAllText($p, $script:Utf8NoBom)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    ConvertTo-AvdLf $t
}

# ============================================================================
# State, logging, dying
# ============================================================================

function Initialize-AvdSetupState {
    param(
        [Parameter(Mandatory)]$Config,
        [System.Collections.IDictionary]$Environment = @{},
        [ValidateSet('Full', 'Check', 'Start', 'Stop', 'Bootstrap')][string]$Mode = 'Full',
        [switch]$Headless
    )
    $platform = $Config.PLATFORM
    $sdk = $Config.AVD_SDK_ROOT
    $name = $Config.AVD_NAME
    $avdDir = Join-AvdPath $platform $Config.AVD_HOME, "$name.avd"
    # PHONESKY_SHARED resolves only when SHARED_CACHE_DIR's parent exists: a
    # cloud folder that is not mounted must not be created as a local one.
    $shared = ''
    if ($Config.SHARED_CACHE_DIR) {
        $parent = Split-Path -Parent $Config.SHARED_CACHE_DIR
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
            $shared = Join-AvdPath $platform $Config.SHARED_CACHE_DIR, 'Phonesky.apk'
        }
    }
    $envValue = { param($k) if ($Environment.Contains($k)) { [string]$Environment[$k] } else { '' } }
    $state = @{
        Config         = $Config
        Environment    = $Environment
        Platform       = $platform
        Mode           = $Mode
        Check          = $Mode -eq 'Check'
        StartOnly      = $Mode -eq 'Start'
        StopOnly       = $Mode -eq 'Stop'
        Headless       = [bool]$Headless
        SdkRoot        = $sdk
        Stamps         = Join-AvdPath $platform $Config.STATE_DIR, 'stamps'
        Log            = Join-AvdPath $platform $Config.LOG_DIR, 'setup.log'
        EmuLog         = Join-AvdPath $platform $Config.LOG_DIR, 'emulator.log'
        # THE DONE MARKER, and it is written only after the LAST phase
        # succeeds. The bootstrap task runs at every login and must resume an
        # interrupted build rather than declare victory: keying it on the
        # emulator's config.ini (which appears in phase 2 of eight) made a run
        # interrupted during the multi-GB download a no-op until the weekly
        # run came round.
        SetupDone      = Join-AvdPath $platform $Config.STATE_DIR, 'setup-complete'
        Lock           = Join-AvdPath $platform $Config.STATE_DIR, 'setup.lock'
        DevTimeout     = [int](ConvertTo-AvdInt (& $envValue 'DEV_TIMEOUT') 60)
        BootWait       = [int](ConvertTo-AvdInt (& $envValue 'BOOT_WAIT') 90)   # x3 s; a cold boot is slow
        Recreate       = (& $envValue 'AVD_RECREATE') -ceq '1'
        Reroot         = (& $envValue 'AVD_REROOT') -ceq '1'
        DonorApi       = & $envValue 'PLAYSTORE_DONOR_API'
        Emulator       = Get-AvdSdkToolPath -SdkRoot $sdk -Name emulator -Platform $platform
        SdkManager     = Get-AvdSdkToolPath -SdkRoot $sdk -Name sdkmanager -Platform $platform
        AvdManager     = Get-AvdSdkToolPath -SdkRoot $sdk -Name avdmanager -Platform $platform
        AvdDir         = $avdDir
        AvdIniFile     = Join-AvdPath $platform $Config.AVD_HOME, "$name.ini"
        ConfigIni      = Join-AvdPath $platform $avdDir, 'config.ini'
        PhoneskyCache  = Join-AvdPath $platform $Config.STATE_DIR, 'phonesky', 'Phonesky.apk'
        PhoneskyShared = $shared
        # Resolved by NAME in Start-AvdSetupEmulator (Get-AvdEmulatorSerial),
        # never assumed: emulator-5554 is only the first free console port, so
        # any emulator started before this one owns it -- and this script
        # flashes modules, patches a ramdisk and reboots whatever serial it is
        # handed.
        Serial         = ''
        EmuStartedByUs = $false
        AdbRootOk      = $false
        GhWarned       = $false
        JavaChecked    = $false
        AccelChecked   = $false
        Api            = ''
        PlaystoreOk    = $false
        # Wall-clock bounds in seconds (the macOS values; tests shrink them).
        SerialWaitSec  = 180
        DonorWaitSec   = 300
        KillWaitSec    = 60
        RebootDownSec  = 60
        StopWaitTries  = 30
    }
    $script:AvdSetup = $state
    $state
}

# setup.log gets the macOS prefixes, no timestamps ('== ', '   ', '   ! ',
# '   ERROR '). Never throws: a log line lost is better than a run failed.
function Add-AvdSetupLog {
    param([AllowEmptyString()][string]$Line)
    $s = $script:AvdSetup
    if ($null -eq $s -or -not $s.Log) { return }
    try { [System.IO.File]::AppendAllText($s.Log, $Line + "`n", $script:Utf8NoBom) }
    catch { Write-Verbose "setup.log: $($_.Exception.Message)" }
}

function Write-AvdSetupHeading {
    param([AllowEmptyString()][string]$Message)
    Write-Host ''
    Write-Host "== $Message"
    Add-AvdSetupLog "== $Message"
}

function Write-AvdSetupStep {
    param([AllowEmptyString()][string]$Message)
    Write-Host "  $Message"
    Add-AvdSetupLog "   $Message"
}

function Write-AvdSetupWarning {
    param([AllowEmptyString()][string]$Message)
    Write-Host "  ! $Message" -ForegroundColor Yellow
    Add-AvdSetupLog "   ! $Message"
}

# die: say it, log it, and unwind to Invoke-AvdSetup, whose finally block is
# the bash script's EXIT trap (stop an emulator we started, release the lock).
function Stop-AvdSetup {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Add-AvdSetupLog "   ERROR $Message"
    $e = [System.InvalidOperationException]::new($Message)
    $e.Data['AvdSetupDie'] = $true
    throw $e
}

# ============================================================================
# Stamps, release lookups, downloads, asset pinning
# ============================================================================

function Get-AvdSetupStamp {
    param([Parameter(Mandatory)][string]$Key)
    $p = Join-AvdPath $script:AvdSetup.Platform $script:AvdSetup.Stamps, $Key
    try {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return ([System.IO.File]::ReadAllText($p, $script:Utf8NoBom)).TrimEnd("`r", "`n") }
    } catch { Write-Verbose "stamp $Key unreadable: $($_.Exception.Message)" }
    ''
}

# Returns whether the write happened: Test-AvdSetupAsset REFUSES an asset whose
# hash it could not record, because a pin nobody can write is not a pin.
function Set-AvdSetupStamp {
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value)
    $p = Join-AvdPath $script:AvdSetup.Platform $script:AvdSetup.Stamps, $Key
    try { [System.IO.File]::WriteAllText($p, $Value, $script:Utf8NoBom); $true }
    catch { Write-Verbose "stamp $Key unwritable: $($_.Exception.Message)"; $false }
}

# Does this pwsh bound a stalled read? -OperationTimeoutSeconds arrived in 7.4,
# where -TimeoutSec also became the CONNECT timeout only (measured on 7.6.5:
# TimeoutSec is an alias of ConnectionTimeoutSeconds). Without it a server that
# accepts and then stalls can hang a download; with it a read that waits
# longer than the bound fails, which is the stalled-server case curl's
# --speed-limit/--speed-time covers on macOS.
function Test-AvdOperationTimeoutSupport {
    (Get-Command -Name Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')
}

# Latest release JSON for a GitHub repo, memoised for an hour. Fetching each
# release twice (tag, then asset URL) tripled the round-trips against the
# unauthenticated 60/hour limit AND raced -- a release published between the
# two recorded a stamp that did not match the flashed asset.
#
# THE LIMIT IS REAL AND THE FALLBACK IS THE POINT: 60 requests per hour per IP,
# shared with everything else on the network. When the API does not answer, a
# STALE cached answer is used and said so (the pipeline then keeps whatever
# version it has, which is correct -- nothing here is pinned and the next run
# updates); with no cache at all the caller gets $null, reports "latest: ?" and
# changes nothing. GITHUB_TOKEN raises the limit to 5,000/hour and is optional.
# It goes in a request header from this process, never on a command line
# (anything there is readable by every process of this user). Retries follow
# curl's --retry 2: transient failures and 408/429/5xx only, never a 403.
function Get-AvdSetupRelease {
    param([Parameter(Mandatory)][string]$Repo)
    $s = $script:AvdSetup
    $f = Join-AvdPath $s.Platform $s.Config.STATE_DIR, ('gh-' + $Repo.Replace('/', '_') + '.json')
    $parse = {
        param($text)
        try { ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $null }
    }
    if ((Test-AvdNonEmptyFile $f) -and (Get-AvdFileAge -Path $f) -le 3600) {
        return (& $parse ([System.IO.File]::ReadAllText($f, $script:Utf8NoBom)))
    }
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($s.Config.GITHUB_TOKEN) { $headers['Authorization'] = 'Bearer ' + $s.Config.GITHUB_TOKEN }
    $req = @{
        Uri                = "https://api.github.com/repos/$Repo/releases/latest"
        Headers            = $headers
        TimeoutSec         = 30
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    if (Test-AvdOperationTimeoutSupport) { $req['OperationTimeoutSeconds'] = 30 }
    $code = $null; $content = ''
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $r = Invoke-WebRequest @req
            $code = [int]$r.StatusCode
            $content = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        } catch {
            $code = $null; $content = ''
            Write-Verbose "GitHub API $Repo`: $($_.Exception.Message)"
        }
        if ($null -ne $code -and @(408, 429, 500, 502, 503, 504) -notcontains $code) { break }
        if ($attempt -lt 2) { Start-Sleep -Seconds ([int][math]::Pow(2, $attempt)) }
    }
    if ($code -eq 200 -and $content.Length -gt 0) {
        Write-AvdTextFile -Path $f -Text $content
        return (& $parse $content)
    }
    $codeText = if ($null -ne $code) { "$code" } else { 'none' }
    if (Test-AvdNonEmptyFile $f) {
        Write-AvdSetupWarning "GitHub API answered $codeText for $Repo -- using the cached release info ($([math]::Floor((Get-AvdFileAge -Path $f) / 3600))h old)"
        return (& $parse ([System.IO.File]::ReadAllText($f, $script:Utf8NoBom)))
    }
    if (-not $s.GhWarned) {
        $s.GhWarned = $true
        if ($code -eq 403 -or $code -eq 429) {
            Write-AvdSetupWarning 'GitHub API rate limit reached (60 requests/hour unauthenticated).'
            Write-AvdSetupWarning 'Version checks are skipped this run; set GITHUB_TOKEN in the config to raise it.'
        } else {
            Write-AvdSetupWarning "GitHub API unreachable (HTTP $codeText) -- version checks skipped this run."
        }
    }
    $null
}

# Download to a temp name, then rename: an interrupted download never leaves a
# truncated file under the name a later `[ -s ]` test accepts. Downloads need
# their own bound (a JSON document's 30 s does not suit a 150 MB image, and no
# bound at all lets a stalled server hang the weekly task forever): -TimeoutSec
# 900 as on macOS, plus the stall bound where this pwsh has one (see
# Test-AvdOperationTimeoutSupport). The progress bar is off: it redraws per
# chunk and throttles a download to a fraction of the line speed.
function Save-AvdSetupDownload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Uri)
    $ProgressPreference = 'SilentlyContinue'
    $tmp = "$Path.part-$PID"
    $req = @{ Uri = $Uri; OutFile = $tmp; TimeoutSec = 900; MaximumRetryCount = 3; RetryIntervalSec = 2; ErrorAction = 'Stop' }
    if (Test-AvdOperationTimeoutSupport) { $req['OperationTimeoutSeconds'] = 60 }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop }
        Invoke-WebRequest @req
        if (-not (Test-Path -LiteralPath $tmp -PathType Leaf)) { return $false }
        [System.IO.File]::Move($tmp, $Path, $true)
        $true
    } catch {
        Write-Verbose "download $Uri`: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $false
    }
}

# Record this asset's sha256 beside its release tag, and refuse it if the same
# tag ever produces different bytes (verify_asset).
#
# WHAT THIS IS AND IS NOT. Everything flashed here is an unsigned artefact from
# a GitHub release, fetched over TLS, and TLS only says the bytes came from
# GitHub -- not that the release is the one that was reviewed. Nothing here is
# version-pinned by design (a re-run is the update), so a hash pinned in this
# repository would be wrong by the next release and is not on offer. What IS on
# offer is that a tag cannot change under you: the first time a tag is seen its
# hash is recorded in stamps\, and a later download of that SAME tag must match
# or nothing is flashed. That catches a re-uploaded asset and a corrupted or
# truncated download; it does not catch a malicious NEW release, which is the
# residual risk the README states plainly.
function Test-AvdSetupAsset {
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Tag, [Parameter(Mandatory)][string]$Path)
    $s = $script:AvdSetup
    if (-not $Tag) { $Tag = 'untagged' }
    if (-not (Test-AvdNonEmptyFile $Path)) { Write-AvdSetupWarning "empty download for $Key"; return $false }
    $have = ''
    try { $have = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { Write-Verbose "hash $Path`: $($_.Exception.Message)" }
    if (-not $have) { Write-AvdSetupWarning "could not hash $Path"; return $false }
    $stampKey = "sha-$Key-$Tag"
    $want = Get-AvdSetupStamp -Key $stampKey
    if ($want -and $want -cne $have) {
        Write-AvdSetupWarning "REFUSING $Key ${Tag}: its bytes changed since this machine first saw that tag"
        Write-AvdSetupWarning "  recorded $(Get-AvdShortHash $want)...  downloaded $(Get-AvdShortHash $have)..."
        Write-AvdSetupWarning "  delete $(Join-AvdPath $s.Platform $s.Stamps, $stampKey) to accept the new bytes deliberately"
        return $false
    }
    if (-not $want) {
        # A RECORD THAT FAILS TO WRITE MUST FAIL THE CHECK. An unwritable
        # stamps directory would otherwise disable the pin silently: every run
        # would record nothing, find nothing recorded, and print a reassuring
        # hash line while accepting whatever bytes arrived.
        if (-not (Set-AvdSetupStamp -Key $stampKey -Value $have)) {
            Write-AvdSetupWarning "could not record $Key $Tag's hash in $($s.Stamps) -- refusing it rather than pinning nothing"
            return $false
        }
        Write-AvdSetupStep "$Key $Tag sha256 $(Get-AvdShortHash $have)... (recorded)"
    } else {
        Write-AvdSetupStep "$Key $Tag sha256 $(Get-AvdShortHash $have)... (matches the recorded hash)"
    }
    $true
}

# ============================================================================
# The device
# ============================================================================

# Time-bounded device shell (dev) returning the device command's OWN status:
# without that, failures on the device were discarded and surfaced later as a
# confusing missing-file error. stderr is folded in, as the callers print it.
# The command goes as ONE argument, LF-only, and the device's sh parses it.
# With no serial there is no call at all: `adb -s ''` addresses whatever single
# device happens to be attached (the macOS -Check with the emulator stopped
# made exactly those calls), so an unresolved serial reads as "no answer".
function Invoke-AvdSetupDevice {
    param([Parameter(Mandatory)][string]$Command, [string]$Serial)
    $s = $script:AvdSetup
    if (-not $PSBoundParameters.ContainsKey('Serial')) { $Serial = $s.Serial }
    if ([string]::IsNullOrEmpty($Serial)) {
        return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = '' }
    }
    Invoke-AvdAdbShell -Serial $Serial -Command @((ConvertTo-AvdLf $Command)) -TimeoutSec $s.DevTimeout -MergeStderr
}

# ROOT ROUTE: on a userdebug image `adb root` works; on a `user` build it is
# refused and privileged commands must go through Magisk's `su`. Detect once,
# route everything through Invoke-AvdSetupRootDevice, and the rest need not
# care. The su route quotes the command properly: the macOS `su -c '$*'`
# breaks on any command with an apostrophe in it (the sepolicy rule and the
# Magisk --sqlite call both have one); for every other command the two strings
# are identical.
function Invoke-AvdSetupRootDevice {
    param([Parameter(Mandatory)][string]$Command)
    if ($script:AvdSetup.AdbRootOk) { return (Invoke-AvdSetupDevice -Command $Command) }
    Invoke-AvdSetupDevice -Command ('su -c ' + (ConvertTo-AvdShellQuoted (ConvertTo-AvdLf $Command)))
}

# EVERY boot drops adbd back to the shell user, after which
# `magisk --install-module` fails with a bare "Run this command with root" that
# reads as a Magisk problem rather than a missing `adb root`.
function Enable-AvdSetupAdbRoot {
    $s = $script:AvdSetup
    $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'root') -TimeoutSec 30
    Start-Sleep -Seconds 4
    $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'wait-for-device') -TimeoutSec 60
    $out = (Invoke-AvdSetupDevice -Command 'id -u').Output
    $s.AdbRootOk = @((ConvertTo-AvdLf $out).Split("`n")) -ccontains '0'
}

# KEEP THE VERSION-SHAPED FILTER. The magisk binary lives in Magisk's tmpfs,
# not on PATH, and `magisk -v` on an UNROOTED device prints "magisk:
# inaccessible or not found" on STDOUT -- a bare non-empty test reads that
# error text as a version and silently skips the whole rooting phase.
function Get-AvdSetupMagiskVersion {
    $first = Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk -v").Output -First 1
    if ($first.Count -gt 0 -and $first[0] -match '^[0-9]+\.[0-9]+') { $first[0] } else { '' }
}

# Zygisk health is "is NeoZygisk's daemon actually running", NOT Magisk's
# `zygisk` setting flag. The flag only says the built-in implementation is
# switched on, which on Android 17 is precisely the thing that does not work.
function Test-AvdSetupZygisk {
    Test-AvdOkLine (Invoke-AvdSetupDevice -Command 'pidof zygiskd64 >/dev/null 2>&1 && echo ok').Output
}

# Root, not plain: /data/adb is 0700 root, so an unprivileged test always says
# "absent" and the phase then tries to reflash a module that is running.
function Test-AvdSetupNeoZygisk {
    Test-AvdOkLine (Invoke-AvdSetupRootDevice -Command '[ -d /data/adb/modules/zygisksu ] && echo ok').Output
}

function Test-AvdSetupModule {
    param([Parameter(Mandatory)][string]$Id)
    Test-AvdOkLine (Invoke-AvdSetupRootDevice -Command "[ -d /data/adb/modules/$Id ] && echo ok").Output
}

function Test-AvdSetupPackage {
    param([Parameter(Mandatory)][string]$Package)
    (Invoke-AvdSetupDevice -Command 'pm list packages 2>/dev/null').Output.Contains("package:$Package")
}

# The ACTIVE build's versionCode: `dumpsys package` lists the active package
# first and the image build under "Hidden system packages".
function Get-AvdSetupVersionCode {
    param([Parameter(Mandatory)][string]$Package)
    $m = [regex]::Match((Invoke-AvdSetupDevice -Command "dumpsys package $Package 2>/dev/null").Output, 'versionCode=([0-9]+)')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

# The device id for google.com/android/uncertified. NOT readable through the
# usual gservices query: on google_apis the GSF package is inert, so it answers
# "No result found" even after a successful check-in, which reads as "this
# device has no id and can never be registered" and is wrong. GMS holds the
# real id, in two places that agree.
function Get-AvdSetupGsfDeviceId {
    $id = ConvertFrom-AvdCheckinXml (Invoke-AvdSetupDevice -Command 'cat /data/data/com.google.android.gms/shared_prefs/Checkin.xml 2>/dev/null').Output
    if (-not $id) {
        $o = (Invoke-AvdSetupDevice -Command 'sqlite3 /data/data/com.google.android.gms/databases/gservices.db "select value from main where name=\"android_id\";" 2>/dev/null').Output
        foreach ($l in (ConvertTo-AvdLf $o).Split("`n")) { if ($l -match '^[0-9]{15,25}$') { $id = $l; break } }
    }
    $id
}

# ============================================================================
# The host tools: Java, sdkmanager, the command-line tools, acceleration
# ============================================================================

# sdkmanager.bat runs %JAVA_HOME%\bin\java.exe when JAVA_HOME is set (and fails
# when it points nowhere), else the java on PATH; this asks the same one.
function Get-AvdSetupJavaPath {
    $s = $script:AvdSetup
    $jh = if ($s.Environment.Contains('JAVA_HOME')) { [string]$s.Environment['JAVA_HOME'] } else { '' }
    if ($jh) {
        $j = Join-AvdPath $s.Platform $jh, 'bin', $(if ($s.Platform -eq 'Windows') { 'java.exe' } else { 'java' })
        if (Test-Path -LiteralPath $j -PathType Leaf) { return $j }
        Stop-AvdSetup "JAVA_HOME is set to $jh, but $j does not exist; point JAVA_HOME at a JDK 17 or newer (winget install Microsoft.OpenJDK.21), or remove it"
    }
    $c = Get-Command -Name 'java' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

# sdkmanager and avdmanager are Java programs and current releases need JDK 17
# or newer; with an older one they die on a class-version error that names
# neither Java nor the fix. Checked once per run, before the first of them.
function Assert-AvdSetupJava {
    $s = $script:AvdSetup
    if ($s.JavaChecked) { return }
    $java = Get-AvdSetupJavaPath
    if (-not $java) { Stop-AvdSetup 'Java not found; sdkmanager needs a JDK 17 or newer: winget install Microsoft.OpenJDK.21, then open a new terminal' }
    $r = Invoke-AvdProcess -FilePath $java -ArgumentList @('-version') -TimeoutSec 30
    $v = Get-AvdJavaMajorVersion ($r.StdErr + "`n" + $r.StdOut)
    if ($r.ExitCode -ne 0) { Stop-AvdSetup "$java -version failed (exit $($r.ExitCode)); sdkmanager needs a JDK 17 or newer: winget install Microsoft.OpenJDK.21" }
    if ($null -eq $v) { Write-AvdSetupWarning "could not read the Java version from $java -version; carrying on" }
    elseif ($v -lt 17) { Stop-AvdSetup "$java is Java $v; sdkmanager needs 17 or newer: winget install Microsoft.OpenJDK.21 (and point JAVA_HOME at it if it is set)" }
    $s.JavaChecked = $true
}

function Resolve-AvdSetupSdkManager {
    $s = $script:AvdSetup
    if (Test-Path -LiteralPath $s.SdkManager -PathType Leaf) { return $s.SdkManager }
    $c = Get-Command -Name 'sdkmanager' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

# sdkm: the root's own sdkmanager once it has one, else whatever sdkmanager is
# on PATH, both with --sdk_root. avdmanager cannot be pointed at a non-default
# SDK root by environment in every packaging (some wrappers PREPEND their own
# path to ANDROID_HOME and the tool then answers "Package path is not valid ...
# : null"), so the writable root gets its OWN cmdline-tools and everything
# after uses those. Windows has no package-manager sdkmanager to start from, so
# with none anywhere the tools are downloaded from Google (not in -Check,
# which changes nothing).
function Invoke-AvdSetupSdkManager {
    param(
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 0,
        [AllowEmptyString()][string]$StdinText = ''
    )
    $s = $script:AvdSetup
    $sdkm = Resolve-AvdSetupSdkManager
    if (-not $sdkm) {
        if ($s.Check) {
            Write-AvdSetupWarning "no sdkmanager yet (neither $($s.SdkManager) nor one on PATH) -- avd-photos-setup installs it"
            return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = 'no sdkmanager' }
        }
        Install-AvdSetupCmdlineTool
        $sdkm = $s.SdkManager
    }
    Assert-AvdSetupJava
    Invoke-AvdProcess -FilePath $sdkm -ArgumentList (@("--sdk_root=$($s.SdkRoot)") + $ArgumentList) -TimeoutSec $TimeoutSec -StdinText $StdinText
}

# The command-line tools, from Google's repository manifest, verified by BOTH
# the manifest's size and its sha1. The zip's top level is a cmdline-tools\
# folder; its CONTENTS must land in <root>\cmdline-tools\latest. Unzipped as-is
# it lands in cmdline-tools\cmdline-tools and sdkmanager then cannot find its
# SDK root -- the classic trap of a manual install. SHA1 because it is the only
# checksum the manifest publishes; it guards against a corrupt or truncated
# download (with the size), and TLS to dl.google.com is what says the bytes
# are Google's.
function Install-AvdSetupCmdlineTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '',
        Justification = 'Google''s SDK manifest publishes only a sha1; it is checked with the size, over TLS.')]
    param()
    $s = $script:AvdSetup
    $hostOs = if ($s.Platform -eq 'Windows') { 'windows' } elseif ($IsMacOS) { 'macosx' } else { 'linux' }
    Write-AvdSetupStep 'no sdkmanager yet: fetching the Android command-line tools from Google (one time)'
    $xml = ''
    try {
        $req = @{ Uri = $script:SetupSdkManifestUri; TimeoutSec = 60; ErrorAction = 'Stop' }
        if (Test-AvdOperationTimeoutSupport) { $req['OperationTimeoutSeconds'] = 60 }
        $r = Invoke-WebRequest @req
        $xml = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    } catch { Stop-AvdSetup "could not read Google's SDK repository manifest ($script:SetupSdkManifestUri): $($_.Exception.Message)" }
    $pkg = $null
    try { $pkg = ConvertFrom-AvdSdkRepositoryXml -Xml $xml -HostOs $hostOs } catch { Write-Verbose "manifest: $($_.Exception.Message)" }
    if (-not $pkg) { Stop-AvdSetup "no cmdline-tools;latest archive for $hostOs in $script:SetupSdkManifestUri" }
    $zip = Join-AvdPath $s.Platform $s.Config.STATE_DIR, 'cmdline-tools-download.zip'
    if (-not (Save-AvdSetupDownload -Path $zip -Uri $pkg.Url)) { Stop-AvdSetup "could not download $($pkg.Url)" }
    $len = (Get-Item -LiteralPath $zip).Length
    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($len -ne $pkg.Size -or $sha -cne $pkg.Sha1) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Stop-AvdSetup "the command-line tools download did not verify: $len bytes, sha1 $sha; the manifest says $($pkg.Size) bytes, sha1 $($pkg.Sha1)"
    }
    $tools = Join-AvdPath $s.Platform $s.SdkRoot, 'cmdline-tools'
    $stage = Join-AvdPath $s.Platform $tools, ".extract-$PID"
    $latest = Join-AvdPath $s.Platform $tools, 'latest'
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Force -Path $stage
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
        $inner = Join-AvdPath $s.Platform $stage, 'cmdline-tools'
        if (-not (Test-Path -LiteralPath $inner -PathType Container)) {
            Stop-AvdSetup "the command-line tools archive has no top-level cmdline-tools folder ($($pkg.Url))"
        }
        if (Test-Path -LiteralPath $latest) { Remove-Item -LiteralPath $latest -Recurse -Force }
        Move-Item -LiteralPath $inner -Destination $latest
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $s.SdkManager -PathType Leaf)) { Stop-AvdSetup "no sdkmanager at $($s.SdkManager) after unpacking the command-line tools" }
    Write-AvdSetupStep "command-line tools $($pkg.Revision) installed in $latest"
}

# The emulator needs a hypervisor it can use, and without one it does not say
# so at boot: the launch line succeeds and no device ever attaches. Asked once
# per run, before the first launch; -Check reports it and nothing more.
function Assert-AvdSetupAcceleration {
    $s = $script:AvdSetup
    if ($s.AccelChecked) { return }
    if (-not (Test-Path -LiteralPath $s.Emulator -PathType Leaf)) { Stop-AvdSetup "emulator binary missing under $($s.SdkRoot)" }
    $r = Invoke-AvdProcess -FilePath $s.Emulator -ArgumentList @('-accel-check') -TimeoutSec 60
    $p = ConvertFrom-AvdAccelCheck ($r.StdOut + "`n" + $r.StdErr)
    $ok = $r.ExitCode -eq 0 -and ($null -eq $p.Status -or $p.Status -eq 0)
    $what = if ($p.Message) { $p.Message } else { "exit $($r.ExitCode)" }
    if ($ok) {
        Write-AvdSetupStep "acceleration: $what"
        $s.AccelChecked = $true
        return
    }
    Write-AvdSetupWarning "acceleration: $what"
    Write-AvdSetupWarning 'the emulator needs a hypervisor. Either turn virtualization on in the UEFI setup and'
    Write-AvdSetupWarning '  enable Windows Hypervisor Platform, as administrator, then reboot:'
    Write-AvdSetupWarning '    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All'
    Write-AvdSetupWarning '  or install AEHD (not together with Hyper-V or Virtualization-based Security):'
    Write-AvdSetupWarning '    sdkmanager "extras;google;Android_Emulator_Hypervisor_Driver", then run its'
    Write-AvdSetupWarning '    silent_install.bat as administrator'
    if ($s.Check) { $s.AccelChecked = $true; return }
    Stop-AvdSetup "the emulator cannot use hardware acceleration ($what)"
}

function Assert-AvdSetupAdb {
    $s = $script:AvdSetup
    if (-not (Get-AvdAdbPath)) {
        Stop-AvdSetup "adb not found (not in $(Join-AvdPath $s.Platform $s.SdkRoot, 'platform-tools') nor on PATH) -- run avd-photos-setup, which installs it"
    }
}

# The emulator mishandles non-ASCII characters in the SDK and AVD paths (a
# user profile named after a person is the usual way to get one), so such a
# path is refused up front, by name, with the fix.
function Assert-AvdSetupPath {
    $cfg = $script:AvdSetup.Config
    $fix = 'set AVD_SDK_ROOT and ANDROID_AVD_HOME to ASCII directories, such as C:\android-avd-sdk and C:\avd'
    if (-not (Test-AvdAsciiPath $cfg.AVD_SDK_ROOT)) { Stop-AvdSetup "AVD_SDK_ROOT ($($cfg.AVD_SDK_ROOT)) has a non-ASCII character, which the emulator mishandles: $fix" }
    if (-not (Test-AvdAsciiPath $cfg.AVD_HOME)) { Stop-AvdSetup "the AVD home ($($cfg.AVD_HOME)) has a non-ASCII character, which the emulator mishandles: $fix" }
}

# Newest API level offered for this tag/ABI, the list cached for a day in
# STATE_DIR\sdk-images.list (see Get-AvdSystemImageApi for the matching rule).
function Get-AvdSetupLatestApi {
    $s = $script:AvdSetup
    $c = Join-AvdPath $s.Platform $s.Config.STATE_DIR, 'sdk-images.list'
    if (-not (Test-AvdNonEmptyFile $c) -or (Get-AvdFileAge -Path $c) -gt 86400) {
        $r = Invoke-AvdSetupSdkManager -ArgumentList @('--list') -TimeoutSec 600
        if ($r.ExitCode -eq 0) { Write-AvdTextFile -Path $c -Text $r.StdOut }
    }
    $text = if (Test-Path -LiteralPath $c -PathType Leaf) { [System.IO.File]::ReadAllText($c, $script:Utf8NoBom) } else { '' }
    $apis = Get-AvdSystemImageApi -Text $text -Tag $s.Config.AVD_TAG -Abi $s.Config.AVD_ABI
    if ($apis.Count -gt 0) { $apis[0] } else { '' }
}

function Get-AvdSetupInstalledApi {
    $s = $script:AvdSetup
    $dir = Join-AvdPath $s.Platform $s.SdkRoot, 'system-images'
    $names = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($d in Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue) {
            $m = [regex]::Match($d.Name, '^android-([0-9]+(?:\.[0-9]+)?)$')
            if ($m.Success) { $names.Add($m.Groups[1].Value) }
        }
    }
    Get-AvdSortedApi -Version $names.ToArray()
}

# ============================================================================
# Booting, and the two reboots
# ============================================================================

# Bound on WALL CLOCK, not on iterations: `for i in 1..BOOT_WAIT; sleep 3`
# claimed 4.5 min, but each pass also pays for its device call, so a wedged
# adb stretched the same loop past an hour inside a caller that assumed
# minutes.
function Wait-AvdSetupBoot {
    $s = $script:AvdSetup
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Invoke-AvdSetupDevice -Command 'getprop sys.boot_completed').Output.Trim() -ceq '1') {
            Write-AvdSetupStep 'boot complete'
            return $true
        }
        Start-Sleep -Seconds 3
    } while ($sw.Elapsed.TotalSeconds -lt $s.BootWait * 3)
    $false
}

# boot_emulator. The launch flags are load-bearing and fail SILENTLY when
# missing (the GPU one above all), which is why avd-start reuses this instead
# of anyone hand-typing an `emulator -avd` line.
function Start-AvdSetupEmulator {
    $s = $script:AvdSetup
    $name = $s.Config.AVD_NAME
    Assert-AvdSetupAdb
    if (Test-AvdEmulatorRunning -AvdName $name) {
        Write-AvdSetupStep 'emulator already running'
    } else {
        Assert-AvdSetupAcceleration
        $launch = @('-avd', $name, '-no-snapshot', '-gpu', $s.Config.AVD_GPU, '-netdelay', 'none', '-netspeed', 'full', '-no-boot-anim')
        if ($s.Headless) { $launch += '-no-window' }
        Write-AvdSetupStep ("launching $name" + $(if ($s.Headless) { ' (headless)' } else { '' }))
        $s.EmuStartedByUs = $true
        $null = Start-AvdEmulatorProcess -EmulatorPath $s.Emulator -ArgumentList $launch -LogPath $s.EmuLog -SdkRoot $s.SdkRoot
        Start-Sleep -Seconds 8
    }
    $null = Invoke-AvdAdb -ArgumentList @('start-server') -TimeoutSec 60
    # WHICH DEVICE IS OURS: ask every attached emulator its AVD name and take
    # the one that answers with ours. Bounded, because the console answers
    # before the guest has booted but not instantly.
    $s.Serial = ''
    $ser = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $ser = Get-AvdEmulatorSerial -AvdName $name
        if ($ser) { break }
        Start-Sleep -Seconds 3
    } while ($sw.Elapsed.TotalSeconds -lt $s.SerialWaitSec)
    if (-not $ser) { Stop-AvdSetup "no attached emulator answers to the name $name -- see $($s.EmuLog)" }
    $s.Serial = $ser
    Write-AvdSetupStep "device: $ser"
    # -s <serial>: a bare wait-for-device returns on ANY transport, so a stale
    # `adb connect` entry satisfied it instantly while this emulator was booting.
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'wait-for-device') -TimeoutSec 120
    if (-not (Wait-AvdSetupBoot)) { Stop-AvdSetup "the emulator did not finish booting -- see $($s.EmuLog)" }
    # Assert once more now that it is up. Everything after this line patches,
    # flashes and reboots, so being sure of the target is worth one console call.
    $nm = Get-AvdNameOfSerial -Serial $ser
    if ($nm -cne $name) { Stop-AvdSetup "$ser is running '$(if ($nm) { $nm } else { 'unknown' })', not $name -- refusing to touch it" }
    Enable-AvdSetupAdbRoot
}

# TWO DIFFERENT REBOOTS, and using the wrong one silently loses the work.
# Restart-AvdSetupEmulator after a ramdisk patch, because QEMU reads
# ramdisk.img once at VM start and `adb reboot` re-runs the same in-memory
# copy; Restart-AvdSetupDevice after a MAGISK MODULE, because `emu kill`
# discards unflushed writes and lands module files as ZERO BYTES. emu kill is
# safe ONLY before any module exists. Do not collapse these two.
function Restart-AvdSetupEmulator {
    $s = $script:AvdSetup
    $name = $s.Config.AVD_NAME
    Write-AvdSetupStep 'restarting the emulator process (a ramdisk patch is only read at VM start)'
    $null = Invoke-AvdSetupDevice -Command 'sync'
    $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'emu', 'kill') -TimeoutSec 30
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $s.KillWaitSec -and (Test-AvdEmulatorRunning -AvdName $name)) { Start-Sleep -Seconds 2 }
    if (Test-AvdEmulatorRunning -AvdName $name) { Stop-AvdEmulatorProcess -AvdName $name; Start-Sleep -Seconds 3 }
    $s.EmuStartedByUs = $false          # Start-AvdSetupEmulator sets it again for the new process
    Start-AvdSetupEmulator
}

function Restart-AvdSetupDevice {
    # GRACEFUL `adb reboot`, never `adb emu kill`: emu kill made every module
    # install look cursed -- files landed as ZERO BYTES and /data/adb/modules
    # was empty at the next boot, so a module that installed cleanly ("Welcome
    # to Vector! ... Done") simply vanished. sync + adb reboot persists it intact.
    $s = $script:AvdSetup
    Write-AvdSetupStep 'rebooting the emulator (graceful; emu kill loses unflushed module writes)'
    $null = Invoke-AvdSetupDevice -Command 'sync'
    $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'reboot') -TimeoutSec 30
    # Wait for the device to GO DOWN first: `adb reboot` is asynchronous, so a
    # bare sleep + wait-for-boot reads sys.boot_completed=1 from the system
    # that is about to shut down and calls the reboot finished before it began.
    $gone = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $s.RebootDownSec) {
        if ((Invoke-AvdSetupDevice -Command 'getprop sys.boot_completed').ExitCode -ne 0) { $gone = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $gone) { Start-Sleep -Seconds 12 }
    if (-not (Test-AvdEmulatorRunning -AvdName $s.Config.AVD_NAME)) { Start-Sleep -Seconds 2; Start-AvdSetupEmulator; return }
    $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'wait-for-device') -TimeoutSec 120
    if (-not (Wait-AvdSetupBoot)) { Write-AvdSetupWarning 'the emulator is slow to come back after the reboot' }
    Enable-AvdSetupAdbRoot
}

# ============================================================================
# 1. SDK: update tools, ensure the newest image is downloaded
# ============================================================================

function Invoke-AvdSetupSdkPhase {
    $s = $script:AvdSetup
    $cfg = $s.Config
    Write-AvdSetupHeading "SDK ($($s.SdkRoot))"
    $newest = Get-AvdSetupLatestApi
    $installed = Get-AvdSetupInstalledApi
    $have = if ($installed.Count -gt 0) { $installed[0] } else { '' }
    if (-not $newest) { $newest = $have }
    if (-not $newest) { Stop-AvdSetup "could not resolve any $($cfg.AVD_TAG)/$($cfg.AVD_ABI) system image" }

    if ($s.Check) {
        $emuver = ''
        if (Test-Path -LiteralPath $s.Emulator -PathType Leaf) {
            $r = Invoke-AvdProcess -FilePath $s.Emulator -ArgumentList @('-version') -TimeoutSec 60
            $first = Select-AvdLine -Text $r.StdOut -First 1
            if ($first.Count -gt 0) {
                $m = [regex]::Match($first[0], 'version ([0-9.]+)')
                $emuver = if ($m.Success) { $m.Groups[1].Value } else { $first[0].Trim() }
            }
        }
        Write-AvdSetupStep "emulator: $(if ($emuver) { $emuver } else { 'absent' })"
        Write-AvdSetupStep "system images installed: $($installed -join ' ')"
        Write-AvdSetupStep "newest available API: $newest"
        if (Test-Path -LiteralPath $s.Emulator -PathType Leaf) { Assert-AvdSetupAcceleration }
        $s.Api = if ($have) { $have } else { $newest }
        return
    }

    Write-AvdSetupStep 'updating SDK tools'
    $null = Invoke-AvdSetupSdkManager -ArgumentList @('--licenses') -StdinText ("y`n" * 100) -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $s.AvdManager -PathType Leaf)) {
        Write-AvdSetupStep 'bootstrapping cmdline-tools into the writable root'
        $null = Invoke-AvdSetupSdkManager -ArgumentList @('--install', 'cmdline-tools;latest') -TimeoutSec 1800
    }
    $r = Invoke-AvdSetupSdkManager -ArgumentList @('--update') -TimeoutSec 1800
    if ($r.ExitCode -eq 0) { Write-AvdSetupStep 'cmdline-tools/emulator/platform-tools current' }
    else { Write-AvdSetupWarning 'sdkmanager --update failed (offline?)' }

    $image = "system-images;android-$newest;$($cfg.AVD_TAG);$($cfg.AVD_ABI)"
    if (-not (Test-Path -LiteralPath (Join-AvdPath $s.Platform $s.SdkRoot, 'system-images', "android-$newest", $cfg.AVD_TAG, $cfg.AVD_ABI) -PathType Container)) {
        Write-AvdSetupStep "downloading $image (multi-GB, one time)"
        $r = Invoke-AvdSetupSdkManager -ArgumentList @('--install', 'emulator', 'platform-tools', 'cmdline-tools;latest', $image) -TimeoutSec 5400
        if ($r.ExitCode -ne 0) { Write-AvdSetupWarning 'system image install failed or timed out' }
    }
    if (-not (Test-Path -LiteralPath $s.Emulator -PathType Leaf)) { Stop-AvdSetup "emulator binary missing under $($s.SdkRoot)" }
    Assert-AvdSetupAcceleration

    # An existing emulator stays on its own API: userdata cannot migrate across
    # API levels, so silently recreating it would wipe a signed-in Photos
    # instance.
    if (Test-Path -LiteralPath $s.ConfigIni -PathType Leaf) {
        $api = Get-AvdSysdirApi -Text ([System.IO.File]::ReadAllText($s.ConfigIni, $script:Utf8NoBom))
        if (-not $api) { $api = $newest }
        if ($api -cne $newest) {
            if ($s.Recreate) {
                # MOVE ASIDE, never delete: a recreate steps onto an API level
                # this pipeline has not rooted before, where the patch can
                # fail, and deleting first would leave no working emulator and
                # no way back. One backup kept.
                $prev = Join-AvdPath $s.Platform $cfg.AVD_HOME, "$($cfg.AVD_NAME).avd.api$api.bak"
                Write-AvdSetupWarning "recreating the emulator on API $newest (AVD_RECREATE=1) -- userdata does NOT migrate"
                Remove-Item -LiteralPath $prev, "$prev.ini" -Recurse -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $s.AvdDir -Destination $prev -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $s.AvdIniFile -Destination "$prev.ini" -ErrorAction SilentlyContinue
                Write-AvdSetupWarning "previous API $api instance kept at $prev"
                Write-AvdSetupWarning "restore with: Remove-Item -Recurse -Force '$($s.AvdDir)', '$($s.AvdIniFile)';"
                Write-AvdSetupWarning "  Move-Item '$prev' '$($s.AvdDir)'; Move-Item '$prev.ini' '$($s.AvdIniFile)'"
                $api = $newest
            } else {
                Write-AvdSetupWarning "the emulator is on API $api; API $newest is available. Recreating starts a"
                Write-AvdSetupWarning 'FRESH instance (userdata cannot migrate), so it is opt-in:'
                Write-AvdSetupWarning '  $env:AVD_RECREATE=1; avd-photos-setup'
            }
        }
    } else { $api = $newest }
    $s.Api = $api
    Write-AvdSetupStep "using API $api"
}

# ============================================================================
# 2. the tablet emulator
# ============================================================================

function Invoke-AvdSetupAvdPhase {
    $s = $script:AvdSetup
    $cfg = $s.Config
    Write-AvdSetupHeading "Emulator ($($cfg.AVD_NAME), device=$($cfg.AVD_DEVICE), API $($s.Api))"
    if (Test-Path -LiteralPath $s.ConfigIni -PathType Leaf) {
        Write-AvdSetupStep 'exists'
        if ($s.Check) { return }
    } else {
        if ($s.Check) { Write-AvdSetupWarning 'not created yet'; return }
        if (-not (Test-Path -LiteralPath $s.AvdManager -PathType Leaf)) { Stop-AvdSetup "cmdline-tools missing under $($s.SdkRoot) (bootstrap failed)" }
        Assert-AvdSetupJava
        $r = Invoke-AvdProcess -FilePath $s.AvdManager -StdinText "no`n" -TimeoutSec 300 -ArgumentList @(
            '--silent', 'create', 'avd', '-n', $cfg.AVD_NAME,
            '-k', "system-images;android-$($s.Api);$($cfg.AVD_TAG);$($cfg.AVD_ABI)", '-d', $cfg.AVD_DEVICE,
            '--abi', $cfg.AVD_ABI, '-p', $s.AvdDir)
        if ($r.ExitCode -ne 0) {
            foreach ($l in (Select-AvdLine -Text ($r.StdOut + "`n" + $r.StdErr) -Last 5)) { if ($l.Trim()) { Write-AvdSetupWarning $l.Trim() } }
            Stop-AvdSetup 'avdmanager create failed'
        }
        if (-not (Test-Path -LiteralPath $s.ConfigIni -PathType Leaf)) { Stop-AvdSetup "avdmanager reported success but wrote no $($s.ConfigIni)" }
        Write-AvdSetupStep 'created'
    }
    $res = [string]$cfg.AVD_RES
    $w = if ($res.LastIndexOf('x') -ge 0) { $res.Substring(0, $res.LastIndexOf('x')) } else { $res }
    $h = if ($res.IndexOf('x') -ge 0) { $res.Substring($res.IndexOf('x') + 1) } else { $res }
    $text = [System.IO.File]::ReadAllText($s.ConfigIni, $script:Utf8NoBom)
    $tuned = ConvertTo-AvdTunedConfigIni -Text $text -Width $w -Height $h -Dpi $cfg.AVD_DPI -Ram $cfg.AVD_RAM `
        -Cores $cfg.AVD_CORES -Disk $cfg.AVD_DISK -Heap $cfg.AVD_HEAP -Gpu $cfg.AVD_GPU
    Write-AvdTextFile -Path $s.ConfigIni -Text $tuned
    Write-AvdSetupStep "tuned ${w}x$h@$($cfg.AVD_DPI)dpi, $($cfg.AVD_RAM)MB RAM, $($cfg.AVD_CORES) cores, $($cfg.AVD_DISK) data, heap $($cfg.AVD_HEAP), gpu $($cfg.AVD_GPU)"
}

# ============================================================================
# 3. root: Magisk's OWN patcher, driven directly
# ============================================================================
# rootAVD is the usual tool for this and is NOT used, because every one of its
# failures is silent: it SELF-UPDATES from GitHub at run time (so any local
# patch is discarded mid-run), its busybox probe requires the version banner to
# contain "Magisk" when current builds say "topjohnwu", it invokes the binary
# as `libbusybox.so` which busybox rejects as an unknown applet, and when its
# version scrape returns nothing its selection menu spins forever printing
# "invalid option". Left alone it quietly patches with its BUNDLED Magisk 25.2.
#
# Doing it directly instead: an emulator ramdisk.img is a bare compressed cpio
# with NO Android boot header, so `boot_patch.sh` cannot unpack it ("Unable to
# unpack boot image") and only the ramdisk section of Magisk's own sequence
# applies. Two details are load-bearing, and are why the on-device script
# (windows\device\patch-ramdisk.sh) exports and re-detects rather than
# assuming: magiskboot reads KEEPVERITY/KEEPFORCEENCRYPT from the ENVIRONMENT
# (plain shell vars are ignored and it silently patches with
# KEEPVERITY=[false]), and the ramdisk is lz4_legacy, not gzip -- the wrong
# codec yields an unbootable image. magiskboot has no Windows build, and the
# macOS script never ran it on the host either: the patch runs on the device.

# On this emulator Magisk's own staged copies under /data/adb/magisk land as
# ZERO-BYTE files, surfacing as "Incomplete Magisk install" and then "Failed to
# execute BusyBox shell". Refilling them from the APK is what the Magisk app's
# "Additional Setup" would do with a tap. The APK's native libraries are under
# lib\<AVD_ABI>: the macOS script hardcodes lib/arm64-v8a, and a Windows host
# runs x86_64 images.
function Complete-AvdSetupMagiskEnvironment {
    $s = $script:AvdSetup
    $body = @'

    mkdir -p /data/adb/magisk
    cd @W@
    cat lib/@ABI@/libmagisk.so       > /data/adb/magisk/magisk
    cat lib/@ABI@/libmagiskboot.so   > /data/adb/magisk/magiskboot
    cat lib/@ABI@/libmagiskinit.so   > /data/adb/magisk/magiskinit
    cat lib/@ABI@/libmagiskpolicy.so > /data/adb/magisk/magiskpolicy
    cat lib/@ABI@/libbusybox.so      > /data/adb/magisk/busybox
    cat assets/stub.apk                  > /data/adb/magisk/stub.apk
    cat assets/module_installer.sh       > /data/adb/magisk/module_installer.sh
    cat assets/util_functions.sh         > /data/adb/magisk/util_functions.sh
    chmod 755 /data/adb/magisk/*
    MT=$(@MAGISK@ --path 2>/dev/null)
    [ -n "$MT" ] && { mkdir -p $MT/.magisk/busybox
      cat /data/adb/magisk/busybox > $MT/.magisk/busybox/busybox
      chmod 755 $MT/.magisk/busybox/busybox; }

'@
    $body = $body.Replace('@W@', $script:SetupPatchDir).Replace('@ABI@', $s.Config.AVD_ABI).Replace('@MAGISK@', $script:SetupMagisk)
    $null = Invoke-AvdSetupDevice -Command $body
    $null = Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --restorecon"
}

function Invoke-AvdSetupRootPhase {
    $s = $script:AvdSetup
    $cfg = $s.Config
    $W = $script:SetupPatchDir
    $abi = $cfg.AVD_ABI
    Write-AvdSetupHeading 'Boot'
    # -Check promises "report versions, change nothing": no boot (a
    # non-headless one throws a window on screen), no `adb root`, no
    # Complete-AvdSetupMagiskEnvironment rewriting /data/adb/magisk. It also
    # used to burn ~6 min of timeouts launching an emulator that had never been
    # created.
    if ($s.Check -and -not (Test-AvdEmulatorRunning -AvdName $cfg.AVD_NAME)) {
        Write-AvdSetupWarning 'emulator not running -- on-device checks skipped (start it, or run without -Check)'
        return
    }
    Start-AvdSetupEmulator
    Write-AvdSetupStep "adb $($s.Serial)"

    Write-AvdSetupHeading 'Magisk'
    $rel = Get-AvdSetupRelease -Repo $script:SetupMagiskRepo
    $latest = (Get-AvdReleaseTag $rel) -replace '^v', ''
    $cur = Get-AvdSetupMagiskVersion
    if ($cur) {
        Write-AvdSetupStep ("installed: $cur" + $(if ($latest) { "  (latest $latest)" } else { '' }))
        if ($latest -and $cur.Split(':')[0] -cne $latest -and -not $s.Reroot) {
            Write-AvdSetupWarning "a newer Magisk ($latest) exists; re-patching can leave the emulator"
            Write-AvdSetupWarning 'unbootable, so it is opt-in: $env:AVD_REROOT=1; avd-photos-setup'
        }
        # Complete-AvdSetupMagiskEnvironment rewrites eight files under
        # /data/adb/magisk and runs restorecon, so -Check must return BEFORE it.
        if ($s.Check) { return }
        if (-not $s.Reroot) { Complete-AvdSetupMagiskEnvironment; return }
    }
    if ($s.Check) { Write-AvdSetupWarning 'not rooted'; return }

    $rd = Join-AvdPath $s.Platform $s.SdkRoot, 'system-images', "android-$($s.Api)", $cfg.AVD_TAG, $abi, 'ramdisk.img'
    if (-not (Test-Path -LiteralPath $rd -PathType Leaf)) { Stop-AvdSetup "ramdisk.img not found at $rd" }
    if (-not (Test-Path -LiteralPath "$rd.backup" -PathType Leaf)) { Copy-Item -LiteralPath $rd -Destination "$rd.backup" -Force }

    $apk = Join-AvdPath $s.Platform $cfg.STATE_DIR, 'magisk-latest.apk'
    $mu = Get-AvdReleaseAssetUrl (Get-AvdSetupRelease -Repo $script:SetupMagiskRepo) '^Magisk-v.*\.apk$'
    if ($mu) { $null = Save-AvdSetupDownload -Path $apk -Uri $mu }
    if (-not (Test-AvdNonEmptyFile $apk)) { Stop-AvdSetup 'could not fetch the Magisk APK' }
    if (-not (Test-AvdSetupAsset -Key 'magisk' -Tag $latest -Path $apk)) { Stop-AvdSetup 'the Magisk APK did not verify -- nothing was patched' }
    Write-AvdSetupStep "patching ramdisk with Magisk $(if ($latest) { $latest } else { 'latest' })"

    $ser = $s.Serial
    $null = Invoke-AvdSetupDevice -Command "rm -rf $W; mkdir -p $W"
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'push', $apk, "$W/magisk.apk") -TimeoutSec 300
    # The PRISTINE ramdisk, never the live one: a re-root patches the backup,
    # so a second patch is never stacked on the first.
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'push', "$rd.backup", "$W/ramdisk.img") -TimeoutSec 300
    $null = Invoke-AvdSetupDevice -Command ("cd $W && unzip -o -q magisk.apk 'assets/*' 'lib/$abi/*' && " +
        "cp lib/$abi/libmagiskboot.so magiskboot && cp lib/$abi/libmagiskinit.so magiskinit && " +
        "cp lib/$abi/libmagisk.so magisk && cp lib/$abi/libinit-ld.so init-ld && " +
        'cp assets/stub.apk stub.apk && chmod 755 magiskboot magiskinit magisk init-ld')

    # Ask Magisk if it is up to answer, else probe for the spare virtio
    # partition. PLAIN device call on purpose: this runs BEFORE Magisk exists,
    # so there is no su to escalate with; it returns nothing and the
    # /dev/block probe answers instead.
    $pre = ''
    foreach ($l in (ConvertTo-AvdLf (Invoke-AvdSetupDevice -Command "$script:SetupMagisk --preinit-device").Output).Split("`n")) {
        if ($l -cmatch '^[a-z0-9]+$') { $pre = $l; break }
    }
    if (-not $pre) {
        # Test with `[ -e ] && echo ok`, NEVER `ls | grep "$c"`: ls prints
        # "ls: /dev/block/vdd1: No such file or directory", which CONTAINS the
        # probe token, so the first candidate always "succeeds" and an
        # arbitrary PREINITDEVICE lands in Magisk's config -- the
        # zero-byte-modules case the patch script's comment describes.
        foreach ($c in @('vdd1', 'vdc1', 'vdb1')) {
            if (Test-AvdOkLine (Invoke-AvdSetupDevice -Command "[ -e /dev/block/$c ] && echo ok").Output) { $pre = $c; break }
        }
    }
    if ($pre) { Write-AvdSetupStep "preinit device: $pre" } else { Write-AvdSetupWarning 'no preinit device found -- modules will not persist' }

    # LF, no BOM, whatever the checkout did to the file: sh on the device reads
    # a CR as part of each command and would fail on the first line.
    $ps = Join-AvdPath $s.Platform $cfg.STATE_DIR, 'patch-ramdisk.sh'
    Write-AvdTextFile -Path $ps -Text (Get-AvdOnDevicePatchScript) -Lf
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'push', $ps, "$W/patch-ramdisk.sh") -TimeoutSec 60
    $out = (Invoke-AvdSetupDevice -Command "chmod 755 $W/patch-ramdisk.sh; PREINITDEVICE='$pre' sh $W/patch-ramdisk.sh").Output
    foreach ($l in (Select-AvdLine -Text $out -Last 4)) { Write-Host $l }

    # Stage then rename: `adb pull` truncates and streams into its destination,
    # so an interrupted pull straight onto ramdisk.img leaves an unbootable
    # emulator.
    $new = "$rd.new"
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'pull', "$W/ramdiskpatched.img", $new) -TimeoutSec 300
    if (-not (Test-AvdNonEmptyFile $new)) {
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        Stop-AvdSetup 'the ramdisk patch produced nothing'
    }
    try { [System.IO.File]::Move($new, $rd, $true) }
    catch { Stop-AvdSetup "could not install the patched ramdisk: $($_.Exception.Message)" }
    $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'install', '-r', $apk) -TimeoutSec 300
    # FULL VM restart, not Restart-AvdSetupDevice: no Magisk module exists yet,
    # so emu kill has nothing to lose and its `sync` still flushes the APK
    # install above.
    Restart-AvdSetupEmulator
    $cur = Get-AvdSetupMagiskVersion
    if ($cur) { Write-AvdSetupStep "Magisk active: $cur"; Complete-AvdSetupMagiskEnvironment }
    else { Write-AvdSetupWarning "Magisk not detected after patching -- check $($s.EmuLog)" }
}

# ============================================================================
# Magisk modules from GitHub releases
# ============================================================================

# The Android 17 SELinux addition for Zygisk. APPEND to NeoZygisk's own
# sepolicy.rule, NEVER overwrite it -- its first line declares the zygisk_file
# type, and replacing it makes the socket resolve as `unlabeled`. The one rule
# Android 17 genuinely adds is the magisk-labelled memfd the module .so arrives
# on; without it injection dies at "recv_fds: No control headers received" /
# "dlopen_ext from fd -1". `execute` is part of it: read/write alone gets to fd
# 75 and then fails on "couldn't map segment 1", which looks the same from
# outside. Both copies are written because Magisk only STAGES a module's rules
# at boot and applies them at the NEXT one -- one reboot instead of two.
# Returns whether it changed anything (the caller reboots).
function Add-AvdSetupSepolicyRule {
    if (-not (Test-AvdSetupModule -Id 'zygisksu')) { return $false }
    $mod = '/data/adb/modules/zygisksu/sepolicy.rule'
    $rule = $script:SetupSepolMemfd
    if (Test-AvdOkLine (Invoke-AvdSetupDevice -Command "grep -qF '$rule' $mod 2>/dev/null && echo ok").Output) { return $false }
    $null = Invoke-AvdSetupRootDevice -Command ("echo '$rule' >> $mod`n" +
        "        [ -d /metadata/watchdog/magisk ] && cp $mod /metadata/watchdog/magisk/sepolicy.rule`n" +
        "        chmod 644 $mod /metadata/watchdog/magisk/sepolicy.rule 2>/dev/null`n" +
        '        sync')
    Write-AvdSetupStep 'sepolicy: added the Android 17 memfd rule (reboot to apply)'
    $true
}

function Invoke-AvdSetupModulePhase {
    $s = $script:AvdSetup
    Write-AvdSetupHeading 'Magisk modules'
    $needReboot = $false
    if (-not $s.Check) { if (Add-AvdSetupSepolicyRule) { $needReboot = $true } }
    foreach ($spec in $script:SetupMagiskModules) {
        $repo = $spec.Substring(0, $spec.IndexOf('|'))
        $rest = $spec.Substring($spec.IndexOf('|') + 1)
        $mid = $rest.Substring(0, $rest.IndexOf('|'))
        $rest = $rest.Substring($rest.IndexOf('|') + 1)
        $re = $rest.Substring(0, $rest.IndexOf('|'))
        $note = $rest.Substring($rest.LastIndexOf('|') + 1)

        $tag = Get-AvdReleaseTag (Get-AvdSetupRelease -Repo $repo)
        $have = Get-AvdSetupStamp -Key "mod-$mid"
        $present = Test-AvdSetupModule -Id $mid
        $shown = if ($have) { $have } elseif ($present) { 'present' } else { 'none' }
        Write-AvdSetupStep "${note}: $shown  latest: $(if ($tag) { $tag } else { '?' })"
        if ($s.Check) { continue }
        if ($present -and -not ($tag -and $have -cne $tag)) { continue }

        $url = Get-AvdReleaseAssetUrl (Get-AvdSetupRelease -Repo $repo) $re
        if (-not $url) { Write-AvdSetupWarning "no matching asset for $repo"; continue }
        $zip = Join-AvdPath $s.Platform $s.Config.STATE_DIR, "mod-$mid.zip"
        if (-not (Save-AvdSetupDownload -Path $zip -Uri $url) -or -not (Test-AvdNonEmptyFile $zip)) { Write-AvdSetupWarning "download failed: $repo"; continue }
        if (-not (Test-AvdSetupAsset -Key "mod-$mid" -Tag $tag -Path $zip)) { Write-AvdSetupWarning "not flashing $mid"; continue }
        $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'push', $zip, "/data/local/tmp/mod-$mid.zip") -TimeoutSec 300
        Complete-AvdSetupMagiskEnvironment
        foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --install-module /data/local/tmp/mod-$mid.zip").Output -Last 3)) { Write-Host $l }
        $null = Set-AvdSetupStamp -Key "mod-$mid" -Value $tag
        Write-AvdSetupStep "flashed $(if ($tag) { $tag } else { 'latest' })"
        $needReboot = $true
    }

    # Integrity Box, if an earlier run flashed it, stays DISABLED: enabled it
    # kills Play Store and drops the Photos account (see SetupMagiskModules).
    if ((Test-AvdSetupModule -Id 'playintegrityfix') -and -not $s.Check) {
        if (-not (Test-AvdOkLine (Invoke-AvdSetupDevice -Command '[ -f /data/adb/modules/playintegrityfix/disable ] && echo ok').Output)) {
            $null = Invoke-AvdSetupDevice -Command 'touch /data/adb/modules/playintegrityfix/disable'
            Write-AvdSetupWarning 'disabled Integrity Box (its CANARY/api_level=32 profile breaks Play Store and the Photos account)'
            $needReboot = $true
        }
    }

    # Two spoof hooks in one process is not additive, so Pixelify is disabled
    # whenever the stronger GPhotosUnlimited is installed.
    if (Test-AvdSetupModule -Id 'unlimitedphotos') {
        $ls = (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli modules ls").Output
        if ($ls.Contains($script:SetupPixelifyPkg)) {
            $enabled = @((ConvertTo-AvdLf $ls).Split("`n") | Where-Object { $_.Contains($script:SetupPixelifyPkg) -and $_ -match 'enabled' })
            if ($enabled.Count -gt 0 -and -not $s.Check) {
                $null = Invoke-AvdSetupRootDevice -Command "$script:SetupVcli modules disable $script:SetupPixelifyPkg"
                Write-AvdSetupStep 'disabled PixelifyPhotos (superseded by GPhotosUnlimited)'
            }
        }
    }

    if ($needReboot -and -not $s.Check) { Restart-AvdSetupDevice }
}

# ============================================================================
# Play Store
# ============================================================================
# `google_apis` ships NO store: com.android.vending is a LicenseChecker STUB
# that answers the licensing API only, and the real Phonesky exists solely in
# `google_apis_playstore` -- which cannot be run here because it is a `user`
# build with adb root disabled. So the real store is lifted out of Google's
# OWN certified image -- never a third-party APK -- and re-homed as a Magisk
# module:
#   system/product/priv-app/Phonesky/Phonesky.apk   the real store, privileged
#   system/product/app/LicenseChecker/.replace      deletes the stub that would
#                                                   otherwise own the package name
# No permissions overlay is needed: the image's own
# privapp-permissions-google-p.xml already grants com.android.vending its
# privileged permissions. The APK is cached locally and, if SHARED_CACHE_DIR
# resolves, in a synced folder, so only a cold machine pays the extraction
# (2.7 GB image, a throwaway donor emulator, pull, delete both).
#
# This is what makes Google Photos UPDATEABLE -- without it Photos is frozen at
# whatever build the system image shipped.

function Test-AvdSetupPlayStore {
    # The stub is versionCode 1801; the real store is ~85 million.
    $vc = 0L
    [long]::TryParse((Get-AvdSetupVersionCode -Package 'com.android.vending'), [ref]$vc) -and $vc -gt 1000000
}

function Save-AvdSetupPhonesky {
    $s = $script:AvdSetup
    $cfg = $s.Config
    $cache = $s.PhoneskyCache
    $shared = $s.PhoneskyShared
    if (Test-AvdNonEmptyFile $cache) { return $true }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cache)
    # The donor is the certified image of the SAME API level, so the store
    # build matches the system the module re-homes it into.
    $donorApi = if ($s.DonorApi) { $s.DonorApi } else { $s.Api }
    if ($shared -and (Test-AvdNonEmptyFile $shared)) {
        # The shared copy was written by another machine, so it gets the same
        # trust-on-first-use check as a download: on this machine's second run
        # the recorded hash must still match.
        $copied = $false
        try { Copy-Item -LiteralPath $shared -Destination $cache -Force -ErrorAction Stop; $copied = $true }
        catch { Write-Verbose "shared Phonesky: $($_.Exception.Message)" }
        if ($copied -and (Test-AvdSetupAsset -Key 'phonesky' -Tag "api$donorApi" -Path $cache)) {
            Write-AvdSetupStep 'Phonesky from the shared cache'
            return $true
        }
        Write-AvdSetupWarning 'the shared Phonesky copy did not verify -- extracting it again'
        Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
    }
    Write-AvdSetupStep "extracting Phonesky from Google's certified android-$donorApi image (one time, ~2.7 GB)"
    $image = "system-images;android-$donorApi;google_apis_playstore;$($cfg.AVD_ABI)"
    $r = Invoke-AvdSetupSdkManager -ArgumentList @('--install', $image) -TimeoutSec 5400
    if ($r.ExitCode -ne 0) { Write-AvdSetupWarning 'could not download the certified image'; return $false }
    $donor = 'phonesky-donor'
    $donorDir = Join-AvdPath $s.Platform $cfg.AVD_HOME, "$donor.avd"
    $donorIni = Join-AvdPath $s.Platform $cfg.AVD_HOME, "$donor.ini"
    Remove-Item -LiteralPath $donorDir, $donorIni -Recurse -Force -ErrorAction SilentlyContinue
    Assert-AvdSetupJava
    $r = Invoke-AvdProcess -FilePath $s.AvdManager -StdinText "no`n" -TimeoutSec 300 -ArgumentList @(
        '--silent', 'create', 'avd', '-n', $donor, '-k', $image, '-d', $cfg.AVD_DEVICE,
        '--abi', $cfg.AVD_ABI, '-p', $donorDir)
    if ($r.ExitCode -ne 0) { Write-AvdSetupWarning 'could not create the donor emulator'; return $false }
    # Free our own emulator's memory for the donor, and remember to bring it
    # back. It is killed by its RESOLVED serial, and the donor is then found by
    # ITS name rather than by assuming it inherited the port the other one just
    # released.
    $wasRunning = $false
    if (Test-AvdEmulatorRunning -AvdName $cfg.AVD_NAME) {
        $wasRunning = $true
        if ($s.Serial) { $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'emu', 'kill') -TimeoutSec 60 }
        Start-Sleep -Seconds 6
    }
    $null = Start-AvdEmulatorProcess -EmulatorPath $s.Emulator -LogPath $s.EmuLog -SdkRoot $s.SdkRoot `
        -ArgumentList @('-avd', $donor, '-no-snapshot', '-no-boot-anim', '-no-window', '-gpu', 'swiftshader_indirect')
    Start-Sleep -Seconds 25
    $null = Invoke-AvdAdb -ArgumentList @('start-server') -TimeoutSec 60
    $dser = $null
    $ok = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $dser = Get-AvdEmulatorSerial -AvdName $donor
        if ($dser) { break }
        Start-Sleep -Seconds 3
    } while ($sw.Elapsed.TotalSeconds -lt $s.DonorWaitSec)
    if (-not $dser) {
        Write-AvdSetupWarning 'the donor emulator never attached -- no Phonesky this run'
    } else {
        Write-AvdSetupStep "donor: $dser"
        while ($sw.Elapsed.TotalSeconds -lt $s.DonorWaitSec) {
            if ((Invoke-AvdSetupDevice -Command 'getprop sys.boot_completed' -Serial $dser).Output.Trim() -ceq '1') { $ok = $true; break }
            Start-Sleep -Seconds 3
        }
    }
    if ($ok) {
        # Staged, as the ramdisk is: a pull cut off by its bound must not leave
        # a truncated APK under the name the next run's `[ -s ]` accepts.
        $part = "$cache.part-$PID"
        $r = Invoke-AvdAdb -ArgumentList @('-s', $dser, 'pull', '/product/priv-app/Phonesky/Phonesky.apk', $part) -TimeoutSec 300
        if ($r.ExitCode -eq 0 -and (Test-AvdNonEmptyFile $part)) { [System.IO.File]::Move($part, $cache, $true) }
        else { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
    if ($dser) { $null = Invoke-AvdAdb -ArgumentList @('-s', $dser, 'emu', 'kill') -TimeoutSec 60 }
    Start-Sleep -Seconds 6
    Stop-AvdEmulatorProcess -AvdName $donor
    Remove-Item -LiteralPath $donorDir, $donorIni -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-AvdPath $s.Platform $s.SdkRoot, 'system-images', "android-$donorApi", 'google_apis_playstore') -Recurse -Force -ErrorAction SilentlyContinue
    if ($wasRunning) { Start-AvdSetupEmulator }
    if (Test-AvdNonEmptyFile $cache) {
        Write-AvdSetupStep "extracted Phonesky ($([math]::Floor((Get-Item -LiteralPath $cache).Length / 1048576)) MB)"
        # RECORD, never refuse, on a LOCAL extraction. These bytes came out of
        # Google's own certified image on this machine a moment ago, so they
        # are the most trustworthy copy available; a mismatch here means the
        # recorded hash came from a shared cache that disagrees, and the right
        # answer is to keep what was just extracted and say so. The
        # shared-cache path above is the opposite case -- another machine's
        # file -- and there a mismatch is fatal.
        if (-not (Test-AvdSetupAsset -Key 'phonesky' -Tag "api$donorApi" -Path $cache)) {
            Write-AvdSetupWarning 'keeping the freshly extracted Phonesky despite that (a local extraction outranks a cached hash)'
        }
        if ($shared) {
            try {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $shared) -ErrorAction Stop
                Copy-Item -LiteralPath $cache -Destination $shared -Force -ErrorAction Stop
                Write-AvdSetupStep "cached to $($cfg.SHARED_CACHE_DIR) for the next machine"
            } catch { Write-Verbose "shared cache: $($_.Exception.Message)" }
        }
        return $true
    }
    Write-AvdSetupWarning 'Phonesky extraction failed'
    $false
}

function Invoke-AvdSetupPlayStorePhase {
    $s = $script:AvdSetup
    Write-AvdSetupHeading 'Play Store'
    if (Test-AvdSetupPlayStore) {
        Write-AvdSetupStep "real Play Store present (versionCode $(Get-AvdSetupVersionCode -Package 'com.android.vending'))"
        return $true
    }
    Write-AvdSetupStep "only the LicenseChecker stub is present (versionCode $(Get-AvdSetupVersionCode -Package 'com.android.vending'))"
    if ($s.Check) { Write-AvdSetupWarning 'Play Store not installed'; return $true }
    if (-not (Save-AvdSetupPhonesky)) { return $false }
    $r = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'push', $s.PhoneskyCache, '/data/local/tmp/Phonesky.apk') -TimeoutSec 300
    if ($r.ExitCode -ne 0) { Write-AvdSetupWarning 'could not push Phonesky'; return $false }
    Complete-AvdSetupMagiskEnvironment
    $module = @'

M=/data/adb/modules/phonesky
rm -rf $M; mkdir -p $M/system/product/priv-app/Phonesky $M/system/product/app/LicenseChecker
cat > $M/module.prop <<EOF
id=phonesky
name=Google Play Store (Phonesky)
version=from google_apis_playstore
versionCode=1
author=avd-photos-setup
description=Real Play Store for the google_apis image, which ships only a LicenseChecker stub.
EOF
cp /data/local/tmp/Phonesky.apk $M/system/product/priv-app/Phonesky/Phonesky.apk
chmod 644 $M/system/product/priv-app/Phonesky/Phonesky.apk
touch $M/system/product/app/LicenseChecker/.replace
find $M -type d -exec chmod 755 {} \;

'@
    $null = Invoke-AvdSetupRootDevice -Command $module
    $null = Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --restorecon"
    Write-AvdSetupStep 'module staged; rebooting'
    Restart-AvdSetupDevice
    if (Test-AvdSetupPlayStore) {
        Write-AvdSetupStep "Play Store active (versionCode $(Get-AvdSetupVersionCode -Package 'com.android.vending'))"
        return $true
    }
    Write-AvdSetupWarning 'Play Store did not take -- check /data/adb/modules/phonesky'
    $false
}

# ============================================================================
# 4. Zygisk + the spoof + Photos, each tracked against latest
# ============================================================================

function Invoke-AvdSetupPhotosPhase {
    Write-AvdSetupHeading 'Google Photos'
    # Nothing to install: google_apis images ship Photos as a SYSTEM app at
    # /product/app/Photos. A future image dropping it is a real finding, not
    # something to paper over by sideloading from an untrusted mirror.
    #
    # BUT the system build is NOT what stays running. Once Phonesky is in, Play
    # Store AUTO-UPDATES Photos over it into /data/app and `dumpsys package`
    # lists both (the active one first, the image build under "Hidden system
    # packages"). A /data/app codePath is the pipeline working, and it is the
    # ONLY thing that modernises the Photos UI; the spoof and the
    # unlimited-backup perk both survive it. Get-AvdSetupVersionCode takes the
    # first match, so it reports the ACTIVE build.
    $code = Get-AvdSetupVersionCode -Package $script:SetupGphotosPkg
    if ($code) {
        Write-AvdSetupStep "present (active versionCode $code; Play Store may update it over the image build)"
    } else {
        Write-AvdSetupWarning 'Google Photos is NOT present in this image. google_apis is supposed to'
        Write-AvdSetupWarning "ship it at /product/app/Photos -- check AVD_TAG=$($script:AvdSetup.Config.AVD_TAG) is right."
    }
}

function Invoke-AvdSetupZygiskPhase {
    # MAGISK'S BUILT-IN ZYGISK CANNOT INJECT ON ANDROID 17 -- use NeoZygisk.
    # Getting it wrong cost a whole failed migration, and it is visible as a 3x
    # zygote restart loop at every boot rather than as an injection error.
    # NeoZygisk REPLACES the built-in implementation, so Magisk's own `zygisk`
    # flag must be turned OFF or the two contend.
    $s = $script:AvdSetup
    Write-AvdSetupHeading 'Zygisk (NeoZygisk)'
    $rel = Get-AvdSetupRelease -Repo $script:SetupNeoZygiskRepo
    $ntag = Get-AvdReleaseTag $rel
    $nhave = Get-AvdSetupStamp -Key 'neozygisk'
    $installed = Test-AvdSetupNeoZygisk
    $latestText = if ($ntag) { $ntag } else { '?' }
    if ($installed) { Write-AvdSetupStep "installed: $(if ($nhave) { $nhave } else { 'present' })  latest: $latestText" }
    else { Write-AvdSetupStep "not installed  latest: $latestText" }
    if (-not $s.Check -and (-not $installed -or ($ntag -and $nhave -cne $ntag))) {
        $nu = Get-AvdReleaseAssetUrl (Get-AvdSetupRelease -Repo $script:SetupNeoZygiskRepo) 'release\.zip$'
        $zip = Join-AvdPath $s.Platform $s.Config.STATE_DIR, 'neozygisk.zip'
        if ($nu -and (Save-AvdSetupDownload -Path $zip -Uri $nu) -and (Test-AvdNonEmptyFile $zip) -and
            (Test-AvdSetupAsset -Key 'neozygisk' -Tag $ntag -Path $zip)) {
            $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'push', $zip, '/data/local/tmp/neozygisk.zip') -TimeoutSec 300
            Complete-AvdSetupMagiskEnvironment
            foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --install-module /data/local/tmp/neozygisk.zip").Output -Last 3)) { Write-Host $l }
            $null = Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --sqlite `"REPLACE INTO settings (key,value) VALUES('zygisk',0)`""
            $null = Set-AvdSetupStamp -Key 'neozygisk' -Value $ntag
            Write-AvdSetupStep "flashed $(if ($ntag) { $ntag } else { 'latest' }); built-in Zygisk disabled"
            Restart-AvdSetupDevice
        } else { Write-AvdSetupWarning 'could not fetch the NeoZygisk module zip' }
    }
    if (Test-AvdSetupZygisk) { Write-AvdSetupStep 'zygiskd running' }
    elseif ($s.Check) { Write-AvdSetupWarning 'zygiskd not running' }
    else { Write-AvdSetupWarning 'zygiskd not running -- the spoof cannot inject; re-run after a reboot' }
}

# ============================================================================
# Vector + Pixelify: the ALTERNATIVE spoof path, OFF by default
# ============================================================================
# Two ways exist to make Photos see a Pixel, and running both is worse than
# either: they hook the same process and the second wins unpredictably.
# AVD_SPOOF=module (default) is GPhotosUnlimited, verified working with SELinux
# ENFORCING; AVD_SPOOF=vector is Vector + PixelifyPhotos, a framework, a daemon
# and an APK that needs its own boot before vector-cli answers. Vector is kept
# as the fallback if a Photos build ever stops honouring the module.
function Invoke-AvdSetupVectorPhase {
    $s = $script:AvdSetup
    $cfg = $s.Config
    if ($cfg.AVD_SPOOF -cne 'vector') {
        Write-AvdSetupHeading 'Vector / Pixelify'
        Write-AvdSetupStep "skipped (AVD_SPOOF=$($cfg.AVD_SPOOF)); GPhotosUnlimited is the active spoof"
        return
    }
    Write-AvdSetupHeading 'Vector (Xposed framework)'
    $vtag = Get-AvdReleaseTag (Get-AvdSetupRelease -Repo $script:SetupVectorRepo)
    $vhave = Get-AvdSetupStamp -Key 'vector'
    $vpresent = (Invoke-AvdSetupDevice -Command 'ls /data/adb/modules/zygisk_vector >/dev/null 2>&1 && echo yes').Output.Contains('yes')
    Write-AvdSetupStep "installed: $(if ($vhave) { $vhave } elseif ($vpresent) { 'present' } else { 'none' })  latest: $(if ($vtag) { $vtag } else { '?' })"
    if (-not $s.Check -and (-not $vpresent -or ($vtag -and $vhave -cne $vtag))) {
        # Vector ships a FLASHABLE MAGISK MODULE zip (module.prop /
        # customize.sh / update-binary), NOT an APK -- flash it, never
        # unzip-and-install it.
        $vu = Get-AvdReleaseAssetUrl (Get-AvdSetupRelease -Repo $script:SetupVectorRepo) 'Release.*\.zip$'
        $zip = Join-AvdPath $s.Platform $cfg.STATE_DIR, 'vector.zip'
        if ($vu -and (Save-AvdSetupDownload -Path $zip -Uri $vu) -and (Test-AvdNonEmptyFile $zip) -and
            (Test-AvdSetupAsset -Key 'vector' -Tag $vtag -Path $zip)) {
            $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'push', $zip, '/data/local/tmp/vector.zip') -TimeoutSec 300
            Complete-AvdSetupMagiskEnvironment
            foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupMagisk --install-module /data/local/tmp/vector.zip").Output -Last 4)) { Write-Host $l }
            $null = Set-AvdSetupStamp -Key 'vector' -Value $vtag
            Write-AvdSetupStep "flashed $vtag"
            Restart-AvdSetupDevice
        } else { Write-AvdSetupWarning 'could not fetch the Vector module zip' }
    }

    Write-AvdSetupHeading 'PixelifyPhotos'
    $ptag = Get-AvdReleaseTag (Get-AvdSetupRelease -Repo $script:SetupPixelifyRepo)
    $phave = Get-AvdSetupStamp -Key 'pixelify'
    $pinst = Test-AvdSetupPackage -Package $script:SetupPixelifyPkg
    Write-AvdSetupStep "installed: $(if ($phave) { $phave } elseif ($pinst) { 'present' } else { 'none' })  latest: $(if ($ptag) { $ptag } else { '?' })"
    if (-not $s.Check -and (-not $pinst -or ($ptag -and $phave -cne $ptag))) {
        $pu = Get-AvdReleaseAssetUrl (Get-AvdSetupRelease -Repo $script:SetupPixelifyRepo) '\.apk$'
        $apk = Join-AvdPath $s.Platform $cfg.STATE_DIR, 'pixelify.apk'
        if ($pu -and (Save-AvdSetupDownload -Path $apk -Uri $pu) -and
            (Test-AvdSetupAsset -Key 'pixelify' -Tag $ptag -Path $apk) -and
            (Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'install', '-r', '-g', $apk) -TimeoutSec 300).ExitCode -eq 0) {
            $null = Set-AvdSetupStamp -Key 'pixelify' -Value $ptag
            Write-AvdSetupStep "installed $ptag"
        } else { Write-AvdSetupWarning 'Pixelify install failed' }
    }

    Write-AvdSetupHeading 'Scope Pixelify to Google Photos'
    # Vector is configured through its OWN cli: `modules ls`, not `list`.
    if ((Invoke-AvdSetupRootDevice -Command "$script:SetupVcli status").Output.Contains('Framework Version')) {
        if (-not $s.Check) {
            foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli modules enable $script:SetupPixelifyPkg").Output -Last 2)) { Write-Host $l }
            foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli scope set $script:SetupPixelifyPkg $script:SetupGphotosPkg/0").Output -Last 1)) { Write-Host $l }
        }
        foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli scope ls $script:SetupPixelifyPkg").Output -First 4)) { Write-Host "    $l" }
    } else { Write-AvdSetupWarning 'vector-cli not responding -- the framework needs one boot after flashing; re-run' }
}

# ============================================================================
# Summary, the done marker, the epilogue
# ============================================================================

function Write-AvdSetupSummary {
    $s = $script:AvdSetup
    Write-AvdSetupHeading 'Summary'
    if (Test-AvdSetupZygisk) { Write-AvdSetupStep 'Zygisk: ON' } else { Write-AvdSetupWarning 'Zygisk: not confirmed' }
    $selinux = (Invoke-AvdSetupDevice -Command 'getenforce').Output.TrimEnd("`n")
    if ($selinux -ceq 'Enforcing') { Write-AvdSetupStep 'SELinux: Enforcing (sepolicy rule, not a global downgrade)' }
    else { Write-AvdSetupWarning "SELinux: $selinux" }
    if ($s.Config.AVD_SPOOF -ceq 'vector') {
        foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli status").Output -First 5)) { Write-Host "    $l" }
        if (Test-AvdSetupPackage -Package $script:SetupPixelifyPkg) { Write-AvdSetupStep 'Pixelify: installed' } else { Write-AvdSetupWarning 'Pixelify: missing' }
    } else {
        if (Test-AvdSetupModule -Id 'unlimitedphotos') { Write-AvdSetupStep 'Spoof: GPhotosUnlimited (Magisk module)' }
        else { Write-AvdSetupWarning 'Spoof: GPhotosUnlimited MISSING' }
    }
    if (Test-AvdSetupPackage -Package $script:SetupGphotosPkg) { Write-AvdSetupStep 'Google Photos: installed' }
    else { Write-AvdSetupWarning 'Google Photos: NOT installed' }
}

function Complete-AvdSetupRun {
    $s = $script:AvdSetup
    $cfg = $s.Config
    # Seed the config on first run. Never overwrite an edited one.
    if (-not (Test-Path -LiteralPath $cfg.CONFIG_FILE -PathType Leaf)) {
        try {
            Write-AvdDefaultConfig -Path $cfg.CONFIG_FILE -Platform $s.Platform
            Write-AvdSetupStep "seeded $($cfg.CONFIG_FILE) -- set ICLOUD_USERNAME before arming"
        } catch { Write-Verbose "config seed: $($_.Exception.Message)" }
    }
    # THE DONE MARKER, written only here: every phase ran, the last one (Play
    # Store) succeeded, and the emulator is rooted with its spoof in place. A
    # run that died earlier leaves no marker, so the login bootstrap resumes it.
    if ($s.PlaystoreOk -and (Get-AvdSetupMagiskVersion) -and (Test-Path -LiteralPath $s.ConfigIni -PathType Leaf)) {
        Write-AvdTextFile -Path $s.SetupDone -Text "$(Get-AvdEpoch)`n"
    } else {
        Remove-Item -LiteralPath $s.SetupDone -Force -ErrorAction SilentlyContinue
        Write-AvdSetupWarning 'setup did not complete -- the next login (or another run) resumes it'
    }
    Write-AvdSetupEpilogue
}

# The macOS epilogue's text with the Windows command names. The check-in line
# names adb by its full path: the pipeline's platform-tools is on this
# process's PATH, not necessarily on the terminal's.
function Write-AvdSetupEpilogue {
    $s = $script:AvdSetup
    $acct = if ($s.Config.GOOGLE_ACCOUNT) { $s.Config.GOOGLE_ACCOUNT } else { 'the Google account you will sign in with' }
    $devid = Get-AvdSetupGsfDeviceId
    $adb = Get-AvdAdbPath
    $adbCmd = if ($adb) { "& '$adb'" } else { 'adb' }
    $ser = if ($s.Serial) { $s.Serial } else { '<serial>' }
    $text = @"

Next: open Google Photos in the emulator, sign in as $acct, Backup ON
(Original quality), and check it presents as a Pixel. Then arm the sync with
'avd-photos-arm'.

SIGN-IN NEEDS A ONE-TIME DEVICE REGISTRATION. This image is userdebug/dev-keys,
so Google treats it as an uncertified device and refuses account sign-in until
the device id below is registered. Register it ONCE, as $acct, then reboot the
emulator and wait a few minutes:

    device id:  $(if ($devid) { $devid } else { '<unknown - boot the emulator and re-run>' })
    register:   https://www.google.com/android/uncertified/

If sign-in still fails afterwards, force a fresh check-in and try again:
    $adbCmd -s $ser shell am broadcast -a android.server.checkin.CHECKIN

The login page only renders under software GL: use 'avd-signin', not 'avd-start'.
"@
    foreach ($l in (ConvertTo-AvdLf $text).Split("`n")) { Write-Host $l }
}

# ============================================================================
# -Start / -Stop: just run the emulator, no setup work
# ============================================================================
# So nobody hand-types an `emulator -avd ...` line and gets the GPU flag wrong
# (the failure is silent). Start-AvdSetupEmulator owns the flags; these modes
# reuse it. SELinux stays ENFORCING -- the one rule Zygisk needs comes from
# Add-AvdSetupSepolicyRule, not from a global downgrade.

function Invoke-AvdSetupStart {
    $s = $script:AvdSetup
    Write-AvdSetupHeading 'Start'
    if (-not (Test-Path -LiteralPath $s.ConfigIni -PathType Leaf)) { Stop-AvdSetup "no $($s.Config.AVD_NAME) emulator yet -- run avd-photos-setup first" }
    Start-AvdSetupEmulator
    Write-AvdSetupStep "ready: $($s.Serial)"
    if ($s.Config.AVD_SPOOF -ceq 'vector') {
        foreach ($l in (Select-AvdLine -Text (Invoke-AvdSetupRootDevice -Command "$script:SetupVcli status").Output -First 3)) { Write-Host "    $l" }
    }
}

# The macOS stop path runs `adb -s "$SER"` before anything has resolved $SER,
# so it addresses whatever single device is attached. Here the serial is
# resolved by name first; when no emulator answers to the name, the process is
# stopped instead (the macOS script's own last resort).
function Invoke-AvdSetupStop {
    $s = $script:AvdSetup
    $name = $s.Config.AVD_NAME
    Write-AvdSetupHeading 'Stop'
    if (-not (Test-AvdEmulatorRunning -AvdName $name)) { Write-AvdSetupStep 'not running'; return }
    $ser = Get-AvdEmulatorSerial -AvdName $name
    if ($ser) {
        $s.Serial = $ser
        $null = Invoke-AvdSetupDevice -Command 'sync'
        $null = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'emu', 'kill') -TimeoutSec 30
        $n = 0
        while ($n -lt $s.StopWaitTries -and (Test-AvdEmulatorRunning -AvdName $name)) { Start-Sleep -Seconds 2; $n++ }
    } else {
        Write-AvdSetupWarning "no adb serial answers to the name $name -- stopping its process instead"
    }
    if (Test-AvdEmulatorRunning -AvdName $name) { Stop-AvdEmulatorProcess -AvdName $name; Start-Sleep -Seconds 2 }
    if (Test-AvdEmulatorRunning -AvdName $name) { Write-AvdSetupWarning 'still running' } else { Write-AvdSetupStep 'stopped' }
}

function Invoke-AvdSetupFull {
    $s = $script:AvdSetup
    Invoke-AvdSetupSdkPhase
    Invoke-AvdSetupAvdPhase
    Invoke-AvdSetupRootPhase
    Invoke-AvdSetupZygiskPhase
    Invoke-AvdSetupModulePhase
    Invoke-AvdSetupVectorPhase
    Invoke-AvdSetupPhotosPhase
    $s.PlaystoreOk = (Invoke-AvdSetupPlayStorePhase | Select-Object -Last 1) -eq $true
    Write-AvdSetupSummary
    if (-not $s.Check) { Complete-AvdSetupRun }
}

# Shut down an emulator WE started. The weekly headless run otherwise leaves a
# 6 GB qemu resident until reboot. An emulator that was already running
# belongs to the user and is left alone, -Start exists precisely to LEAVE the
# emulator running, and an empty serial means nothing was ever resolved.
function Invoke-AvdSetupCleanup {
    $s = $script:AvdSetup
    if ($s.EmuStartedByUs -and $s.Headless -and -not $s.StartOnly -and $s.Serial) {
        try {
            $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'shell', 'sync') -TimeoutSec 30
            $null = Invoke-AvdAdb -ArgumentList @('-s', $s.Serial, 'emu', 'kill') -TimeoutSec 30
        } catch { Write-Verbose "cleanup: $($_.Exception.Message)" }
    }
}

# The entry point: the whole of bin/avd-photos-setup's top level. Returns the
# process exit code (0, or 1 after an ERROR); a busy lock is 0, as on macOS,
# because the other run is doing the work.
function Invoke-AvdSetup {
    [CmdletBinding()]
    param(
        [ValidateSet('Full', 'Check', 'Start', 'Stop', 'Bootstrap')][string]$Mode = 'Full',
        [switch]$Headless,
        # A config from Get-AvdConfig; read from the environment when omitted.
        $Config,
        # Where DEV_TIMEOUT, BOOT_WAIT, AVD_RECREATE, AVD_REROOT,
        # PLAYSTORE_DONOR_API and JAVA_HOME are read (environment-only knobs,
        # as on macOS). This process's environment when omitted.
        [System.Collections.IDictionary]$Environment
    )
    if ($null -eq $Environment) { $Environment = Get-AvdEnvironment }
    if ($null -eq $Config) { $Config = Get-AvdConfig -Environment $Environment }
    $s = Initialize-AvdSetupState -Config $Config -Environment $Environment -Mode $Mode -Headless:$Headless

    # FRESH-MACHINE BOOTSTRAP: runs at login so a new machine builds the whole
    # rooted stack unattended. It MUST be a no-op once setup has COMPLETED --
    # the full path boots an emulator and downloads several GB -- and an
    # interrupted build must resume at the next login, which is why the marker
    # is the last phase's, not the emulator directory's.
    if ($Mode -eq 'Bootstrap') {
        if (Test-Path -LiteralPath $s.SetupDone -PathType Leaf) { return 0 }
        $s.Headless = $true   # nobody asked for a window at login
    }

    Add-AvdToolPath -Directory @((Join-AvdPath $s.Platform $s.SdkRoot, 'platform-tools'))
    # Fatal: stamps\ holds the release tags AND the hashes each tag must keep
    # producing, so a run that cannot write it cannot verify anything it flashes.
    try { $null = New-Item -ItemType Directory -Force -Path $s.Stamps -ErrorAction Stop }
    catch { Write-Host "ERROR: cannot create $($s.Stamps)" -ForegroundColor Red; return 1 }

    # SINGLE INSTANCE. The weekly task can fire while a manual run is
    # mid-flight, and two concurrent root phases race on ramdisk.img, its
    # backup, `adb root` and the config.ini rewrite -- i.e. they can leave an
    # unbootable emulator.
    $lock = Enter-AvdLock -Path $s.Lock
    if ($lock.Status -eq 'busy') {
        Write-Host "another avd-photos-setup is running (pid $(if ($lock.OwnerId) { $lock.OwnerId } else { '?' })) -- exiting"
        return 0
    }
    if ($lock.Status -ne 'held') { Write-Host "cannot take lock $($s.Lock)" -ForegroundColor Red; return 1 }

    $rc = 0
    try {
        Initialize-AvdLog -Path $s.Log
        if ($Config.PSObject.Properties['WARNINGS']) { foreach ($w in @($Config.WARNINGS)) { if ($w) { Write-AvdSetupWarning $w } } }
        Assert-AvdSetupPath
        switch ($s.Mode) {
            'Stop' { $null = Invoke-AvdSetupStop }
            'Start' { $null = Invoke-AvdSetupStart }
            default { $null = Invoke-AvdSetupFull }
        }
    } catch {
        $rc = 1
        if (-not $_.Exception.Data.Contains('AvdSetupDie')) {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Add-AvdSetupLog "   ERROR $($_.Exception.Message)"
            Add-AvdSetupLog "   $(($_.ScriptStackTrace -split "`n") -join ' <- ')"
        }
    } finally {
        Invoke-AvdSetupCleanup
        Exit-AvdLock -Path $s.Lock
    }
    $rc
}
