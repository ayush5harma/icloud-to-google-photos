#Requires -Version 7.2
# The sync port: its pure helpers one by one, its texts against the macOS
# script it ports (SQL, the on-device loop, the phase strings -- each an
# interface), and whole runs against the fake device in FakeDevice.ps1. The
# SQLite reader runs for real under uv, so these need uv on PATH.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    . (Join-Path $PSScriptRoot 'FakeDevice.ps1')
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MacSync = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'bin' 'avd-photos-sync'))
    $script:WinSync = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'windows' 'lib' 'Sync.ps1'))
    $script:RealSetPhase = (Get-Command -Module AvdPhotos -Name Set-AvdSyncPhase).ScriptBlock
    # The sync seeds PATH and sets PYTHONUTF8 for its children; put both back.
    $script:SavedPath = $env:PATH
    $script:SavedUtf8 = [System.Environment]::GetEnvironmentVariable('PYTHONUTF8')

    # A scratch world: config, state, logs, staging (under a bracketed
    # directory, the macOS prefix incident), an AVD and an emulator binary, the
    # sentinel unless -Unarmed, and a fresh fake device in $script:Fake.
    function New-SyncWorld {
        param([hashtable]$Environment = @{}, [switch]$Unarmed)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 10))
        $h = Join-Path $root 'home'
        $e = @{
            HOME                  = $h
            USERPROFILE           = $h
            AVD_PHOTOS_CONFIG_DIR = (Join-Path $root 'config')
            AVD_PHOTOS_STATE_DIR  = (Join-Path $root 'state')
            AVD_PHOTOS_LOG_DIR    = (Join-Path $root 'logs')
            STAGING               = (Join-Path $root 'My Drive' '[05] Backups' 'icloud staging')
            AVD_SDK_ROOT          = (Join-Path $root 'sdk')
            ANDROID_AVD_HOME      = (Join-Path $root 'avd')
            ICLOUD_USERNAME       = 'someone@example.invalid'
        }
        foreach ($k in $Environment.Keys) { $e[$k] = $Environment[$k] }
        $cfg = Get-AvdConfig -Environment $e -Platform (Get-AvdPlatform)
        if (-not $Unarmed) { [System.IO.File]::WriteAllText($cfg.SENTINEL, '') }
        $null = [System.IO.Directory]::CreateDirectory((Join-Path $cfg.AVD_HOME "$($cfg.AVD_NAME).avd"))
        $emu = Join-Path $cfg.AVD_SDK_ROOT 'emulator' $(if ($IsWindows) { 'emulator.exe' } else { 'emulator' })
        $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $emu))
        [System.IO.File]::WriteAllText($emu, '')
        $null = [System.IO.Directory]::CreateDirectory($cfg.STAGING)
        $script:Fake = New-FakeDevice -Root (Join-Path $root 'device') -AvdName $cfg.AVD_NAME
        $script:Fake.Staging = $cfg.STAGING
        [pscustomobject]@{ Config = $cfg; State = $cfg.STATE_DIR; Staging = $cfg.STAGING; Log = (Join-Path $cfg.LOG_DIR 'sync.log') }
    }
    function Add-Staged {
        param($World, [string[]]$Rel, [int]$Bytes = 100)
        foreach ($r in $Rel) {
            $full = [System.IO.Path]::Join($World.Staging, $r.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [System.IO.File]::WriteAllText($full, ('x' * $Bytes))
        }
    }
    function Get-StatePath { param($World, [string]$Name) Join-Path $World.State $Name }
    function Get-SyncLog { param($World) if (Test-Path -LiteralPath $World.Log) { [System.IO.File]::ReadAllText($World.Log) } else { '' } }
    function Get-Line { param($World, [string]$Name) $l = Read-AvdLine -Path (Get-StatePath $World $Name); $l }
    function Set-Stamp { param($World) [System.IO.File]::WriteAllText((Get-StatePath $World 'last-upload-confirmed'), "1757000000`n") }
    function Assert-CleanFake {
        $script:Fake.Unknown | Should -BeNullOrEmpty -Because 'every device command must be one the macOS script sends'
        $script:Fake.WrongSerial | Should -BeNullOrEmpty -Because 'nothing may address the other emulator'
    }
    function ConvertTo-LogPattern { param([string]$Text) [regex]::Escape($Text) }
}

AfterAll {
    $env:PATH = $script:SavedPath
    if ($null -eq $script:SavedUtf8) { [System.Environment]::SetEnvironmentVariable('PYTHONUTF8', [NullString]::Value) }
    else { [System.Environment]::SetEnvironmentVariable('PYTHONUTF8', $script:SavedUtf8) }
}

Describe 'the texts that are interfaces match bin/avd-photos-sync' {
    It 'has the same verify SQL' {
        $q = Get-AvdPhotoQuery -InList '@IN@'
        foreach ($pair in @(@('SQL_UP', $q.Up), @('SQL_TOT', $q.Tot), @('SQL_FAIL', $q.Fail), @('SQL_REG', $q.Reg))) {
            $m = [regex]::Match($MacSync, "(?m)^\s*$($pair[0])=`"([^`"]*)`"")
            $m.Success | Should -BeTrue -Because $pair[0]
            $m.Groups[1].Value.Replace('$inlist', '@IN@') | Should -BeExactly $pair[1] -Because $pair[0]
        }
        $m = [regex]::Match($MacSync, 'photos_sql "(select distinct l\.filepath[^"]*)"')
        $m.Groups[1].Value.Replace('$inlist', '@IN@') | Should -BeExactly $q.Prune
    }
    It 'sends the same on-device loop and bodies' {
        foreach ($mode in 'scan', 'prune', 'touch') {
            $m = [regex]::Match($MacSync, "(?m)^\s*$mode\)\s+body='([^']*)'")
            $m.Success | Should -BeTrue
            $WinSync | Should -Match (ConvertTo-LogPattern "'$mode' { '$($m.Groups[1].Value)' }")
        }
        $m = [regex]::Match($MacSync, '"(while IFS= read -r f; do .*avd-batch)"')
        $mac = $m.Groups[1].Value.Replace('\"', '"').Replace('\$', '$').Replace('$body', '@BODY@')
        $mac | Should -BeExactly 'while IFS= read -r f; do [ -n "$f" ] && { @BODY@; }; done < /data/local/tmp/avd-batch; rm -f /data/local/tmp/avd-batch'
        $WinSync | Should -Match (ConvertTo-LogPattern "'while IFS= read -r f; do [ -n `"`$f`" ] && { ' + `$body + '; }; done < /data/local/tmp/avd-batch; rm -f /data/local/tmp/avd-batch'")
    }
    It 'writes the same phase strings (the tray parses them)' {
        # Every variable, however spelled, becomes '#': the TEXT is the interface.
        $norm = { param($s) $s -replace '\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*', '#' }
        $mac = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($m in [regex]::Matches($MacSync, '(?m)\bphase "([^"]*)"')) { [void]$mac.Add((& $norm $m.Groups[1].Value)) }
        foreach ($m in [regex]::Matches($MacSync, '(?m)device_each "[^"]*" \w+ "([^"]*)"')) { [void]$mac.Add((& $norm ($m.Groups[1].Value + ' # of #'))) }
        $win = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($m in [regex]::Matches($WinSync, "Set-AvdSyncPhase \`$\w+ (?:'([^']*)'|`"([^`"]*)`")")) {
            $t = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            [void]$win.Add((& $norm $t))
        }
        foreach ($m in [regex]::Matches($WinSync, "Invoke-AvdDeviceEach \`$\w+ \S+ \w+ '([^']*)'")) { [void]$win.Add((& $norm ($m.Groups[1].Value + ' # of #'))) }
        # The macOS phase() body itself and the generic label line are not strings the tray sees.
        $mac.Remove('#') | Out-Null; $win.Remove('#') | Out-Null
        $mac.Remove('# # of #') | Out-Null; $win.Remove('# # of #') | Out-Null
        @($win) | Should -Be @($mac)
    }
}

Describe 'pure helpers' {
    It 'treats Drive and OneDrive placeholders as evicted, and nothing else' {
        Test-AvdCloudPlaceholder -Attributes 0x00400000 | Should -BeTrue
        Test-AvdCloudPlaceholder -Attributes 0x00040000 | Should -BeTrue
        Test-AvdCloudPlaceholder -Attributes ([long][System.IO.FileAttributes]::Offline) | Should -BeTrue
        Test-AvdCloudPlaceholder -Attributes (0x00400000 -bor 0x20 -bor 0x400) | Should -BeTrue
        Test-AvdCloudPlaceholder -Attributes 0x20 | Should -BeFalse
        Test-AvdCloudPlaceholder -Attributes (0x1 -bor 0x2 -bor 0x4 -bor 0x80 -bor 0x400) | Should -BeFalse
        Test-AvdCloudPlaceholder -Attributes 0 | Should -BeFalse
    }
    It 'reverses the device name, and a legacy basename only when the ledger match is unique' {
        Get-AvdRelOfDevname -Name '2026_05_IMG_2885.HEIC' | Should -BeExactly '2026/05/IMG_2885.HEIC'
        Get-AvdRelOfDevname -Name "2026_05_it's & more.JPG" | Should -BeExactly "2026/05/it's & more.JPG"
        Get-AvdRelOfDevname -Name 'IMG_1.HEIC' -Ledger @('2026/05/IMG_1.HEIC', '2026/05/XIMG_1.HEIC') | Should -BeExactly '2026/05/IMG_1.HEIC'
        Get-AvdRelOfDevname -Name 'IMG_1.HEIC' -Ledger @('2026/05/IMG_1.HEIC', '2025/01/IMG_1.HEIC') | Should -BeNullOrEmpty
        Get-AvdRelOfDevname -Name 'IMG_1.HEIC' -Ledger @('2026/05/IMG_1.HEIC', '2026/05/IMG_1.HEIC') | Should -BeNullOrEmpty
        Get-AvdRelOfDevname -Name 'IMG_1.HEIC' -Ledger @('IMG_1.HEIC') | Should -BeNullOrEmpty
        Get-AvdRelOfDevname -Name 'img_1.heic' -Ledger @('2026/05/IMG_1.HEIC') | Should -BeNullOrEmpty
        Get-AvdRelOfDevname -Name '2026_5_x.jpg' -Ledger @() | Should -BeNullOrEmpty
        Get-AvdRelOfDevname -Name '2026_05_' -Ledger @() | Should -BeNullOrEmpty
    }
    It 'builds the IN list with quotes doubled, and a valid empty one' {
        ConvertTo-AvdSqlInList -DeviceDir '/storage/emulated/0/DCIM/Camera' -Name @('a.jpg', "it's & more.JPG") |
            Should -BeExactly "'/storage/emulated/0/DCIM/Camera/a.jpg','/storage/emulated/0/DCIM/Camera/it''s & more.JPG'"
        ConvertTo-AvdSqlInList -DeviceDir '/d' -Name @() | Should -BeExactly "''"
    }
    It 'finds the 0-byte files in stat -c "%s %n" output' {
        $t = "0 /sdcard/DCIM/Camera/a b.HEIC`n123 /sdcard/DCIM/Camera/c.jpg`n00 /sdcard/DCIM/Camera/d.jpg`n0 `n0`t/sdcard/DCIM/Camera/e.jpg`n"
        $e = ConvertFrom-AvdEmptyStat $t
        $e | Should -Be @('/sdcard/DCIM/Camera/a b.HEIC', '/sdcard/DCIM/Camera/e.jpg')
        (ConvertFrom-AvdEmptyStat '').Count | Should -Be 0
    }
    It 'reads counts as tr -dc 0-9 does' {
        ConvertTo-AvdDigit "3`r`n" | Should -BeExactly '3'
        ConvertTo-AvdDigit '' | Should -BeExactly ''
        ConvertTo-AvdCount '' | Should -Be 0
        ConvertTo-AvdCount "  12`n" | Should -Be 12
    }
    It 'classifies an icloudpd exit' {
        (Get-AvdIcloudpdOutcome -ExitCode 0).Kind | Should -Be 'ok'
        $o = Get-AvdIcloudpdOutcome -ExitCode -1073741819
        $o.Kind | Should -Be 'crash'
        $o.Code | Should -Be '0xC0000005'
        (Get-AvdIcloudpdOutcome -ExitCode -1).Code | Should -Be '0xFFFFFFFF'
        (Get-AvdIcloudpdOutcome -ExitCode 127).Kind | Should -Be 'notexec'
        (Get-AvdIcloudpdOutcome -ExitCode 1 -Tail @('x', 'ERROR    None of providers gave password')).Kind | Should -Be 'auth'
        (Get-AvdIcloudpdOutcome -ExitCode 1 -Tail @('EOFError: EOF when reading a line')).Kind | Should -Be 'auth'
        (Get-AvdIcloudpdOutcome -ExitCode 1 -Tail @('  in ask_password_in_console')).Kind | Should -Be 'auth'
        (Get-AvdIcloudpdOutcome -ExitCode 1 -Tail @('INFO all done')).Kind | Should -Be 'other'
        (Get-AvdIcloudpdOutcome -ExitCode 2).Kind | Should -Be 'other'
    }
}

Describe 'the staging listing' {
    BeforeEach {
        $script:St = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'My Drive' '[05] Backups' 'stage'
        foreach ($r in '2026/05/IMG_1.HEIC', '2026/05/b.jpg', '2026/05/B.PNG', '2026/05/.hidden.jpg', '2026/05/notes.txt',
            'top.mov', "2026/05/sub dir/it's & x.Mp4", '2026/05/IMG_1.HEIC.xmp') {
            $full = [System.IO.Path]::Join($St, $r.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [System.IO.File]::WriteAllText($full, 'x')
        }
    }
    It 'lists media relative to a bracketed staging path, with / separators, dotfiles included, sorted byte-wise' {
        $l = Get-AvdStagingList -Staging $St
        $l.Error | Should -BeNullOrEmpty
        $l.Files | Should -Be @('2026/05/.hidden.jpg', '2026/05/B.PNG', '2026/05/IMG_1.HEIC', '2026/05/b.jpg', "2026/05/sub dir/it's & x.Mp4", 'top.mov')
    }
    It 'strips a staging path given with a trailing separator by length too' {
        (Get-AvdStagingList -Staging ($St + [System.IO.Path]::DirectorySeparatorChar)).Files[0] | Should -BeExactly '2026/05/.hidden.jpg'
    }
    It 'reports a missing tree as an error, not as an empty one' {
        $l = Get-AvdStagingList -Staging (Join-Path $TestDrive 'nope')
        $l.Error | Should -Not -BeNullOrEmpty
        $l.AccessDenied | Should -BeFalse
        $l.Files.Count | Should -Be 0
    }
    It 'reports a refused directory as access denied, never as a shorter list' -Skip:$IsWindows {
        $locked = Join-Path $St 'locked'
        $null = [System.IO.Directory]::CreateDirectory($locked)
        [System.IO.File]::WriteAllText((Join-Path $locked 'a.jpg'), 'x')
        [System.IO.File]::SetUnixFileMode($locked, [System.IO.UnixFileMode]::None)
        try {
            $l = Get-AvdStagingList -Staging $St
            $l.AccessDenied | Should -BeTrue
            $l.Error | Should -Match 'denied'
            $l.Files.Count | Should -Be 0
        } finally {
            [System.IO.File]::SetUnixFileMode($locked, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
    }
    It 'does not count dotfiles as staging-root entries' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($d)
        Test-AvdStagingHasEntry -Staging $d | Should -BeFalse
        [System.IO.File]::WriteAllText((Join-Path $d '.DS_Store'), 'x')
        Test-AvdStagingHasEntry -Staging $d | Should -BeFalse
        [System.IO.File]::WriteAllText((Join-Path $d 'notes.txt'), 'x')
        Test-AvdStagingHasEntry -Staging $d | Should -BeTrue
    }
    It 'does not count Hidden or System entries (desktop.ini) as staging-root entries' -Tag 'WindowsOnly' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($d)
        $ini = Join-Path $d 'desktop.ini'
        [System.IO.File]::WriteAllText($ini, '[.ShellClassInfo]')
        [System.IO.File]::SetAttributes($ini, [System.IO.FileAttributes]'Hidden, System')
        Test-AvdStagingHasEntry -Staging $d | Should -BeFalse
    }
}

Describe 'the process seams' {
    It 'passes host SQL through a file, never on the command line' {
        $script:seen = $null
        Mock -ModuleName AvdPhotos Get-AvdCommandPath { '/fake/uv' } -ParameterFilter { $Name -eq 'uv' }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess {
            $script:seen = [pscustomobject]@{ Args = $ArgumentList; Sql = [System.IO.File]::ReadAllText($ArgumentList[-1]) }
            New-FakeResult -StdOut "1`n"
        }
        $inlist = ConvertTo-AvdSqlInList -DeviceDir '/storage/emulated/0/DCIM/Camera' -Name @(1..1000 | ForEach-Object { "2026_05_IMG_$_ it's.HEIC" })
        $sql = (Get-AvdPhotoQuery -InList $inlist).Up
        $sql.Length | Should -BeGreaterThan 32767
        (Invoke-AvdHostSql -DbPath '/tmp/photos.db' -Sql $sql).StdOut | Should -Be "1`n"
        $seen.Args[0..5] | Should -Be @('run', '--no-project', '-q', '--python', '3.13', (Join-Path $RepoRoot 'windows' 'lib' 'sqlite_query.py'))
        $seen.Args[6] | Should -Be '/tmp/photos.db'
        $seen.Args.Count | Should -Be 8
        $seen.Sql | Should -BeExactly "$sql`n"
        ($seen.Args -join ' ') | Should -Not -Match 'select'
    }
    It 'runs the reclaim as uv run -q --no-project --python 3.13 --with <spec> <script> <args>' {
        Mock -ModuleName AvdPhotos Get-AvdCommandPath { '/fake/uv' } -ParameterFilter { $Name -eq 'uv' }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-FakeResult }
        $null = Invoke-AvdReclaimProcess -Spec 'icloudpd @ git+x@v1' -Script '/r.py' -ArgumentList @('--username', 'u') -TimeoutSec 1800
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq '/fake/uv' -and $TimeoutSec -eq 1800 -and
            ($ArgumentList -join '|') -eq 'run|-q|--no-project|--python|3.13|--with|icloudpd @ git+x@v1|/r.py|--username|u'
        }
    }
    It 'reports a missing uv as 127 rather than running anything' {
        Mock -ModuleName AvdPhotos Get-AvdCommandPath { $null } -ParameterFilter { $Name -eq 'uv' }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { throw 'must not run' }
        (Invoke-AvdReclaimProcess -Spec 's' -Script 'p' -ArgumentList @('x')).ExitCode | Should -Be 127
        (Invoke-AvdHostSql -DbPath 'd' -Sql 'select 1;').ExitCode | Should -Be 127
    }
}

Describe 'the on-device loop' {
    BeforeEach { Register-FakeDeviceMock }
    It 'sends 100 paths per batch as an LF file and reports "<label> N of M"' {
        $w = New-SyncWorld
        $Fake.Running = $true
        $ctx = New-AvdSyncContext -Config $w.Config
        $ctx.Serial = $Fake.OurSerial
        $paths = @(1..250 | ForEach-Object { "/sdcard/DCIM/Camera/2026_05_IMG_$_ & it's.HEIC" })
        foreach ($p in $paths) { [System.IO.File]::WriteAllText((Join-Path $Fake.Dcim $p.Substring(20)), 'x') }
        Invoke-AvdDeviceEach $ctx $paths scan 'indexing in MediaStore:' | Should -BeTrue
        @($Fake.Calls | Where-Object { $_ -like '* push * /data/local/tmp/avd-batch' }).Count | Should -Be 3
        @($Fake.Phases) | Should -Be @('indexing in MediaStore: 100 of 250', 'indexing in MediaStore: 200 of 250', 'indexing in MediaStore: 250 of 250')
        $Fake.Indexed.Count | Should -Be 250
        Assert-CleanFake
    }
}

Describe 'a whole sync against the fake device' {
    BeforeEach { Register-FakeDeviceMock }

    It '(1) does nothing but say so when not armed' {
        $w = New-SyncWorld -Unarmed
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        (Get-SyncLog $w) | Should -Match 'not armed \(no .*ENABLED\) - skipping'
        $Fake.Calls.Count | Should -Be 0
        $Fake.IcloudpdArgs | Should -BeNullOrEmpty
        Test-Path (Get-StatePath $w 'pushed.list') | Should -BeFalse
        Test-Path (Get-StatePath $w 'phase') | Should -BeFalse
        Test-Path (Get-StatePath $w 'sync.lock') | Should -BeFalse
        $env:PYTHONUTF8 | Should -Be '1'
    }

    It '(2) keeps the emulator off on a quiet tick and still completes the run' {
        $w = New-SyncWorld
        Add-Staged $w '2026/05/IMG_0001.HEIC', '2026/05/IMG_0002.HEIC'
        Set-AvdLine -Path (Get-StatePath $w 'pushed.list') -Line @('2026/05/IMG_0002.HEIC', '2026/05/IMG_0001.HEIC')
        Set-Stamp $w
        Write-AvdTextFile -Path (Get-StatePath $w 'phase') -Text "failed: an earlier run`n"
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'start (user someone@example.invalid)')
        $log | Should -Match (ConvertTo-LogPattern 'icloudpd ok')
        $log | Should -Match (ConvertTo-LogPattern 'nothing new: 2 staged, all pushed and confirmed - the emulator stays off')
        $log | Should -Match '\d{2}:\d{2}:\d{2} done \(0 pushed this run\)'
        $Fake.Calls.Count | Should -Be 0
        $Fake.EmuStarts.Count | Should -Be 0
        $Fake.ReclaimCalls.Count | Should -Be 0
        Test-Path (Get-StatePath $w 'phase') | Should -BeFalse
        Test-Path (Get-StatePath $w 'sync.lock') | Should -BeFalse
        # icloudpd got the macOS arguments plus the keyring-only provider.
        ($Fake.IcloudpdArgs -join '|') | Should -BeExactly (@('--username', 'someone@example.invalid', '--directory', $w.Staging,
                '--until-found', '50', '--recent', '2000', '--folder-structure', '{:%Y/%m}', '--no-progress-bar', '--log-level', 'info',
                '--password-provider', 'keyring') -join '|')
    }

    It '(3) pushes a new batch to OUR emulator, confirms it in Photos, prunes it and reclaims exactly it' {
        $w = New-SyncWorld
        $rels = @('2026/05/IMG_0001.HEIC', "2026/05/it's & more.JPG", '2026/06/IMG_0002.MOV')
        foreach ($r in $rels) { $Fake.Downloads.Add($r) }
        $Fake.IcloudpdLive = 1
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        # icloudpd's output reached the log, and its progress the phase.
        $log | Should -Match ' INFO +Downloaded .*IMG_0001\.HEIC'
        $Fake.Phases | Should -Contain 'downloading from iCloud: 3 new so far'
        # Booted, and found by NAME on 5556 while 5554 runs someone else's AVD.
        $Fake.EmuStarts[0] | Should -BeExactly '-avd gphotos-tablet -no-snapshot -no-boot-anim -no-window -gpu host'
        $log | Should -Match (ConvertTo-LogPattern 'emulator up (emulator-5556 is gphotos-tablet)')
        $Fake.Calls | Should -Contain '-s emulator-5554 emu avd name'
        # Flattened device names, every push to the right serial, from under the bracketed staging path.
        @($Fake.Pushes) | Should -Be @('/sdcard/DCIM/Camera/2026_05_IMG_0001.HEIC', "/sdcard/DCIM/Camera/2026_05_it's & more.JPG", '/sdcard/DCIM/Camera/2026_06_IMG_0002.MOV')
        $Fake.Calls | Should -Contain ('-s emulator-5556 push ' + [System.IO.Path]::Join($w.Staging, '2026', '05', "it's & more.JPG") + " /sdcard/DCIM/Camera/2026_05_it's & more.JPG")
        Get-Line $w 'pushed.list' | Should -Be $rels
        Get-Line $w 'device.id' | Should -Be @('a1b2c3d4e5f60718')
        $log | Should -Match (ConvertTo-LogPattern 'staged 3 media file(s), ledger 0; new since last run: 3; pushed 3 (cap 1000), failed 0, evicted-skipped 0, empty-skipped 0')
        $log | Should -Match (ConvertTo-LogPattern 'media scan requested for 3 file(s)')
        $log | Should -Match (ConvertTo-LogPattern 'MediaStore indexed 3 file(s) (2 image, 1 video) under /sdcard/DCIM/Camera')
        $log | Should -Match (ConvertTo-LogPattern 'Google Photos foregrounded')
        $Fake.Phases | Should -Contain 'pushing 0 of 3 to the emulator'
        $Fake.Phases | Should -Contain 'indexing in MediaStore: 3 of 3'
        # Verified on a host copy of the WAL-mode DB, all three files pulled, the device copy removed.
        $log | Should -Match (ConvertTo-LogPattern 'device has no sqlite3 - verifying uploads by copying the Photos DB to the host')
        @($Fake.Calls | Where-Object { $_ -like '-s emulator-5556 pull /sdcard/gphotos0.db*' }).Count | Should -Be 3
        @(Get-ChildItem -LiteralPath $Fake.Sdcard).Count | Should -Be 0
        $log | Should -Match (ConvertTo-LogPattern 'UPLOAD CONFIRMED: 3 file(s) backed up to Google Photos')
        Test-Path (Get-StatePath $w 'last-upload-confirmed') | Should -BeTrue
        @(Get-Line $w 'upload-status')[0] | Should -Match '^3 3 0 \d+$'
        # Pruned, and ONLY the prune fed the reclaim: the three staged paths, '/'-separated.
        @(Get-ChildItem -LiteralPath $Fake.Dcim).Count | Should -Be 0
        $log | Should -Match (ConvertTo-LogPattern 'reclaimed emulator space: removed 3 confirmed file(s) from DCIM (0 remain on device)')
        $Fake.ReclaimCalls.Count | Should -Be 1
        $Fake.ReclaimCalls[0].Pending | Should -Be $rels
        $a = $Fake.ReclaimCalls[0].Args
        ($a[0..4] -join '|') | Should -BeExactly ('--username|someone@example.invalid|--staging|' + $w.Staging + '|--pending')
        ($a[6..9] -join '|') | Should -BeExactly ('--out|' + $a[7] + '|--keep-days|7')
        $a.Count | Should -Be 10
        $Fake.Phases | Should -Contain 'reclaiming iCloud space: 3 confirmed file(s)'
        Get-Line $w 'reclaimed.list' | Should -Be $rels
        @(Get-Line $w 'reclaim-pending.list').Count | Should -Be 0
        $log | Should -Match (ConvertTo-LogPattern 'iCloud reclaim: 3 confirmed file(s) pending (icloudpd library 1.32.3)')
        $log | Should -Match (ConvertTo-LogPattern '; 0 still pending')
        # Drained and confirmed: the emulator is stopped, gracefully.
        $Fake.EmuKills | Should -Be 1
        $log | Should -Match (ConvertTo-LogPattern 'emulator stopped: device drained, batch confirmed')
        Test-Path (Get-StatePath $w 'device-busy') | Should -BeFalse
        $log | Should -Match (ConvertTo-LogPattern 'done (3 pushed this run)')
        Test-Path (Get-StatePath $w 'phase') | Should -BeFalse
        Test-Path (Get-StatePath $w 'sync.lock') | Should -BeFalse
        Assert-CleanFake
    }

    It '(3b) verifies through the device sqlite3 when the image has one' {
        $w = New-SyncWorld
        $Fake.HasSqlite = $true
        $Fake.Downloads.Add('2026/05/IMG_0001.HEIC')
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Not -Match 'device has no sqlite3'
        $log | Should -Match (ConvertTo-LogPattern 'UPLOAD CONFIRMED: 1 file(s) backed up to Google Photos')
        $Fake.Calls | Should -Contain "-s emulator-5556 shell su -c 'sqlite3 /data/data/com.google.android.apps.photos/databases/gphotos0.db < /data/local/tmp/avd-query.sql' 2>/dev/null"
        @($Fake.Calls | Where-Object { $_ -like '* pull *' }).Count | Should -Be 0
        Assert-CleanFake
    }

    It '(4) deletes the stamp and reclaims nothing when only 2 of 3 confirm by the deadline' {
        $w = New-SyncWorld -Environment @{ UPLOAD_WAIT = '0' }
        Set-Stamp $w
        Set-AvdLine -Path (Get-StatePath $w 'reclaimed.list') -Line @('2025/01/OLD.HEIC')
        foreach ($r in '2026/05/IMG_0001.HEIC', '2026/05/IMG_0003.HEIC', '2026/06/IMG_0002.MOV') { $Fake.Downloads.Add($r) }
        [void]$Fake.NotUploaded.Add('2026_06_IMG_0002.MOV')
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'upload in progress: 2/3 confirmed (3 registered by Photos), 0 failed')
        $Fake.Phases | Should -Contain 'verifying uploads: 2 of 3 confirmed'
        $log | Should -Match (ConvertTo-LogPattern 'WARNING: upload NOT complete - 2 of 3 done (3 registered by Photos), 1 pending, 0 permanently failed')
        Test-Path (Get-StatePath $w 'last-upload-confirmed') | Should -BeFalse
        @(Get-Line $w 'upload-status')[0] | Should -Match '^2 3 0 \d+$'
        # The two confirmed files are pruned and pending, but the gate holds.
        Get-Line $w 'reclaim-pending.list' | Should -Be @('2026/05/IMG_0001.HEIC', '2026/05/IMG_0003.HEIC')
        $log | Should -Match (ConvertTo-LogPattern 'iCloud reclaim SKIPPED: the last verify did not confirm its batch, so nothing is deleted (2 confirmed file(s) stay pending)')
        $Fake.ReclaimCalls.Count | Should -Be 0
        Get-Line $w 'reclaimed.list' | Should -Be @('2025/01/OLD.HEIC')
        # A batch is still on the device: it stays up and busy.
        Test-Path (Get-StatePath $w 'device-busy') | Should -BeTrue
        $Fake.EmuKills | Should -Be 0
        $log | Should -Match (ConvertTo-LogPattern 'done (3 pushed this run)')
        Assert-CleanFake
    }

    It '(5) treats a short push as failed: not in the ledger, the device copy removed' {
        $w = New-SyncWorld
        foreach ($r in '2026/05/IMG_0001.HEIC', "2026/05/it's & more.JPG", '2026/06/IMG_0002.MOV') { $Fake.Downloads.Add($r) }
        [void]$Fake.ShortPush.Add("2026_05_it's & more.JPG")
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern "WARNING: short push, not recorded: 2026/05/it's & more.JPG (staged 100 bytes, on device 93)")
        $Fake.Calls | Should -Contain "-s emulator-5556 shell rm -f '/sdcard/DCIM/Camera/2026_05_it'\''s & more.JPG'"
        Get-Line $w 'pushed.list' | Should -Be @('2026/05/IMG_0001.HEIC', '2026/06/IMG_0002.MOV')
        $log | Should -Match (ConvertTo-LogPattern 'pushed 2 (cap 1000), failed 1, evicted-skipped 0, empty-skipped 0')
        $log | Should -Match (ConvertTo-LogPattern '1 left for the next run')
        $log | Should -Match (ConvertTo-LogPattern 'UPLOAD CONFIRMED: 2 file(s) backed up to Google Photos')
        $Fake.ReclaimCalls[0].Pending | Should -Be @('2026/05/IMG_0001.HEIC', '2026/06/IMG_0002.MOV')
        Assert-CleanFake
    }

    It '(6) resets the ledger for a recreated emulator and pushes everything again' {
        $w = New-SyncWorld
        $rels = @('2026/05/IMG_0001.HEIC', '2026/05/IMG_0003.HEIC', '2026/06/IMG_0002.MOV')
        Add-Staged $w $rels
        Set-AvdLine -Path (Get-StatePath $w 'pushed.list') -Line $rels
        Write-AvdTextFile -Path (Get-StatePath $w 'device.id') -Text "0badc0ffee000000`n"
        Set-Stamp $w
        $Fake.Running = $true
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'new device detected (android_id 0badc0ffee000000 -> a1b2c3d4e5f60718) - resetting ledger; everything will be re-pushed')
        $Fake.EmuStarts.Count | Should -Be 0
        $Fake.Pushes.Count | Should -Be 3
        Get-Line $w 'pushed.list' | Should -Be $rels
        Get-Line $w 'device.id' | Should -Be @('a1b2c3d4e5f60718')
        $log | Should -Match (ConvertTo-LogPattern 'staged 3 media file(s), ledger 3; new since last run: 3; pushed 3')
        Assert-CleanFake
    }

    It '(7) fails loudly, naming the fix, when the staging directory refuses the listing' {
        $w = New-SyncWorld
        Set-Stamp $w
        Mock -ModuleName AvdPhotos Get-AvdStagingFileEntry { throw [System.UnauthorizedAccessException]::new("Access to the path 'C:\Users\me\My Drive\x' is denied.") }
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 1
        $phase = [System.IO.File]::ReadAllText((Get-StatePath $w 'phase'))
        $phase | Should -BeExactly "failed: no access to the staging directory (Access to the path 'C:\Users\me\My Drive\x' is denied.) - see Staging in the README`n"
        $phase | Should -Not -Match 'app bundle|macOS|TCC'
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'FAILED: no access to the staging directory (')
        $log | Should -Not -Match 'done \('
        $Fake.EmuStarts.Count | Should -Be 0
        $Fake.Calls.Count | Should -Be 0
        Test-Path (Get-StatePath $w 'sync.lock') | Should -BeFalse
    }

    It '(9) leaves a running sync alone: no lock, phase or icloudpd touched' {
        $w = New-SyncWorld
        $lock = Get-StatePath $w 'sync.lock'
        (Enter-AvdLock -Path $lock).Status | Should -Be 'held'
        try {
            $before = [System.IO.File]::ReadAllText((Join-Path $lock 'started'))
            Write-AvdTextFile -Path (Get-StatePath $w 'phase') -Text "pushing 25 of 100 to the emulator`n"
            Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
            (Get-SyncLog $w) | Should -Match (ConvertTo-LogPattern "another sync run is in progress (pid $PID) - skipping")
            (Get-Content -LiteralPath (Join-Path $lock 'pid') -Raw).Trim() | Should -Be "$PID"
            [System.IO.File]::ReadAllText((Join-Path $lock 'started')) | Should -BeExactly $before
            [System.IO.File]::ReadAllText((Get-StatePath $w 'phase')) | Should -BeExactly "pushing 25 of 100 to the emulator`n"
            $Fake.IcloudpdArgs | Should -BeNullOrEmpty
            $Fake.Calls.Count | Should -Be 0
        } finally {
            Exit-AvdLock -Path $lock
        }
    }

    It 're-announces the files Photos has not registered, on the third poll' {
        $w = New-SyncWorld
        foreach ($r in '2026/05/IMG_0001.HEIC', '2026/05/IMG_0003.HEIC', '2026/06/IMG_0002.MOV') { $Fake.Downloads.Add($r) }
        [void]$Fake.Unregistered.Add('2026_05_IMG_0003.HEIC')
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'Google Photos has not registered 1 of 3 device file(s) - touching and rescanning them')
        @($Fake.Touched) | Should -Be @('2026_05_IMG_0003.HEIC')
        $Fake.Phases | Should -Contain 're-announcing to Photos: 1 of 1'
        $log | Should -Match (ConvertTo-LogPattern 'UPLOAD CONFIRMED: 3 file(s) backed up to Google Photos')
        Assert-CleanFake
    }

    It 'removes an empty device file and queues its staged path again' {
        $w = New-SyncWorld
        Add-Staged $w '2026/05/IMG_0001.HEIC', '2026/05/EMPTY.HEIC'
        Set-AvdLine -Path (Get-StatePath $w 'pushed.list') -Line @('2026/05/EMPTY.HEIC', '2026/05/IMG_0001.HEIC')
        $Fake.Running = $true
        [System.IO.File]::WriteAllText((Join-Path $Fake.Dcim '2026_05_EMPTY.HEIC'), '')
        [System.IO.File]::WriteAllText((Join-Path $Fake.Dcim '2026_05_IMG_0001.HEIC'), ('x' * 100))
        [void]$Fake.Indexed.Add('2026_05_EMPTY.HEIC'); [void]$Fake.Indexed.Add('2026_05_IMG_0001.HEIC')
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern '1 empty device file(s) removed and queued again: 2026_05_EMPTY.HEIC ')
        Test-Path (Join-Path $Fake.Dcim '2026_05_EMPTY.HEIC') | Should -BeFalse
        Get-Line $w 'pushed.list' | Should -Be @('2026/05/IMG_0001.HEIC')
        $log | Should -Match (ConvertTo-LogPattern 'UPLOAD CONFIRMED: 1 file(s) backed up to Google Photos')
        $Fake.ReclaimCalls[0].Pending | Should -Be @('2026/05/IMG_0001.HEIC')
        Assert-CleanFake
    }

    It 'skips a cloud placeholder and an empty staged file, pushing neither' {
        $w = New-SyncWorld
        Add-Staged $w '2026/05/IMG_0001.HEIC', '2026/05/STREAMED.HEIC'
        Add-Staged $w '2026/05/EMPTY.HEIC' -Bytes 0
        # RECALL_ON_DATA_ACCESS | ARCHIVE, what Google Drive streaming reports.
        Mock -ModuleName AvdPhotos Get-AvdLocalFileInfo { [pscustomobject]@{ Exists = $true; Attributes = 0x00400020L; Length = 5000000L } } -ParameterFilter { $Path -like '*STREAMED.HEIC' }
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern '  empty staged file skipped (delete it to let icloudpd fetch it again): 2026/05/EMPTY.HEIC')
        $log | Should -Match (ConvertTo-LogPattern 'pushed 1 (cap 1000), failed 0, evicted-skipped 1, empty-skipped 1')
        @($Fake.Pushes) | Should -Be @('/sdcard/DCIM/Camera/2026_05_IMG_0001.HEIC')
        Assert-CleanFake
    }

    It 'fails, not skips, when a prerequisite is missing' {
        $w = New-SyncWorld -Environment @{ ICLOUD_USERNAME = '' }
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 1
        [System.IO.File]::ReadAllText((Get-StatePath $w 'phase')) | Should -Match '^failed: ICLOUD_USERNAME unset in '
        $w = New-SyncWorld
        Remove-Item -LiteralPath (Join-Path $w.Config.AVD_HOME 'gphotos-tablet.avd') -Recurse
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 1
        [System.IO.File]::ReadAllText((Get-StatePath $w 'phase')) | Should -BeExactly "failed: no gphotos-tablet emulator - run avd-photos-setup`n"
        (Get-SyncLog $w) | Should -Match (ConvertTo-LogPattern 'FAILED: no gphotos-tablet emulator - run avd-photos-setup')
    }

    It 'fails on a crashed icloudpd, naming the NTSTATUS' {
        $w = New-SyncWorld
        $Fake.IcloudpdExit = -1073741819
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 1
        [System.IO.File]::ReadAllText((Get-StatePath $w 'phase')) | Should -BeExactly "failed: icloudpd crashed (0xC0000005) - the binary is broken, not the account`n"
        (Get-SyncLog $w) | Should -Match (ConvertTo-LogPattern 'reinstall it (uv tool install icloudpd).')
        $Fake.Calls.Count | Should -Be 0
    }

    It 'continues with a login hint when icloudpd has no saved session, judged on the last 40 lines only' {
        $w = New-SyncWorld
        Add-Staged $w '2026/05/IMG_0001.HEIC'
        Set-AvdLine -Path (Get-StatePath $w 'pushed.list') -Line @('2026/05/IMG_0001.HEIC')
        Set-Stamp $w
        $Fake.IcloudpdExit = 1
        $Fake.IcloudpdErr = "Traceback (most recent call last):`nicloudpd.exceptions: None of providers gave password`n"
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        $log = Get-SyncLog $w
        $log | Should -Match (ConvertTo-LogPattern 'icloudpd has NO SAVED SESSION - it needs a one-time interactive login:')
        $log | Should -Match (ConvertTo-LogPattern "    icloudpd --username someone@example.invalid --directory `"$($w.Staging)`" --recent 1")
        $log | Should -Match (ConvertTo-LogPattern 'None of providers gave password')
        $log | Should -Match (ConvertTo-LogPattern 'done (0 pushed this run)')

        $w = New-SyncWorld
        $Fake.IcloudpdExit = 1
        $Fake.IcloudpdOut = "EOFError at the start`n" + ((1..45 | ForEach-Object { "INFO line $_`n" }) -join '')
        Invoke-AvdPhotosSync -Config $w.Config | Out-Null
        (Get-SyncLog $w) | Should -Match (ConvertTo-LogPattern "icloudpd rc=1 (often just 'no new items' or needs re-auth) - continuing")
        (Get-SyncLog $w) | Should -Not -Match 'NO SAVED SESSION'
    }

    It 'stops at PUSH_CAP and leaves the rest for the next run' {
        $w = New-SyncWorld -Environment @{ PUSH_CAP = '2' }
        foreach ($r in '2026/05/A.HEIC', '2026/05/B.HEIC', '2026/05/C.HEIC') { $Fake.Downloads.Add($r) }
        Invoke-AvdPhotosSync -Config $w.Config | Should -Be 0
        Get-Line $w 'pushed.list' | Should -Be @('2026/05/A.HEIC', '2026/05/B.HEIC')
        $Fake.Phases | Should -Contain 'pushing 0 of 2 to the emulator'
        (Get-SyncLog $w) | Should -Match (ConvertTo-LogPattern '1 left for the next run')
    }
}

Describe 'the iCloud reclaim' {
    BeforeEach {
        Register-FakeDeviceMock
        $script:W = New-SyncWorld
        Set-AvdLine -Path (Get-StatePath $W 'reclaim-pending.list') -Line @('2026/05/B.HEIC', '2026/05/A.HEIC', '2026/05/A.HEIC', '2025/01/GONE.HEIC')
        Set-AvdLine -Path (Get-StatePath $W 'reclaimed.list') -Line @('2025/01/GONE.HEIC')
        $script:Ctx = New-AvdSyncContext -Config $W.Config
        $Ctx.Icloudpd = $Fake.IcloudpdPath
    }

    It 'deletes nothing without the confirmation stamp' {
        Invoke-AvdReclaim $Ctx
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'iCloud reclaim SKIPPED: the last verify did not confirm its batch, so nothing is deleted (4 confirmed file(s) stay pending)')
        $Fake.ReclaimCalls.Count | Should -Be 0
        Get-Line $W 'reclaimed.list' | Should -Be @('2025/01/GONE.HEIC')
    }

    It 'hands over pending minus reclaimed, and records what it reclaimed' {
        Set-Stamp $W
        Invoke-AvdReclaim $Ctx
        $Fake.ReclaimCalls[0].Pending | Should -Be @('2026/05/A.HEIC', '2026/05/B.HEIC')
        Get-Line $W 'reclaimed.list' | Should -Be @('2025/01/GONE.HEIC', '2026/05/A.HEIC', '2026/05/B.HEIC')
        @(Get-Line $W 'reclaim-pending.list').Count | Should -Be 0
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'iCloud reclaim: {"pending":2,"walked":40,"deleted":2,"held":0,"kept":0,"not_found":0,"errors":0,"dry_run":false}; 0 still pending')
        (Get-Content -LiteralPath $Ctx.ReclaimLog -Raw) | Should -Match 'reclaim log line'
    }

    It 'passes --keep-days only when KEEP_ICLOUD_DAYS is not 0' {
        Set-Stamp $W
        Invoke-AvdReclaim $Ctx
        $Fake.ReclaimCalls[0].Args | Should -Contain '--keep-days'
        $w0 = New-SyncWorld -Environment @{ KEEP_ICLOUD_DAYS = '0' }
        Set-AvdLine -Path (Get-StatePath $w0 'reclaim-pending.list') -Line @('2026/05/A.HEIC')
        Set-Stamp $w0
        $c0 = New-AvdSyncContext -Config $w0.Config
        $c0.Icloudpd = $Fake.IcloudpdPath
        Invoke-AvdReclaim $c0
        $Fake.ReclaimCalls[0].Args | Should -Not -Contain '--keep-days'
        $Fake.ReclaimCalls[0].Args | Should -Not -Contain '--dry-run'
    }

    It 'changes no ledger on a dry run, even when the reclaim writes --out anyway' {
        $d = New-SyncWorld -Unarmed
        $Fake.ReclaimOutOnDry = $true
        Set-AvdLine -Path (Get-StatePath $d 'reclaim-pending.list') -Line @('2026/05/A.HEIC')
        Invoke-AvdPhotosSync -Config $d.Config -ReclaimDryRun | Should -Be 0
        $log = Get-SyncLog $d
        $log | Should -Match (ConvertTo-LogPattern 'reclaim DRY RUN (user someone@example.invalid)')
        $log | Should -Match (ConvertTo-LogPattern 'iCloud reclaim (DRY RUN): 1 confirmed file(s) pending (icloudpd library 1.32.3)')
        $log | Should -Match (ConvertTo-LogPattern '  nothing was deleted and no ledger changed - see ')
        $log | Should -Match (ConvertTo-LogPattern 'dry run finished')
        $log | Should -Not -Match 'done \('
        $Fake.ReclaimCalls[0].Args | Should -Contain '--dry-run'
        Test-Path (Get-StatePath $d 'reclaimed.list') | Should -BeFalse
        Get-Line $d 'reclaim-pending.list' | Should -Be @('2026/05/A.HEIC')
        $Fake.Phases | Should -Contain 'dry run: checking what would leave iCloud'
        Test-Path (Get-StatePath $d 'phase') | Should -BeFalse
        $Fake.Calls.Count | Should -Be 0
        $Fake.IcloudpdArgs | Should -BeNullOrEmpty
    }

    It 'records nothing when the reclaim reports dry_run without being asked' {
        Set-Stamp $W
        $Fake.ReclaimStats = '{"pending":2,"walked":40,"deleted":2,"held":0,"kept":0,"not_found":0,"errors":0,"dry_run":true}'
        Invoke-AvdReclaim $Ctx
        $log = Get-SyncLog $W
        $log | Should -Match (ConvertTo-LogPattern 'WARNING: that run reported dry_run without being asked to - nothing was recorded')
        Get-Line $W 'reclaimed.list' | Should -Be @('2025/01/GONE.HEIC')
        @(Get-Line $W 'reclaim-pending.list').Count | Should -Be 4
    }

    It 'keeps everything on an authentication failure (rc 2) and a timeout (124)' {
        Set-Stamp $W
        $Fake.ReclaimExit = 2
        $Fake.ReclaimOut = @()
        $Fake.ReclaimStats = ''
        Invoke-AvdReclaim $Ctx
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'WARNING: iCloud reclaim could not authenticate - icloudpd needs its one-time interactive login; 2 file(s) stay in iCloud')
        $Fake.ReclaimExit = 124
        Invoke-AvdReclaim $Ctx
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'WARNING: iCloud reclaim timed out after 1800s - 2 file(s) stay in iCloud')
        $Fake.ReclaimExit = 3
        Invoke-AvdReclaim $Ctx
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'WARNING: iCloud reclaim exited 3 - see ')
        Get-Line $W 'reclaimed.list' | Should -Be @('2025/01/GONE.HEIC')
        @(Get-Line $W 'reclaim-pending.list').Count | Should -Be 4
    }

    It 'records a partial run (rc 1) and warns when nothing was found' {
        Set-Stamp $W
        $Fake.ReclaimExit = 1
        $Fake.ReclaimOut = @('2026/05/A.HEIC')
        Invoke-AvdReclaim $Ctx
        Get-Line $W 'reclaim-pending.list' | Should -Be @('2026/05/B.HEIC')
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'WARNING: some iCloud deletions failed - see ')
        $Fake.ReclaimExit = 0
        $Fake.ReclaimOut = $null
        $Fake.ReclaimStats = '{"pending":1,"walked":19,"deleted":0,"held":0,"kept":0,"not_found":1,"errors":0,"dry_run":false}'
        Invoke-AvdReclaim $Ctx
        (Get-SyncLog $W) | Should -Match (ConvertTo-LogPattern 'WARNING: none of the pending file(s) was found in iCloud')
        @(Get-Line $W 'reclaim-pending.list').Count | Should -Be 0
    }

    It 'reclaims on a quiet tick only with DELETE_FROM_ICLOUD=1 or -Offload' {
        $q = New-SyncWorld -Environment @{ DELETE_FROM_ICLOUD = '0' }
        Add-Staged $q '2026/05/A.HEIC'
        Set-AvdLine -Path (Get-StatePath $q 'pushed.list') -Line @('2026/05/A.HEIC')
        Set-AvdLine -Path (Get-StatePath $q 'reclaim-pending.list') -Line @('2026/05/A.HEIC')
        Set-Stamp $q
        Invoke-AvdPhotosSync -Config $q.Config | Should -Be 0
        $Fake.ReclaimCalls.Count | Should -Be 0
        (Get-SyncLog $q) | Should -Match (ConvertTo-LogPattern 'iCloud reclaim OFF (DELETE_FROM_ICLOUD=0 in ')
        Invoke-AvdPhotosSync -Config $q.Config -Offload | Should -Be 0
        (Get-SyncLog $q) | Should -Match (ConvertTo-LogPattern 'manual offload requested (--offload)')
        $Fake.ReclaimCalls.Count | Should -Be 1
        Get-Line $q 'reclaimed.list' | Should -Be @('2026/05/A.HEIC')
    }
}

Describe 'the commands' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
        # Run a command in a child pwsh whose environment points everything at a
        # scratch tree, set INSIDE the child so this process's environment is
        # never touched. The AVD and icloudpd names exist nowhere, so no path
        # through the command can reach a real emulator, adb or Apple account.
        function Invoke-ScratchCommand {
            param([string]$Command, [string[]]$Switch = @())
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 10))
            $vars = [ordered]@{
                HOME = (Join-Path $root 'home'); USERPROFILE = (Join-Path $root 'home')
                APPDATA = (Join-Path $root 'appdata'); LOCALAPPDATA = (Join-Path $root 'localappdata')
                AVD_PHOTOS_CONFIG_DIR = (Join-Path $root 'config'); AVD_PHOTOS_STATE_DIR = (Join-Path $root 'state')
                AVD_PHOTOS_LOG_DIR = (Join-Path $root 'logs'); STAGING = (Join-Path $root 'staging')
                AVD_SDK_ROOT = (Join-Path $root 'sdk'); ANDROID_AVD_HOME = (Join-Path $root 'avd')
                AVD_NAME = 'avd-test-no-such-avd'; ICLOUDPD = 'avd-test-no-such-icloudpd'
            }
            $sets = ($vars.GetEnumerator() | ForEach-Object { "`$env:$($_.Key) = '$($_.Value)'" }) -join '; '
            $script = Join-Path $RepoRoot 'windows' 'bin' $Command
            $line = "$sets; & '$script' $($Switch -join ' '); exit `$LASTEXITCODE"
            $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $line) -TimeoutSec 120
            $log = Join-Path $root 'logs' 'sync.log'
            [pscustomobject]@{
                ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr
                Log      = if (Test-Path -LiteralPath $log) { [System.IO.File]::ReadAllText($log) } else { '' }
                Phase    = Join-Path $root 'state' 'phase'
            }
        }
    }
    It 'avd-photos-sync.ps1 runs the sync and exits with its code' {
        $r = Invoke-ScratchCommand 'avd-photos-sync.ps1'
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        $r.Log | Should -Match 'not armed \(no .*ENABLED\) - skipping'
    }
    It 'avd-photos-offload.ps1 forces the reclaim on' {
        $r = Invoke-ScratchCommand 'avd-photos-offload.ps1'
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        $r.Log | Should -Match (ConvertTo-LogPattern 'manual offload requested (--offload)')
    }
    It 'avd-photos-offload.ps1 -DryRun runs the reclaim dry run, which needs no arming and fails loudly without icloudpd' {
        $r = Invoke-ScratchCommand 'avd-photos-offload.ps1' -Switch @('-DryRun')
        $r.ExitCode | Should -Be 1
        $r.Log | Should -Match (ConvertTo-LogPattern 'FAILED: icloudpd (avd-test-no-such-icloudpd) missing from PATH')
        $r.Log | Should -Not -Match 'not armed'
        [System.IO.File]::ReadAllText($r.Phase) | Should -BeExactly "failed: icloudpd (avd-test-no-such-icloudpd) missing from PATH`n"
    }
}
