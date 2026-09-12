#Requires -Version 7.2
# The tray's model against Photo Sync.app's (Sources/main.swift): the status
# parse, the derived flags, the ring's state machine, the menu, the formatting
# and the .ico container. All pure, so every case runs on any OS; drawing and
# WinForms are TrayWindows.Tests.ps1, on Windows only.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:HostPath = Join-Path $PSScriptRoot '..' 'bin' 'avd-photos-tray.ps1'
    function New-S { param([hashtable]$P = @{}) New-AvdTrayStatus -Property $P }
    # An armed pipeline with a confirmed, drained ledger: the green state, which
    # each case below then disturbs one field at a time.
    function New-Healthy {
        param([hashtable]$P = @{})
        $base = @{ Armed = $true; Emulator = $false; Staged = 2831; Confirmed = $true; ConfirmedAge = 3600; LastRunAge = 900; UploadAge = 42; Uploaded = 377 }
        foreach ($k in $P.Keys) { $base[$k] = $P[$k] }
        New-AvdTrayStatus -Property $base
    }
    function Get-State { param($S, [bool]$Sick = $false) Get-AvdTrayState -Stats $S -CollectorSick $Sick }
    function Get-Menu {
        param($S, [string]$Err, [bool]$Sick = $false, [bool]$Offloading = $false, [bool]$Sync = $true, [bool]$OpenAvd = $false)
        Get-AvdTrayMenu -Stats $S -LastError $Err -CollectorSick $Sick -Offloading $Offloading -SyncAvailable $Sync -OpenAvdAvailable $OpenAvd
    }
    function Get-Note { param($S, [string]$Err, [bool]$Sick = $false) Get-AvdTrayStatusNote -Stats $S -LastError $Err -CollectorSick $Sick }
    function Get-Mono { param($Menu, [string]$Label) @($Menu | Where-Object { $_.Kind -eq 'mono' -and $_.Label -eq $Label }) }
    # The printf in bin/avd-photos-status, with the values of a live verify pass.
    $script:RealJson = '{"backup":{"armed":true,"emulator":true,"staged":2831,"remaining":0,"on_device":377,"uploaded":120,"queued":257,"failed":0,"upload_age":0,"confirmed":true,"confirmed_age":3600,"last_run_age":900,"running":true,"phase":"verifying uploads: 120 of 377 confirmed","reclaimed":1500,"reclaim_pending":12},"ts":1789000000}' + "`n"
}

Describe 'ConvertFrom-AvdTrayStatus' {
    It 'reads every field of the JSON bin/avd-photos-status prints' {
        $s = ConvertFrom-AvdTrayStatus -Text $RealJson
        $s.Armed | Should -BeTrue
        $s.Emulator | Should -BeTrue
        $s.Staged | Should -Be 2831
        $s.Remaining | Should -Be 0
        $s.OnDevice | Should -Be 377
        $s.Uploaded | Should -Be 120
        $s.Queued | Should -Be 257
        $s.Failed | Should -Be 0
        $s.UploadAge | Should -Be 0
        $s.Confirmed | Should -BeTrue
        $s.ConfirmedAge | Should -Be 3600
        $s.LastRunAge | Should -Be 900
        $s.Running | Should -BeTrue
        $s.Phase | Should -Be 'verifying uploads: 120 of 377 confirmed'
        $s.Reclaimed | Should -Be 1500
        $s.ReclaimPending | Should -Be 12
    }
    It 'gives a missing field the Swift default' {
        $s = ConvertFrom-AvdTrayStatus -Text '{"backup":{}}'
        $s.Armed | Should -BeFalse
        $s.Emulator | Should -BeFalse
        $s.Confirmed | Should -BeFalse
        $s.Running | Should -BeFalse
        $s.Staged | Should -Be 0
        $s.Failed | Should -Be 0
        $s.UploadAge | Should -Be -1
        $s.ConfirmedAge | Should -Be -1
        $s.LastRunAge | Should -Be -1
        $s.Phase | Should -Be ''
    }
    It 'keeps the default for a field of the wrong JSON type, as `as? Int ?? 0` does' {
        $s = ConvertFrom-AvdTrayStatus -Text '{"backup":{"staged":"12","armed":"true","phase":7,"failed":1.5,"on_device":3.0}}'
        $s.Staged | Should -Be 0
        $s.Armed | Should -BeFalse
        $s.Phase | Should -Be ''
        $s.Failed | Should -Be 0
        $s.OnDevice | Should -Be 3
    }
    It 'compares keys case-sensitively, as a Swift dictionary does' {
        $s = ConvertFrom-AvdTrayStatus -Text '{"backup":{"Armed":true,"STAGED":5}}'
        $s.Armed | Should -BeFalse
        $s.Staged | Should -Be 0
        ConvertFrom-AvdTrayStatus -Text '{"Backup":{"armed":true}}' | Should -BeNullOrEmpty
    }
    It 'keeps a date-shaped phase a string' {
        (ConvertFrom-AvdTrayStatus -Text '{"backup":{"phase":"2026-09-13T10:00:00"}}').Phase | Should -Be '2026-09-13T10:00:00'
    }
    It 'returns $null for text that is not a status' {
        foreach ($t in @($null, '', '   ', 'garbage', '{', '[]', '"x"', '{"backup":[]}', '{"backup":1}', '{"ts":1}', '{"backup":{},}')) {
            ConvertFrom-AvdTrayStatus -Text $t | Should -BeNullOrEmpty -Because "input: $t"
        }
    }
}

Describe 'the derived flags (struct Stats)' {
    It 'backupDone needs staged work, nothing left, nothing on the device and the stamp' {
        (New-Healthy).BackupDone | Should -BeTrue
        (New-Healthy @{ Confirmed = $false }).BackupDone | Should -BeFalse
        (New-Healthy @{ Remaining = 1 }).BackupDone | Should -BeFalse
        (New-Healthy @{ OnDevice = 1 }).BackupDone | Should -BeFalse
        (New-Healthy @{ Staged = 0 }).BackupDone | Should -BeFalse
    }
    It 'backupUnverified is the same counts without the stamp' {
        (New-Healthy @{ Confirmed = $false }).BackupUnverified | Should -BeTrue
        (New-Healthy).BackupUnverified | Should -BeFalse
        (New-Healthy @{ Confirmed = $false; Staged = 0 }).BackupUnverified | Should -BeFalse
    }
    It 'backupStalled is a batch on the device with nothing uploaded and no run alive' {
        (New-S @{ OnDevice = 5 }).BackupStalled | Should -BeTrue
        (New-S @{ OnDevice = 5; Uploaded = 1 }).BackupStalled | Should -BeFalse
        (New-S @{ OnDevice = 5; Running = $true }).BackupStalled | Should -BeFalse
        (New-S).BackupStalled | Should -BeFalse
    }
    It 'uploadFraction is uploaded over on-device, 0 with nothing on the device' {
        (New-S @{ OnDevice = 4; Uploaded = 1 }).UploadFraction | Should -Be 0.25
        (New-S @{ Uploaded = 9 }).UploadFraction | Should -Be 0
    }
    It 'backupStale follows the Swift branches in order' {
        (New-Healthy @{ Running = $true; LastRunAge = 99999 }).BackupStale | Should -BeFalse
        (New-Healthy @{ Armed = $false; LastRunAge = 99999 }).BackupStale | Should -BeFalse
        (New-Healthy @{ OnDevice = 3; UploadAge = 3601 }).BackupStale | Should -BeTrue
        (New-Healthy @{ OnDevice = 3; UploadAge = 3600 }).BackupStale | Should -BeFalse
        (New-Healthy @{ LastRunAge = -1 }).BackupStale | Should -BeTrue
        (New-Healthy @{ LastRunAge = -1; Staged = 0 }).BackupStale | Should -BeFalse
        (New-Healthy @{ LastRunAge = 10800 }).BackupStale | Should -BeFalse
        (New-Healthy @{ LastRunAge = 10801 }).BackupStale | Should -BeTrue
    }
    It 'recomputes a flag when a field changes, as a computed var does' {
        $s = New-Healthy
        $s.BackupDone | Should -BeTrue
        $s.Confirmed = $false
        $s.BackupDone | Should -BeFalse
    }
    It 'refuses a field the Swift struct does not have' {
        { New-S @{ Stagged = 1 } } | Should -Throw '*Stagged*'
    }
}

Describe 'Format-AvdCompactCount (compact)' {
    It 'formats <n> as <want>' -ForEach @(
        @{ n = 0; want = '0' }, @{ n = 999; want = '999' }, @{ n = 1000; want = '1.0k' }, @{ n = 1234; want = '1.2k' },
        @{ n = 1050; want = '1.1k' }, @{ n = 1150; want = '1.1k' }, @{ n = 1250; want = '1.2k' }, @{ n = 1750; want = '1.8k' },
        @{ n = 9949; want = '9.9k' }, @{ n = 9960; want = '10.0k' }, @{ n = 10000; want = '10k' }, @{ n = 12345; want = '12k' },
        @{ n = 999999; want = '999k' }, @{ n = 1000000; want = '1000k' }
    ) {
        Format-AvdCompactCount $n | Should -BeExactly $want
    }
}

Describe 'Format-AvdRelativeAge (relAge)' {
    It 'formats <s> s as <want>' -ForEach @(
        @{ s = -1; want = 'never' }, @{ s = 0; want = 'just now' }, @{ s = 4; want = 'just now' }, @{ s = 5; want = '5s ago' },
        @{ s = 59; want = '59s ago' }, @{ s = 60; want = '1m ago' }, @{ s = 119; want = '1m ago' }, @{ s = 3599; want = '59m ago' },
        @{ s = 3600; want = '1.0h ago' }, @{ s = 4500; want = '1.2h ago' }, @{ s = 8640; want = '2.4h ago' },
        @{ s = 86399; want = '24.0h ago' }, @{ s = 86400; want = '1d ago' }, @{ s = 259200; want = '3d ago' }
    ) {
        Format-AvdRelativeAge $s | Should -BeExactly $want
    }
    It 'writes a decimal point whatever the thread culture' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
            Format-AvdRelativeAge 8640 | Should -BeExactly '2.4h ago'
            Format-AvdCompactCount 1234 | Should -BeExactly '1.2k'
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
    }
}

Describe 'Get-AvdRunStep (RunStep)' {
    It 'reads <phase> as <kind> <n>/<m>' -ForEach @(
        @{ phase = 'pushing 120 of 500 to the emulator'; kind = 'device'; n = 120; m = 500 }
        @{ phase = 'indexing in MediaStore: 40 of 500'; kind = 'device'; n = 40; m = 500 }
        @{ phase = 'waiting for MediaStore to index 3 file(s)'; kind = 'device'; n = 0; m = 0 }
        @{ phase = 're-announcing 7 files'; kind = 'device'; n = 7; m = 0 }
        @{ phase = 'reclaiming emulator space: 3 of 9'; kind = 'device'; n = 3; m = 9 }
        @{ phase = 'removing empty device files'; kind = 'device'; n = 0; m = 0 }
        @{ phase = 'verifying uploads: 40 of 500 confirmed'; kind = 'cloud'; n = 40; m = 500 }
        @{ phase = 'reclaiming iCloud space: 12 of 40 deleted'; kind = 'offload'; n = 12; m = 0 }
        @{ phase = 'downloading from iCloud (340 so far)'; kind = 'download'; n = 340; m = 0 }
        @{ phase = 'booting the emulator'; kind = 'busy'; n = 0; m = 0 }
        @{ phase = ''; kind = 'busy'; n = 0; m = 0 }
        @{ phase = 'pushing'; kind = 'busy'; n = 0; m = 0 }
        @{ phase = 'Pushing 1 of 2'; kind = 'busy'; n = 0; m = 0 }
        @{ phase = 'pushing 99999999999999999999 of 5'; kind = 'device'; n = 5; m = 0 }
        @{ phase = 'pushing 1,234 of 5'; kind = 'device'; n = 1; m = 234 }
    ) {
        $r = Get-AvdRunStep -Phase $phase
        $r.Kind | Should -Be $kind
        $r.N | Should -Be $n
        $r.M | Should -Be $m
    }
}

Describe 'Test-AvdCollectorSick (collectorSick)' {
    It 'is sick after three failures, or 150 s without a good collection' {
        Test-AvdCollectorSick -FailStreak 0 -SecondsSinceGood $null | Should -BeFalse
        Test-AvdCollectorSick -FailStreak 2 -SecondsSinceGood $null | Should -BeFalse
        Test-AvdCollectorSick -FailStreak 3 -SecondsSinceGood $null | Should -BeTrue
        Test-AvdCollectorSick -FailStreak 0 -SecondsSinceGood 150 | Should -BeFalse
        Test-AvdCollectorSick -FailStreak 0 -SecondsSinceGood 150.5 | Should -BeTrue
        Test-AvdCollectorSick -FailStreak 3 -SecondsSinceGood 1 | Should -BeTrue
    }
}

Describe 'Get-AvdTrayState (render)' {
    It 'is a plain red ring before the first collection, sick or not' {
        foreach ($sick in $false, $true) {
            $r = Get-State $null $sick
            $r.Tint | Should -Be 'red'
            $r.Mark | Should -Be 'none'
            $r.Fraction | Should -Be 0
            $r.Text | Should -Be ''
        }
    }
    It 'badges a sick collector with an exclamation once stats were had, above every other state' {
        $r = Get-State (New-Healthy @{ Failed = 3; Running = $true }) $true
        $r.Tint | Should -Be 'red'
        $r.Mark | Should -Be 'exclaim'
        $r.Spin | Should -BeFalse
    }
    It 'is a dim ring when not armed, whatever else is true' {
        $r = Get-State (New-Healthy @{ Armed = $false; Failed = 4; Running = $true })
        $r.Tint | Should -Be 'dim'
        $r.Mark | Should -Be 'none'
        $r.Text | Should -Be ''
    }
    It 'shows failed uploads red, with the count, above a running sync' {
        $r = Get-State (New-Healthy @{ Failed = 1500; Running = $true; OnDevice = 10; Uploaded = 5 })
        $r.Tint | Should -Be 'red'
        $r.Mark | Should -Be 'exclaim'
        $r.Fraction | Should -Be 0.5
        $r.Text | Should -Be '1.5k'
        (Get-State (New-Healthy @{ Failed = 2; OnDevice = 0 })).Fraction | Should -Be 0.06
    }
    It 'paints a device step yellow with its n/m, and spins when there is no n yet' {
        $r = Get-State (New-Healthy @{ Running = $true; Phase = 'pushing 120 of 480 to the emulator' })
        $r.Tint | Should -Be 'yellow'; $r.Spin | Should -BeFalse; $r.Fraction | Should -Be 0.25; $r.Text | Should -Be '120/480'
        $r = Get-State (New-Healthy @{ Running = $true; Phase = 'pushing 0 of 480 to the emulator' })
        $r.Spin | Should -BeTrue; $r.Text | Should -Be '0/480'
        $r = Get-State (New-Healthy @{ Running = $true; Phase = 'waiting for MediaStore to index 3 file(s)' })
        $r.Tint | Should -Be 'yellow'; $r.Spin | Should -BeTrue; $r.Text | Should -Be ''
    }
    It 'paints the verify pass blue' {
        $r = Get-State (New-Healthy @{ Running = $true; Phase = 'verifying uploads: 40 of 500 confirmed' })
        $r.Tint | Should -Be 'blue'; $r.Fraction | Should -Be 0.08; $r.Text | Should -Be '40/500'
    }
    It 'clamps a count past its total to a full ring' {
        (Get-State (New-Healthy @{ Running = $true; Phase = 'pushing 600 of 500' })).Fraction | Should -Be 1
    }
    It 'spins purple while offloading, with the compact count' {
        $r = Get-State (New-Healthy @{ Running = $true; Phase = 'reclaiming iCloud space: 1234 of 2000' })
        $r.Tint | Should -Be 'purple'; $r.Spin | Should -BeTrue; $r.Text | Should -Be '1.2k'
        (Get-State (New-Healthy @{ Running = $true; Phase = 'reclaiming iCloud space' })).Text | Should -Be ''
    }
    It 'spins dim while downloading: the tally, else the backlog' {
        $r = Get-State (New-Healthy @{ Running = $true; Remaining = 50; Phase = 'downloading (340 so far)' })
        $r.Tint | Should -Be 'dim'; $r.Spin | Should -BeTrue; $r.Text | Should -Be '340'
        (Get-State (New-Healthy @{ Running = $true; Remaining = 50; Phase = 'downloading' })).Text | Should -Be '50'
        (Get-State (New-Healthy @{ Running = $true; Phase = 'downloading' })).Text | Should -Be ''
    }
    It 'spins dim on a step with no count, showing the backlog' {
        $r = Get-State (New-Healthy @{ Running = $true; Remaining = 2500; Phase = 'booting the emulator' })
        $r.Tint | Should -Be 'dim'; $r.Spin | Should -BeTrue; $r.Text | Should -Be '2.5k'
    }
    It 'marks a stale pipeline orange: the batch fraction when one is on the device, else full' {
        $r = Get-State (New-Healthy @{ OnDevice = 10; Uploaded = 0; UploadAge = 7200 })
        $r.Tint | Should -Be 'orange'; $r.Mark | Should -Be 'exclaim'; $r.Fraction | Should -Be 0.06; $r.Text | Should -Be '0/10'
        $r = Get-State (New-Healthy @{ LastRunAge = 20000 })
        $r.Tint | Should -Be 'orange'; $r.Fraction | Should -Be 1; $r.Text | Should -Be ''
    }
    It 'shows a batch in flight blue, or yellow at the floor when stalled' {
        $r = Get-State (New-Healthy @{ OnDevice = 10; Uploaded = 4 })
        $r.Tint | Should -Be 'blue'; $r.Fraction | Should -Be 0.4; $r.Text | Should -Be '4/10'; $r.Mark | Should -Be 'none'
        $r = Get-State (New-Healthy @{ OnDevice = 10; Uploaded = 0 })
        $r.Tint | Should -Be 'yellow'; $r.Fraction | Should -Be 0.06; $r.Text | Should -Be '0/10'
    }
    It 'shows a waiting backlog dim with its compact count' {
        $r = Get-State (New-Healthy @{ Remaining = 1234 })
        $r.Tint | Should -Be 'dim'; $r.Fraction | Should -Be 0; $r.Text | Should -Be '1.2k'
    }
    It 'shows the green check only with the confirmation stamp' {
        $r = Get-State (New-Healthy)
        $r.Tint | Should -Be 'green'; $r.Mark | Should -Be 'check'; $r.Fraction | Should -Be 1; $r.Text | Should -Be ''
        $r = Get-State (New-Healthy @{ Confirmed = $false })
        $r.Tint | Should -Be 'yellow'; $r.Mark | Should -Be 'exclaim'; $r.Fraction | Should -Be 1
    }
    It 'is dim when nothing is staged' {
        $r = Get-State (New-Healthy @{ Staged = 0 })
        $r.Tint | Should -Be 'dim'; $r.Mark | Should -Be 'none'; $r.Spin | Should -BeFalse
    }
}

Describe 'Get-AvdTrayStatusNote (the coloured line)' {
    It 'says Collecting... before the first result, or the error in red' {
        $n = Get-Note $null ''
        $n.Text | Should -Be 'Collecting...'; $n.Color | Should -Be 'secondary'
        $n = Get-Note $null 'avd-photos-status not found'
        $n.Text | Should -Be 'avd-photos-status not found'; $n.Color | Should -Be 'red'
    }
    It 'says the meter is not refreshing, above a running sync' {
        (Get-Note (New-Healthy @{ Running = $true }) 'collector timed out' $true).Text | Should -Be 'Meter not refreshing -- collector timed out'
        $n = Get-Note (New-Healthy) '' $true
        $n.Text | Should -Be 'Meter not refreshing -- collector silent'; $n.Color | Should -Be 'red'
    }
    It 'reports a running step verbatim, above a failure left behind' {
        $n = Get-Note (New-Healthy @{ Running = $true; Phase = 'pushing 1 of 2'; Failed = 3 })
        $n.Text | Should -Be 'Running -- pushing 1 of 2'; $n.Color | Should -Be 'blue'
        (Get-Note (New-Healthy @{ Running = $true })).Text | Should -Be 'Running -- sync in progress'
    }
    It 'reports the reason a run failed, above permanently failed uploads' {
        $n = Get-Note (New-Healthy @{ Phase = "failed:  `tno access to the staging directory "; Failed = 3 })
        $n.Text | Should -Be 'Last run failed -- no access to the staging directory'; $n.Color | Should -Be 'orange'
    }
    It 'counts permanently failed uploads, singular and plural' {
        $n = Get-Note (New-Healthy @{ Failed = 1 })
        $n.Text | Should -Be '1 upload permanently failed'; $n.Color | Should -Be 'red'
        (Get-Note (New-Healthy @{ Failed = 2 })).Text | Should -Be '2 uploads permanently failed'
    }
    It 'says why the pipeline is stale' {
        (Get-Note (New-Healthy @{ OnDevice = 5; UploadAge = 7200 })).Text | Should -Be 'Stale -- sync died mid-upload -- verifier silent 2.0h ago'
        (Get-Note (New-Healthy @{ LastRunAge = -1 })).Text | Should -Be 'Stale -- the sync job has never run'
        $n = Get-Note (New-Healthy @{ LastRunAge = 18000 })
        $n.Text | Should -Be 'Stale -- sync job silent 5.0h ago'; $n.Color | Should -Be 'orange'
    }
    It 'reports a batch uploading, or stalled' {
        $n = Get-Note (New-Healthy @{ OnDevice = 10; Uploaded = 4 })
        $n.Text | Should -Be 'Uploading 4 of 10'; $n.Color | Should -Be 'secondary'
        $n = Get-Note (New-Healthy @{ OnDevice = 10; Uploaded = 0 })
        $n.Text | Should -Be 'Stalled -- nothing reaching the server'; $n.Color | Should -Be 'orange'
    }
    It 'reports the backlog, the verified state, the unverified state and an empty pipeline' {
        (Get-Note (New-Healthy @{ Remaining = 1234 })).Text | Should -Be '1234 waiting for the next sync run'
        $n = Get-Note (New-Healthy)
        $n.Text | Should -Be 'All backed up - verified 1.0h ago'; $n.Color | Should -Be 'green'
        $n = Get-Note (New-Healthy @{ Confirmed = $false })
        $n.Text | Should -Be 'Unverified -- the last sync could not confirm uploads'; $n.Color | Should -Be 'orange'
        $n = Get-Note (New-Healthy @{ Staged = 0 })
        $n.Text | Should -Be 'Nothing staged yet'; $n.Color | Should -Be 'secondary'
    }
}

Describe 'Get-AvdTrayMenu (buildMenu)' {
    It 'lays out a healthy armed pipeline row for row' {
        $m = Get-Menu (New-Healthy @{ Reclaimed = 1500; ReclaimPending = 12 }) -OpenAvd $true
        ($m | ForEach-Object { if ($_.Kind -eq 'separator') { '---' } else { "$($_.Kind):$($_.Text)" } }) | Should -Be @(
            'header:iCloud -> Google Photos'
            'note:All backed up - verified 1.0h ago'
            '---'
            'mono:Staged      2831'
            'mono:Backlog     caught up'
            'mono:Verified    377 - 1.0h ago'
            'mono:iCloud      1500 freed - 12 confirmed, pending'
            'mono:Last run    15m ago'
            'mono:Emulator    stopped'
            '---'
            'action:Open Google Photos (AVD)'
            'action:Offload from iCloud'
            'action:Check iCloud now'
            'action:Refresh Now'
            '---'
            'action:Quit Photo Sync'
        )
        @($m | Where-Object Kind -EQ 'action' | ForEach-Object Action) | Should -Be @('openAvd', 'offload', 'check', 'refresh', 'quit')
        ($m | Where-Object Action -EQ 'refresh').Key | Should -Be 'r'
        ($m | Where-Object Action -EQ 'quit').Key | Should -Be 'q'
    }
    It 'shows a default ledger and only Refresh and Quit before the first collection' {
        $m = Get-Menu $null '' -Sync $true
        $m[1].Text | Should -Be 'Collecting...'
        @($m | Where-Object Kind -EQ 'mono' | ForEach-Object Text) | Should -Be @(
            'Staged      0', 'Backlog     caught up', 'Verified    NOT confirmed', 'iCloud      0 freed', 'Last run    never', 'Emulator    stopped')
        @($m | Where-Object Kind -EQ 'action' | ForEach-Object Action) | Should -Be @('refresh', 'quit')
        @($m | Where-Object { $_.Text -like 'Dormant*' }).Count | Should -Be 0
    }
    It 'adds the Dormant note, with the Windows command, only when stats say not armed' {
        $m = Get-Menu (New-Healthy @{ Armed = $false })
        $d = @($m | Where-Object { $_.Text -like 'Dormant*' })
        $d.Count | Should -Be 1
        $d[0].Text | Should -Be 'Dormant -- run avd-photos-arm -Yes to enable the sync'
        $d[0].Color | Should -Be 'orange'
        [array]::IndexOf(@($m), $d[0]) | Should -Be 2
        @($m | Where-Object Kind -EQ 'action' | ForEach-Object Action) | Should -Be @('refresh', 'quit')
    }
    It 'shows On device when the emulator runs or files are on it, with the queue' {
        (Get-Mono (Get-Menu (New-Healthy)) 'On device').Count | Should -Be 0
        (Get-Mono (Get-Menu (New-Healthy @{ Emulator = $true })) 'On device')[0].Text | Should -Be 'On device   0'
        (Get-Mono (Get-Menu (New-Healthy @{ OnDevice = 377; Queued = 257; Uploaded = 120 })) 'On device')[0].Value | Should -Be '377 (257 queued)'
    }
    It 'states Verified in the four Swift cases' {
        (Get-Mono (Get-Menu (New-Healthy @{ Confirmed = $false })) 'Verified')[0].Value | Should -Be 'NOT confirmed'
        (Get-Mono (Get-Menu (New-Healthy @{ Running = $true; OnDevice = 377; Uploaded = 120 })) 'Verified')[0].Value | Should -Be '120 of 377 so far'
        (Get-Mono (Get-Menu (New-Healthy @{ UploadAge = -1 })) 'Verified')[0].Value | Should -Be 'last batch 1.0h ago'
        (Get-Mono (Get-Menu (New-Healthy)) 'Verified')[0].Value | Should -Be '377 - 1.0h ago'
    }
    It 'shows the backlog count and a running last run' {
        (Get-Mono (Get-Menu (New-Healthy @{ Remaining = 12 })) 'Backlog')[0].Value | Should -Be '12'
        (Get-Mono (Get-Menu (New-Healthy @{ Running = $true })) 'Last run')[0].Value | Should -Be 'running now'
        (Get-Mono (Get-Menu (New-Healthy @{ Emulator = $true })) 'Emulator')[0].Value | Should -Be 'running'
    }
    It 'gates the Offload row exactly as the Swift does' {
        $row = { param($m) @($m | Where-Object { $_.Action -eq 'offload' -or $_.Text -like 'Offload*' }) }
        (& $row (Get-Menu (New-Healthy) -Sync $false)).Count | Should -Be 0
        (& $row (Get-Menu (New-Healthy @{ Armed = $false }))).Count | Should -Be 0
        $r = & $row (Get-Menu (New-Healthy) -Offloading $true)
        $r[0].Kind | Should -Be 'note'; $r[0].Text | Should -Be 'Offloading from iCloud...'
        $r = & $row (Get-Menu (New-Healthy @{ Running = $true }))
        $r[0].Kind | Should -Be 'note'; $r[0].Text | Should -Be 'Offload unavailable while a sync is running'
        $r = & $row (Get-Menu (New-Healthy))
        $r[0].Kind | Should -Be 'action'; $r[0].Text | Should -Be 'Offload from iCloud'
        $r = & $row (Get-Menu (New-Healthy @{ Confirmed = $false }))
        $r[0].Kind | Should -Be 'note'; $r[0].Text | Should -Be 'Offload unavailable -- no confirmed upload yet'
    }
    It 'offers Check iCloud now when armed and idle, and says why not while a run is alive' {
        $m = Get-Menu (New-Healthy)
        @($m | Where-Object Action -EQ 'check').Count | Should -Be 1
        $m = Get-Menu (New-Healthy @{ Running = $true })
        @($m | Where-Object Action -EQ 'check').Count | Should -Be 0
        @($m | Where-Object Text -EQ 'Checking -- a sync run is in progress').Count | Should -Be 1
        $m = Get-Menu (New-Healthy @{ Armed = $false })
        @($m | Where-Object { $_.Action -eq 'check' -or $_.Text -like 'Checking*' }).Count | Should -Be 0
    }
    It 'offers Check iCloud now even without the sync script (Task Scheduler runs it)' {
        $m = Get-Menu (New-Healthy) -Sync $false
        @($m | Where-Object Action -EQ 'check').Count | Should -Be 1
    }
    It 'shows Open Google Photos (AVD) only when its shortcut exists' {
        $m = Get-Menu (New-Healthy) -OpenAvd $false
        @($m | Where-Object Action -EQ 'openAvd').Count | Should -Be 0
    }
    It 'has exactly one status note, second, in every state' {
        foreach ($s in @($null, (New-Healthy), (New-Healthy @{ Running = $true }), (New-Healthy @{ Armed = $false }))) {
            $m = Get-Menu $s
            $m[0].Kind | Should -Be 'header'
            $m[1].Kind | Should -Be 'note'
            @($m | Where-Object Kind -EQ 'separator').Count | Should -Be 3
        }
    }
    It 'is ASCII in every state' {
        foreach ($s in @($null, (New-Healthy), (New-Healthy @{ Running = $true; OnDevice = 2 }), (New-Healthy @{ Confirmed = $false }))) {
            foreach ($i in Get-Menu $s 'x' -OpenAvd $true) { $i.Text | Should -Not -Match '[^\x20-\x7E]' }
        }
    }
}

Describe 'ConvertTo-AvdMenuText' {
    It 'marks the key equivalent as the mnemonic and doubles a literal ampersand' {
        ConvertTo-AvdMenuText -Text 'Refresh Now' -Key 'r' | Should -BeExactly '&Refresh Now'
        ConvertTo-AvdMenuText -Text 'Quit Photo Sync' -Key 'q' | Should -BeExactly '&Quit Photo Sync'
        ConvertTo-AvdMenuText -Text 'Running -- a & b' | Should -BeExactly 'Running -- a && b'
        ConvertTo-AvdMenuText -Text 'Check iCloud now' | Should -BeExactly 'Check iCloud now'
    }
}

Describe 'Format-AvdTrayTooltip' {
    It 'names the app and the note, with the count first when there is one' {
        Format-AvdTrayTooltip -Note 'All backed up - verified 3m ago' | Should -Be 'Photo Sync - All backed up - verified 3m ago'
        Format-AvdTrayTooltip -Note 'Uploading 4 of 10' -Count '4/10' | Should -Be 'Photo Sync 4/10 - Uploading 4 of 10'
    }
    It 'fits NotifyIcon.Text: 63 characters at most, the cut marked with ...' {
        $exact = 'x' * (63 - 'Photo Sync - '.Length)
        Format-AvdTrayTooltip -Note $exact | Should -Be "Photo Sync - $exact"
        $t = Format-AvdTrayTooltip -Note ('Running -- ' + 'pushing 120 of 500 to the emulator, very slowly indeed') -Count '120/500'
        $t.Length | Should -Be 63
        $t | Should -BeLike 'Photo Sync 120/500 - Running -- *...'
    }
}

Describe 'ConvertTo-AvdIcoByte' {
    It 'writes ICONDIR, one entry per image and the PNGs in order' {
        $a = [byte[]](1, 2, 3, 4, 5)
        $b = [byte[]](9, 8, 7)
        $ico = ConvertTo-AvdIcoByte -Image @(@{ Width = 16; Height = 16; Data = $a }, @{ Width = 256; Height = 256; Data = $b })
        $ico.GetType() | Should -Be ([byte[]])
        $ico.Length | Should -Be (6 + 2 * 16 + 5 + 3)
        [BitConverter]::ToUInt16($ico, 0) | Should -Be 0
        [BitConverter]::ToUInt16($ico, 2) | Should -Be 1
        [BitConverter]::ToUInt16($ico, 4) | Should -Be 2
        # Entry 1
        $ico[6] | Should -Be 16; $ico[7] | Should -Be 16; $ico[8] | Should -Be 0; $ico[9] | Should -Be 0
        [BitConverter]::ToUInt16($ico, 10) | Should -Be 1
        [BitConverter]::ToUInt16($ico, 12) | Should -Be 32
        [BitConverter]::ToUInt32($ico, 14) | Should -Be 5
        [BitConverter]::ToUInt32($ico, 18) | Should -Be 38
        # Entry 2: 256 is written as 0
        $ico[22] | Should -Be 0; $ico[23] | Should -Be 0
        [BitConverter]::ToUInt32($ico, 30) | Should -Be 3
        [BitConverter]::ToUInt32($ico, 34) | Should -Be 43
        $ico[38..42] | Should -Be $a
        $ico[43..45] | Should -Be $b
    }
    It 'refuses an image larger than an icon can hold' {
        { ConvertTo-AvdIcoByte -Image @(@{ Width = 300; Height = 300; Data = [byte[]](1) }) } | Should -Throw '*outside 1..256*'
    }
}

Describe 'the icon cache key and the spinner' {
    It 'cycles the spinner through 18 angles and back, as startSpinner does' {
        $a = 90.0
        $seen = [System.Collections.Generic.HashSet[double]]::new()
        for ($i = 0; $i -lt 18; $i++) { [void]$seen.Add($a); $a = Step-AvdSpinAngle $a }
        $a | Should -Be 90
        $seen.Count | Should -Be 18
        ($seen | Measure-Object -Minimum -Maximum).Minimum | Should -Be -250
    }
    It 'keys a spinning state on its angle only, so a whole cycle is 18 icons' {
        $st = New-AvdTrayRingState -Tint purple -Spin $true
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        $a = 90.0
        for ($i = 0; $i -lt 100; $i++) { [void]$keys.Add((Get-AvdTrayIconKey -State $st -SpinAngle $a)); $a = Step-AvdSpinAngle $a }
        $keys.Count | Should -Be 18
    }
    It 'ignores the angle when not spinning and buckets the fraction to 37 values' {
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        for ($i = 0; $i -le 1000; $i++) {
            [void]$keys.Add((Get-AvdTrayIconKey -State (New-AvdTrayRingState -Tint blue -Fraction ($i / 1000)) -SpinAngle (Get-Random -Maximum 360)))
        }
        $keys.Count | Should -Be 37
        Get-AvdTrayIconKey -State (New-AvdTrayRingState -Tint green -Fraction 1 -Mark check) | Should -Be 'green|36|check|-'
    }
    It 'never rounds a started batch to nothing or an unfinished one to full' {
        Get-AvdTrayFractionBucket 0 | Should -Be 0
        Get-AvdTrayFractionBucket 0.001 | Should -Be 1
        Get-AvdTrayFractionBucket 0.5 | Should -Be 18
        Get-AvdTrayFractionBucket 0.999 | Should -Be 35
        Get-AvdTrayFractionBucket 1 | Should -Be 36
    }
}

Describe 'Get-AvdRingGeometry (ring)' {
    It 'keeps the Mac proportions: radius 7.5 and stroke 2.2 on a 19 px square' {
        $g = Get-AvdRingGeometry -Size 19 -State (New-AvdTrayRingState)
        $g.Center | Should -Be 9.5
        $g.Radius | Should -Be 7.5
        $g.LineWidth | Should -BeGreaterThan 2.19
        $g.LineWidth | Should -BeLessThan 2.21
        $g.Arc | Should -BeNullOrEmpty
    }
    It 'fits the ring inside every icon size' -ForEach @(@{ z = 16 }, @{ z = 20 }, @{ z = 24 }, @{ z = 32 }) {
        $g = Get-AvdRingGeometry -Size $z -State (New-AvdTrayRingState)
        ($g.Radius + $g.LineWidth / 2) | Should -BeLessThan ($z / 2)
    }
    It 'draws the fraction from 12 o clock clockwise, in the bucket the cache keys on' {
        $g = Get-AvdRingGeometry -Size 16 -State (New-AvdTrayRingState -Tint blue -Fraction 0.25)
        $g.Arc.Start | Should -Be -90
        $g.Arc.Sweep | Should -Be 90
        (Get-AvdRingGeometry -Size 16 -State (New-AvdTrayRingState -Fraction 1)).Arc.Sweep | Should -Be 360
    }
    It 'draws a 100-degree spinner at the spin angle, y flipped from AppKit' {
        $g = Get-AvdRingGeometry -Size 16 -State (New-AvdTrayRingState -Spin $true) -SpinAngle 90
        $g.Arc.Start | Should -Be -90
        $g.Arc.Sweep | Should -Be 100
        (Get-AvdRingGeometry -Size 16 -State (New-AvdTrayRingState -Spin $true) -SpinAngle -250).Arc.Start | Should -Be 250
    }
    It 'draws no arc for a mark at fraction 0' {
        $g = Get-AvdRingGeometry -Size 16 -State (New-AvdTrayRingState -Tint red -Mark exclaim)
        $g.Arc | Should -BeNullOrEmpty
        $g.Dot | Should -Not -BeNullOrEmpty
    }
    It 'places the check and the exclamation as ring() does, y down' {
        $g = Get-AvdRingGeometry -Size 19 -State (New-AvdTrayRingState -Mark check -Fraction 1)
        @($g.Lines).Count | Should -Be 1
        $pts = @($g.Lines)[0]
        $pts.Count | Should -Be 3
        $pts[1][1] | Should -BeGreaterThan $g.Center
        $pts[2][0] | Should -BeGreaterThan $g.Center
        $g = Get-AvdRingGeometry -Size 19 -State (New-AvdTrayRingState -Mark exclaim)
        $line = @($g.Lines)[0]
        $line[0][0] | Should -Be $g.Center
        $line[0][1] | Should -Be ($g.Center - 0.5 * $g.Radius)
        $g.Dot.Y | Should -Be ($g.Center + 0.55 * $g.Radius)
        $g.Dot.Diameter | Should -Be (0.28 * $g.Radius)
    }
}

Describe 'the colours (muted)' {
    It 'blends the system colours 38% toward a 0.58 grey' {
        $p = Get-AvdTrayPalette
        $p.red | Should -Be (ConvertTo-AvdArgb 214 93 86)
        $p.blue | Should -Be (ConvertTo-AvdArgb 56 132 214)
        foreach ($k in 'red', 'orange', 'yellow', 'blue', 'purple', 'green', 'dim') {
            (($p[$k] -shr 24) -band 0xFF) | Should -Be 255 -Because $k
        }
        (($p.track -shr 24) -band 0xFF) | Should -Be 102
    }
    It 'packs ARGB as the signed int Color.FromArgb takes' {
        ConvertTo-AvdArgb 0 0 0 | Should -Be -16777216
        ConvertTo-AvdArgb 1 2 3 0 | Should -Be 0x010203
    }
    It 'has a text colour for every note colour but secondary' {
        $c = Get-AvdTrayTextColor
        foreach ($k in 'red', 'orange', 'blue', 'green') { $c.Contains($k) | Should -BeTrue }
    }
}

Describe 'the host script (static)' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $script:HostAst = [System.Management.Automation.Language.Parser]::ParseFile($HostPath, [ref]$tokens, [ref]$errors)
        $script:HostErrors = @($errors)
        $script:HostFunctions = @($HostAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        # The code without its comments, which are free to name what the code
        # must not use and why.
        $script:HostText = @($tokens | Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } | ForEach-Object Text) -join ' '
    }
    It 'parses' {
        $HostErrors.Count | Should -Be 0
    }
    It 'defines the drawing, menu, icon cache and host entry points' {
        foreach ($f in 'Start-AvdTrayHost', 'New-AvdTrayRingBitmap', 'ConvertTo-AvdTrayPngByte', 'Get-AvdTrayIcon', 'Clear-AvdTrayIconCache',
            'New-AvdTrayMenuItem', 'Update-AvdTrayMenu', 'Start-AvdTrayCollection', 'Update-AvdTrayCollection', 'Update-AvdTrayView',
            'Invoke-AvdTrayAction') {
            $HostFunctions | Should -Contain $f
        }
    }
    It 'does not shadow a module function when dot-sourced' {
        $module = @((Get-Module AvdPhotos).ExportedFunctions.Keys)
        foreach ($f in $HostFunctions) { $module | Should -Not -Contain $f }
    }
    It 'never makes an icon with GetHicon (a leaked GDI handle per frame)' {
        $HostText | Should -Not -Match 'GetHicon'
    }
    It 'uses no timer or event raised off the UI thread' {
        $HostText | Should -Not -Match 'System\.Timers\.Timer|Register-ObjectEvent|add_Exited|SystemEvents|OutputDataReceived'
    }
    It 'starts every child through Start-AvdDetachedProcess' {
        $HostText | Should -Not -Match 'Start-Process|Diagnostics\.Process\]::Start|Invoke-AvdProcess'
        $HostText | Should -Match 'Start-AvdDetachedProcess'
    }
    It 'reads nothing from the environment to decide what it runs' {
        $vars = @($HostAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.DriveName -eq 'env' }, $true))
        $vars.Count | Should -Be 0
        $HostText | Should -Not -Match 'GetEnvironmentVariable'
    }
    It 'returns before the message loop when dot-sourced' {
        $HostText | Should -Match "InvocationName -eq '\.'"
    }
}

# The host's own logic -- the collection's failStreak, lastError and watchdog,
# the one-at-a-time rule, the offload flag, the heartbeat -- is plain
# PowerShell over the tray state, so it runs here against fake processes and
# timers. The host loads WinForms only on Windows and stops before its message
# loop when dot-sourced.
Describe 'the host logic (dot-sourced, fake processes and timers)' {
    BeforeAll {
        . $HostPath
        function New-FakeProcess {
            param([bool]$Exited = $true)
            $p = [pscustomobject]@{ HasExited = $Exited; Killed = $false; KilledTree = $null; WaitedMs = $null; Disposed = $false }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($tree) $this.Killed = $true; $this.KilledTree = $tree; $this.HasExited = $true }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.WaitedMs = $ms; $true }
            $p | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
            $p
        }
        function New-FakeTimer {
            $x = [pscustomobject]@{ Enabled = $false; Starts = 0 }
            $x | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Enabled = $true; $this.Starts = $this.Starts + 1 }
            $x | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Enabled = $false }
            $x
        }
        function Set-TrayState {
            param([hashtable]$P = @{})
            $quit = [pscustomobject]@{ Signalled = $false; WaitedMs = $null }
            $quit | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { param($ms) $this.WaitedMs = $ms; $this.Signalled }
            $s = @{
                Pwsh = 'pwsh'; StatusScript = 'C:\t\avd-photos-status.ps1'; SyncScript = 'C:\t\avd-photos-sync.ps1'; AppScript = ''
                AvdShortcut = (Join-Path $TestDrive 'Google Photos (AVD).lnk'); LogFile = (Join-Path $TestDrive 'tray.log')
                Stats = $null; LastError = $null; LastGoodTick = $null; FailStreak = 0; Collector = $null
                Offloading = $false; OffloadProcess = $null; SpinAngle = 90.0; LastBeatTick = [System.Environment]::TickCount64
                Icons = @{}; Timers = @{ Poll = (New-FakeTimer); Spin = (New-FakeTimer) }; QuitEvent = $quit
                Notify = [pscustomobject]@{ Icon = $null; Text = '' }
            }
            foreach ($k in $P.Keys) { $s[$k] = $P[$k] }
            $script:AvdTray = $s
            $s
        }
        function New-Collector {
            param([AllowNull()][string]$Json, [bool]$Exited = $true, [long]$AgeMs = 0)
            $f = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N') + '.json')
            if ($null -ne $Json) { [System.IO.File]::WriteAllText($f, $Json) }
            @{ Process = (New-FakeProcess -Exited $Exited); OutFile = $f; StartedTick = [System.Environment]::TickCount64 - $AgeMs }
        }
    }

    Context 'collecting (refresh)' {
        BeforeEach { Mock Update-AvdTrayView {} }
        It 'counts a missing status script as a failed collection, as the Swift does' {
            Mock Start-AvdDetachedProcess { New-FakeProcess }
            $t = Set-TrayState @{ StatusScript = '' }
            Start-AvdTrayCollection
            $t.LastError | Should -Be 'avd-photos-status not found'
            $t.FailStreak | Should -Be 1
            Should -Invoke Start-AvdDetachedProcess -Times 0 -Exactly
            Should -Invoke Update-AvdTrayView -Times 1 -Exactly
        }
        It 'starts one windowless pwsh at a time, writing to a temp file' {
            Mock Start-AvdDetachedProcess { New-FakeProcess -Exited $false }
            $t = Set-TrayState
            Start-AvdTrayCollection
            Start-AvdTrayCollection
            Should -Invoke Start-AvdDetachedProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'pwsh' -and $ArgumentList[0] -eq '-NoProfile' -and $ArgumentList -contains '-NonInteractive' -and
                $ArgumentList[3] -eq 'C:\t\avd-photos-status.ps1' -and $ArgumentList[4] -eq '-OutFile' -and $ArgumentList[5] -like '*.json'
            }
            $t.Collector | Should -Not -BeNullOrEmpty
            $t.Timers.Poll.Enabled | Should -BeTrue
        }
        It 'reports a collector that cannot start' {
            Mock Start-AvdDetachedProcess { throw 'no pwsh' }
            $t = Set-TrayState
            Start-AvdTrayCollection
            $t.LastError | Should -Be 'collector failed to start'
            $t.FailStreak | Should -Be 1
            $t.Collector | Should -BeNullOrEmpty
        }
        It 'takes a good result: stats, no error, lastGood now, the streak reset' {
            $c = New-Collector -Json $RealJson
            $t = Set-TrayState @{ Collector = $c; FailStreak = 2; LastError = 'x' }
            $t.Timers.Poll.Start()
            Update-AvdTrayCollection
            $t.Stats.Staged | Should -Be 2831
            $t.LastError | Should -BeNullOrEmpty
            $t.FailStreak | Should -Be 0
            $t.LastGoodTick | Should -Not -BeNullOrEmpty
            $t.Collector | Should -BeNullOrEmpty
            $t.Timers.Poll.Enabled | Should -BeFalse
            $c.Process.Disposed | Should -BeTrue
            Test-Path -LiteralPath $c.OutFile | Should -BeFalse
            Should -Invoke Update-AvdTrayView -Times 1 -Exactly
        }
        It 'names an empty result a timeout and a bad one unparseable, keeping the last stats' {
            $old = New-Healthy
            $t = Set-TrayState @{ Collector = (New-Collector -Json $null); Stats = $old }
            Update-AvdTrayCollection
            $t.LastError | Should -Be 'collector timed out'
            $t.FailStreak | Should -Be 1
            [object]::ReferenceEquals($t.Stats, $old) | Should -BeTrue
            $t.Collector = New-Collector -Json 'garbage'
            Update-AvdTrayCollection
            $t.LastError | Should -Be 'collector output unparseable'
            $t.FailStreak | Should -Be 2
        }
        It 'leaves a collection alone for 25 s, then kills its tree' {
            $c = New-Collector -Json $null -Exited $false -AgeMs 1000
            $t = Set-TrayState @{ Collector = $c }
            Update-AvdTrayCollection
            $c.Process.Killed | Should -BeFalse
            $t.Collector | Should -Not -BeNullOrEmpty
            $c.StartedTick = [System.Environment]::TickCount64 - 26000
            Update-AvdTrayCollection
            $c.Process.Killed | Should -BeTrue
            $c.Process.KilledTree | Should -BeTrue
            $t.Collector | Should -BeNullOrEmpty
            $t.LastError | Should -Be 'collector timed out'
        }
    }

    Context 'rendering' {
        It 'paints the icon and tooltip from the model and spins only while a spinning state shows' {
            Mock Get-AvdTrayIcon { "icon:$($State.Tint)" }
            $t = Set-TrayState @{ Stats = (New-Healthy @{ Running = $true; Remaining = 2500; Phase = 'booting the emulator' }); LastGoodTick = [System.Environment]::TickCount64 }
            Update-AvdTrayView
            $t.Notify.Icon | Should -Be 'icon:dim'
            $t.Notify.Text | Should -Be 'Photo Sync 2.5k - Running -- booting the emulator'
            $t.Timers.Spin.Enabled | Should -BeTrue
            $t.Stats = New-Healthy
            Update-AvdTrayView
            $t.Notify.Icon | Should -Be 'icon:green'
            $t.Notify.Text | Should -Be 'Photo Sync - All backed up - verified 1.0h ago'
            $t.Timers.Spin.Enabled | Should -BeFalse
        }
        It 'turns red once good data is older than 150 s' {
            Mock Get-AvdTrayIcon { "icon:$($State.Tint)|$($State.Mark)" }
            $t = Set-TrayState @{ Stats = (New-Healthy); LastGoodTick = [System.Environment]::TickCount64 - 151000 }
            Update-AvdTrayView
            $t.Notify.Icon | Should -Be 'icon:red|exclaim'
            $t.Notify.Text | Should -Be 'Photo Sync - Meter not refreshing -- collector silent'
        }
        It 'advances the spinner and repaints' {
            Mock Update-AvdTrayView {}
            $t = Set-TrayState
            Invoke-AvdTraySpinner
            $t.SpinAngle | Should -Be 70
            Should -Invoke Update-AvdTrayView -Times 1 -Exactly
        }
        It 'builds the menu model from the tray state and the shortcut on disk' {
            $t = Set-TrayState @{ Stats = (New-Healthy) }
            $m = Get-AvdTrayMenuModel
            @($m | Where-Object Action -EQ 'openAvd').Count | Should -Be 0
            @($m | Where-Object Action -EQ 'offload').Count | Should -Be 1
            [System.IO.File]::WriteAllText($t.AvdShortcut, '')
            $t.SyncScript = ''
            $m = Get-AvdTrayMenuModel
            @($m | Where-Object Action -EQ 'openAvd').Count | Should -Be 1
            @($m | Where-Object Action -EQ 'offload').Count | Should -Be 0
        }
    }

    Context 'actions and the heartbeat' {
        BeforeEach { Mock Start-AvdTrayCollection {} }
        It 'starts one offload run at a time, the sync with -Offload' {
            Mock Start-AvdDetachedProcess { New-FakeProcess -Exited $false }
            $t = Set-TrayState
            Invoke-AvdTrayAction -Action offload
            Invoke-AvdTrayAction -Action offload
            Should -Invoke Start-AvdDetachedProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'pwsh' -and $ArgumentList[3] -eq 'C:\t\avd-photos-sync.ps1' -and $ArgumentList[4] -eq '-Offload'
            }
            $t.Offloading | Should -BeTrue
            Invoke-AvdTrayHeartbeat
            $t.Offloading | Should -BeTrue
            $t.OffloadProcess.HasExited = $true
            Invoke-AvdTrayHeartbeat
            $t.Offloading | Should -BeFalse
            $t.OffloadProcess | Should -BeNullOrEmpty
            Should -Invoke Start-AvdTrayCollection -Times 1 -Exactly
        }
        It 'clears the offload flag and refreshes when the run cannot start' {
            Mock Start-AvdDetachedProcess { throw 'no pwsh' }
            $t = Set-TrayState
            Invoke-AvdTrayOffload
            $t.Offloading | Should -BeFalse
            Should -Invoke Start-AvdTrayCollection -Times 1 -Exactly
        }
        It 'refreshes on a heartbeat more than 10 s late (a wake from sleep), not on a punctual one' {
            $t = Set-TrayState
            Invoke-AvdTrayHeartbeat
            Should -Invoke Start-AvdTrayCollection -Times 0 -Exactly
            $t.LastBeatTick = [System.Environment]::TickCount64 - 11000
            Invoke-AvdTrayHeartbeat
            Should -Invoke Start-AvdTrayCollection -Times 1 -Exactly
        }
        It 'quits when a newer copy signals, and says so in the log' {
            Mock Stop-AvdTrayHost {}
            $t = Set-TrayState
            $t.QuitEvent.Signalled = $true
            Invoke-AvdTrayHeartbeat
            # Polled, never waited on: the UI thread must not block.
            $t.QuitEvent.WaitedMs | Should -Be 0
            Should -Invoke Stop-AvdTrayHost -Times 1 -Exactly
            Get-Content -LiteralPath $t.LogFile -Raw | Should -Match 'newer copy asked this one to quit'
        }
        It 'routes each menu action id, and refuses one it does not know' {
            Mock Invoke-AvdTrayCheck {}
            Mock Invoke-AvdTrayOpenAvd {}
            $null = Set-TrayState
            Invoke-AvdTrayAction -Action refresh
            Invoke-AvdTrayAction -Action check
            Invoke-AvdTrayAction -Action openAvd
            Should -Invoke Start-AvdTrayCollection -Times 1 -Exactly
            Should -Invoke Invoke-AvdTrayCheck -Times 1 -Exactly
            Should -Invoke Invoke-AvdTrayOpenAvd -Times 1 -Exactly
            { Invoke-AvdTrayAction -Action nope } | Should -Throw '*nope*'
        }
        It 'logs a handler error instead of throwing, and passes the handler its argument' {
            $t = Set-TrayState
            { Invoke-AvdTrayGuarded { param($x) throw "boom $x" } -ArgumentList 7 } | Should -Not -Throw
            Get-Content -LiteralPath $t.LogFile -Raw | Should -Match 'tray: boom 7'
        }
    }
}
