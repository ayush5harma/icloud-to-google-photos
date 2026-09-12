# A fake emulator for the sync's orchestration tests, dot-sourced by
# Sync.Tests.ps1. Every adb call the sync makes goes through Invoke-AvdAdb
# (Core's one seam), so mocking that one function puts the whole run on this
# model; nothing here starts an emulator, a real adb, icloudpd or the reclaim.
#
# The model, and why each part is there:
#   - two attached emulators, someone else's on emulator-5554 and ours on
#     emulator-5556, so a run that addressed a device by port instead of by
#     name would be caught (every call to the wrong serial is recorded);
#   - DCIM is a real folder: push copies the file, `stat -c %s` answers its
#     size (or a WRONG size for the names in ShortPush), ls lists, rm deletes;
#   - MediaStore and Google Photos are sets of device names (Indexed,
#     Unregistered, PermFailed, and the Uploads predicate), and the `su -c cp`
#     of gphotos0.db BUILDS a real SQLite database from them -- in WAL mode
#     with the rows still in the WAL, so a sync that did not copy and pull all
#     three files would read no rows and never confirm -- plus stale rows (a
#     pruned file, a non-camera file) and duplicate remote rows, so a query
#     that lost its path scoping or counted join rows would over-count;
#   - the on-device batch loop is parsed and applied, and its batch file must
#     be LF-only with no BOM, as the device's `read -r` needs;
#   - every command that matches none of the patterns below (copies of the
#     macOS command strings) is recorded in Unknown, and every scenario asserts
#     that list is empty.
# sqlite_query.py runs for real under uv, as it does on Windows.

$script:FakeDcim = '/sdcard/DCIM/Camera'
$script:FakeDevDir = '/storage/emulated/0/DCIM/Camera'
$script:FakePhotosDb = '/data/data/com.google.android.apps.photos/databases/gphotos0.db'

# Writes a Photos database the way a live device holds one: schema in the main
# file, the rows only in the WAL, and the three files copied while the writer
# still has them open.
$script:FakeDbBuilder = @'
import json, os, shutil, sqlite3, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.argv[2]
tmp = os.path.join(out, "build.db")
for base in (tmp, os.path.join(out, "gphotos0.db")):
    for s in ("", "-wal", "-shm"):
        if os.path.exists(base + s):
            os.remove(base + s)
c = sqlite3.connect(tmp)
c.execute("pragma journal_mode=wal")
c.execute("pragma wal_autocheckpoint=0")
c.executescript("create table local_media (filepath text, dedup_key text, in_camera_folder integer,"
                " has_upload_permanently_failed integer); create table remote_media (dedup_key text);")
c.commit()
c.execute("pragma wal_checkpoint(truncate)")
c.executemany("insert into local_media values (?, ?, ?, ?)", [tuple(r) for r in spec["local"]])
c.executemany("insert into remote_media values (?)", [(k,) for k in spec["remote"]])
c.commit()
for s in ("", "-wal", "-shm"):
    if os.path.exists(tmp + s):
        shutil.copy(tmp + s, os.path.join(out, "gphotos0.db" + s))
c.close()
'@

function New-FakeDevice {
    param([Parameter(Mandatory)][string]$Root, [string]$AvdName = 'gphotos-tablet')
    $f = @{
        Root         = $Root
        Dcim         = Join-Path $Root 'dcim'
        Sdcard       = Join-Path $Root 'sdcard'
        Tmp          = Join-Path $Root 'tmp'
        Data         = Join-Path $Root 'data'
        AvdName      = $AvdName
        OurSerial    = 'emulator-5556'
        OtherSerial  = 'emulator-5554'
        OtherName    = 'someone-elses-avd'
        Running      = $false
        Booted       = $true
        AndroidId    = 'a1b2c3d4e5f60718'
        HasSqlite    = $false
        # The `su -c cp` of the Photos DB copies nothing (su refused, the DB
        # missing), so every pull of it fails: no host copy is ever coherent.
        CopyFails    = $false
        ShortPush    = [System.Collections.Generic.HashSet[string]]::new()
        Indexed      = [System.Collections.Generic.HashSet[string]]::new()
        Unregistered = [System.Collections.Generic.HashSet[string]]::new()
        PermFailed   = [System.Collections.Generic.HashSet[string]]::new()
        NotUploaded  = [System.Collections.Generic.HashSet[string]]::new()
        Calls        = [System.Collections.Generic.List[string]]::new()
        Unknown      = [System.Collections.Generic.List[string]]::new()
        WrongSerial  = [System.Collections.Generic.List[string]]::new()
        Pushes       = [System.Collections.Generic.List[string]]::new()
        Touched      = [System.Collections.Generic.List[string]]::new()
        Phases       = [System.Collections.Generic.List[string]]::new()
        EmuStarts    = [System.Collections.Generic.List[string]]::new()
        EmuKills     = 0
        # A wedged emulator: `emu kill` answers OK and the VM keeps running.
        IgnoresKill  = $false
        ProcessKills = 0
        Snapshots    = 0
        # icloudpd: the files it downloads into Staging (staging-relative
        # paths), extra output, how many polls it stays alive, its exit code.
        IcloudpdPath = (Join-Path $Root 'bin' 'icloudpd')
        Staging      = $null
        Downloads    = [System.Collections.Generic.List[string]]::new()
        IcloudpdOut  = ''
        IcloudpdErr  = ''
        IcloudpdLive = 0
        IcloudpdExit = 0
        IcloudpdArgs = $null
        # The reclaim runner. By default it behaves like the real script with a
        # healthy session; the fields below make it misbehave on purpose.
        ReclaimExit      = 0
        ReclaimOut       = $null     # lines for --out; $null = every pending path
        ReclaimStats     = $null     # raw stdout; $null = computed stats
        ReclaimOutOnDry  = $false    # write --out even on --dry-run
        ReclaimCalls     = [System.Collections.Generic.List[object]]::new()
        Clock        = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Builder      = Join-Path $Root 'build_photos_db.py'
        Helper       = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib' 'sqlite_query.py'
        Uv           = (Get-Command -Name 'uv' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }
    foreach ($d in $f.Dcim, $f.Sdcard, $f.Tmp, $f.Data, (Split-Path -Parent $f.IcloudpdPath)) {
        $null = [System.IO.Directory]::CreateDirectory($d)
    }
    [System.IO.File]::WriteAllText($f.Builder, $script:FakeDbBuilder)
    $f
}

function New-FakeResult {
    param([int]$ExitCode = 0, [AllowEmptyString()][string]$StdOut = '', [AllowEmptyString()][string]$StdErr = '')
    [pscustomobject]@{ ExitCode = $ExitCode; TimedOut = $false; StdOut = $StdOut; StdErr = $StdErr }
}

# A device path under the camera folder, as the host file backing it, or $null.
function Get-FakeDcimFile {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string]$DevicePath)
    foreach ($p in "$script:FakeDcim/", "$script:FakeDevDir/") {
        if ($DevicePath.StartsWith($p, [System.StringComparison]::Ordinal)) {
            $leaf = $DevicePath.Substring($p.Length)
            if ($leaf -and -not $leaf.Contains('/')) { return (Join-Path $Fake.Dcim $leaf) }
        }
    }
    $null
}

function Get-FakeDcimName {
    param([Parameter(Mandatory)][hashtable]$Fake)
    $names = @(Get-ChildItem -LiteralPath $Fake.Dcim -File -Force | ForEach-Object Name | Where-Object { -not $_.StartsWith('.') })
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($n in $names) { [void]$set.Add($n) }
    , ([string[]]@($set))
}

# Undo ConvertTo-AvdShellQuoted.
function ConvertFrom-FakeShellQuoted {
    param([Parameter(Mandatory)][string]$Quoted)
    $Quoted.Substring(1, $Quoted.Length - 2).Replace("'\''", "'")
}

# Build the device's gphotos0.db (and -wal, -shm) from the model.
function Update-FakePhotoDb {
    param([Parameter(Mandatory)][hashtable]$Fake)
    $Fake.Snapshots++
    $local = [System.Collections.Generic.List[object]]::new()
    $remote = [System.Collections.Generic.List[string]]::new()
    foreach ($n in (Get-FakeDcimName -Fake $Fake)) {
        if (-not $Fake.Indexed.Contains($n) -or $Fake.Unregistered.Contains($n)) { continue }
        $failed = if ($Fake.PermFailed.Contains($n)) { 1 } else { 0 }
        $local.Add([object[]]@("$script:FakeDevDir/$n", "dk-$n", 1, $failed))
        if (-not $Fake.NotUploaded.Contains($n)) {
            # Two remote rows per key: one dedup_key matches several
            # remote_media rows on a real account.
            $remote.Add("dk-$n"); $remote.Add("dk-$n")
        }
    }
    # Rows that outlive a prune, and a non-camera file, both uploaded.
    $local.Add([object[]]@("$script:FakeDevDir/2025_01_PRUNED_LONG_AGO.HEIC", 'dk-stale', 1, 0)); $remote.Add('dk-stale')
    $local.Add([object[]]@('/storage/emulated/0/Pictures/Screenshots/shot.png', 'dk-screen', 0, 0)); $remote.Add('dk-screen')
    $json = Join-Path $Fake.Root 'photos-spec.json'
    [System.IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject @{ local = $local; remote = $remote } -Depth 5 -Compress),
        [System.Text.UTF8Encoding]::new($false))
    $null = & $Fake.Uv run --no-project -q --python 3.13 $Fake.Builder $json $Fake.Data 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fake Photos DB build failed ($LASTEXITCODE)" }
}

function Invoke-FakeBatch {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string]$Body)
    $scan = 'content call --uri content://media --method scan_file --arg "$f" >/dev/null 2>&1'
    $mode = switch ($Body) {
        $scan { 'scan' }
        ('rm -f "$f" && ' + $scan) { 'prune' }
        ('touch "$f" && ' + $scan) { 'touch' }
        default { $null }
    }
    $batch = Join-Path $Fake.Tmp 'avd-batch'
    if (-not $mode -or -not (Test-Path -LiteralPath $batch)) {
        $Fake.Unknown.Add("batch: $Body")
        return (New-FakeResult -ExitCode 1)
    }
    $bytes = [System.IO.File]::ReadAllBytes($batch)
    if ($bytes -contains [byte]13 -or ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $Fake.Unknown.Add('batch file is not LF-only UTF-8 without a BOM')
    }
    foreach ($p in ([System.Text.Encoding]::UTF8.GetString($bytes)).Split("`n")) {
        if (-not $p) { continue }
        $file = Get-FakeDcimFile -Fake $Fake -DevicePath $p
        if (-not $file) { $Fake.Unknown.Add("batch path: $p"); continue }
        $name = Split-Path -Leaf $file
        switch ($mode) {
            'scan' { if (Test-Path -LiteralPath $file) { [void]$Fake.Indexed.Add($name) } else { [void]$Fake.Indexed.Remove($name) } }
            'prune' { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; [void]$Fake.Indexed.Remove($name) }
            'touch' {
                if (Test-Path -LiteralPath $file) {
                    $Fake.Touched.Add($name)
                    [void]$Fake.Indexed.Add($name)
                    [void]$Fake.Unregistered.Remove($name)
                }
            }
        }
    }
    Remove-Item -LiteralPath $batch -Force
    New-FakeResult
}

function Invoke-FakeShell {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string]$Command)
    $db = $script:FakePhotosDb
    $images = '\.(jpg|jpeg|png|heic|heif|gif|webp)$'
    $videos = '\.(mp4|mov|m4v|3gp)$'
    switch -CaseSensitive -Regex ($Command) {
        '^getprop sys\.boot_completed$' { return (New-FakeResult -StdOut $(if ($Fake.Booted) { "1`r`n" } else { "`r`n" })) }
        '^settings get secure android_id$' { return (New-FakeResult -StdOut "$($Fake.AndroidId)`r`n") }
        '^mkdir -p /sdcard/DCIM/Camera$' { return (New-FakeResult) }
        "^stat -c %s ('.*') 2>/dev/null$" {
            $file = Get-FakeDcimFile -Fake $Fake -DevicePath (ConvertFrom-FakeShellQuoted $Matches[1])
            if (-not $file -or -not (Test-Path -LiteralPath $file)) { return (New-FakeResult -ExitCode 1) }
            $size = (Get-Item -LiteralPath $file).Length
            if ($Fake.ShortPush.Contains((Split-Path -Leaf $file))) { $size = [math]::Max(0, $size - 7) }
            return (New-FakeResult -StdOut "$size`r`n")
        }
        "^rm -f ('.*')$" {
            $file = Get-FakeDcimFile -Fake $Fake -DevicePath (ConvertFrom-FakeShellQuoted $Matches[1])
            if ($file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; return (New-FakeResult) }
        }
        '^while IFS= read -r f; do \[ -n "\$f" \] && \{ (.*); \}; done < /data/local/tmp/avd-batch; rm -f /data/local/tmp/avd-batch$' {
            return (Invoke-FakeBatch -Fake $Fake -Body $Matches[1])
        }
        "^content query --uri content://media/external/(images|video)/media --projection _id --where `"_data LIKE '%/Camera/%'`"$" {
            $want = if ($Matches[1] -eq 'images') { $images } else { $videos }
            $names = Get-FakeDcimName -Fake $Fake
            $rows = @($names | Where-Object { $Fake.Indexed.Contains($_) -and $_ -match $want })
            $i = 0
            return (New-FakeResult -StdOut (($rows | ForEach-Object { "Row: $i _id=$(1000 + $i)`r`n"; $i++ }) -join ''))
        }
        '^monkey -p com\.google\.android\.apps\.photos -c android\.intent\.category\.LAUNCHER 1$' { return (New-FakeResult -StdOut "Events injected: 1`r`n") }
        '^command -v sqlite3$' {
            if ($Fake.HasSqlite) { return (New-FakeResult -StdOut "/system/bin/sqlite3`r`n") }
            return (New-FakeResult -ExitCode 1)
        }
        '^readlink -f /sdcard/DCIM/Camera$' { return (New-FakeResult -StdOut "$script:FakeDevDir`r`n") }
        "^ls -1 /sdcard/DCIM/Camera 2>/dev/null \| grep -vc '\^\\\.'$" {
            return (New-FakeResult -StdOut "$((Get-FakeDcimName -Fake $Fake).Count)`r`n")
        }
        '^ls -1 /sdcard/DCIM/Camera 2>/dev/null$' {
            return (New-FakeResult -StdOut (((Get-FakeDcimName -Fake $Fake) | ForEach-Object { "$_`r`n" }) -join ''))
        }
        '^ls /sdcard/DCIM/Camera 2>/dev/null \| wc -l$' {
            return (New-FakeResult -StdOut "$((Get-FakeDcimName -Fake $Fake).Count)`r`n")
        }
        "^stat -c '%s %n' /sdcard/DCIM/Camera/\* 2>/dev/null$" {
            $lines = foreach ($n in (Get-FakeDcimName -Fake $Fake)) { "$((Get-Item -LiteralPath (Join-Path $Fake.Dcim $n)).Length) $script:FakeDcim/$n`r`n" }
            return (New-FakeResult -StdOut (@($lines) -join ''))
        }
        '^rm -f /sdcard/gphotos0\.db /sdcard/gphotos0\.db-wal /sdcard/gphotos0\.db-shm$' {
            foreach ($s in '', '-wal', '-shm') { Remove-Item -LiteralPath (Join-Path $Fake.Sdcard "gphotos0.db$s") -Force -ErrorAction SilentlyContinue }
            return (New-FakeResult)
        }
        '^sync$' { return (New-FakeResult) }
    }
    # The two su commands, compared whole: they are the argv words of the macOS
    # script, joined by adb exactly as it joins them.
    if ($Command -ceq "su -c cp $db $db-wal $db-shm /sdcard/ 2>/dev/null; chmod 644 /sdcard/gphotos0.db*") {
        # `2>/dev/null; chmod` hides a failed cp: the shell still exits 0.
        if ($Fake.CopyFails) { return (New-FakeResult) }
        Update-FakePhotoDb -Fake $Fake
        foreach ($s in '', '-wal', '-shm') {
            $src = Join-Path $Fake.Data "gphotos0.db$s"
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Fake.Sdcard "gphotos0.db$s") -Force }
        }
        return (New-FakeResult)
    }
    if ($Command -ceq "su -c 'sqlite3 $db < /data/local/tmp/avd-query.sql' 2>/dev/null" -and $Fake.HasSqlite) {
        Update-FakePhotoDb -Fake $Fake
        $out = & $Fake.Uv run --no-project -q --python 3.13 $Fake.Helper (Join-Path $Fake.Data 'gphotos0.db') (Join-Path $Fake.Tmp 'avd-query.sql') 2>$null
        return (New-FakeResult -StdOut ((@($out) | ForEach-Object { "$_`n" }) -join ''))
    }
    $Fake.Unknown.Add("shell: $Command")
    New-FakeResult -ExitCode 127
}

# The fake adb: one call, its argument list exactly as the sync built it.
function Invoke-FakeAdb {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string[]]$ArgumentList)
    $a = @($ArgumentList)
    $Fake.Calls.Add(($a -join ' '))
    if ($a.Count -eq 1 -and $a[0] -eq 'devices') {
        $out = "List of devices attached`r`n$($Fake.OtherSerial)`tdevice`r`n"
        if ($Fake.Running) { $out += "$($Fake.OurSerial)`tdevice`r`n" }
        return (New-FakeResult -StdOut "$out`r`n")
    }
    if ($a.Count -eq 1 -and $a[0] -eq 'start-server') { return (New-FakeResult) }
    if ($a.Count -lt 3 -or $a[0] -ne '-s') { $Fake.Unknown.Add("adb: $($a -join ' ')"); return (New-FakeResult -ExitCode 1) }
    $ser = $a[1]
    if ($a.Count -eq 5 -and $a[2] -eq 'emu' -and $a[3] -eq 'avd' -and $a[4] -eq 'name') {
        if ($ser -eq $Fake.OtherSerial) { return (New-FakeResult -StdOut "$($Fake.OtherName)`r`nOK`r`n") }
        if ($ser -eq $Fake.OurSerial -and $Fake.Running) { return (New-FakeResult -StdOut "$($Fake.AvdName)`r`nOK`r`n") }
        return (New-FakeResult -ExitCode 1 -StdErr "error: device '$ser' not found")
    }
    if ($ser -ne $Fake.OurSerial) { $Fake.WrongSerial.Add(($a -join ' ')); return (New-FakeResult -ExitCode 1) }
    if (-not $Fake.Running) { return (New-FakeResult -ExitCode 1 -StdErr "error: device '$ser' not found") }
    switch ($a[2]) {
        'push' {
            $local = $a[3]; $remote = $a[4]
            if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { return (New-FakeResult -ExitCode 1 -StdErr "adb: error: cannot stat '$local'") }
            $file = Get-FakeDcimFile -Fake $Fake -DevicePath $remote
            if ($file) {
                Copy-Item -LiteralPath $local -Destination $file -Force
                $Fake.Pushes.Add($remote)
                return (New-FakeResult -StdOut "$local`: 1 file pushed.`r`n")
            }
            if ($remote -ceq '/data/local/tmp/avd-batch' -or $remote -ceq '/data/local/tmp/avd-query.sql') {
                Copy-Item -LiteralPath $local -Destination (Join-Path $Fake.Tmp ($remote.Substring($remote.LastIndexOf('/') + 1))) -Force
                return (New-FakeResult)
            }
        }
        'pull' {
            $remote = $a[3]; $local = $a[4]
            if ($remote.StartsWith('/sdcard/') -and -not $remote.Substring(8).Contains('/')) {
                $src = Join-Path $Fake.Sdcard $remote.Substring(8)
                if (-not (Test-Path -LiteralPath $src)) { return (New-FakeResult -ExitCode 1 -StdErr "adb: error: failed to stat remote object '$remote'") }
                Copy-Item -LiteralPath $src -Destination $local -Force
                return (New-FakeResult)
            }
        }
        'emu' {
            if ($a.Count -eq 4 -and $a[3] -eq 'kill') {
                if (-not $Fake.IgnoresKill) { $Fake.Running = $false }
                $Fake.EmuKills++
                return (New-FakeResult -StdOut "OK: killing emulator, bye bye`r`n")
            }
        }
        'shell' { return (Invoke-FakeShell -Fake $Fake -Command (($a[3..($a.Count - 1)]) -join ' ')) }
    }
    $Fake.Unknown.Add("adb: $($a -join ' ')")
    New-FakeResult -ExitCode 1
}

# The reclaim: by default what bin/avd-photos-reclaim.py does with a healthy
# session and every pending path in the library -- deletes them all, writes
# --out unless it is a dry run, prints its stats. Records each call with the
# pending list it was handed (the file itself is gone after the call).
function Invoke-FakeReclaim {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string[]]$ArgumentList)
    $pending = $ArgumentList[[array]::IndexOf($ArgumentList, '--pending') + 1]
    $out = $ArgumentList[[array]::IndexOf($ArgumentList, '--out') + 1]
    $dry = $ArgumentList -contains '--dry-run'
    $paths = [string[]]@([System.IO.File]::ReadAllLines($pending) | Where-Object { $_ })
    $Fake.ReclaimCalls.Add([pscustomobject]@{ Args = $ArgumentList; Pending = $paths })
    $write = if ($null -ne $Fake.ReclaimOut) { [string[]]@($Fake.ReclaimOut) } else { $paths }
    if (-not $dry -or $Fake.ReclaimOutOnDry) { [System.IO.File]::AppendAllText($out, (($write | ForEach-Object { "$_`n" }) -join '')) }
    $stats = $Fake.ReclaimStats
    if ($null -eq $stats) {
        $stats = ConvertTo-Json -Compress -InputObject ([ordered]@{
                pending = $paths.Count; walked = 40; deleted = $write.Count; held = 0; kept = 0; not_found = 0; errors = 0; dry_run = $dry })
    }
    New-FakeResult -ExitCode $Fake.ReclaimExit -StdOut "$stats`n" -StdErr "2026-09-13 10:00:00,000 INFO    reclaim log line`n"
}

# The icloudpd the sync starts: downloads Fake.Downloads into Fake.Staging and
# writes one INFO Downloaded line per file, as icloudpd v1.32 does.
function Invoke-FakeIcloudpd {
    param([Parameter(Mandatory)][hashtable]$Fake, [Parameter(Mandatory)][string]$StdoutPath, [Parameter(Mandatory)][string]$StderrPath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($rel in $Fake.Downloads) {
        $full = [System.IO.Path]::Join($Fake.Staging, $rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full))
        [System.IO.File]::WriteAllText($full, ('x' * 100))
        [void]$sb.Append("2026-09-13 10:00:00 INFO     Downloaded $full`n")
    }
    [void]$sb.Append($Fake.IcloudpdOut)
    [System.IO.File]::WriteAllText($StdoutPath, $sb.ToString())
    [System.IO.File]::WriteAllText($StderrPath, $Fake.IcloudpdErr)
}

# A process object for the fake icloudpd: alive for $Live polls, then exited.
function New-FakeProcess {
    param([int]$ExitCode = 0, [int]$Live = 0)
    $p = [pscustomobject]@{ ExitCode = $ExitCode; State = @{ Live = $Live } }
    $p | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
        if ($this.State.Live -gt 0) { $this.State.Live--; return $false }
        $true
    }
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $null }
    $p
}

# Every mock the orchestration needs, over the model in $script:Fake. Called
# from a BeforeEach, after $script:Fake is set.
function Register-FakeDeviceMock {
    Mock -ModuleName AvdPhotos Invoke-AvdAdb { Invoke-FakeAdb -Fake $script:Fake -ArgumentList $ArgumentList }
    Mock -ModuleName AvdPhotos Get-AvdAdbPath { 'adb' }
    Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $script:Fake.Running }
    Mock -ModuleName AvdPhotos Get-AvdEmulatorProcess { , [int[]]@() }
    Mock -ModuleName AvdPhotos Start-AvdEmulatorProcess {
        $script:Fake.EmuStarts.Add(($ArgumentList -join ' '))
        $script:Fake.Running = $true
        [pscustomobject]@{ Id = 0 }
    }
    Mock -ModuleName AvdPhotos Stop-AvdEmulatorProcess { $script:Fake.Running = $false; $script:Fake.ProcessKills++ }
    Mock -ModuleName AvdPhotos Get-AvdCommandPath { $script:Fake.IcloudpdPath } -ParameterFilter { $Name -eq 'icloudpd' }
    Mock -ModuleName AvdPhotos Start-AvdProcess {
        $script:Fake.IcloudpdArgs = $ArgumentList
        Invoke-FakeIcloudpd -Fake $script:Fake -StdoutPath $StdoutPath -StderrPath $StderrPath
        New-FakeProcess -ExitCode $script:Fake.IcloudpdExit -Live $script:Fake.IcloudpdLive
    }
    Mock -ModuleName AvdPhotos Invoke-AvdProcess {
        New-FakeResult -StdOut "version:1.32.3, commit sha:0123abcd, commit timestamp:Sat Sep 12 2026`n"
    } -ParameterFilter { $FilePath -eq $script:Fake.IcloudpdPath }
    Mock -ModuleName AvdPhotos Invoke-AvdReclaimProcess { Invoke-FakeReclaim -Fake $script:Fake -ArgumentList $ArgumentList }
    # Time: every sleep advances the fake clock, and the deadlines read it, so
    # a verify loop reaches its deadline instantly and deterministically.
    Mock -ModuleName AvdPhotos Start-Sleep { $script:Fake.Clock += [long]$Seconds }
    Mock -ModuleName AvdPhotos Get-AvdEpoch { $script:Fake.Clock }
    Mock -ModuleName AvdPhotos Set-AvdSyncPhase {
        $script:Fake.Phases.Add($Text)
        & $script:RealSetPhase -Context $Context -Text $Text
    }
}
