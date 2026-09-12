#Requires -Version 7.2
# What only real Windows can answer, run by CI on windows-latest: Task
# Scheduler's reading of the task definitions, the registry type of the user
# PATH, the config ACL, cmd.exe's handling of a .bat's arguments, a process
# tree kill, the detached emulator launch, and the shell's shortcuts. Tagged
# WindowsOnly, so Invoke-Checks skips them elsewhere.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'scheduled tasks as Task Scheduler reads them back' -Tag 'WindowsOnly' {
    BeforeAll {
        $script:Prefix = 'test.avd-photos.' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:BinDir = Join-Path $TestDrive 'bin dir'
        $script:Defs = Get-AvdTaskDefinition -BinDir $BinDir -LabelPrefix $Prefix
        foreach ($d in $Defs) { $null = Register-AvdTask -Definition $d -PwshPath $Pwsh -WorkingDirectory $TestDrive -ErrorAction Stop }
        function Task([string]$Suffix) { Get-ScheduledTask -TaskName "$Prefix.$Suffix" -TaskPath '\' }
    }
    AfterAll {
        foreach ($d in $Defs) { $null = Unregister-AvdTask -Name $d.Name }
    }
    It 'registers the sync at logon and every 15 minutes, indefinitely' {
        $t = Task sync
        $kinds = $t.Triggers | ForEach-Object { $_.CimClass.CimClassName }
        $kinds | Should -Contain 'MSFT_TaskLogonTrigger'
        $kinds | Should -Contain 'MSFT_TaskTimeTrigger'
        $rep = ($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' }).Repetition
        $rep.Interval | Should -Be 'PT15M'
        # Empty (or absent) duration is Task Scheduler's "indefinitely".
        [string]$rep.Duration | Should -BeNullOrEmpty
    }
    It 'runs the sync headless, interactively as this user, on battery, with no time limit, one at a time' {
        $t = Task sync
        $t.Actions[0].Execute | Should -Match 'conhost\.exe$'
        $t.Actions[0].Arguments | Should -Match '^--headless '
        $t.Actions[0].Arguments | Should -Match 'avd-photos-sync\.ps1'
        $t.Principal.LogonType | Should -Be 'Interactive'
        $t.Principal.RunLevel | Should -Be 'Limited'
        $t.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $t.Settings.DisallowStartIfOnBatteries | Should -BeFalse
        $t.Settings.StopIfGoingOnBatteries | Should -BeFalse
        $t.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
        $t.Settings.StartWhenAvailable | Should -BeTrue
        $t.Settings.Priority | Should -Be 7
    }
    It 'registers the weekly setup on Saturday at 05:30' {
        $w = (Task setup).Triggers[0]
        $w.CimClass.CimClassName | Should -Be 'MSFT_TaskWeeklyTrigger'
        $w.DaysOfWeek | Should -Be 64
        $w.StartBoundary | Should -Match 'T05:30:00'
        (Task setup).Actions[0].Arguments | Should -Match '-Headless$'
    }
    It 'registers the tray as plain pwsh, restarted on failure, at normal priority' {
        $t = Task tray
        $t.Actions[0].Execute | Should -Be $Pwsh
        $t.Actions[0].Arguments | Should -Match '-STA'
        $t.Settings.RestartCount | Should -Be 999
        $t.Settings.RestartInterval | Should -Be 'PT1M'
        $t.Settings.Priority | Should -Be 5
    }
    It 'unregisters exactly what it registered' {
        foreach ($d in $Defs) { Unregister-AvdTask -Name $d.Name | Should -BeTrue }
        foreach ($d in $Defs) { Get-ScheduledTask -TaskName $d.Name -TaskPath '\' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
        Unregister-AvdTask -Name "$Prefix.sync" | Should -BeFalse
    }
}

Describe 'the user PATH keeps its registry type' -Tag 'WindowsOnly' {
    It 'writes and reads back REG_EXPAND_SZ with %VARIABLES% unexpanded' {
        $orig = Get-AvdUserPath
        try {
            Set-AvdUserPath -Value '%USERPROFILE%\avd-photos-test;C:\avd photos test' -Kind ExpandString
            $p = Get-AvdUserPath
            $p.Value | Should -Be '%USERPROFILE%\avd-photos-test;C:\avd photos test'
            $p.Kind | Should -Be 'ExpandString'
        } finally {
            Set-AvdUserPath -Value $orig.Value -Kind $orig.Kind
        }
        (Get-AvdUserPath).Value | Should -Be $orig.Value
    }
}

Describe 'the config file is owner-only' -Tag 'WindowsOnly' {
    It 'cuts inheritance and leaves only this user and SYSTEM, once' {
        $p = Join-Path $TestDrive 'config'
        Write-AvdDefaultConfig -Path $p -Platform Windows
        $acl = Get-Acl -LiteralPath $p
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sids | Should -Be (@($me, 'S-1-5-18') | Sort-Object -Unique)
        Protect-AvdFile -Path $p | Should -Be 'already'
        [System.IO.File]::ReadAllText($p) | Should -Match "`r`n"
    }
}

Describe 'the process runner on Windows' -Tag 'WindowsOnly' {
    It 'hands a .bat its arguments intact through cmd.exe (the sdkmanager.bat pattern: %* to the real program)' {
        # The stand-in reads its argv as the C runtime split it
        # ([Environment]::GetCommandLineArgs), not PowerShell's $args, which
        # re-reads a value that starts with a dash as a parameter name --
        # sdkmanager.bat's real target is java, which does no such thing.
        $echo = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echo -Value '$a = [Environment]::GetCommandLineArgs(); $i = [Array]::IndexOf($a, ''-File''); ConvertTo-Json -Compress -InputObject @($a[($i + 2)..($a.Count - 1)])'
        $bat = Join-Path $TestDrive 'fake tool.bat'
        Set-Content -LiteralPath $bat -Value "@`"$Pwsh`" -NoProfile -NonInteractive -File `"$echo`" %*" -Encoding ascii
        $want = @('system-images;android-37.0;google_apis;x86_64', '--sdk_root=C:\Users\John Smith\sdk', 'C:\trailing dir\', 'a&b|c', '(x)^y')
        $r = Invoke-AvdProcess -FilePath $bat -ArgumentList $want -TimeoutSec 120
        $r.ExitCode | Should -Be 0
        ($r.StdOut.Trim() | ConvertFrom-Json) | Should -Be $want
    }
    It 'kills the whole tree on timeout, grandchildren included' {
        $pidFile = Join-Path $TestDrive 'grandchild.pid'
        $cmd = "`$c = Start-Process -FilePath '$Pwsh' -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru -NoNewWindow; Set-Content -LiteralPath '$pidFile' -Value `$c.Id; Start-Sleep -Seconds 120"
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) -TimeoutSec 15
        $r.ExitCode | Should -Be 124
        $grandchild = [int](Get-Content -LiteralPath $pidFile)
        Start-Sleep -Seconds 2
        Get-Process -Id $grandchild -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'launches the emulator detached, appending its output to the log' {
        $log = Join-Path $TestDrive 'logs dir\emulator.log'
        foreach ($n in 1, 2) {
            $p = Start-AvdEmulatorProcess -EmulatorPath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Write-Output 'fake emulator run $n'; exit 0") -LogPath $log -SdkRoot 'C:\sdk'
            $p.WaitForExit(60000) | Should -BeTrue
        }
        $text = [System.IO.File]::ReadAllText($log)
        $text | Should -Match 'fake emulator run 1'
        $text | Should -Match 'fake emulator run 2'
    }
    It 'passes ANDROID_HOME and ANDROID_SDK_ROOT to the emulator' {
        $log = Join-Path $TestDrive 'env.log'
        # No double quote in the command: nothing can carry one through cmd.exe,
        # and ConvertTo-AvdCmdArgument refuses it.
        $p = Start-AvdEmulatorProcess -EmulatorPath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output (''home='' + $env:ANDROID_HOME + '' root='' + $env:ANDROID_SDK_ROOT)') -LogPath $log -SdkRoot 'C:\the sdk'
        $p.WaitForExit(60000) | Should -BeTrue
        [System.IO.File]::ReadAllText($log) | Should -Match 'home=C:\\the sdk root=C:\\the sdk'
    }
    It 'queries emulator processes through CIM without error when none runs' {
        $found = Get-AvdEmulatorProcess -AvdName ('no-such-avd-' + [guid]::NewGuid().ToString('N'))
        $found.Count | Should -Be 0
    }
}

Describe 'shortcuts and the tray signal' -Tag 'WindowsOnly' {
    It 'writes a shortcut that runs the script with pwsh, hidden' {
        $lnk = Join-Path $TestDrive 'Google Photos (AVD).lnk'
        Set-AvdShortcut -Path $lnk -PwshPath $Pwsh -Script 'C:\Users\John Smith\repo\windows\bin\avd-photos-app.ps1' -ScriptArgument @('-Open') -Description 'test'
        Test-Path -LiteralPath $lnk | Should -BeTrue
        $sh = New-Object -ComObject WScript.Shell
        $read = $sh.CreateShortcut($lnk)
        $read.TargetPath | Should -Be $Pwsh
        $read.Arguments | Should -Be '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\John Smith\repo\windows\bin\avd-photos-app.ps1" -Open'
    }
    It 'reports no tray to stop when none runs' {
        Stop-AvdTray | Should -BeFalse
    }
}
