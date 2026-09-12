# The status collector, ported from bin/avd-photos-status: ONE JSON blob
# describing the pipeline, the same fields, types and order as the macOS one
# (the Swift app's parse() and the Windows tray read the same shape). The tray
# polls it every 30 seconds and paints its ring from it; a person can run it
# too (`avd-photos-status | ConvertFrom-Json`).
#
# IT COMPUTES ALMOST NOTHING. Every number that needs the Photos database, the
# ledger or a device query is WRITTEN BY THE SYNC JOB and only read here, with
# its age reported -- one writer, many readers. The two exceptions are cheap
# and need no root: counting the staging tree, and listing the camera folder
# when an emulator is ALREADY running. This never starts an emulator.
#
# FAST AND SILENT, and it always answers: every read shares the file with the
# sync that may be writing it, and a piece that cannot be read reports its
# default rather than failing the whole blob (the tray reads a missing blob as
# "collector failed").

# Explorer writes Thumbs.db and desktop.ini (Hidden, System) into picture
# folders. Counted, they would keep "remaining" above zero forever -- the
# macOS .DS_Store reasoning, for the files Windows hides by attribute rather
# than by name.
$script:AvdStatusSkipAttributes = [long]([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)

# Does a staged file count toward "staged"? Not a dotfile (find ! -name '.*'),
# and not a Hidden or System file.
function Test-AvdStagedCountable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [long]$Attributes = 0)
    (-not $Name.StartsWith('.')) -and (($Attributes -band $script:AvdStatusSkipAttributes) -eq 0)
}

# Files in the staging tree that count (Test-AvdStagedCountable, inlined in the
# loop: 50,000 PowerShell function calls cost ~1.1 s against ~20 ms inline,
# measured on pwsh 7.6 on 2026-09-13, and a real staging tree is the whole
# library). Like `find ... 2>/dev/null | wc -l`: inaccessible directories are
# skipped, and dot directories are descended into, since find tests the name
# of the file, not of its parents.
function Measure-AvdStagedFile {
    param([Parameter(Mandatory)][string]$Staging)
    if (-not [System.IO.Directory]::Exists($Staging)) { return 0L }
    $opt = [System.IO.EnumerationOptions]::new()
    $opt.RecurseSubdirectories = $true
    $opt.IgnoreInaccessible = $true
    $opt.AttributesToSkip = [System.IO.FileAttributes]0
    $skip = $script:AvdStatusSkipAttributes
    $n = 0L
    try {
        foreach ($fi in [System.IO.DirectoryInfo]::new($Staging).EnumerateFiles('*', $opt)) {
            if ((-not $fi.Name.StartsWith('.')) -and (([long]$fi.Attributes -band $skip) -eq 0)) { $n++ }
        }
    } catch {
        Write-Verbose "staging count stopped early: $($_.Exception.Message)"
    }
    $n
}

# The non-empty lines of a file the sync may be writing (grep -c . semantics).
function Get-AvdStatusLine {
    param([Parameter(Mandatory)][string]$Path)
    $all = Read-AvdSharedLine -Path $Path
    , ([string[]]@($all | Where-Object { $_.Length -gt 0 }))
}

# A file's mtime as Unix seconds, or $null.
function Get-AvdFileEpoch {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        [System.DateTimeOffset]::new((Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch { $null }
}

# The time of the newest completed run: the last "YYYY-MM-DD HH:MM:SS done ("
# line, read as LOCAL time (Write-AvdLog writes local time), as Unix seconds;
# $null when there is none.
function Get-AvdLastDoneEpoch {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    $opts = [System.Text.RegularExpressions.RegexOptions]'Multiline, RightToLeft'
    $m = [regex]::Match($Text, '^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) done \(', $opts)
    if (-not $m.Success) { return $null }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt)) { return $null }
    [System.DateTimeOffset]::new($dt).ToUnixTimeSeconds()
}

# The phase line as the JSON carries it: the first line, '"' and '\' removed
# (the macOS printf could not escape them), at most 160 characters.
function ConvertTo-AvdStatusPhase {
    param([AllowEmptyString()][AllowNull()][string]$Line)
    if (-not $Line) { return '' }
    $p = $Line -replace '["\\]', ''
    if ($p.Length -gt 160) {
        $cut = 160
        if ([char]::IsHighSurrogate($p[159])) { $cut = 159 }
        $p = $p.Substring(0, $cut)
    }
    $p
}

function Get-AvdPhotosStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param($Config)
    if ($null -eq $Config) { $Config = Get-AvdConfig -NoCreate }
    Add-AvdToolPath -Directory @((Join-Path $Config.AVD_SDK_ROOT 'platform-tools'))
    $state = $Config.STATE_DIR
    $now = [long](Get-AvdEpoch)

    $armed = Test-Path -LiteralPath $Config.SENTINEL -PathType Leaf
    $emu = $false
    try { $emu = [bool](Test-AvdEmulatorRunning -AvdName $Config.AVD_NAME) } catch { $emu = $false }

    $staged = Measure-AvdStagedFile -Staging $Config.STAGING

    $ondev = 0L; $uploaded = 0L; $queued = 0L; $failed = 0L; $uplAge = -1L
    if ($emu) {
        # ASK WHICH SERIAL IS OURS rather than assuming 5554: another emulator
        # on this machine would otherwise have its camera folder counted as
        # this pipeline's backlog. An emulator that is running but cannot be
        # resolved (still booting, or a wedged console) reports 0, which is
        # what it is worth.
        try {
            $ser = Get-AvdEmulatorSerial -AvdName $Config.AVD_NAME
            if ($ser) {
                $r = Invoke-AvdAdbShell -Serial $ser -Command @("ls $($Config.DEST_DCIM) 2>/dev/null | wc -l") -TimeoutSec 6
                $ondev = ConvertTo-AvdCount $r.Output
            }
        } catch {
            Write-Verbose "on-device count unavailable: $($_.Exception.Message)"
        }
    }

    # THE BACKLOG is staged files the ledger has not seen.
    $ledger = Join-Path $state 'pushed.list'
    $remaining = 0L
    if ($staged -gt 0 -and (Test-Path -LiteralPath $ledger -PathType Leaf)) {
        $remaining = [math]::Max(0L, $staged - (Get-AvdStatusLine -Path $ledger).Count)
    }

    # THE VERIFY COUNT DESCRIBES THE DEVICE AS OF ITS WRITE, and a push after
    # it starts a batch it knows nothing about: read verbatim, a 05:47 status
    # (1000 of 1000, then pruned) sat beside 377 freshly pushed files nine
    # hours later and the bar read "1000/377" with an exclamation mark. So it
    # counts only while its stamp is not older than the ledger's last change.
    $us = Join-Path $state 'upload-status'
    if (Test-Path -LiteralPath $us -PathType Leaf) {
        $usLines = Read-AvdSharedLine -Path $us
        $first = if ($usLines.Count -gt 0) { $usLines[0] } else { '' }
        $f = @($first.Trim() -split '\s+')
        $field = { param($i) if ($f.Count -gt $i) { $f[$i] } else { '' } }
        $ts = & $field 3
        $ledM = Get-AvdFileEpoch -Path $ledger
        if ($null -eq $ledM) { $ledM = 0L }
        if ($ts -eq '' -or $ts -match '^[0-9]+$') {
            $tsN = ConvertTo-AvdInt -Value $ts -Default 0
            if ($tsN -ge $ledM) {
                $u = ConvertTo-AvdInt -Value (& $field 0) -Default 0
                $t = ConvertTo-AvdInt -Value (& $field 1) -Default 0
                $uploaded = $u
                $failed = ConvertTo-AvdInt -Value (& $field 2) -Default 0
                $queued = [math]::Max(0L, $t - $u)
                if ($ts -ne '') { $uplAge = $now - $tsN }
            }
        }
    }

    # THE CONFIRMATION STAMP IS THE ONLY HONEST "BACKED UP": the sync writes it
    # only when every camera-folder file matched in remote_media with zero
    # permanent failures, and DELETES it when a run cannot confirm. The tray
    # gates its green state on this and never on arithmetic.
    $confirmed = $false; $confirmedAge = -1L
    $cf = Join-Path $state 'last-upload-confirmed'
    if (Test-Path -LiteralPath $cf -PathType Leaf) {
        $cts = ConvertTo-AvdDigit ((Read-AvdSharedLine -Path $cf) -join '')
        if ($cts) {
            $confirmed = $true
            $confirmedAge = [math]::Max(0L, $now - (ConvertTo-AvdInt -Value $cts -Default 0))
        }
    }

    # PIPELINE LIVENESS is the age of the last COMPLETED run (the newest
    # "done (" line), NOT the log's mtime: a run that bails writes the log
    # too, so on macOS the mtime said "21.7h ago" and the meter said "All
    # backed up" through five days of "icloudpd missing" skips. A healthy
    # no-op still ends in "done (0 pushed this run)".
    $lastRunAge = -1L
    $syncLog = Join-Path $Config.LOG_DIR 'sync.log'
    if (Test-Path -LiteralPath $syncLog -PathType Leaf) {
        $lm = Get-AvdLastDoneEpoch -Text ((Read-AvdSharedLine -Path $syncLog) -join "`n")
        if ($null -eq $lm) { $lm = Get-AvdFileEpoch -Path $syncLog }
        if ($null -ne $lm) { $lastRunAge = [math]::Max(0L, $now - $lm) }
    }

    # The reclaim ledgers: what has been deleted from iCloud after
    # confirmation, and what is confirmed but not yet deleted.
    $reclaimedPath = Join-Path $state 'reclaimed.list'
    $pendingPath = Join-Path $state 'reclaim-pending.list'
    $reclaimedLines = Get-AvdStatusLine -Path $reclaimedPath
    $reclaimed = [long]$reclaimedLines.Count
    $reclaimPending = 0L
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        $pend = Get-AvdSortedUnique -Line (Get-AvdStatusLine -Path $pendingPath)
        $reclaimPending = [long](Get-AvdLineDifference -Line $pend -Exclude (Get-AvdSortedUnique -Line $reclaimedLines)).Count
    }

    # LIVE PHASE AND THE RUNNING FLAG come from the sync job itself: its lock
    # names the run in flight and the phase file is its current step or the
    # "failed: <why>" it left behind. Read, never computed: a run is alive only
    # while its process is (pid AND start time, Core's lock), so a crashed job
    # cannot look busy.
    $running = [bool](Test-AvdLockAlive -Path (Join-Path $state 'sync.lock'))
    $phase = ''
    $pf = Join-Path $state 'phase'
    if (Test-Path -LiteralPath $pf -PathType Leaf) {
        $pl = Read-AvdSharedLine -Path $pf
        if ($pl.Count -gt 0) { $phase = ConvertTo-AvdStatusPhase -Line $pl[0] }
    }
    # A verify pass in flight publishes "verifying uploads: N of M confirmed"
    # as its phase; while the run is alive that is the live count for the batch
    # on the device (upload-status is written only after the pass ends).
    if ($running) {
        $m = [regex]::Match($phase, '^verifying uploads: ([0-9]+) of ([0-9]+) confirmed$')
        if ($m.Success) {
            $vu = ConvertTo-AvdInt -Value $m.Groups[1].Value -Default 0
            $vt = ConvertTo-AvdInt -Value $m.Groups[2].Value -Default 0
            $uploaded = $vu
            $queued = [math]::Max(0L, $vt - $vu)
            $uplAge = 0L
        }
    }

    $o = [ordered]@{
        backup = [ordered]@{
            armed           = [bool]$armed
            emulator        = [bool]$emu
            staged          = [long]$staged
            remaining       = [long]$remaining
            on_device       = [long]$ondev
            uploaded        = [long]$uploaded
            queued          = [long]$queued
            failed          = [long]$failed
            upload_age      = [long]$uplAge
            confirmed       = [bool]$confirmed
            confirmed_age   = [long]$confirmedAge
            last_run_age    = [long]$lastRunAge
            running         = [bool]$running
            phase           = [string]$phase
            reclaimed       = [long]$reclaimed
            reclaim_pending = [long]$reclaimPending
        }
        ts     = $now
    }
    # ASCII on the wire whatever the console code page: a non-ASCII staging
    # path in a "failed: ..." phase is escaped, not mangled.
    ConvertTo-Json -InputObject $o -Compress -Depth 3 -EscapeHandling EscapeNonAscii
}
