# The sync job, ported from bin/avd-photos-sync: pull new iCloud photos and
# hand them to Google Photos in the (Pixel-spoofed) rooted tablet emulator,
# which backs them up. Run every 15 minutes and at login by the sync scheduled
# task, and from the tray's "Check iCloud now". Dormant until the arming
# sentinel exists (avd-photos-arm).
#
# Flow: icloudpd -> staging -> push into DCIM/Camera -> media rescan -> Photos
# backup -> each dedup_key appears in Photos' own remote_media -> the emulator
# copy is pruned -> the CONFIRMED items leave iCloud.
#
# THIS IS THE STEP THAT DELETES PHOTOGRAPHS, so it is a port, not a rewrite:
# the same steps in the same order, the same log lines, the same phase strings
# (an interface: the tray parses them), the same SQL, the same gates. Where
# Windows forces a difference the comment says so; windows/DESIGN.md has the
# decisions in one place.
#
# WHY A LEDGER AND NOT A MODIFIED-SINCE CHECK: icloudpd stamps each file with the
# PHOTO's creation date, not the download time, so "what changed in the last
# two days" skips almost the whole library while the job looks healthy. Keyed
# on the path relative to staging, with '/' separators on every platform, so a
# re-download, a staging move or a ledger carried between machines does not
# confuse it.

# Media only; the same list as the macOS grep -iE.
$script:AvdMediaPattern = [regex]::new('\.(jpg|jpeg|png|heic|heif|gif|webp|mp4|mov|m4v|3gp)$',
    [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
$script:AvdGphotosPkg = 'com.google.android.apps.photos'
# gphotos0.db is the SIGNED-IN account's (0 = backup_prefs_account_id);
# gphotos-1.db beside it is the signed-out placeholder, same tables all EMPTY,
# so "the first gphotos*.db" reads zero.
$script:AvdPhotosDb = '/data/data/com.google.android.apps.photos/databases/gphotos0.db'
# A cloud-provider placeholder (Google Drive streaming, OneDrive Files
# On-Demand): FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, _RECALL_ON_OPEN, _OFFLINE.
$script:AvdPlaceholderBits = 0x00400000 -bor 0x00040000 -bor 0x1000

# -- Pure helpers (tested one by one in Sync.Tests.ps1) -------------------------

# Is this file a cloud placeholder? The Windows form of the macOS `dataless`
# stub, and the same rule (lib/fs.sh): READING one is not safe -- the provider
# hydrates it on the read, which can block with no timeout (measured on macOS
# 2026-08-25: `head -c 1` on an evicted 1.95 GB file, zero progress, no
# error) -- so the test is METADATA ONLY, and the file mirrors on a later run.
function Test-AvdCloudPlaceholder {
    param([Parameter(Mandatory)][long]$Attributes)
    ($Attributes -band $script:AvdPlaceholderBits) -ne 0
}

# Staged path for a device file name (rel_of_devname): the YYYY_MM_name device
# naming reverses directly; any other name reverses through the ledger,
# matched on the whole basename.
#
# THE FALLBACK ANSWERS ONLY WHEN THE MATCH IS UNIQUE. iCloud basenames repeat
# across months (IMG_0001.HEIC exists in many years), so a first-match lookup
# could hand the reclaim step a DIFFERENT photo's staged path than the one
# Google Photos confirmed. Returning nothing instead means that device file
# maps to no staged path, so its original simply stays in iCloud -- the safe
# direction, and the only one available without more evidence. (The awk it
# ports compares the last length(name)+1 characters of each ledger line with
# "/" name, which is an ordinal EndsWith, and counts lines, not distinct ones.)
function Get-AvdRelOfDevname {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][string[]]$Ledger = @())
    if ($Name -cmatch '^[0-9]{4}_[0-9]{2}_.') {
        return $Name.Substring(0, 4) + '/' + $Name.Substring(5, 2) + '/' + $Name.Substring(8)
    }
    $suffix = '/' + $Name
    $n = 0
    $hit = $null
    foreach ($l in $Ledger) {
        if ($l.EndsWith($suffix, [System.StringComparison]::Ordinal)) { $n++; $hit = $l }
    }
    if ($n -eq 1) { return $hit }
    $null
}

# The SQL IN list of every file on the device, as Photos stores its path:
# '<dev_dir>/<name>', single quotes doubled, comma-joined; '' for none, so the
# query stays valid and matches nothing.
function ConvertTo-AvdSqlInList {
    param([Parameter(Mandatory)][string]$DeviceDir, [AllowEmptyCollection()][string[]]$Name = @())
    $parts = foreach ($n in $Name) {
        if ($n.Length -gt 0) { "'" + ($DeviceDir + '/' + $n).Replace("'", "''") + "'" }
    }
    $parts = @($parts)
    if ($parts.Count -eq 0) { return "''" }
    $parts -join ','
}

# The verify queries, verbatim from bin/avd-photos-sync (Sync.Tests.ps1 fails
# if the two ever differ). UPLOADED = the local row's dedup_key in
# remote_media, scoped to in_camera_folder=1 AND to the files on the device by
# path; each of those three was a false UPLOAD CONFIRMED once
# (first_backup_timestamp is stamped at QUEUE time; an unscoped count never
# converges; rows outlive a prune). COUNT DISTINCT FILES, NOT JOIN ROWS: one
# dedup_key matches several remote_media rows (7,393 keys are shared on the
# author's account), and count(*) reported 1,894 uploaded for 1,393 files on
# the device -- a false UPLOAD CONFIRMED 11 s after a 1,000 push.
function Get-AvdPhotoQuery {
    param([Parameter(Mandatory)][string]$InList)
    [pscustomobject]@{
        Up    = "select count(distinct l.filepath) from local_media l join remote_media r on l.dedup_key=r.dedup_key where l.in_camera_folder=1 and l.filepath in ($InList);"
        Tot   = "select count(distinct filepath) from local_media where in_camera_folder=1 and filepath in ($InList);"
        Fail  = "select count(distinct filepath) from local_media where has_upload_permanently_failed=1 and in_camera_folder=1 and filepath in ($InList);"
        Reg   = "select filepath from local_media where in_camera_folder=1 and filepath in ($InList);"
        Prune = "select distinct l.filepath from local_media l join remote_media r on l.dedup_key=r.dedup_key where l.in_camera_folder=1 and l.filepath in ($InList);"
    }
}

# The device paths `stat -c '%s %n'` reports as 0 bytes (the macOS awk
# '$1 == "0" { sub(/^0[ \t]+/, ""); if (length($0)) print }').
function ConvertFrom-AvdEmptyStat {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $out = foreach ($l in (ConvertTo-AvdLf $Text).Split("`n")) {
        $first = ($l.Trim(" `t".ToCharArray()) -split '[ \t]+', 2)[0]
        if ($first -cne '0') { continue }
        $m = [regex]::Match($l, '^0[ \t]+(.*)$')
        $rest = if ($m.Success) { $m.Groups[1].Value } else { $l }
        if ($rest.Length -gt 0) { $rest }
    }
    , ([string[]]@($out))
}

# `tr -dc '0-9'`: every digit of a command's output, '' when there is none.
function ConvertTo-AvdDigit {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $Text -replace '[^0-9]', ''
}

# A count read from a command's output, 0 when it printed none (${x:-0}).
function ConvertTo-AvdCount {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    ConvertTo-AvdInt -Value (ConvertTo-AvdDigit $Text) -Default 0
}

# What an icloudpd exit means (step 1). DISTINGUISH "no new items" FROM "the
# binary is broken": a plain non-zero exit is routine, a crash is not, and
# treating them alike is how the macOS pipeline once stayed a silent no-op for
# days (a packaged icloudpd that aborted on every invocation while `command -v`
# still found it). macOS reads a crash as death by signal (rc >= 128); on
# Windows a crash is a NEGATIVE exit code, the NTSTATUS of the fault
# (-1073741819 = 0xC0000005, an access violation; -1 = a frozen-app bootloader
# that could not start its script).
#   ok       0
#   crash    negative; Code is the NTSTATUS in hex
#   notexec  127, the process runner's "could not be started"
#   auth     no saved session: the markers in the last 40 lines of THIS run's
#            output (with the keyring as the only password provider, a missing
#            session ends in 'None of providers gave password'; the other two
#            are the console-prompt failures macOS matches)
#   other    anything else, often just "no new items" or a transient error
function Get-AvdIcloudpdOutcome {
    param([Parameter(Mandatory)][int]$ExitCode, [AllowEmptyCollection()][string[]]$Tail = @())
    if ($ExitCode -eq 0) { return [pscustomobject]@{ Kind = 'ok'; Code = '0' } }
    if ($ExitCode -lt 0) {
        $u = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($ExitCode), 0)
        return [pscustomobject]@{ Kind = 'crash'; Code = ('0x{0:X8}' -f $u) }
    }
    if ($ExitCode -eq 127) { return [pscustomobject]@{ Kind = 'notexec'; Code = '127' } }
    foreach ($l in $Tail) {
        if ($l -match 'None of providers gave password|EOFError|ask_password_in_console') {
            return [pscustomobject]@{ Kind = 'auth'; Code = "$ExitCode" }
        }
    }
    [pscustomobject]@{ Kind = 'other'; Code = "$ExitCode" }
}

# The staging tree's files, raw: the seam a test replaces to play a refused
# directory. NOT the default options: those skip Hidden and System files, which
# `find -type f` does not, and IgnoreInaccessible must be off so a refused
# directory is an error rather than a silently shorter list (the macOS
# incident: "new since last run: 0" over 2,689 files because every directory
# was refused and the error went nowhere).
function Get-AvdStagingFileEntry {
    param([Parameter(Mandatory)][string]$Root)
    $opt = [System.IO.EnumerationOptions]::new()
    $opt.RecurseSubdirectories = $true
    $opt.IgnoreInaccessible = $false
    $opt.AttributesToSkip = [System.IO.FileAttributes]0
    $list = [System.Collections.Generic.List[string]]::new([System.IO.Directory]::EnumerateFiles($Root, '*', $opt))
    , $list.ToArray()
}

# The staging tree's media, as sorted paths RELATIVE to staging with '/'
# separators (enumerate_staging). Returns Files, Error (the first error's
# message, or $null) and AccessDenied. On an error the list is not trusted at
# all, as the macOS caller treats a find that complained.
#
# STRIP THE PREFIX BY LENGTH, NEVER BY PATTERN: a staging path may contain
# brackets ("[05] Backups" did), which in a pattern are a CHARACTER CLASS, so
# on macOS the prefix never matched, the push target became
# "$STAGING/$STAGING/..." and every push failed. Treat this path as hostile.
function Get-AvdStagingList {
    param([Parameter(Mandatory)][string]$Staging)
    try {
        $all = Get-AvdStagingFileEntry -Root $Staging
    } catch {
        $e = $_.Exception
        $found = $null
        for ($x = $e; $null -ne $x; $x = $x.InnerException) {
            if ($x -is [System.UnauthorizedAccessException] -or $x -is [System.IO.IOException] -or
                $x -is [System.Security.SecurityException]) { $found = $x; break }
        }
        if ($null -eq $found) { $found = $e }
        return [pscustomobject]@{
            Files        = [string[]]@()
            Error        = $found.Message
            AccessDenied = ($found -is [System.UnauthorizedAccessException] -or $found -is [System.Security.SecurityException])
        }
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $rels = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $all) {
        if (-not $f.StartsWith($Staging, [System.StringComparison]::Ordinal)) { continue }
        $n = $Staging.Length
        if ($n -lt $f.Length -and ($f[$n] -eq $sep -or $f[$n] -eq '/')) { $n++ }
        $rel = $f.Substring($n)
        if ($sep -ne '/') { $rel = $rel.Replace($sep, '/') }
        if ($rel.Length -gt 0 -and $script:AvdMediaPattern.IsMatch($rel)) { $rels.Add($rel) }
    }
    [pscustomobject]@{ Files = (Get-AvdSortedUnique -Line $rels.ToArray()); Error = $null; AccessDenied = $false }
}

# Does the staging root list anything (the macOS `ls "$STAGING"`)? Dotfiles do
# not count, as `ls` does not show them, and neither do Hidden or System
# entries: Explorer writes desktop.ini and Thumbs.db into picture folders, and
# on Windows one of those beside an empty tree would make every listing
# "suspect" and fail the run after six retries.
function Test-AvdStagingHasEntry {
    param([Parameter(Mandatory)][string]$Staging)
    $skip = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Staging).EnumerateFileSystemInfos()) {
            if ($e.Name.StartsWith('.')) { continue }
            if (($e.Attributes -band $skip) -ne 0) { continue }
            return $true
        }
    } catch {
        Write-Verbose "staging root unreadable: $($_.Exception.Message)"
    }
    $false
}

# A command on PATH, as `command -v` answers it, or $null.
function Get-AvdCommandPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not $Name) { return $null }
    $c = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $null
}

# Every line of a file another process may still be writing (icloudpd's
# output, the sync log): read with write and delete sharing, CRs dropped.
function Read-AvdSharedLine {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , [string[]]@() }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $sr = [System.IO.StreamReader]::new($fs, $script:Utf8NoBom, $true)
            $text = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch {
        return , [string[]]@()
    }
    $lines = [System.Collections.Generic.List[string]]::new((ConvertTo-AvdLf $text).Split("`n"))
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    , $lines.ToArray()
}

# Copy what a writer that has EXITED left after -Offset, including a last line
# without its newline (which Copy-AvdNewByte holds back for a live writer),
# and end it with one.
function Copy-AvdRemainingByte {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [long]$Offset = 0)
    $o = Copy-AvdNewByte -Source $Source -Destination $Destination -Offset $Offset
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    try {
        $fs = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            if ($fs.Length -le $o) { return }
            $null = $fs.Seek($o, [System.IO.SeekOrigin]::Begin)
            $buf = [byte[]]::new($fs.Length - $o)
            $read = 0
            while ($read -lt $buf.Length) {
                $n = $fs.Read($buf, $read, $buf.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Dispose() }
        $ds = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $ds.Write($buf, 0, $read); $ds.WriteByte(10) } finally { $ds.Dispose() }
    } catch {
        Write-Verbose "tail of $Source not copied: $($_.Exception.Message)"
    }
}

# A staged file's metadata -- existence, attributes, size -- and never its
# bytes (reading a placeholder hydrates it). A seam: the tests give one file
# placeholder attributes, which no API sets off Windows.
function Get-AvdLocalFileInfo {
    param([Parameter(Mandatory)][string]$Path)
    $fi = [System.IO.FileInfo]::new($Path)
    if (-not $fi.Exists) { return [pscustomobject]@{ Exists = $false; Attributes = 0L; Length = 0L } }
    [pscustomobject]@{ Exists = $true; Attributes = [long]$fi.Attributes; Length = $fi.Length }
}

function New-AvdTempDirectory {
    param([string]$Prefix = 'avd-sync-')
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    $null = [System.IO.Directory]::CreateDirectory($d)
    $d
}

# -- The run's context, log, phase and failure ---------------------------------

function New-AvdSyncContext {
    param([Parameter(Mandatory)]$Config, [switch]$ReclaimDryRun)
    $state = $Config.STATE_DIR
    $emu = if ($IsWindows) { 'emulator.exe' } else { 'emulator' }
    @{
        Config           = $Config
        Log              = Join-Path $Config.LOG_DIR 'sync.log'
        ReclaimLog       = Join-Path $Config.LOG_DIR 'reclaim.log'
        EmulatorLog      = Join-Path $Config.LOG_DIR 'emulator.log'
        Ledger           = Join-Path $state 'pushed.list'
        # Staged paths Google Photos has confirmed (fed ONLY by the prune step),
        # and the ones already deleted from iCloud or found not to be there.
        ReclaimPending   = Join-Path $state 'reclaim-pending.list'
        Reclaimed        = Join-Path $state 'reclaimed.list'
        # Settings.Secure android_id, regenerated whenever userdata is: the
        # right key for "is this still the device the ledger was written for".
        # A recreated emulator wipes /sdcard while the ledger survives, and the
        # job would report "new since last run: 0" against an empty DCIM.
        DeviceIdFile     = Join-Path $state 'device.id'
        # From the first push of a batch until the prune leaves DCIM empty, so
        # the quiet-tick gate (step 2) does not skip the emulator mid-batch. A
        # run killed between push and verify leaves the ledger full and the old
        # confirmation stamp intact; without this marker that batch would never
        # verify.
        DeviceBusy       = Join-Path $state 'device-busy'
        Confirmed        = Join-Path $state 'last-upload-confirmed'
        UploadStatus     = Join-Path $state 'upload-status'
        Phase            = Join-Path $state 'phase'
        Lock             = Join-Path $state 'sync.lock'
        # icloudpd's own output, truncated per run and mirrored into sync.log.
        IcloudpdOut      = Join-Path $state 'icloudpd.out'
        IcloudpdErr      = Join-Path $state 'icloudpd.err'
        Staging          = [string]$Config.STAGING
        DestDcim         = [string]$Config.DEST_DCIM
        AvdName          = [string]$Config.AVD_NAME
        AvdEmu           = Join-Path $Config.AVD_SDK_ROOT 'emulator' $emu
        AdbTimeout       = [int](Get-AvdConfigInt -Config $Config -Key ADB_TIMEOUT)
        ReclaimTimeout   = [int](Get-AvdConfigInt -Config $Config -Key RECLAIM_TIMEOUT)
        UploadWait       = [long](Get-AvdConfigInt -Config $Config -Key UPLOAD_WAIT)
        PushCap          = [long](Get-AvdConfigInt -Config $Config -Key PUSH_CAP)
        KeepDays         = [long](Get-AvdConfigInt -Config $Config -Key KEEP_ICLOUD_DAYS)
        DeleteFromIcloud = [string]$Config.DELETE_FROM_ICLOUD
        ReclaimDryRun    = [bool]$ReclaimDryRun
        # Resolved by NAME in step 3, never assumed: emulator-5554 is just the
        # first free console port, and any emulator started before this one
        # owns it instead. Empty until then, and nothing before step 3 talks to
        # a device.
        Serial           = ''
        Icloudpd         = $null
        SqlMode          = ''
        HostDb           = $null
        TempDirs         = [System.Collections.Generic.List[string]]::new()
        Outcome          = ''
    }
}

function Write-AvdSyncLog {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-AvdLog -Path $Context.Log -Message $Message
}

# LIVE PHASE FOR THE TRAY: avd-photos-status reads the phase file every tick
# and the tray paints its ring from it, so THE PHASE STRINGS ARE AN INTERFACE.
# A phase that cannot be written (the file held open by an editor) is dropped:
# it must never fail the run that wanted to report it.
function Set-AvdSyncPhase {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        Write-AvdTextFile -Path $Context.Phase -Text "$Text`n"
    } catch {
        try { [System.IO.File]::WriteAllText($Context.Phase, "$Text`n", $script:Utf8NoBom) }
        catch { Write-Verbose "phase not written: $($_.Exception.Message)" }
    }
}

# fail(): the run cannot do its job. Logged as FAILED, left in the phase file
# as "failed: <why>" by the entry point's cleanup, exit 1. Every prerequisite
# that used to skip quietly is one of these: five days of "icloudpd missing"
# skips on macOS were invisible because they were not.
function Stop-AvdSyncRun {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Reason)
    $Context.Outcome = "failed: $Reason"
    Write-AvdSyncLog $Context "FAILED: $Reason"
    throw "avd-photos-sync failed: $Reason"
}

# A device command's output, bounded (dev_out): CRs removed, stderr dropped.
function Get-AvdDeviceOutput {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string[]]$Command)
    (Invoke-AvdAdbShell -Serial $Context.Serial -Command $Command -TimeoutSec $Context.AdbTimeout).Output
}

# -- The on-device per-path loop (device_each) ------------------------------------

# An on-device per-path loop over a list of device paths, $Mode = scan | prune
# | touch, phase "<label> N of M"; $false if any chunk failed. PASS THE LIST AS
# A FILE: a real export is named "Google Photos_ Backup & Edit.PNG", which a
# word-split loop splits on spaces while the bare `&` backgrounds a device
# command. The file goes LF-only and without a BOM, since the device's
# `read -r` would take a CR into every path. 100 per adb call: 500 scan_file
# calls took ~122 s, past the 120 s ADB_TIMEOUT, and 1,000 in one call froze
# the phase line for 12+ minutes.
function Invoke-AvdDeviceEach {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowEmptyCollection()][string[]]$Path = @(),
        [Parameter(Mandatory)][ValidateSet('scan', 'prune', 'touch')][string]$Mode,
        [Parameter(Mandatory)][string]$Label
    )
    $items = @($Path | Where-Object { $_.Length -gt 0 })
    $total = $items.Count
    $body = switch ($Mode) {
        'scan' { 'content call --uri content://media --method scan_file --arg "$f" >/dev/null 2>&1' }
        'prune' { 'rm -f "$f" && content call --uri content://media --method scan_file --arg "$f" >/dev/null 2>&1' }
        'touch' { 'touch "$f" && content call --uri content://media --method scan_file --arg "$f" >/dev/null 2>&1' }
    }
    $loop = 'while IFS= read -r f; do [ -n "$f" ] && { ' + $body + '; }; done < /data/local/tmp/avd-batch; rm -f /data/local/tmp/avd-batch'
    $ok = $true
    $done = 0
    $dir = New-AvdTempDirectory -Prefix 'avd-batch-'
    try {
        for ($i = 0; $i -lt $total; $i += 100) {
            $last = [math]::Min($i + 99, $total - 1)
            $chunk = [string[]]@($items[$i..$last])
            $file = Join-Path $dir ('c.{0:D3}' -f [int][math]::Floor($i / 100))
            Set-AvdLine -Path $file -Line $chunk
            $null = Invoke-AvdAdb -ArgumentList @('-s', $Context.Serial, 'push', $file, '/data/local/tmp/avd-batch') -TimeoutSec $Context.AdbTimeout
            $r = Invoke-AvdAdbShell -Serial $Context.Serial -Command @($loop) -TimeoutSec ($Context.AdbTimeout + 200)
            if ($r.ExitCode -ne 0) { $ok = $false }
            $done += $chunk.Count
            Set-AvdSyncPhase $Context "$Label $done of $total"
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ok
}

# -- The staging listing --------------------------------------------------------

# One listing of the staging tree, its error logged, a refused directory a
# named failure. No TCC and no app bundle on Windows (DESIGN decision 12), so
# the message says nothing about either: an access-denied here is an ACL, a
# cloud client that is not signed in, or a drive that is not mounted.
function Read-AvdStagingTree {
    param([Parameter(Mandatory)][hashtable]$Context)
    $l = Get-AvdStagingList -Staging $Context.Staging
    if ($null -ne $l.Error) {
        Write-AvdSyncLog $Context "  listing: $($l.Error)"
        if ($l.AccessDenied) {
            Stop-AvdSyncRun $Context "no access to the staging directory ($($l.Error)) - see Staging in the README"
        }
    }
    $l
}

# -- Photos' own database (step 5) ------------------------------------------------

# NOT EVERY IMAGE SHIPS sqlite3 (and `su -c sqlite3` then fails to a silent
# empty string): the macOS verifier polled "0 done" for the whole UPLOAD_WAIT
# and failed a working backup. It fails SAFE, but success became unreachable,
# which is as broken. So: the device's sqlite3 when it exists, else the
# ~200 MB database copied to the host and read by sqlite_query.py.
function Initialize-AvdPhotoSql {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ((Get-AvdDeviceOutput $Context @('command -v sqlite3')) -match 'sqlite3') {
        $Context.SqlMode = 'device'
    } else {
        $Context.SqlMode = 'host'
        $d = New-AvdTempDirectory -Prefix 'avd-photos-db-'
        $Context.TempDirs.Add($d)
        $Context.HostDb = Join-Path $d 'photos.db'
        Write-AvdSyncLog $Context 'device has no sqlite3 - verifying uploads by copying the Photos DB to the host'
    }
}

# Run SQL against a host copy of the Photos DB through sqlite_query.py, under
# the uv-managed Python the reclaim uses. The SQL ALWAYS through a file: a
# 1,000-file IN list is ~55,000 characters and a Windows command line stops at
# 32,767 (DESIGN decision 7). Bounded, as every process here is; 300 s covers
# uv fetching its Python on a first use.
function Invoke-AvdHostSql {
    param([Parameter(Mandatory)][string]$DbPath, [Parameter(Mandatory)][string]$Sql, [int]$TimeoutSec = 300)
    $uv = Get-AvdCommandPath 'uv'
    if (-not $uv) { return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = 'uv not found on PATH' } }
    $helper = Join-Path $script:AvdLibDir 'sqlite_query.py'
    $dir = New-AvdTempDirectory -Prefix 'avd-sql-'
    $q = Join-Path $dir 'query.sql'
    try {
        Write-AvdTextFile -Path $q -Text "$Sql`n"
        Invoke-AvdProcess -FilePath $uv -ArgumentList @('run', '--no-project', '-q', '--python', '3.13', $helper, $DbPath, $q) -TimeoutSec $TimeoutSec
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# COPY ALL THREE FILES IN ONE SHOT (photos_sql_refresh): the db is in WAL mode
# and Photos writes to it continuously, so pulling the .db and the -wal in
# separate adb calls captures them seconds apart and sqlite rejects the pair as
# "database disk image is malformed" -- a silent false negative on the check
# that gates iCloud deletion. Still possible under load, hence the retry rather
# than a count. $true once the host copy answers a trivial query.
function Update-AvdPhotoDbCopy {
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context.SqlMode -ne 'host') { return $true }
    $db = $script:AvdPhotosDb
    $hostDb = $Context.HostDb
    $t = $Context.AdbTimeout
    for ($i = 0; $i -lt 3; $i++) {
        $null = Invoke-AvdAdbShell -Serial $Context.Serial -TimeoutSec $t -Command @(
            'su', '-c', "cp $db $db-wal $db-shm /sdcard/ 2>/dev/null; chmod 644 /sdcard/gphotos0.db*")
        foreach ($s in '', '-wal', '-shm') { Remove-Item -LiteralPath "$hostDb$s" -Force -ErrorAction SilentlyContinue }
        foreach ($s in '', '-wal', '-shm') {
            $null = Invoke-AvdAdb -ArgumentList @('-s', $Context.Serial, 'pull', "/sdcard/gphotos0.db$s", "$hostDb$s") -TimeoutSec $t
        }
        # DELETE THE STAGING COPY, whether or not the pull worked: /sdcard is
        # the only place the shell user can read the DB from, this runs every
        # poll, and the file is ~230 MB (a 233 MB orphan sat on the emulator
        # disk for a day).
        $null = Invoke-AvdAdbShell -Serial $Context.Serial -TimeoutSec $t -Command @(
            'rm', '-f', '/sdcard/gphotos0.db', '/sdcard/gphotos0.db-wal', '/sdcard/gphotos0.db-shm')
        # A trivial query proves the snapshot is coherent before its counts
        # are trusted.
        if ((Test-AvdNonEmptyFile -Path $hostDb) -and
            (Invoke-AvdHostSql -DbPath $hostDb -Sql 'select count(*) from local_media;').ExitCode -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    Write-AvdSyncLog $Context '  could not get a coherent copy of the Photos DB (retried 3x)'
    $false
}

# One query's output (photos_sql). On the device: through a pushed file, not
# the command line, since the IN list of every device path is tens of KB,
# which no nested su/sh quoting survives. On the host: nothing when there is
# no copy, and stderr dropped, as the macOS `2>/dev/null`.
function Invoke-AvdPhotoSql {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Sql)
    if ($Context.SqlMode -eq 'device') {
        $dir = New-AvdTempDirectory -Prefix 'avd-query-'
        try {
            $q = Join-Path $dir 'query.sql'
            Write-AvdTextFile -Path $q -Text "$Sql`n"
            $null = Invoke-AvdAdb -ArgumentList @('-s', $Context.Serial, 'push', $q, '/data/local/tmp/avd-query.sql') -TimeoutSec $Context.AdbTimeout
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return (Get-AvdDeviceOutput $Context @("su -c 'sqlite3 $($script:AvdPhotosDb) < /data/local/tmp/avd-query.sql' 2>/dev/null"))
    }
    if (-not $Context.HostDb -or -not (Test-AvdNonEmptyFile -Path $Context.HostDb)) { return '' }
    ((Invoke-AvdHostSql -DbPath $Context.HostDb -Sql $Sql).StdOut -replace "`r", '')
}

# -- The iCloud reclaim -------------------------------------------------------------

# The one place the reclaim's process starts, so the tests can replace it:
# `uv run -q --no-project --python 3.13 --with <spec> <script> <args>`.
# stdout is the stats JSON; stderr is the per-file log.
function Invoke-AvdReclaimProcess {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSec = 1800
    )
    $uv = Get-AvdCommandPath 'uv'
    if (-not $uv) { return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = "uv not found on PATH`n" } }
    Invoke-AvdProcess -FilePath $uv -TimeoutSec $TimeoutSec -ArgumentList (
        @('run', '-q', '--no-project', '--python', '3.13', '--with', $Spec, $Script) + $ArgumentList)
}

# A field of the reclaim's stats JSON, or $null.
function Get-AvdStatField {
    param($Stats, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Stats) { return $null }
    $p = $Stats.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

# iCloud reclaim (step 6, and the quiet-tick path in step 2):
# bin/avd-photos-reclaim.py -- the file macOS runs, unchanged -- on icloudpd's
# own library, pinned to the installed tool's version and sharing its
# ~/.pyicloud session. Exit 2 = no valid session, nothing deleted; the pending
# list survives a failure and drains next run. A small "walked" count is a
# small library, not a broken walk.
function Invoke-AvdReclaim {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    $dry = $c.ReclaimDryRun
    # THE GATE, in ONE place, because this is the step that deletes
    # photographs: nothing leaves iCloud unless the last verify pass confirmed
    # its whole batch cleanly. The stamp is written only by that pass and
    # DELETED by a pass that could not confirm, so a pipeline that breaks stops
    # reclaiming on the very next run -- including a run that finds a pending
    # list left over from a healthier one, which is exactly the case this check
    # exists for. A dry run deletes nothing and is allowed without it.
    if (-not $dry -and -not (Test-Path -LiteralPath $c.Confirmed -PathType Leaf)) {
        Write-AvdSyncLog $c "iCloud reclaim SKIPPED: the last verify did not confirm its batch, so nothing is deleted ($(Measure-AvdLine -Path $c.ReclaimPending) confirmed file(s) stay pending)"
        return
    }
    # A dry run creates nothing, not even an empty ledger.
    if (-not $dry -and -not (Test-Path -LiteralPath $c.Reclaimed)) { Add-AvdLine -Path $c.Reclaimed -Line @() }
    $rlog = $c.ReclaimLog
    Initialize-AvdLog -Path $rlog
    $reclaimedNow = Get-AvdSortedUnique -Line (Read-AvdLine -Path $c.Reclaimed)
    $pend = Get-AvdLineDifference -Line (Get-AvdSortedUnique -Line (Read-AvdLine -Path $c.ReclaimPending)) -Exclude $reclaimedNow
    $n = $pend.Count
    if ($n -eq 0) {
        if ($dry) { Write-AvdSyncLog $c 'nothing pending: no confirmed file is waiting to leave iCloud' }
        return
    }
    $py = Get-AvdReclaimScript
    if (-not $py) {
        Write-AvdSyncLog $c "WARNING: avd-photos-reclaim.py not found - $n confirmed file(s) stay in iCloud"
        return
    }
    # THE LIBRARY, NOT THE TOOL: a `uv tool` icloudpd is a self-contained
    # binary with nothing importable in it, so the reclaim runs against the
    # source of the SAME version, which shares the tool's session unchanged.
    $ver = Get-AvdIcloudpdVersion -Text (Invoke-AvdProcess -FilePath $c.Icloudpd -ArgumentList @('--version') -TimeoutSec 300).StdOut
    if (-not $ver) {
        Write-AvdSyncLog $c "WARNING: cannot read icloudpd's version - reclaim skipped, $n file(s) stay in iCloud"
        return
    }
    $spec = Get-AvdIcloudpdSpec -Version $ver
    Set-AvdSyncPhase $c "reclaiming iCloud space: $n confirmed file(s)"
    $dir = New-AvdTempDirectory -Prefix 'avd-reclaim-'
    try {
        $pendFile = Join-Path $dir 'pending'
        $outFile = Join-Path $dir 'out'
        Set-AvdLine -Path $pendFile -Line $pend
        Add-AvdLine -Path $outFile -Line @()
        # BUILD THE FLAGS FROM THE VALUES. On macOS `${RECLAIM_DRY_RUN:+--dry-run}`
        # expanded whenever the variable was NON-EMPTY, and its default was the
        # string "0" -- so every real reclaim ran as a dry run while the code
        # below still consumed its output, recording photos as reclaimed that
        # were never deleted and never retrying them.
        $rargs = [System.Collections.Generic.List[string]]::new()
        foreach ($a in @('--username', $c.Config.ICLOUD_USERNAME, '--staging', $c.Staging, '--pending', $pendFile, '--out', $outFile)) { $rargs.Add([string]$a) }
        # 0 and empty both mean "no floor"; anything else is a day count.
        if ($c.KeepDays -ne 0) { $rargs.Add('--keep-days'); $rargs.Add([string]$c.KeepDays) }
        if ($dry) { $rargs.Add('--dry-run') }
        if ($dry) { Write-AvdSyncLog $c "iCloud reclaim (DRY RUN): $n confirmed file(s) pending (icloudpd library $ver)" }
        else { Write-AvdSyncLog $c "iCloud reclaim: $n confirmed file(s) pending (icloudpd library $ver)" }
        $r = Invoke-AvdReclaimProcess -Spec $spec -Script $py -ArgumentList $rargs.ToArray() -TimeoutSec $c.ReclaimTimeout
        $rc = [int]$r.ExitCode
        if ($r.StdErr) {
            $e = ConvertTo-AvdLf $r.StdErr
            if (-not $e.EndsWith("`n")) { $e += "`n" }
            try { [System.IO.File]::AppendAllText($rlog, $e, $script:Utf8NoBom) }
            catch { Write-AvdSyncLog $c "  reclaim.log not written: $($_.Exception.Message)" }
        }
        $statsText = ConvertTo-AvdLf ([string]$r.StdOut)
        $statsFlat = $statsText.Replace("`n", '')
        $stats = $null
        try { $stats = $statsText | ConvertFrom-Json -ErrorAction Stop } catch { $stats = $null }
        # A DRY RUN CHANGES NO LEDGER, decided TWICE: by the flag this run
        # passed, and by what the reclaim itself reports in its stats.
        # Consuming a dry run's output is the worst failure this pipeline has
        # -- those paths would be recorded as reclaimed, dropped from the
        # pending list, and never deleted from iCloud or looked at again -- so
        # it is worth two independent reasons to refuse.
        $saidDryValue = Get-AvdStatField -Stats $stats -Name 'dry_run'
        $saidDry = ($saidDryValue -is [bool] -and $saidDryValue) -or ($saidDryValue -is [string] -and $saidDryValue -eq 'true')
        if ($dry -or $saidDry) {
            Write-AvdSyncLog $c "iCloud reclaim (DRY RUN) rc=${rc}: $statsFlat"
            Write-AvdSyncLog $c "  nothing was deleted and no ledger changed - see $rlog for the per-file decisions"
            if (-not $dry) { Write-AvdSyncLog $c 'WARNING: that run reported dry_run without being asked to - nothing was recorded' }
            return
        }
        switch ($rc) {
            { $_ -eq 0 -or $_ -eq 1 } {
                $before = Read-AvdLine -Path $c.Reclaimed
                $got = Read-AvdLine -Path $outFile
                $merged = Get-AvdSortedUnique -Line (@($before) + @($got))
                Set-AvdLine -Path $c.Reclaimed -Line $merged
                # Resolved paths leave the pending list; held and kept ones stay
                # for next time.
                $left = Get-AvdLineDifference -Line (Get-AvdSortedUnique -Line (Read-AvdLine -Path $c.ReclaimPending)) -Exclude $merged
                Set-AvdLine -Path $c.ReclaimPending -Line $left
                Write-AvdSyncLog $c "iCloud reclaim: $statsFlat; $(Measure-AvdLine -Path $c.ReclaimPending) still pending"
                $deleted = Get-AvdStatField -Stats $stats -Name 'deleted'
                $notFound = Get-AvdStatField -Stats $stats -Name 'not_found'
                if ($null -ne $stats -and ("$(if ($deleted) { $deleted } else { 0 })" -eq '0') -and
                    ("$(if ($notFound) { $notFound } else { 0 })" -ne '0')) {
                    Write-AvdSyncLog $c "WARNING: none of the pending file(s) was found in iCloud - already gone, or the staged-path rebuild no longer matches (see $rlog)"
                }
                if ($rc -eq 1) { Write-AvdSyncLog $c "WARNING: some iCloud deletions failed - see $rlog" }
                break
            }
            2 { Write-AvdSyncLog $c "WARNING: iCloud reclaim could not authenticate - icloudpd needs its one-time interactive login; $n file(s) stay in iCloud"; break }
            { $_ -eq 124 -or $_ -eq 137 } { Write-AvdSyncLog $c "WARNING: iCloud reclaim timed out after $($c.ReclaimTimeout)s - $n file(s) stay in iCloud"; break }
            default { Write-AvdSyncLog $c "WARNING: iCloud reclaim exited $rc - see $rlog; $n file(s) stay in iCloud" }
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -- Step 1: icloudpd ---------------------------------------------------------------

# FIRST, BEFORE THE EMULATOR: the incremental pass IS the check for new photos,
# about a minute against a saved session. --log-level info, not the default
# debug: at 96 passes a day the fifty "already exists" DEBUG lines per pass
# would be most of the log, while "Downloaded" and errors are INFO.
function Invoke-AvdIcloudpdStep {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    $cfg = $c.Config
    try { $null = [System.IO.Directory]::CreateDirectory($c.Staging) }
    catch { Stop-AvdSyncRun $c "cannot mkdir staging $($c.Staging)" }
    # NEVER --delete-after-download: it removed each item from iCloud the moment
    # its bytes landed in staging, hours before Google Photos had it, gated only
    # on SOME earlier run having confirmed uploads. Step 6 offloads per file,
    # after confirmation, and nothing else ever leaves iCloud.
    #
    # --password-provider keyring, which macOS does not pass (DESIGN decision
    # 5): on macOS a job with no saved session fails fast because getpass()
    # falls back to stdin, which is empty. On Windows getpass() reads the
    # CONSOLE through msvcrt and ignores stdin (icloudpd v1.32.3,
    # base.py:ask_password_in_console), so the same job would block forever
    # holding the sync lock -- the macOS 10-minute hang, unbounded. With only
    # the keyring provider a missing session ends in "None of providers gave
    # password" within seconds, and the interactive login stores the password
    # in Windows Credential Manager, so an expired session can still
    # re-authenticate unattended.
    $a = @('--username', $cfg.ICLOUD_USERNAME, '--directory', $c.Staging,
        '--until-found', [string](Get-AvdConfigInt -Config $cfg -Key UNTIL_FOUND),
        '--recent', [string](Get-AvdConfigInt -Config $cfg -Key RECENT),
        '--folder-structure', '{:%Y/%m}', '--no-progress-bar', '--log-level', 'info',
        '--password-provider', 'keyring')
    if ($c.DeleteFromIcloud -eq '1') {
        if ($c.KeepDays -eq 0) { Write-AvdSyncLog $c 'iCloud reclaim ON: confirmed uploads are deleted from iCloud after verification' }
        else { Write-AvdSyncLog $c "iCloud reclaim ON: confirmed uploads are deleted from iCloud after verification (keeping the newest $($c.KeepDays) day(s))" }
    } else {
        Write-AvdSyncLog $c "iCloud reclaim OFF (DELETE_FROM_ICLOUD=0 in $($cfg.CONFIG_FILE)): confirmed uploads stay in iCloud"
    }
    # PROGRESS: one "Downloaded <path>" line per new original. stdout and
    # stderr go to files (a pipe would be held open by any grandchild), every 5
    # s their new bytes are copied into sync.log so the log is live, and the
    # Downloaded lines of THIS run are counted from them.
    Set-AvdSyncPhase $c 'downloading from iCloud'
    foreach ($f in $c.IcloudpdOut, $c.IcloudpdErr) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $p = $null
    try {
        $p = Start-AvdProcess -FilePath $c.Icloudpd -ArgumentList $a -StdoutPath $c.IcloudpdOut -StderrPath $c.IcloudpdErr
    } catch {
        Write-AvdSyncLog $c "  icloudpd did not start: $($_.Exception.Message)"
    }
    $rc = 127
    if ($null -ne $p) {
        $oo = 0L; $eo = 0L
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 5
            $oo = Copy-AvdNewByte -Source $c.IcloudpdOut -Destination $c.Log -Offset $oo
            $eo = Copy-AvdNewByte -Source $c.IcloudpdErr -Destination $c.Log -Offset $eo
            # Assigned first: a list function returns ONE array object, and
            # @(F) would nest it rather than flatten it.
            $outLines = Read-AvdSharedLine -Path $c.IcloudpdOut
            $errLines = Read-AvdSharedLine -Path $c.IcloudpdErr
            $nDl = @(@($outLines) + @($errLines) | Where-Object { $_ -match ' INFO +Downloaded ' }).Count
            if ($nDl -gt 0) { Set-AvdSyncPhase $c "downloading from iCloud: $nDl new so far" }
        }
        $p.WaitForExit()
        $rc = [int]$p.ExitCode
        Copy-AvdRemainingByte -Source $c.IcloudpdOut -Destination $c.Log -Offset $oo
        Copy-AvdRemainingByte -Source $c.IcloudpdErr -Destination $c.Log -Offset $eo
    }
    $outLines = Read-AvdSharedLine -Path $c.IcloudpdOut
    $errLines = Read-AvdSharedLine -Path $c.IcloudpdErr
    $tail = @($outLines | Select-Object -Last 40) + @($errLines | Select-Object -Last 40)
    $o = Get-AvdIcloudpdOutcome -ExitCode $rc -Tail $tail
    switch ($o.Kind) {
        'ok' { Write-AvdSyncLog $c 'icloudpd ok' }
        'crash' {
            Write-AvdSyncLog $c 'a broken icloudpd build aborts on every invocation; reinstall it (uv tool install icloudpd).'
            Stop-AvdSyncRun $c "icloudpd crashed ($($o.Code)) - the binary is broken, not the account"
        }
        'notexec' { Stop-AvdSyncRun $c 'icloudpd not executable (127)' }
        'auth' {
            Write-AvdSyncLog $c 'icloudpd has NO SAVED SESSION - it needs a one-time interactive login:'
            Write-AvdSyncLog $c "    icloudpd --username $($cfg.ICLOUD_USERNAME) --directory `"$($c.Staging)`" --recent 1"
            Write-AvdSyncLog $c '  continuing with whatever is already staged'
        }
        default { Write-AvdSyncLog $c "icloudpd rc=$rc (often just 'no new items' or needs re-auth) - continuing" }
    }
}

# -- Step 2: anything for the emulator? ------------------------------------------------

# A 15-minute tick must not boot a headless Android VM to learn there is
# nothing to push. This ONE listing is trusted only when it reported no error
# and is at least as large as the ledger; anything else falls through to step
# 4, which lists twice and names a refused directory. The ledger's device check
# needs adb, so a recreated emulator is noticed by the first run that boots.
# $true when the run is done.
function Test-AvdQuietTick {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    if ((Test-AvdEmulatorRunning -AvdName $c.AvdName) -or -not (Test-Path -LiteralPath $c.Confirmed -PathType Leaf) -or
        (Test-Path -LiteralPath $c.DeviceBusy)) { return $false }
    if (-not (Test-Path -LiteralPath $c.Ledger)) { Add-AvdLine -Path $c.Ledger -Line @() }
    $q = Read-AvdStagingTree $c
    $nQuick = if ($null -ne $q.Error) { -1 } else { $q.Files.Count }
    $ledger = Read-AvdLine -Path $c.Ledger
    if ($nQuick -gt 0 -and $nQuick -ge $ledger.Count -and
        (Get-AvdLineDifference -Line $q.Files -Exclude (Get-AvdSortedUnique -Line $ledger)).Count -eq 0) {
        Write-AvdSyncLog $c "nothing new: $nQuick staged, all pushed and confirmed - the emulator stays off"
        if ($c.DeleteFromIcloud -eq '1' -and (Test-AvdNonEmptyFile -Path $c.ReclaimPending)) { $null = Invoke-AvdReclaim $c }
        Write-AvdSyncLog $c 'done (0 pushed this run)'
        return $true
    }
    $false
}

# -- Step 3: the emulator, headless, found by name --------------------------------------

function Start-AvdSyncEmulator {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    $cfg = $c.Config
    if (-not (Test-AvdEmulatorRunning -AvdName $c.AvdName)) {
        if (-not (Test-Path -LiteralPath $c.AvdEmu -PathType Leaf)) { Stop-AvdSyncRun $c "emulator binary missing at $($c.AvdEmu)" }
        Write-AvdSyncLog $c "starting $($c.AvdName) (headless)"
        Set-AvdSyncPhase $c 'booting the emulator'
        # Detached and window-less (Core's Start-AvdEmulatorProcess): an
        # emulator attached to the task's console would keep the task
        # "running" and every later tick would be skipped as a duplicate.
        $null = Start-AvdEmulatorProcess -EmulatorPath $c.AvdEmu -LogPath $c.EmulatorLog -SdkRoot $cfg.AVD_SDK_ROOT -ArgumentList @(
            '-avd', $c.AvdName, '-no-snapshot', '-no-boot-anim', '-no-window', '-gpu', [string]$cfg.AVD_GPU)
        Start-Sleep -Seconds 8
    }
    $null = Invoke-AvdAdb -ArgumentList @('start-server') -TimeoutSec 60
    Set-AvdSyncPhase $c 'waiting for the emulator to boot'
    # WHICH DEVICE IS OURS. Ask every attached emulator its AVD name and take
    # the one that answers with ours. A second emulator on this machine -- an
    # app developer's, a CI job's -- owns 5554 whenever it started first, and
    # every push, query, prune and `emu kill` below would have gone to it.
    for ($i = 0; $i -lt 40; $i++) {
        $c.Serial = [string](Get-AvdEmulatorSerial -AvdName $c.AvdName)
        if ($c.Serial) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $c.Serial) { Stop-AvdSyncRun $c "no attached emulator answers to the name $($c.AvdName)" }
    $booted = $false
    for ($i = 0; $i -lt 90; $i++) {
        if ((Get-AvdDeviceOutput $c @('getprop', 'sys.boot_completed')).TrimEnd("`n") -eq '1') { $booted = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $booted) { Stop-AvdSyncRun $c 'the emulator did not boot within 4.5 min' }
    # Assert it again now that it is up: the resolution above raced a booting
    # VM, and everything after this line writes to the device.
    $nameNow = Get-AvdNameOfSerial -Serial $c.Serial
    if ($nameNow -ne $c.AvdName) {
        Stop-AvdSyncRun $c "$($c.Serial) is running '$(if ($nameNow) { $nameNow } else { 'unknown' })', not $($c.AvdName) - refusing to touch it"
    }
    Write-AvdSyncLog $c "emulator up ($($c.Serial) is $($c.AvdName))"
}

# -- Step 4: push everything the ledger has not seen, then rescan ------------------------

# Returns the number of files pushed this run.
function Invoke-AvdPushStep {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    $ser = $c.Serial
    $dcim = $c.DestDcim
    $null = Invoke-AvdAdbShell -Serial $ser -Command @("mkdir -p $dcim") -TimeoutSec $c.AdbTimeout

    # NEVER TRUST ONE LISTING OF THE STAGING TREE, AND NEVER SWALLOW ITS ERROR.
    # Measured 2026-09-06 on macOS against a cloud-provider mount: "new since
    # last run: 0" over 2,689 files, because every directory of the mount was
    # refused and the error went to a stderr aimed at /dev/null. Two listings
    # that agree, report no error, are not empty while the directory has
    # entries, and are not smaller than the ledger.
    if (-not (Test-Path -LiteralPath $c.Ledger)) { Add-AvdLine -Path $c.Ledger -Line @() }
    $nLedger = Measure-AvdLine -Path $c.Ledger
    Set-AvdSyncPhase $c 'listing the staging tree'
    $attempt = 0; $prev = -2; $nCand = -1
    $cand = [string[]]@()
    while ($true) {
        $attempt++
        $l = Read-AvdStagingTree $c
        if ($null -ne $l.Error) { $nCand = -1; $cand = [string[]]@() } else { $cand = $l.Files; $nCand = $cand.Count }
        $suspect = $false
        if ($nCand -lt 0) { $suspect = $true }
        if ($nCand -eq 0 -and (Test-AvdStagingHasEntry -Staging $c.Staging)) { $suspect = $true }
        if ($nCand -ge 0 -and $nCand -lt $nLedger) { $suspect = $true }
        if (-not $suspect -and $nCand -eq $prev) { break }
        if ($attempt -ge 6) {
            if ($nCand -le 0) { Stop-AvdSyncRun $c "staging tree unreadable: $attempt listings of $($c.Staging) found nothing" }
            Write-AvdSyncLog $c "WARNING: staging lists $nCand media file(s), fewer than the $nLedger in the ledger - proceeding"
            break
        }
        if ($suspect) {
            Write-AvdSyncLog $c "  staging listing suspect (attempt ${attempt}: $nCand file(s), ledger $nLedger) - retrying in 20 s"
            Start-Sleep -Seconds 20
        }
        $prev = $nCand
    }

    # Invalidate the ledger if this is not the device it was written for.
    $curDev = (Get-AvdDeviceOutput $c @('settings', 'get', 'secure', 'android_id')) -replace "[`r`n]", ''
    if ($curDev -eq '' -or $curDev -eq 'null' -or $curDev.StartsWith('Exception')) { $curDev = '' }
    if ($curDev) {
        $prevDev = ''
        if (Test-Path -LiteralPath $c.DeviceIdFile -PathType Leaf) {
            $prevDev = ([System.IO.File]::ReadAllText($c.DeviceIdFile, $script:Utf8NoBom)).TrimEnd("`r", "`n")
        }
        if ($prevDev -and $prevDev -ne $curDev) {
            Write-AvdSyncLog $c "new device detected (android_id $prevDev -> $curDev) - resetting ledger; everything will be re-pushed"
            Set-AvdLine -Path $c.Ledger -Line @()
        }
        Write-AvdTextFile -Path $c.DeviceIdFile -Text "$curDev`n"
    }
    $newf = Get-AvdLineDifference -Line $cand -Exclude (Get-AvdSortedUnique -Line (Read-AvdLine -Path $c.Ledger))
    $totalNew = $newf.Count

    $pushed = 0; $failed = 0; $evicted = 0; $empty = 0
    $pushedPaths = [System.Collections.Generic.List[string]]::new()
    $toPush = [math]::Min([long]$totalNew, $c.PushCap)
    if ($toPush -gt 0) {
        if (-not (Test-Path -LiteralPath $c.DeviceBusy)) { Add-AvdLine -Path $c.DeviceBusy -Line @() }
        Set-AvdSyncPhase $c "pushing 0 of $toPush to the emulator"
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($rel in $newf) {
        if ($rel.Length -eq 0) { continue }
        if ($pushed -ge $c.PushCap) { break }
        $local = [System.IO.Path]::Join($c.Staging, $rel.Replace('/', $sep))
        $fi = Get-AvdLocalFileInfo -Path $local
        $size = $fi.Length
        # A placeholder can BLOCK when read, so test METADATA only and skip; it
        # mirrors on a later run.
        if (Test-AvdCloudPlaceholder -Attributes $fi.Attributes) { $evicted++; continue }
        # A 0-byte staged file (a download left truncated) is never pushed: a
        # 0-byte push would pass the size check below and loop through the
        # empty-device sweep every run. Delete it from staging to fetch it again.
        if ($size -eq 0) {
            $empty++
            Write-AvdSyncLog $c "  empty staged file skipped (delete it to let icloudpd fetch it again): $rel"
            continue
        }
        # ONE DEVICE NAME PER STAGED PATH: DCIM/Camera is flat and iCloud names
        # repeat across months, so a bare-basename push overwrote the earlier
        # file before Photos had it. "/" -> "_" (2026/05/IMG_2885.HEIC ->
        # 2026_05_IMG_2885.HEIC).
        $devname = $rel.Replace('/', '_')
        $devPath = "$dcim/$devname"
        $r = Invoke-AvdAdb -ArgumentList @('-s', $ser, 'push', $local, $devPath) -TimeoutSec $c.AdbTimeout
        if ($r.ExitCode -eq 0) {
            # CHECK THE SIZE THAT LANDED. `adb push` reported success for three
            # files on 2026-09-07 while writing them EMPTY (a cloud fault-in
            # racing the read is the likely cause), the ledger recorded them as
            # pushed, and Photos can register but never upload an empty HEIC --
            # so every later run burned the full UPLOAD_WAIT on "0 of 3
            # confirmed" and the device-busy marker never cleared. A mismatch
            # is a failed push: drop the device copy and leave the path OUT of
            # the ledger so the next run sends it again.
            $srcSz = (Get-AvdLocalFileInfo -Path $local).Length
            $devSz = ConvertTo-AvdDigit (Get-AvdDeviceOutput $c @("stat -c %s $(ConvertTo-AvdShellQuoted $devPath) 2>/dev/null"))
            if ($srcSz -gt 0 -and $devSz -ne '' -and $devSz -eq "$srcSz") {
                Add-AvdLine -Path $c.Ledger -Line @($rel)
                $pushed++
                $pushedPaths.Add($devPath)
                if ($pushed % 25 -eq 0) { Set-AvdSyncPhase $c "pushing $pushed of $toPush to the emulator" }
            } else {
                Write-AvdSyncLog $c "WARNING: short push, not recorded: $rel (staged $srcSz bytes, on device $(if ($devSz) { $devSz } else { '?' }))"
                $null = Invoke-AvdAdbShell -Serial $ser -Command @('rm', '-f', (ConvertTo-AvdShellQuoted $devPath)) -TimeoutSec $c.AdbTimeout
                $failed++
            }
        } else {
            $failed++
            # adb.exe opens the local file with the classic Win32 path limit
            # unless Windows long paths are enabled AND the program opts in, so
            # a staged path of 260+ characters can fail here while every
            # PowerShell step before it worked.
            if ($IsWindows -and $local.Length -ge 260) {
                Write-AvdSyncLog $c "WARNING: adb push failed for a $($local.Length)-character path ($rel): adb.exe may not open paths past 260 characters - set a shorter STAGING, or enable long paths (LongPathsEnabled=1 under HKLM\SYSTEM\CurrentControlSet\Control\FileSystem)"
            }
        }
    }

    Write-AvdSyncLog $c "staged $nCand media file(s), ledger $nLedger; new since last run: $totalNew; pushed $pushed (cap $($c.PushCap)), failed $failed, evicted-skipped $evicted, empty-skipped $empty"
    if ($totalNew -gt $pushed) { Write-AvdSyncLog $c "$($totalNew - $pushed) left for the next run" }

    if ($pushed -gt 0) {
        # INDEX VIA content call scan_file. On Android 17 the two obvious
        # commands are useless: `cmd media rescan --dir` and `cmd media scan`
        # fail with "cmd: Can't find service: media", and the legacy
        # MEDIA_MOUNTED broadcast RETURNS SUCCESS while indexing nothing.
        if (Invoke-AvdDeviceEach $c $pushedPaths.ToArray() scan 'indexing in MediaStore:') {
            Write-AvdSyncLog $c "media scan requested for $pushed file(s)"
        } else {
            Write-AvdSyncLog $c 'WARNING: media scan failed - Photos may not see the new files'
        }
        Set-AvdSyncPhase $c "waiting for MediaStore to index $pushed file(s)"
        # POLL: scan_file is asynchronous, so querying immediately after
        # requesting it reports 0 rows and reads as a failure while the scan is
        # still in flight. MATCH ON THE DIRECTORY NAME, not DEST_DCIM:
        # MediaStore stores the CANONICAL /storage/emulated/0/... path, so a
        # LIKE '/sdcard/%' predicate never matched. And COUNT BOTH COLLECTIONS
        # -- a real iCloud batch is a third Live-Photo videos.
        $leaf = $dcim.Substring($dcim.LastIndexOf('/') + 1)
        $ii = 0; $vv = 0; $indexed = 0
        for ($i = 0; $i -lt 15; $i++) {
            $ii = @((Get-AvdDeviceOutput $c @("content query --uri content://media/external/images/media --projection _id --where `"_data LIKE '%/$leaf/%'`"")).Split("`n") | Where-Object { $_.StartsWith('Row:') }).Count
            $vv = @((Get-AvdDeviceOutput $c @("content query --uri content://media/external/video/media --projection _id --where `"_data LIKE '%/$leaf/%'`"")).Split("`n") | Where-Object { $_.StartsWith('Row:') }).Count
            $indexed = $ii + $vv
            if ($indexed -gt 0) { break }
            Start-Sleep -Seconds 2
        }
        if ($indexed -gt 0) {
            Write-AvdSyncLog $c "MediaStore indexed $indexed file(s) ($ii image, $vv video) under $dcim"
        } else {
            Write-AvdSyncLog $c "WARNING: nothing indexed under $dcim after 30s; Google Photos will not see these files"
        }
        # Foreground Google Photos, and LOG WHAT ACTUALLY HAPPENED: the log used
        # to claim "Google Photos foregrounded" while the call did nothing.
        $r = Invoke-AvdAdbShell -Serial $ser -Command @("monkey -p $($script:AvdGphotosPkg) -c android.intent.category.LAUNCHER 1") -TimeoutSec $c.AdbTimeout
        if ($r.ExitCode -eq 0) { Write-AvdSyncLog $c 'Google Photos foregrounded' }
        else { Write-AvdSyncLog $c 'WARNING: could not foreground Google Photos - backup may be delayed' }
    }
    $pushed
}

# -- Step 5: confirm Google Photos actually UPLOADED them --------------------------------

# RE-ANNOUNCE WHAT PHOTOS HAS NOT REGISTERED: it syncs MediaStore
# incrementally and never revisits what it skipped (measured: 369 files with no
# local_media row an hour after indexing). A `touch` plus scan_file bumps the
# row's generation and Photos picks them up (146 -> 468 in one pass).
function Invoke-AvdReannounce {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$RegSql,
        [Parameter(Mandatory)][string]$DeviceDir,
        [AllowEmptyCollection()][string[]]$DeviceList = @()
    )
    $reg = Get-AvdSortedUnique -Line @((Invoke-AvdPhotoSql $Context $RegSql).Split("`n") | Where-Object { $_.StartsWith('/') })
    $all = Get-AvdSortedUnique -Line @($DeviceList | ForEach-Object { "$DeviceDir/$_" })
    $unreg = Get-AvdLineDifference -Line $all -Exclude $reg
    if ($unreg.Count -gt 0) {
        Write-AvdSyncLog $Context "Google Photos has not registered $($unreg.Count) of $($DeviceList.Count) device file(s) - touching and rescanning them"
        if (-not (Invoke-AvdDeviceEach $Context $unreg touch 're-announcing to Photos:')) {
            Write-AvdSyncLog $Context 'WARNING: some re-announce chunks failed'
        }
        Set-AvdSyncPhase $Context 'verifying uploads with Google Photos'
    }
}

function Invoke-AvdVerifyStep {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][long]$Pushed)
    $c = $Context
    $dcim = $c.DestDcim
    # Verify after a push, AND when the last run did not finish cleanly
    # (otherwise the confirmation stamp that gates DELETE_FROM_ICLOUD stays off
    # with nothing re-testing it), AND whenever anything is still on the device
    # -- one run left 513 files uploading after a 1,000 push, and without this
    # they would sit there until the next new photo. One `ls` decides.
    $verify = $Pushed -gt 0 -or -not (Test-Path -LiteralPath $c.Confirmed -PathType Leaf) -or
    (ConvertTo-AvdCount (Get-AvdDeviceOutput $c @("ls -1 $dcim 2>/dev/null | grep -vc '^\.'"))) -gt 0
    if (-not $verify) {
        # Nothing pushed, nothing on the device, last batch confirmed: a marker
        # left by a batch whose pushes all failed has nothing to wait for.
        Remove-Item -LiteralPath $c.DeviceBusy -Force -ErrorAction SilentlyContinue
        return
    }
    $devDir = (Get-AvdDeviceOutput $c @("readlink -f $dcim")) -replace "[`r`n]", ''
    if (-not $devDir) {
        $rest = if ($dcim.StartsWith('/sdcard/')) { $dcim.Substring(8) } else { $dcim }
        $devDir = "/storage/emulated/0/$rest"
    }
    $devList = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Get-AvdDeviceOutput $c @("ls -1 $dcim 2>/dev/null")).Split("`n")) {
        if ($l.Length -gt 0 -and -not $l.StartsWith('.')) { $devList.Add($l) }
    }
    # A 0-BYTE FILE ON THE DEVICE CAN NEVER CONFIRM, so it must not be counted
    # or waited for: Photos registers an empty HEIC and never uploads it, and
    # three such files left by one bad push made every macOS run since burn the
    # whole UPLOAD_WAIT on "0 of 3 confirmed" with the device-busy marker stuck
    # on. Remove them, take their staged paths back out of the ledger so the
    # next run pushes them again, and leave them out of the counts below.
    $emptyf = ConvertFrom-AvdEmptyStat (Get-AvdDeviceOutput $c @("stat -c '%s %n' $dcim/* 2>/dev/null"))
    if ($emptyf.Count -gt 0) {
        $emptyNames = ($emptyf | ForEach-Object { $_.Substring($_.LastIndexOf('/') + 1) + ' ' }) -join ''
        Write-AvdSyncLog $c "$($emptyf.Count) empty device file(s) removed and queued again: $emptyNames"
        if (-not (Invoke-AvdDeviceEach $c $emptyf prune 'removing empty device files:')) {
            Write-AvdSyncLog $c 'WARNING: some empty-file removals failed'
        }
        foreach ($ep in $emptyf) {
            $base = $ep.Substring($ep.LastIndexOf('/') + 1)
            if (Test-Path -LiteralPath $c.Ledger -PathType Leaf) {
                $ledger = Read-AvdLine -Path $c.Ledger
                $er = Get-AvdRelOfDevname -Name $base -Ledger $ledger
                if ($er) { Set-AvdLine -Path $c.Ledger -Line ([string[]]@($ledger | Where-Object { $_ -cne $er })) }
            }
            $keep = [string[]]@($devList | Where-Object { $_ -cne $base })
            $devList = [System.Collections.Generic.List[string]]::new($keep)
        }
        if ($devList.Count -eq 0) { Remove-Item -LiteralPath $c.DeviceBusy -Force -ErrorAction SilentlyContinue }
    }
    $nDev = $devList.Count
    $names = $devList.ToArray()
    $sql = Get-AvdPhotoQuery -InList (ConvertTo-AvdSqlInList -DeviceDir $devDir -Name $names)
    $end = (Get-AvdEpoch) + $c.UploadWait + $nDev * 2
    Set-AvdSyncPhase $c 'verifying uploads with Google Photos'
    Initialize-AvdPhotoSql $c
    $null = Update-AvdPhotoDbCopy $c
    $polls = 0; $reannounced = 0
    $uploaded = 0L; $total = 0L; $failed = 0L; $pending = 0L
    while ($true) {
        $uploaded = ConvertTo-AvdCount (Invoke-AvdPhotoSql $c $sql.Up)
        $total = ConvertTo-AvdCount (Invoke-AvdPhotoSql $c $sql.Tot)
        $failed = ConvertTo-AvdCount (Invoke-AvdPhotoSql $c $sql.Fail)
        $polls++
        # Third poll (Photos has had a minute) and again after thirty more if short.
        if ($total -lt $nDev -and (($polls -eq 3 -and $reannounced -eq 0) -or ($polls -eq 33 -and $reannounced -eq 1))) {
            Invoke-AvdReannounce -Context $c -RegSql $sql.Reg -DeviceDir $devDir -DeviceList $names
            $reannounced++
        }
        if ($uploaded -gt $nDev) { Write-AvdSyncLog $c "WARNING: uploaded ($uploaded) exceeds files on device ($nDev) - the query is over-counting" }
        $pending = $nDev - $uploaded
        if ($nDev -gt 0 -and $pending -le 0) { $pending = 0; break }
        if ($nDev -eq 0) { $pending = 0; Remove-Item -LiteralPath $c.DeviceBusy -Force -ErrorAction SilentlyContinue; break }
        if ((Get-AvdEpoch) -ge $end) { break }
        Write-AvdSyncLog $c "upload in progress: $uploaded/$nDev confirmed ($total registered by Photos), $failed failed"
        Set-AvdSyncPhase $c "verifying uploads: $uploaded of $nDev confirmed"
        Start-Sleep -Seconds 20
        $null = Update-AvdPhotoDbCopy $c
    }
    # Publish the counts for the tray; it must NOT recompute them, since the
    # only honest query needs the ~200 MB Photos DB copied to the host.
    Write-AvdTextFile -Path $c.UploadStatus -Text "$uploaded $nDev $failed $(Get-AvdEpoch)`n"
    if ($pending -eq 0 -and $failed -eq 0) {
        Write-AvdSyncLog $c "UPLOAD CONFIRMED: $uploaded file(s) backed up to Google Photos"
        Write-AvdTextFile -Path $c.Confirmed -Text "$(Get-AvdEpoch)`n"
    } else {
        Write-AvdSyncLog $c "WARNING: upload NOT complete - $uploaded of $nDev done ($total registered by Photos), $pending pending, $failed permanently failed"
        Write-AvdSyncLog $c '         iCloud deletion stays disabled until a run confirms cleanly'
        Remove-Item -LiteralPath $c.Confirmed -Force -ErrorAction SilentlyContinue
    }

    # Reclaim DEVICE space: drop confirmed copies from the emulator. What makes
    # the loop self-sustaining: the emulator is a disposable STAGING device,
    # and left alone DCIM grows with the ENTIRE library until the disk fills.
    # Safe because remote_media means Google holds the content and the ledger
    # is keyed on the STAGING path, so a pruned DCIM never re-pushes. NOT
    # DELETE_FROM_ICLOUD -- this frees the throwaway emulator.
    if ($c.Config.PRUNE_DEVICE_AFTER_UPLOAD -eq '1' -and $uploaded -gt 0) {
        Set-AvdSyncPhase $c 'reclaiming emulator space'
        $prunelist = [string[]]@((Invoke-AvdPhotoSql $c $sql.Prune).Split("`n") | Where-Object { $_.StartsWith('/') })
        $npr = $prunelist.Count
        if ($npr -gt 0) {
            # A scan of a vanished file removes its MediaStore row; Photos
            # reconciles local_media on its own, and the backup is untouched.
            if (-not (Invoke-AvdDeviceEach $c $prunelist prune 'reclaiming emulator space:')) {
                Write-AvdSyncLog $c 'WARNING: some prune chunks failed'
            }
            # HAND THE CONFIRMED FILES TO THE iCLOUD RECLAIM (step 6). This list
            # is the ONLY thing that feeds it: nothing else counts as
            # confirmation, and a filename match least of all -- of 1,525
            # confirmed files, 444 matched Google Photos by name and size, 109
            # by name only, 972 not at all.
            $ledger = Read-AvdLine -Path $c.Ledger
            $toReclaim = foreach ($dp in $prunelist) {
                $r = Get-AvdRelOfDevname -Name $dp.Substring($dp.LastIndexOf('/') + 1) -Ledger $ledger
                if ($r) { $r }
            }
            Add-AvdLine -Path $c.ReclaimPending -Line ([string[]]@($toReclaim))
            $remain = ConvertTo-AvdDigit (Get-AvdDeviceOutput $c @("ls $dcim 2>/dev/null | wc -l"))
            Write-AvdSyncLog $c "reclaimed emulator space: removed $npr confirmed file(s) from DCIM ($(if ($remain) { $remain } else { '0' }) remain on device)"
            if ((ConvertTo-AvdInt -Value $remain -Default 1) -eq 0) { Remove-Item -LiteralPath $c.DeviceBusy -Force -ErrorAction SilentlyContinue }
        }
    }
}

# -- Stopping the emulator ------------------------------------------------------------

# Once the device is drained and the batch confirmed, so a quiet tick is one
# icloudpd pass and no VM; the next batch pays the ~90 s boot. Same recipe as
# avd-photos-setup --stop: sync, then emu kill -- graceful, because a hard stop
# discards unflushed writes. The process kill is the Windows last resort after
# 60 s (the macOS job only warns), since a wedged emulator attached to nothing
# would otherwise hold its AVD until the next reboot.
function Stop-AvdSyncEmulator {
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    Set-AvdSyncPhase $c 'stopping the emulator'
    $null = Get-AvdDeviceOutput $c @('sync')
    $null = Invoke-AvdAdb -ArgumentList @('-s', $c.Serial, 'emu', 'kill') -TimeoutSec 30
    $n = 0
    while ($n -lt 30 -and (Test-AvdEmulatorRunning -AvdName $c.AvdName)) { Start-Sleep -Seconds 2; $n++ }
    if (Test-AvdEmulatorRunning -AvdName $c.AvdName) {
        Write-AvdSyncLog $c 'WARNING: the emulator did not stop within 60 s - ending its process'
        Stop-AvdEmulatorProcess -AvdName $c.AvdName
    } else {
        Write-AvdSyncLog $c 'emulator stopped: device drained, batch confirmed'
    }
}

# -- The run -----------------------------------------------------------------------

function Invoke-AvdSyncRun {
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$Offload)
    $c = $Context
    $cfg = $c.Config
    # --offload (the tray item, the avd-photos-offload command): reclaim ON for
    # this run whatever the config says. Only confirmed files are ever deleted,
    # so the button is safe to press at any time.
    if ($Offload) {
        $c.DeleteFromIcloud = '1'
        Write-AvdSyncLog $c 'manual offload requested (--offload)'
    }

    # A DRY RUN of the reclaim only: which confirmed files would leave iCloud,
    # and whether their staged paths still resolve to assets in the library. It
    # touches no emulator, needs no arming (this is the check to run BEFORE
    # arming), deletes nothing and changes no ledger. It deliberately does not
    # write a "done (" line, which is what the status collector reads as a
    # completed sync run.
    if ($c.ReclaimDryRun) {
        $c.Icloudpd = Get-AvdCommandPath $cfg.ICLOUDPD
        if (-not $c.Icloudpd) { Stop-AvdSyncRun $c "icloudpd ($($cfg.ICLOUDPD)) missing from PATH" }
        if (-not $cfg.ICLOUD_USERNAME) { Stop-AvdSyncRun $c "ICLOUD_USERNAME unset in $($cfg.CONFIG_FILE)" }
        Write-AvdSyncLog $c "reclaim DRY RUN (user $($cfg.ICLOUD_USERNAME))"
        Set-AvdSyncPhase $c 'dry run: checking what would leave iCloud'
        Invoke-AvdReclaim $c
        Write-AvdSyncLog $c 'dry run finished'
        return
    }

    # Dormancy + prerequisites.
    if (-not (Test-Path -LiteralPath $cfg.SENTINEL -PathType Leaf)) {
        Write-AvdSyncLog $c "not armed (no $($cfg.SENTINEL)) - skipping"
        return
    }
    # The config file is read, not sourced (DESIGN decision 10), and a line it
    # could not use is reported rather than dropped: in the log of every armed
    # run, beside whatever failure a lost value causes.
    if ($cfg.PSObject.Properties['WARNINGS']) {
        foreach ($w in @($cfg.WARNINGS)) { Write-AvdSyncLog $c "WARNING: config: $w" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $cfg.AVD_HOME "$($c.AvdName).avd") -PathType Container)) {
        Stop-AvdSyncRun $c "no $($c.AvdName) emulator - run avd-photos-setup"
    }
    if (-not (Get-AvdAdbPath)) { Stop-AvdSyncRun $c 'adb missing from PATH' }
    $c.Icloudpd = Get-AvdCommandPath $cfg.ICLOUDPD
    if (-not $c.Icloudpd) { Stop-AvdSyncRun $c "icloudpd ($($cfg.ICLOUDPD)) missing from PATH" }
    # Not a macOS prerequisite, because macOS ships sqlite3: on Windows uv runs
    # the Photos DB query as well as the reclaim, and without it no batch could
    # ever confirm -- a pipeline that runs and never finishes, which is the
    # quiet failure every prerequisite here exists to make loud.
    if (-not (Get-AvdCommandPath 'uv')) { Stop-AvdSyncRun $c 'uv missing from PATH (it runs the Photos DB check and the iCloud reclaim)' }
    if (-not $cfg.ICLOUD_USERNAME) { Stop-AvdSyncRun $c "ICLOUD_USERNAME unset in $($cfg.CONFIG_FILE)" }

    Write-AvdSyncLog $c "start (user $($cfg.ICLOUD_USERNAME))"
    Set-AvdSyncPhase $c 'starting'

    Invoke-AvdIcloudpdStep $c
    if (Test-AvdQuietTick $c) { return }
    Start-AvdSyncEmulator $c
    $pushed = Invoke-AvdPushStep $c
    Invoke-AvdVerifyStep -Context $c -Pushed $pushed

    # Step 6: reclaim iCloud space for what Google Photos has CONFIRMED; only
    # the prune list of step 5 ever feeds its pending list.
    if ($c.DeleteFromIcloud -eq '1' -and (Test-AvdNonEmptyFile -Path $c.ReclaimPending)) { Invoke-AvdReclaim $c }

    # STOP_EMULATOR_WHEN_IDLE=0 in the config keeps it resident.
    if ($cfg.STOP_EMULATOR_WHEN_IDLE -eq '1' -and -not (Test-Path -LiteralPath $c.DeviceBusy) -and
        (Test-Path -LiteralPath $c.Confirmed -PathType Leaf) -and (Test-AvdEmulatorRunning -AvdName $c.AvdName)) {
        Stop-AvdSyncEmulator $c
    }
    Write-AvdSyncLog $c "done ($pushed pushed this run)"
}

# THE ENTRY POINT: one sync run, returning its exit code (0, or 1 on a
# failure). -Config is a Get-AvdConfig result; the tests pass one built from a
# scratch environment.
function Invoke-AvdPhotosSync {
    [CmdletBinding()]
    [OutputType([int])]
    param([switch]$Offload, [switch]$ReclaimDryRun, $Config)
    $ErrorActionPreference = 'Stop'
    if ($null -eq $Config) { $Config = Get-AvdConfig }
    $ctx = New-AvdSyncContext -Config $Config -ReclaimDryRun:$ReclaimDryRun
    # UTF-8 mode for every Python child (icloudpd, uv, the reclaim, the SQLite
    # reader; DESIGN decision 6): without it Python on Windows writes
    # redirected output and opens files in the ANSI code page, so icloudpd can
    # die on a UnicodeEncodeError logging a filename, and a non-ASCII path in
    # the reclaim's --out list would never match its ledger entry.
    $env:PYTHONUTF8 = '1'
    # A scheduled task inherits the logon environment, not a shell profile.
    Add-AvdToolPath -Directory @((Join-Path $Config.AVD_SDK_ROOT 'platform-tools'))
    Initialize-AvdLog -Path $ctx.Log

    # ONE RUN AT A TIME: the task fires every 15 minutes AND at every login,
    # while a run against a real library is hours long (measured on macOS: 2 h
    # 41 min in icloudpd alone), so a login tick lands mid-run. Taken BEFORE the
    # cleanup below is armed, so a contending run touches neither the lock nor
    # the phase file of its owner.
    $syncLogPath = $ctx.Log
    $lock = Enter-AvdLock -Path $ctx.Lock -Notice { param($m) Write-AvdLog -Path $syncLogPath -Message $m }
    if ($lock.Status -eq 'busy') {
        Write-AvdLog -Path $ctx.Log -Message "another sync run is in progress (pid $(if ($lock.OwnerId) { $lock.OwnerId } else { '?' })) - skipping"
        return 0
    }
    if ($lock.Status -ne 'held') {
        Write-AvdLog -Path $ctx.Log -Message "cannot take $($ctx.Lock) - skipping"
        return 0
    }
    $code = 0
    try {
        $null = Invoke-AvdSyncRun -Context $ctx -Offload:$Offload
    } catch {
        $code = 1
        # A failure reported through Stop-AvdSyncRun is already logged; anything
        # else is a bug or an environment this port did not foresee, and it
        # fails loudly too rather than leaving a run that simply stopped.
        if (-not $ctx.Outcome) {
            $msg = ($_.Exception.Message -replace "[`r`n]+", ' ').Trim()
            $ctx.Outcome = "failed: unexpected error: $msg"
            Write-AvdSyncLog $ctx "FAILED: unexpected error: $msg"
            Write-AvdSyncLog $ctx "  at $($_.InvocationInfo.PositionMessage -replace "[`r`n]+", ' ')"
        }
    } finally {
        # A clean exit removes the phase file; a run that could not do its job
        # leaves "failed: <why>" for the tray.
        if ($ctx.Outcome) { Set-AvdSyncPhase $ctx $ctx.Outcome }
        else { Remove-Item -LiteralPath $ctx.Phase -Force -ErrorAction SilentlyContinue }
        foreach ($d in $ctx.TempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        Exit-AvdLock -Path $ctx.Lock
    }
    $code
}
