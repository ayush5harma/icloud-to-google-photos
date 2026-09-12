#Requires -Version 7.2
# The installer's definitions (pure, any OS) and the small commands that are
# thin over the config (run as real child processes in a scratch config).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Bin = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin'
}

Describe 'the scheduled-task definitions' {
    BeforeAll { $script:Defs = Get-AvdTaskDefinition -BinDir 'C:\Users\John Smith\icloud-to-google-photos\windows\bin' }
    It 'are the launchd agents minus .app, under the launchd labels' {
        $n = $Defs | ForEach-Object Name
        $n | Should -Be @(
            'com.ayushsharma.icloud-to-google-photos.sync',
            'com.ayushsharma.icloud-to-google-photos.setup',
            'com.ayushsharma.icloud-to-google-photos.bootstrap',
            'com.ayushsharma.icloud-to-google-photos.tray')
        (Get-AvdTaskDefinition -BinDir 'C:\b' -NoTray).Count | Should -Be 3
    }
    It 'run the right script with the right arguments' {
        $by = @{}; foreach ($d in $Defs) { $by[$d.Suffix] = $d }
        $by.sync.Script | Should -Be 'C:\Users\John Smith\icloud-to-google-photos\windows\bin\avd-photos-sync.ps1'
        $by.setup.Arguments | Should -Be @('-Headless')
        $by.bootstrap.Arguments | Should -Be @('-Bootstrap')
        $by.tray.Script | Should -Match 'avd-photos-tray\.ps1$'
    }
    It 'fire when launchd fired: sync at logon and every 15 minutes, setup on Saturday at 05:30' {
        $by = @{}; foreach ($d in $Defs) { $by[$d.Suffix] = $d }
        ($by.sync.Triggers | ForEach-Object Kind) | Should -Be @('Logon', 'Repeat')
        ($by.sync.Triggers | Where-Object Kind -EQ 'Repeat').Minutes | Should -Be 15
        $by.setup.Triggers[0].Kind | Should -Be 'Weekly'
        $by.setup.Triggers[0].Day | Should -Be 'Saturday'
        $by.setup.Triggers[0].At | Should -Be '05:30'
        $by.bootstrap.Triggers[0].Kind | Should -Be 'Logon'
        $by.tray.Triggers[0].Kind | Should -Be 'Logon'
    }
    It 'run the background tasks below normal and the tray at normal priority' {
        ($Defs | Where-Object { -not $_.Tray } | ForEach-Object Priority) | Should -Be @(7, 7, 7)
        ($Defs | Where-Object Tray).Priority | Should -Be 5
    }
}

Describe 'the task actions' {
    BeforeAll {
        $script:Defs = Get-AvdTaskDefinition -BinDir 'C:\Users\John Smith\repo\windows\bin'
        $script:P = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
    It 'run a background task under conhost --headless with every path quoted' {
        $a = Get-AvdTaskAction -Definition $Defs[1] -PwshPath $P -SystemRoot 'C:\Windows'
        $a.Execute | Should -Be 'C:\Windows\System32\conhost.exe'
        $a.Argument | Should -Be '--headless "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Users\John Smith\repo\windows\bin\avd-photos-setup.ps1" -Headless'
    }
    It 'fall back to a hidden pwsh with -VisibleConsole' {
        $a = Get-AvdTaskAction -Definition $Defs[0] -PwshPath $P -VisibleConsole
        $a.Execute | Should -Be $P
        $a.Argument | Should -Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\John Smith\repo\windows\bin\avd-photos-sync.ps1"'
    }
    It 'never put the tray under conhost, and run it STA' {
        $a = Get-AvdTaskAction -Definition $Defs[3] -PwshPath $P
        $a.Execute | Should -Be $P
        $a.Argument | Should -Match '-WindowStyle Hidden -STA -File '
    }
}

Describe 'the user PATH edit' {
    It 'appends once, comparing as Windows does' {
        Add-AvdPathEntry -PathValue 'C:\a;%USERPROFILE%\b' -Entry 'C:\x\bin' | Should -Be 'C:\a;%USERPROFILE%\b;C:\x\bin'
        Add-AvdPathEntry -PathValue 'C:\a;c:\X\BIN\' -Entry 'C:\x\bin' | Should -Be 'C:\a;c:\X\BIN\'
        Add-AvdPathEntry -PathValue '' -Entry 'C:\x' | Should -Be 'C:\x'
        Add-AvdPathEntry -PathValue $null -Entry 'C:\x' | Should -Be 'C:\x'
        Add-AvdPathEntry -PathValue 'C:\a;;' -Entry 'C:\x' | Should -Be 'C:\a;C:\x'
    }
    It 'removes exactly its own entry and nothing else' {
        Remove-AvdPathEntry -PathValue 'C:\a;C:\x\bin\;%LOCALAPPDATA%\y;C:\x\bin2' -Entry 'C:\X\bin' | Should -Be 'C:\a;%LOCALAPPDATA%\y;C:\x\bin2'
        Remove-AvdPathEntry -PathValue 'C:\a' -Entry 'C:\x' | Should -Be 'C:\a'
    }
}

Describe 'the install layout' {
    It 'points at the checkout, or at a copy under LOCALAPPDATA that keeps its layout' {
        $l = Get-AvdInstallLayout -RepoRoot 'D:\src\repo' -LocalAppData 'C:\Users\me\AppData\Local'
        $l.BinDir | Should -Be 'D:\src\repo\windows\bin'
        $c = Get-AvdInstallLayout -RepoRoot 'D:\src\repo' -LocalAppData 'C:\Users\me\AppData\Local' -Copy
        $c.Root | Should -Be 'C:\Users\me\AppData\Local\avd-photos\app'
        $c.BinDir | Should -Be 'C:\Users\me\AppData\Local\avd-photos\app\windows\bin'
        $c.Items | Should -Contain 'bin\avd-photos-reclaim.py'
        $c.Items | Should -Contain 'windows\device'
    }
}

Describe 'avd-photos-arm and avd-photos-config' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Saved = @{}
        foreach ($k in 'AVD_PHOTOS_CONFIG_DIR', 'AVD_PHOTOS_STATE_DIR', 'AVD_PHOTOS_LOG_DIR', 'ICLOUD_USERNAME', 'DELETE_FROM_ICLOUD', 'KEEP_ICLOUD_DAYS') {
            $Saved[$k] = [System.Environment]::GetEnvironmentVariable($k)
            # [NullString]::Value: a plain $null reaches .NET as '' and would
            # leave an EMPTY variable, which the config rightly reads as set.
            [System.Environment]::SetEnvironmentVariable($k, [NullString]::Value)
        }
        $env:AVD_PHOTOS_CONFIG_DIR = Join-Path $Dir 'config'
        $env:AVD_PHOTOS_STATE_DIR = Join-Path $Dir 'state'
        function Run([string]$Name, [string[]]$A = @()) {
            Invoke-AvdProcess -FilePath $Pwsh -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', (Join-Path $Bin $Name)) + $A) -TimeoutSec 120
        }
    }
    AfterEach {
        foreach ($k in $Saved.Keys) {
            $v = if ($null -eq $Saved[$k]) { [NullString]::Value } else { $Saved[$k] }
            [System.Environment]::SetEnvironmentVariable($k, $v)
        }
    }
    It 'refuses to arm without an Apple ID' {
        $r = Run 'avd-photos-arm.ps1'
        $r.ExitCode | Should -Be 1 -Because ($r.StdOut + $r.StdErr)
        $r.StdErr | Should -Match 'ICLOUD_USERNAME'
        Test-Path (Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'ENABLED') | Should -BeFalse
    }
    It 'needs -Yes to arm while iCloud deletion is on, and prints what it switches on' {
        $env:ICLOUD_USERNAME = 'someone@example.invalid'
        $r = Run 'avd-photos-arm.ps1'
        $r.ExitCode | Should -Be 1 -Because ($r.StdOut + $r.StdErr)
        ($r.StdOut + $r.StdErr) | Should -Match 'Not armed\. Re-run as: avd-photos-arm -Yes'
        ($r.StdOut + $r.StdErr) | Should -Match 'keep the newest\s+7 day'
        Test-Path (Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'ENABLED') | Should -BeFalse
        $r = Run 'avd-photos-arm.ps1' @('-Yes')
        $r.ExitCode | Should -Be 0 -Because ($r.StdOut + $r.StdErr)
        Test-Path (Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'ENABLED') | Should -BeTrue
        (Run 'avd-photos-arm.ps1' @('-Status')).StdOut | Should -Match '^armed'
        (Run 'avd-photos-arm.ps1' @('-Off')).ExitCode | Should -Be 0
        Test-Path (Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'ENABLED') | Should -BeFalse
        (Run 'avd-photos-arm.ps1' @('-Status')).StdOut | Should -Match '^dormant'
    }
    It 'arms without -Yes when nothing can be deleted' {
        $env:ICLOUD_USERNAME = 'someone@example.invalid'
        $env:DELETE_FROM_ICLOUD = '0'
        (Run 'avd-photos-arm.ps1').ExitCode | Should -Be 0
        Test-Path (Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'ENABLED') | Should -BeTrue
    }
    It 'rejects conflicting switches' {
        (Run 'avd-photos-arm.ps1' @('-Yes', '-Off')).ExitCode | Should -Be 2
        (Run 'avd-photos-config.ps1' @('-Force', '-Paths')).ExitCode | Should -Be 2
    }
    It 'writes the default config once, keeps a .bak on -Force, and reports a bad line' {
        $cfgFile = Join-Path $env:AVD_PHOTOS_CONFIG_DIR 'config'
        (Run 'avd-photos-config.ps1').ExitCode | Should -Be 0
        Test-Path $cfgFile | Should -BeTrue
        [System.IO.File]::AppendAllText($cfgFile, "not an assignment`n")
        $r = Run 'avd-photos-config.ps1' @('-Paths')
        $r.StdOut | Should -Match 'avd home'
        $r.StdOut | Should -Match 'config: .*not a KEY=value assignment'
        (Run 'avd-photos-config.ps1' @('-Force')).ExitCode | Should -Be 0
        Test-Path "$cfgFile.bak" | Should -BeTrue
        [System.IO.File]::ReadAllText($cfgFile) | Should -Not -Match 'not an assignment'
    }
}
