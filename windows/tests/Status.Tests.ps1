#Requires -Version 7.2
# The status collector: the JSON's shape against the two things that fix it
# (the macOS printf it ports and the Swift parse() that reads it), and each
# field against a scratch state tree.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MacStatus = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'bin' 'avd-photos-status'))
    $script:Swift = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'Sources' 'main.swift'))
    $script:SavedPath = $env:PATH

    function New-StatusWorld {
        param([hashtable]$Environment = @{})
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 10))
        $e = @{
            HOME                  = (Join-Path $root 'home')
            USERPROFILE           = (Join-Path $root 'home')
            AVD_PHOTOS_CONFIG_DIR = (Join-Path $root 'config')
            AVD_PHOTOS_STATE_DIR  = (Join-Path $root 'state')
            AVD_PHOTOS_LOG_DIR    = (Join-Path $root 'logs')
            STAGING               = (Join-Path $root 'staging')
            AVD_SDK_ROOT          = (Join-Path $root 'sdk')
        }
        foreach ($k in $Environment.Keys) { $e[$k] = $Environment[$k] }
        $cfg = Get-AvdConfig -Environment $e -Platform (Get-AvdPlatform) -NoCreate
        foreach ($d in $cfg.CONFIG_DIR, $cfg.STATE_DIR, $cfg.LOG_DIR) { $null = [System.IO.Directory]::CreateDirectory($d) }
        [pscustomobject]@{ Config = $cfg; State = $cfg.STATE_DIR; Staging = $cfg.STAGING; Log = (Join-Path $cfg.LOG_DIR 'sync.log') }
    }
    function Get-Status { param($World) Get-AvdPhotosStatus -Config $World.Config | ConvertFrom-Json }
    function Set-StateFile { param($World, [string]$Name, [string]$Text) [System.IO.File]::WriteAllText((Join-Path $World.State $Name), $Text) }
    function Set-FileEpoch { param([string]$Path, [long]$Epoch) [System.IO.File]::SetLastWriteTimeUtc($Path, [System.DateTimeOffset]::FromUnixTimeSeconds($Epoch).UtcDateTime) }
    function Get-Now { [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    function Add-StagedFile {
        param($World, [string[]]$Rel)
        foreach ($r in $Rel) {
            $full = [System.IO.Path]::Join($World.Staging, $r.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [System.IO.File]::WriteAllText($full, 'x')
        }
    }
}

AfterAll { $env:PATH = $script:SavedPath }

Describe 'the JSON shape' {
    BeforeEach { Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $false } }
    It 'has the fields of bin/avd-photos-status, in its order' {
        $fmt = [regex]::Match($MacStatus, 'printf ''(\{"backup"[^'']*)\\n''').Groups[1].Value
        $fmt | Should -Not -BeNullOrEmpty
        $macKeys = @([regex]::Matches($fmt, '"(\w+)":') | ForEach-Object { $_.Groups[1].Value })
        $json = Get-AvdPhotosStatus -Config (New-StatusWorld).Config
        $winKeys = @([regex]::Matches($json, '"(\w+)":') | ForEach-Object { $_.Groups[1].Value })
        $macKeys.Count | Should -Be 18
        $winKeys | Should -Be $macKeys
    }
    It 'gives every field the type the Swift parse() reads, and ts a number' {
        $json = Get-AvdPhotosStatus -Config (New-StatusWorld).Config
        $typed = @([regex]::Matches($Swift, 'b\["(\w+)"\] as\? (Bool|Int|String)'))
        $typed.Count | Should -Be 16
        foreach ($t in $typed) {
            $k = $t.Groups[1].Value
            $pattern = switch ($t.Groups[2].Value) {
                'Bool' { "`"$k`":(true|false)[,}]" }
                'Int' { "`"$k`":-?[0-9]+[,}]" }
                'String' { "`"$k`":`"" }
            }
            $json | Should -Match $pattern -Because $k
        }
        $json | Should -Match '"ts":[0-9]+}$'
    }
    It 'is one compact line of ASCII' {
        $w = New-StatusWorld
        Set-StateFile $w 'phase' ("failed: no access to C:\Users\Jos" + [char]0xE9 + "\Pictures`n")
        $json = Get-AvdPhotosStatus -Config $w.Config
        $json | Should -Not -Match "`n"
        [System.Text.Encoding]::UTF8.GetByteCount($json) | Should -Be $json.Length
        ($json | ConvertFrom-Json).backup.phase | Should -BeExactly ('failed: no access to C:UsersJos' + [char]0xE9 + 'Pictures')
    }
}

Describe 'the fields' {
    BeforeEach { Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $false } }

    It 'reports an empty world with the documented defaults' {
        $w = New-StatusWorld
        $s = Get-Status $w
        $b = $s.backup
        $b.armed | Should -BeFalse
        $b.emulator | Should -BeFalse
        $b.staged | Should -Be 0
        $b.remaining | Should -Be 0
        $b.on_device | Should -Be 0
        $b.uploaded | Should -Be 0
        $b.queued | Should -Be 0
        $b.failed | Should -Be 0
        $b.upload_age | Should -Be -1
        $b.confirmed | Should -BeFalse
        $b.confirmed_age | Should -Be -1
        $b.last_run_age | Should -Be -1
        $b.running | Should -BeFalse
        $b.phase | Should -BeExactly ''
        $b.reclaimed | Should -Be 0
        $b.reclaim_pending | Should -Be 0
        [math]::Abs($s.ts - (Get-Now)) | Should -BeLessThan 5
    }

    It 'is armed exactly when the sentinel exists' {
        $w = New-StatusWorld
        [System.IO.File]::WriteAllText($w.Config.SENTINEL, '')
        (Get-Status $w).backup.armed | Should -BeTrue
    }

    It 'counts staged files as find ! -name ".*" does, and the backlog against the ledger' {
        $w = New-StatusWorld
        Add-StagedFile $w '2026/05/a.jpg', '2026/05/b/c.HEIC', 'notes.txt', '.DS_Store', '.thumbs/t.jpg', '2026/05/.x.jpg'
        Set-StateFile $w 'pushed.list' "2026/05/a.jpg`n`n"
        $b = (Get-Status $w).backup
        $b.staged | Should -Be 4
        $b.remaining | Should -Be 3
        Set-StateFile $w 'pushed.list' (((1..10) | ForEach-Object { "p$_" }) -join "`n")
        (Get-Status $w).backup.remaining | Should -Be 0
    }

    It 'does not count Hidden or System files (Thumbs.db, desktop.ini) or dotfiles' {
        Test-AvdStagedCountable -Name 'IMG_0001.HEIC' -Attributes ([long][System.IO.FileAttributes]::Archive) | Should -BeTrue
        Test-AvdStagedCountable -Name 'IMG_0001.HEIC' | Should -BeTrue
        Test-AvdStagedCountable -Name 'Thumbs.db' -Attributes ([long]([System.IO.FileAttributes]'Hidden, System, Archive')) | Should -BeFalse
        Test-AvdStagedCountable -Name 'desktop.ini' -Attributes ([long]([System.IO.FileAttributes]'Hidden, System')) | Should -BeFalse
        Test-AvdStagedCountable -Name 'x.jpg' -Attributes ([long][System.IO.FileAttributes]::Hidden) | Should -BeFalse
        Test-AvdStagedCountable -Name 'x.jpg' -Attributes ([long][System.IO.FileAttributes]::System) | Should -BeFalse
        Test-AvdStagedCountable -Name '.DS_Store' | Should -BeFalse
    }

    It 'does not count Explorer''s Thumbs.db and desktop.ini in a real tree' -Tag 'WindowsOnly' {
        $w = New-StatusWorld
        Add-StagedFile $w '2026/05/a.jpg', '2026/05/Thumbs.db', 'desktop.ini'
        foreach ($f in (Join-Path $w.Staging '2026' '05' 'Thumbs.db'), (Join-Path $w.Staging 'desktop.ini')) {
            [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]'Hidden, System')
        }
        (Get-Status $w).backup.staged | Should -Be 1
    }

    It 'honours upload-status only while its stamp is not older than the ledger' {
        $w = New-StatusWorld
        $now = Get-Now
        Set-StateFile $w 'pushed.list' "a`n"
        Set-FileEpoch (Join-Path $w.State 'pushed.list') ($now - 100)
        Set-StateFile $w 'upload-status' "2 5 1 $($now - 50)`n"
        $b = (Get-Status $w).backup
        $b.uploaded | Should -Be 2
        $b.queued | Should -Be 3
        $b.failed | Should -Be 1
        $b.upload_age | Should -BeGreaterOrEqual 50
        $b.upload_age | Should -BeLessThan 60
        Set-FileEpoch (Join-Path $w.State 'pushed.list') ($now - 10)
        $b = (Get-Status $w).backup
        $b.uploaded | Should -Be 0
        $b.queued | Should -Be 0
        $b.failed | Should -Be 0
        $b.upload_age | Should -Be -1
    }

    It 'reports the confirmation stamp and its age' {
        $w = New-StatusWorld
        Set-StateFile $w 'last-upload-confirmed' "$((Get-Now) - 3600)`n"
        $b = (Get-Status $w).backup
        $b.confirmed | Should -BeTrue
        $b.confirmed_age | Should -BeGreaterOrEqual 3600
        $b.confirmed_age | Should -BeLessThan 3610
        Set-StateFile $w 'last-upload-confirmed' ''
        (Get-Status $w).backup.confirmed | Should -BeFalse
    }

    It 'ages the last run by its newest "done (" line, in local time, not by the log''s mtime' {
        $w = New-StatusWorld
        $fmt = { param($ago) [datetime]::Now.AddSeconds(-$ago).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) }
        [System.IO.File]::WriteAllText($w.Log, (
                "$(& $fmt 7200) done (3 pushed this run)`n" +
                "$(& $fmt 600) done (0 pushed this run)`n" +
                "$(& $fmt 60) FAILED: icloudpd (icloudpd) missing from PATH`n"))
        $age = (Get-Status $w).backup.last_run_age
        $age | Should -BeGreaterOrEqual 598
        $age | Should -BeLessThan 610
        # No completed run in the log: its mtime, as macOS falls back.
        [System.IO.File]::WriteAllText($w.Log, "$(& $fmt 60) FAILED: x`n")
        Set-FileEpoch $w.Log ((Get-Now) - 1000)
        $age = (Get-Status $w).backup.last_run_age
        $age | Should -BeGreaterOrEqual 1000
        $age | Should -BeLessThan 1010
    }

    It 'counts what was reclaimed and what is still pending, de-duplicated' {
        $w = New-StatusWorld
        Set-StateFile $w 'reclaimed.list' "2026/05/A.HEIC`n2025/01/Z.HEIC`n"
        Set-StateFile $w 'reclaim-pending.list' "2026/05/B.HEIC`n2026/05/A.HEIC`n2026/05/B.HEIC`n2026/05/C.HEIC`n"
        $b = (Get-Status $w).backup
        $b.reclaimed | Should -Be 2
        $b.reclaim_pending | Should -Be 2
    }

    It 'strips quotes and backslashes from the phase and cuts it to 160 characters' {
        $w = New-StatusWorld
        Set-StateFile $w 'phase' "failed: a `"quoted`" C:\path`nsecond line`n"
        (Get-Status $w).backup.phase | Should -BeExactly 'failed: a quoted C:path'
        Set-StateFile $w 'phase' (('x' * 200) + "`n")
        (Get-Status $w).backup.phase | Should -BeExactly ('x' * 160)
    }

    It 'is running while the sync lock''s owner lives, and then takes the live verify count from the phase' {
        $w = New-StatusWorld
        Set-StateFile $w 'upload-status' "9 9 0 $(Get-Now)`n"
        Set-StateFile $w 'phase' "verifying uploads: 4 of 9 confirmed`n"
        $b = (Get-Status $w).backup
        $b.running | Should -BeFalse
        $b.uploaded | Should -Be 9
        $lock = Join-Path $w.State 'sync.lock'
        (Enter-AvdLock -Path $lock).Status | Should -Be 'held'
        try {
            $b = (Get-Status $w).backup
            $b.running | Should -BeTrue
            $b.phase | Should -BeExactly 'verifying uploads: 4 of 9 confirmed'
            $b.uploaded | Should -Be 4
            $b.queued | Should -Be 5
            $b.upload_age | Should -Be 0
            Set-StateFile $w 'phase' "pushing 25 of 100 to the emulator`n"
            (Get-Status $w).backup.uploaded | Should -Be 9
        } finally {
            Exit-AvdLock -Path $lock
        }
    }
}

Describe 'the on-device count' {
    BeforeEach {
        $script:AdbCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AvdPhotos Invoke-AvdAdb {
            $a = $ArgumentList -join ' '
            $script:AdbCalls.Add("$a @$TimeoutSec")
            $out = switch -Regex ($a) {
                '^devices$' { "List of devices attached`nemulator-5554`tdevice`nemulator-5556`tdevice`n" }
                '^-s emulator-5554 emu avd name$' { "someone-elses-avd`r`nOK`r`n" }
                '^-s emulator-5556 emu avd name$' { "$($script:OurName)`r`nOK`r`n" }
                '^-s emulator-5556 shell ls /sdcard/DCIM/Camera 2>/dev/null \| wc -l$' { "7`r`n" }
                default { '' }
            }
            [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = $out; StdErr = '' }
        }
    }
    It 'lists OUR camera folder, bounded, when the emulator is up' {
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $true }
        $script:OurName = 'gphotos-tablet'
        $b = (Get-Status (New-StatusWorld)).backup
        $b.emulator | Should -BeTrue
        $b.on_device | Should -Be 7
        $AdbCalls | Should -Contain '-s emulator-5556 shell ls /sdcard/DCIM/Camera 2>/dev/null | wc -l @6'
        @($AdbCalls | Where-Object { $_ -like '-s emulator-5554 shell*' }).Count | Should -Be 0
    }
    It 'reports 0 when the running emulator does not answer to our name' {
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $true }
        $script:OurName = 'still-booting'
        (Get-Status (New-StatusWorld)).backup.on_device | Should -Be 0
        @($AdbCalls | Where-Object { $_ -like '* shell *' }).Count | Should -Be 0
    }
    It 'never calls adb when no emulator runs' {
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $false }
        (Get-Status (New-StatusWorld)).backup.on_device | Should -Be 0
        $AdbCalls.Count | Should -Be 0
    }
}

Describe 'avd-photos-status.ps1' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
        # A child pwsh with its environment pointed at a scratch tree from
        # inside, and an AVD name that exists nowhere, so no real emulator or
        # adb is ever consulted.
        function Invoke-StatusCommand {
            param([string]$Root, [string[]]$Switch = @())
            $vars = [ordered]@{
                HOME = (Join-Path $Root 'home'); USERPROFILE = (Join-Path $Root 'home')
                APPDATA = (Join-Path $Root 'appdata'); LOCALAPPDATA = (Join-Path $Root 'localappdata')
                AVD_PHOTOS_CONFIG_DIR = (Join-Path $Root 'config'); AVD_PHOTOS_STATE_DIR = (Join-Path $Root 'state')
                AVD_PHOTOS_LOG_DIR = (Join-Path $Root 'logs'); STAGING = (Join-Path $Root 'staging')
                AVD_SDK_ROOT = (Join-Path $Root 'sdk'); AVD_NAME = 'avd-test-no-such-avd'
            }
            $sets = ($vars.GetEnumerator() | ForEach-Object { "`$env:$($_.Key) = '$($_.Value)'" }) -join '; '
            $script = Join-Path $RepoRoot 'windows' 'bin' 'avd-photos-status.ps1'
            $line = "$sets; & '$script' $($Switch -join ' '); exit `$LASTEXITCODE"
            Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $line) -TimeoutSec 120
        }
    }
    It 'prints the JSON' {
        $root = Join-Path $TestDrive 'cmd1'
        $r = Invoke-StatusCommand -Root $root
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        ($r.StdOut.Trim() | ConvertFrom-Json).backup.armed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'state') | Should -BeFalse -Because 'the collector creates nothing'
    }
    It 'writes the JSON to -OutFile instead, whole, and prints nothing' {
        $root = Join-Path $TestDrive 'cmd2'
        $out = Join-Path $TestDrive 'status-out' 'status.json'
        $r = Invoke-StatusCommand -Root $root -Switch @('-OutFile', "'$out'")
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        $r.StdOut | Should -BeNullOrEmpty
        $text = [System.IO.File]::ReadAllText($out)
        $text | Should -Match '^\{"backup":\{"armed":false,.*\},"ts":[0-9]+\}\n$'
        [System.IO.File]::ReadAllBytes($out)[0] | Should -Be ([byte][char]'{')
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $out)).Count | Should -Be 1
    }
}
