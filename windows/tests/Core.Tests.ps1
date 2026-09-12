#Requires -Version 7.2
# The core module: config contract, paths, files, logs, locks, the process
# runner and the adb helpers. Pure functions are tested with explicit inputs
# (the environment included), so every case here runs on any OS.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Pwsh = (Get-Process -Id $PID).Path
    function New-WinEnv {
        param([hashtable]$Extra = @{})
        $e = @{
            USERPROFILE  = 'C:\Users\me'
            APPDATA      = 'C:\Users\me\AppData\Roaming'
            LOCALAPPDATA = 'C:\Users\me\AppData\Local'
        }
        foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
        $e
    }
}

Describe 'the key list' {
    It 'has the 31 keys of lib/config.sh, once each' {
        $k = Get-AvdConfigKey
        $k.Count | Should -Be 31
        ($k | Sort-Object -Unique).Count | Should -Be 31
    }
}

Describe 'Join-AvdPath' {
    It 'joins with the target platform separator, whatever the host' {
        Join-AvdPath Windows 'C:\Users\me', 'Pictures' | Should -Be 'C:\Users\me\Pictures'
        Join-AvdPath Unix '/home/me', 'Pictures' | Should -Be '/home/me/Pictures'
    }
    It 'does not double separators and skips empty parts' {
        Join-AvdPath Windows 'C:\a\', '\b', '', 'c' | Should -Be 'C:\a\b\c'
    }
}

Describe 'Get-AvdPathSet' {
    It 'puts config in APPDATA and state and logs in LOCALAPPDATA on Windows' {
        $p = Get-AvdPathSet -Platform Windows -Environment (New-WinEnv)
        $p.CONFIG_DIR | Should -Be 'C:\Users\me\AppData\Roaming\avd-photos'
        $p.STATE_DIR | Should -Be 'C:\Users\me\AppData\Local\avd-photos'
        $p.LOG_DIR | Should -Be 'C:\Users\me\AppData\Local\avd-photos\logs'
        $p.CONFIG_FILE | Should -Be 'C:\Users\me\AppData\Roaming\avd-photos\config'
        $p.SENTINEL | Should -Be 'C:\Users\me\AppData\Roaming\avd-photos\ENABLED'
    }
    It 'takes the three AVD_PHOTOS_* overrides, and the log dir follows the state dir' {
        $p = Get-AvdPathSet -Platform Windows -Environment (New-WinEnv @{ AVD_PHOTOS_CONFIG_DIR = 'D:\c'; AVD_PHOTOS_STATE_DIR = 'D:\s' })
        $p.CONFIG_DIR | Should -Be 'D:\c'
        $p.STATE_DIR | Should -Be 'D:\s'
        $p.LOG_DIR | Should -Be 'D:\s\logs'
    }
    It 'treats an EMPTY override as unset, as ${VAR:-default} does' {
        $p = Get-AvdPathSet -Platform Windows -Environment (New-WinEnv @{ AVD_PHOTOS_STATE_DIR = '' })
        $p.STATE_DIR | Should -Be 'C:\Users\me\AppData\Local\avd-photos'
    }
    It 'matches lib/config.sh on Unix' {
        $p = Get-AvdPathSet -Platform Unix -Environment @{ HOME = '/Users/me' }
        $p.CONFIG_DIR | Should -Be '/Users/me/.config/avd-photos'
        $p.STATE_DIR | Should -Be '/Users/me/.cache/avd-photos'
        $p.LOG_DIR | Should -Be '/Users/me/.cache/avd-photos/logs'
    }
}

Describe 'Resolve-AvdHome' {
    It 'follows the emulator order: ANDROID_AVD_HOME, ANDROID_USER_HOME, ANDROID_SDK_HOME, the profile' {
        Resolve-AvdHome -Platform Windows -Environment (New-WinEnv) | Should -Be 'C:\Users\me\.android\avd'
        Resolve-AvdHome -Platform Windows -Environment (New-WinEnv @{ ANDROID_SDK_HOME = 'E:\sdkhome' }) | Should -Be 'E:\sdkhome\.android\avd'
        Resolve-AvdHome -Platform Windows -Environment (New-WinEnv @{ ANDROID_SDK_HOME = 'E:\x'; ANDROID_USER_HOME = 'E:\u' }) | Should -Be 'E:\u\avd'
        Resolve-AvdHome -Platform Windows -Environment (New-WinEnv @{ ANDROID_USER_HOME = 'E:\u'; ANDROID_AVD_HOME = 'C:\avd' }) | Should -Be 'C:\avd'
    }
}

Describe 'the machine architecture, not the process''s' {
    It 'answers X64 on an x64 PC and Arm64 on an Arm64 PC for a native pwsh' {
        $x = Get-AvdHostArchitecture -OsArchitecture X64 -ProcessArchitecture X64 -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64' }
        $x.Os | Should -Be 'X64'
        $x.Process | Should -Be 'X64'
        $x.Emulated | Should -BeFalse
        $a = Get-AvdHostArchitecture -OsArchitecture Arm64 -ProcessArchitecture Arm64 -Environment @{ PROCESSOR_ARCHITECTURE = 'ARM64' }
        $a.Os | Should -Be 'Arm64'
        $a.Process | Should -Be 'Arm64'
        $a.Emulated | Should -BeFalse
    }
    It 'answers Arm64 for an x64 pwsh under emulation, which is told PROCESSOR_ARCHITECTURE=AMD64' {
        $e = Get-AvdHostArchitecture -OsArchitecture Arm64 -ProcessArchitecture X64 -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64' }
        $e.Os | Should -Be 'Arm64'
        $e.Process | Should -Be 'X64'
        $e.Emulated | Should -BeTrue
    }
    It 'takes PROCESSOR_ARCHITEW6432 as the machine when the runtime answers with the process''s view' {
        $e = Get-AvdHostArchitecture -OsArchitecture X64 -ProcessArchitecture X64 -Environment @{ PROCESSOR_ARCHITECTURE = 'AMD64'; PROCESSOR_ARCHITEW6432 = 'ARM64' }
        $e.Os | Should -Be 'Arm64'
        $e.Emulated | Should -BeTrue
    }
    It 'answers for a 32-bit x86 pwsh under WOW64, on either machine' {
        $onArm = Get-AvdHostArchitecture -OsArchitecture Arm64 -ProcessArchitecture X86 -Environment @{ PROCESSOR_ARCHITECTURE = 'x86'; PROCESSOR_ARCHITEW6432 = 'ARM64' }
        $onArm.Os | Should -Be 'Arm64'
        $onArm.Process | Should -Be 'X86'
        $onArm.Emulated | Should -BeTrue
        $onX64 = Get-AvdHostArchitecture -OsArchitecture X64 -ProcessArchitecture X86 -Environment @{ PROCESSOR_ARCHITECTURE = 'x86'; PROCESSOR_ARCHITEW6432 = 'AMD64' }
        $onX64.Os | Should -Be 'X64'
        $onX64.Process | Should -Be 'X86'
        $onX64.Emulated | Should -BeTrue
    }
    It 'falls back to the environment when the runtime gives nothing' {
        $e = Get-AvdHostArchitecture -OsArchitecture '' -ProcessArchitecture '' -Environment @{ PROCESSOR_ARCHITECTURE = 'ARM64' }
        $e.Os | Should -Be 'Arm64'
        $e.Process | Should -Be 'Arm64'
    }
    It 'spells every name one way' {
        foreach ($n in 'X64', 'AMD64', 'x64', 'x86_64') { ConvertTo-AvdArchitectureName $n | Should -Be 'X64' -Because $n }
        foreach ($n in 'Arm64', 'ARM64', 'aarch64') { ConvertTo-AvdArchitectureName $n | Should -Be 'Arm64' -Because $n }
        foreach ($n in 'X86', 'x86', 'i686') { ConvertTo-AvdArchitectureName $n | Should -Be 'X86' -Because $n }
        ConvertTo-AvdArchitectureName 'RiscV64' | Should -Be 'RiscV64'
        ConvertTo-AvdArchitectureName $null | Should -Be ''
    }
    It 'answers for this host with the runtime''s own values' {
        $h = Get-AvdHostArchitecture
        $h.Os | Should -Be (ConvertTo-AvdArchitectureName ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture))
        $h.Process | Should -Be (ConvertTo-AvdArchitectureName ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture))
    }
}

Describe 'an executable''s architecture, from its PE header' {
    BeforeAll {
        # A DOS header whose e_lfanew points at "PE\0\0" and the machine field.
        function New-PeHeader([int]$Machine, [int]$Offset = 0x80) {
            $b = [byte[]]::new(0x100)
            $b[0] = 0x4D; $b[1] = 0x5A
            [System.BitConverter]::GetBytes([int]$Offset).CopyTo($b, 0x3C)
            $b[$Offset] = 0x50; $b[$Offset + 1] = 0x45
            [System.BitConverter]::GetBytes([uint16]$Machine).CopyTo($b, $Offset + 4)
            , $b
        }
    }
    It 'reads x64, arm64 and x86 and nothing else' {
        Get-AvdPeArchitecture -Header (New-PeHeader 0x8664) | Should -Be 'X64'
        Get-AvdPeArchitecture -Header (New-PeHeader 0xAA64) | Should -Be 'Arm64'
        Get-AvdPeArchitecture -Header (New-PeHeader 0x014C) | Should -Be 'X86'
        Get-AvdPeArchitecture -Header (New-PeHeader 0x01C4) | Should -Be ''
    }
    It 'refuses what is not a PE header rather than guessing' {
        Get-AvdPeArchitecture -Header ([System.Text.Encoding]::ASCII.GetBytes('#!/bin/sh' + (' ' * 80))) | Should -Be ''
        # e_lfanew past the bytes that were read.
        $far = New-PeHeader 0x8664
        [System.BitConverter]::GetBytes([int]0x1000).CopyTo($far, 0x3C)
        Get-AvdPeArchitecture -Header $far | Should -Be ''
        $noSig = New-PeHeader 0x8664; $noSig[0x80] = 0
        Get-AvdPeArchitecture -Header $noSig | Should -Be ''
        Get-AvdPeArchitecture -Header ([byte[]]@(0x4D, 0x5A)) | Should -Be ''
        Get-AvdPeArchitecture -Header $null | Should -Be ''
    }
    It 'reads a file, and answers empty for a missing or empty one' {
        $f = Join-Path $TestDrive 'tool.exe'
        [System.IO.File]::WriteAllBytes($f, (New-PeHeader 0xAA64))
        Get-AvdExecutableArchitecture -Path $f | Should -Be 'Arm64'
        Get-AvdExecutableArchitecture -Path (Join-Path $TestDrive 'nope.exe') | Should -Be ''
        $empty = Join-Path $TestDrive 'empty.exe'
        [System.IO.File]::WriteAllBytes($empty, [byte[]]@())
        Get-AvdExecutableArchitecture -Path $empty | Should -Be ''
        Get-AvdExecutableArchitecture -Path '' | Should -Be ''
    }
}

Describe 'Get-AvdDefault' {
    It 'uses x86_64, four cores and Windows locations on an x64 PC' {
        $d = Get-AvdDefault -Platform Windows -Environment (New-WinEnv) -Architecture X64
        $d.AVD_ABI | Should -Be 'x86_64'
        $d.AVD_CORES | Should -Be '4'
        $d.AVD_SDK_ROOT | Should -Be 'C:\Users\me\AppData\Local\android-avd-sdk'
        $d.STAGING | Should -Be 'C:\Users\me\Pictures\icloud-photos-staging'
        $d.ICLOUD_DIR | Should -Be 'C:\Users\me\iCloudDrive'
        $d.SHARED_CACHE_DIR | Should -Be 'C:\Users\me\iCloudDrive\avd-photos'
    }
    It 'uses arm64-v8a on Windows on Arm, and nothing else changes with the architecture' {
        $a = Get-AvdDefault -Platform Windows -Environment (New-WinEnv) -Architecture Arm64
        $x = Get-AvdDefault -Platform Windows -Environment (New-WinEnv) -Architecture X64
        $a.AVD_ABI | Should -Be 'arm64-v8a'
        foreach ($k in (Get-AvdConfigKey)) {
            if ($k -eq 'AVD_ABI') { continue }
            $a[$k] | Should -Be $x[$k] -Because $k
        }
    }
    It 'keeps the macOS defaults on Unix whatever the architecture' {
        (Get-AvdDefault -Platform Unix -Environment @{ HOME = '/Users/me' } -Architecture X64).AVD_ABI | Should -Be 'arm64-v8a'
        (Get-AvdDefault -Platform Unix -Environment @{ HOME = '/Users/me' } -Architecture Arm64).AVD_CORES | Should -Be '8'
    }
    It 'keeps every other default identical to macOS' {
        $w = Get-AvdDefault -Platform Windows -Environment (New-WinEnv) -Architecture X64
        $u = Get-AvdDefault -Platform Unix -Environment @{ HOME = '/Users/me' }
        $platformKeys = 'STAGING', 'ICLOUD_DIR', 'SHARED_CACHE_DIR', 'AVD_SDK_ROOT', 'AVD_ABI', 'AVD_CORES'
        foreach ($k in (Get-AvdConfigKey)) {
            if ($platformKeys -contains $k) { continue }
            $w[$k] | Should -Be $u[$k] -Because $k
        }
    }
}

Describe 'what to install, per architecture' {
    It 'names the same winget packages, pinned to arm64 on Windows on Arm' {
        Get-AvdInstallHint -Tool pwsh -Architecture X64 | Should -Be 'winget install --id Microsoft.PowerShell --source winget'
        Get-AvdInstallHint -Tool pwsh -Architecture Arm64 | Should -Be 'winget install --id Microsoft.PowerShell --source winget --architecture arm64'
        Get-AvdInstallHint -Tool java -Architecture X64 | Should -Be 'winget install Microsoft.OpenJDK.21'
        Get-AvdInstallHint -Tool java -Architecture Arm64 | Should -Be 'winget install Microsoft.OpenJDK.21 --architecture arm64'
        Get-AvdInstallHint -Tool git -Architecture Arm64 | Should -Be 'winget install Git.Git --architecture arm64'
        Get-AvdInstallHint -Tool uv -Architecture Arm64 | Should -Be 'winget install astral-sh.uv --architecture arm64'
    }
    It 'installs icloudpd''s own build on x64 and its pure-Python wheel under Python 3.13 on Arm64' {
        Get-AvdInstallHint -Tool icloudpd -Architecture X64 | Should -Be 'uv tool install icloudpd'
        Get-AvdInstallHint -Tool icloudpd -Architecture Arm64 | Should -Be 'uv tool install --python 3.13 icloudpd'
        $a = Get-AvdIcloudpdInstallArgument -Architecture Arm64
        , $a | Should -BeOfType [string[]]
        $a | Should -Be @('tool', 'install', '--python', '3.13', 'icloudpd')
    }
    It 'treats a config without an architecture as x64' {
        Get-AvdConfigArchitecture ([pscustomobject]@{ PLATFORM = 'Windows' }) | Should -Be ''
        Get-AvdConfigArchitecture ([pscustomobject]@{ ARCHITECTURE = 'Arm64' }) | Should -Be 'Arm64'
        Get-AvdInstallHint -Tool java -Architecture '' | Should -Be 'winget install Microsoft.OpenJDK.21'
    }
}

Describe 'Expand-AvdConfigValue' {
    BeforeAll { $script:envs = @{ USERPROFILE = 'C:\Users\me'; TEMP = 'C:\T' } }
    It 'expands $NAME and ${NAME} from the lookup first, then the environment' {
        Expand-AvdConfigValue -Value '$BASE\x' -Lookup @{ BASE = 'D:\p' } -Environment $envs -HomeDir 'C:\Users\me' | Should -Be 'D:\p\x'
        Expand-AvdConfigValue -Value '${TEMP}x' -Lookup @{} -Environment $envs -HomeDir 'C:\Users\me' | Should -Be 'C:\Tx'
        Expand-AvdConfigValue -Value '$TEMP' -Lookup @{ TEMP = 'L' } -Environment $envs -HomeDir 'h' | Should -Be 'L'
    }
    It 'makes an unknown $NAME empty, as the shell does' {
        Expand-AvdConfigValue -Value 'a$NOPE/b' -Lookup @{} -Environment $envs -HomeDir 'h' | Should -Be 'a/b'
    }
    It 'falls back to the profile directory for $HOME' {
        Expand-AvdConfigValue -Value '$HOME\Pictures' -Lookup @{} -Environment $envs -HomeDir 'C:\Users\me' | Should -Be 'C:\Users\me\Pictures'
    }
    It 'expands %NAME% from the environment and leaves an unknown one as written' {
        Expand-AvdConfigValue -Value '%USERPROFILE%\a' -Lookup @{} -Environment $envs -HomeDir 'h' | Should -Be 'C:\Users\me\a'
        Expand-AvdConfigValue -Value '%NOPE%\a' -Lookup @{} -Environment $envs -HomeDir 'h' | Should -Be '%NOPE%\a'
        Expand-AvdConfigValue -Value '100%' -Lookup @{} -Environment $envs -HomeDir 'h' | Should -Be '100%'
    }
    It 'expands a leading ~ only' {
        Expand-AvdConfigValue -Value '~\x' -Lookup @{} -Environment $envs -HomeDir 'C:\Users\me' | Should -Be 'C:\Users\me\x'
        Expand-AvdConfigValue -Value 'a~b' -Lookup @{} -Environment $envs -HomeDir 'C:\Users\me' | Should -Be 'a~b'
    }
    It 'keeps a lone or trailing $ and never expands twice' {
        Expand-AvdConfigValue -Value 'a$ b$' -Lookup @{} -Environment $envs -HomeDir 'h' | Should -Be 'a$ b$'
        Expand-AvdConfigValue -Value '$A' -Lookup @{ A = '$B'; B = 'no' } -Environment $envs -HomeDir 'h' | Should -Be '$B'
    }
}

Describe 'ConvertFrom-AvdConfigText' {
    BeforeAll {
        $envs = @{ USERPROFILE = 'C:\Users\me' }
        function Parse([string]$t) { ConvertFrom-AvdConfigText -Text $t -Seed @{} -Environment $envs -HomeDir 'C:\Users\me' }
    }
    It 'keeps backslashes literal in an unquoted Windows path' {
        (Parse 'STAGING=C:\Users\me\Pictures\x').Values.STAGING | Should -Be 'C:\Users\me\Pictures\x'
    }
    It 'takes the rest of the line, so a path with spaces needs no quotes' {
        (Parse 'STAGING=C:\Users\John Smith\Pictures').Values.STAGING | Should -Be 'C:\Users\John Smith\Pictures'
    }
    It 'drops a trailing comment but keeps a # inside a word' {
        (Parse 'STAGING=D:\photos   # the big disk').Values.STAGING | Should -Be 'D:\photos'
        (Parse 'STAGING=D:\a#b').Values.STAGING | Should -Be 'D:\a#b'
    }
    It 'takes double-quoted values with spaces, and a drive root, verbatim' {
        (Parse 'STAGING="C:\Users\John Smith\P"').Values.STAGING | Should -Be 'C:\Users\John Smith\P'
        (Parse 'STAGING="D:\"').Values.STAGING | Should -Be 'D:\'
    }
    It 'does not expand inside single quotes, and does inside double quotes' {
        (Parse "STAGING='`$HOME\x'").Values.STAGING | Should -Be '$HOME\x'
        (Parse 'STAGING="$HOME\x"').Values.STAGING | Should -Be 'C:\Users\me\x'
    }
    It 'records an empty value as SET (KEEP_ICLOUD_DAYS= means no floor)' {
        $v = (Parse 'KEEP_ICLOUD_DAYS=').Values
        $v.Contains('KEEP_ICLOUD_DAYS') | Should -BeTrue
        $v.KEEP_ICLOUD_DAYS | Should -Be ''
    }
    It 'accepts export and spaces around =, ignores comments and blank lines' {
        $v = (Parse "# c`n`nexport AVD_GPU=host`n  AVD_RAM = 4096`n#AVD_CORES=2").Values
        $v.AVD_GPU | Should -Be 'host'
        $v.AVD_RAM | Should -Be '4096'
        $v.Contains('AVD_CORES') | Should -BeFalse
    }
    It 'lets a later line use an earlier assignment, known key or not, and keeps only known keys' {
        $r = Parse "BASE=D:\photos`nSTAGING=`$BASE\staging"
        $r.Values.STAGING | Should -Be 'D:\photos\staging'
        $r.Values.Contains('BASE') | Should -BeFalse
    }
    It 'reads a BOM and CRLF line endings' {
        $t = [char]0xFEFF + "ICLOUD_USERNAME=a@b.c`r`nAVD_NAME=x`r`n"
        $v = (Parse $t).Values
        $v.ICLOUD_USERNAME | Should -Be 'a@b.c'
        $v.AVD_NAME | Should -Be 'x'
    }
    It 'reports a line that is not an assignment instead of dropping it silently' {
        $r = Parse "this is not config`nAVD_NAME=x"
        $r.Warnings.Count | Should -Be 1
        $r.Warnings[0] | Should -Match 'line 1'
        $r.Values.AVD_NAME | Should -Be 'x'
    }
    It 'never repeats a line in a warning, so a mistyped token cannot reach a log' {
        $r = Parse "set GITHUB_TOKEN=ghp_notarealtoken1`n`$env:GITHUB_TOKEN = 'ghp_notarealtoken2'`nghp_notarealtoken3`nGITHUB_TOKEN='ghp_notarealtoken4'tail5"
        $r.Warnings.Count | Should -Be 4
        ($r.Warnings -join "`n") | Should -Not -Match 'notarealtoken|tail5'
        $r.Warnings[0] | Should -BeExactly 'line 1: not a KEY=value assignment, ignored (it names GITHUB_TOKEN; the line is not repeated here)'
        $r.Warnings[1] | Should -Match '^line 2: .*it names GITHUB_TOKEN'
        $r.Warnings[2] | Should -BeExactly 'line 3: not a KEY=value assignment, ignored (the line is not repeated here, in case it holds a secret)'
        $r.Warnings[3] | Should -BeExactly 'line 4: text after the closing quote of GITHUB_TOKEN ignored'
    }
    It 'names a known key only as a whole word' {
        (Parse 'set MY_GITHUB_TOKENS=1').Warnings[0] | Should -Match 'in case it holds a secret'
    }
    It 'reports an unterminated quote and text after a closing quote' {
        $r = Parse "STAGING=`"C:\x`nAVD_NAME='a' b"
        $r.Values.Contains('STAGING') | Should -BeFalse
        $r.Values.AVD_NAME | Should -Be 'a'
        $r.Warnings.Count | Should -Be 2
    }
    It 'lets the last assignment win' {
        (Parse "AVD_NAME=a`nAVD_NAME=b").Values.AVD_NAME | Should -Be 'b'
    }
    It 'reads a value starting with # as empty, as the shell reads a comment' {
        (Parse 'GOOGLE_ACCOUNT=#later').Values.GOOGLE_ACCOUNT | Should -Be ''
    }
}

Describe 'Get-AvdConfig precedence' {
    BeforeEach {
        $cdir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $cdir
        $base = New-WinEnv @{ AVD_PHOTOS_CONFIG_DIR = $cdir; AVD_PHOTOS_STATE_DIR = (Join-Path $cdir 'state') }
        # The host platform: the config file is read from a real directory.
        function Cfg([hashtable]$Extra = @{}) {
            $e = @{}; foreach ($k in $base.Keys) { $e[$k] = $base[$k] }; foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
            Get-AvdConfig -Environment $e -Platform (Get-AvdPlatform) -NoCreate
        }
        function SetFile([string]$t) { [System.IO.File]::WriteAllText((Join-Path $cdir 'config'), $t) }
    }
    It 'uses the defaults with no file' {
        $c = Cfg
        $c.AVD_NAME | Should -Be 'gphotos-tablet'
        $c.SOURCES.AVD_NAME | Should -Be 'default'
        $c.WARNINGS.Count | Should -Be 0
    }
    It 'lets the file beat the default and the environment beat the file' {
        SetFile "AVD_GPU=swiftshader_indirect`nAVD_NAME=fromfile"
        $c = Cfg @{ AVD_GPU = 'host' }
        $c.AVD_GPU | Should -Be 'host'
        $c.SOURCES.AVD_GPU | Should -Be 'environment'
        $c.AVD_NAME | Should -Be 'fromfile'
        $c.SOURCES.AVD_NAME | Should -Be 'config'
    }
    It 'decides by SET, not non-empty: an empty environment value beats the file' {
        SetFile 'KEEP_ICLOUD_DAYS=7'
        $c = Cfg @{ KEEP_ICLOUD_DAYS = '' }
        $c.KEEP_ICLOUD_DAYS | Should -Be ''
        Get-AvdConfigInt -Config $c -Key KEEP_ICLOUD_DAYS | Should -Be 0
    }
    It 'lets an empty file value beat the default' {
        SetFile 'KEEP_ICLOUD_DAYS='
        (Cfg).KEEP_ICLOUD_DAYS | Should -Be ''
    }
    It 'moves SHARED_CACHE_DIR with a configured ICLOUD_DIR unless it is set itself' {
        SetFile 'ICLOUD_DIR=E:\iCloud'
        (Cfg).SHARED_CACHE_DIR | Should -Be (Join-AvdPath (Get-AvdPlatform) 'E:\iCloud', 'avd-photos')
        SetFile "ICLOUD_DIR=E:\iCloud`nSHARED_CACHE_DIR=F:\cache"
        (Cfg).SHARED_CACHE_DIR | Should -Be 'F:\cache'
    }
    It 'shows the file what the environment set, as a sourced file would see' {
        SetFile 'STAGING=$AVD_NAME-staging'
        (Cfg @{ AVD_NAME = 'envname' }).STAGING | Should -Be 'envname-staging'
    }
    It 'warns about a non-numeric number and falls back to its default' {
        SetFile 'PUSH_CAP=lots'
        $c = Cfg
        ($c.WARNINGS -join "`n") | Should -Match 'PUSH_CAP=lots'
        Get-AvdConfigInt -Config $c -Key PUSH_CAP | Should -Be 1000
    }
    It 'reports the parser warnings with the file name' {
        SetFile 'nonsense'
        ((Cfg).WARNINGS -join "`n") | Should -Match 'config: line 1'
    }
    It 'creates the three directories unless told not to' {
        $e = @{}; foreach ($k in $base.Keys) { $e[$k] = $base[$k] }
        $null = Get-AvdConfig -Environment $e -Platform (Get-AvdPlatform) -NoCreate
        Test-Path (Join-Path $cdir 'state') | Should -BeFalse
        $null = Get-AvdConfig -Environment $e -Platform (Get-AvdPlatform)
        Test-Path (Join-Path $cdir 'state') | Should -BeTrue
    }
    It 'resolves the AVD home and carries the label prefix' {
        $c = Cfg @{ ANDROID_AVD_HOME = 'C:\avd' }
        $c.AVD_HOME | Should -Be 'C:\avd'
        $c.LABEL_PREFIX | Should -Be 'com.ayushsharma.icloud-to-google-photos'
    }
    It 'carries the machine''s architecture, and the AVD_ABI default follows it unless AVD_ABI is set' {
        $e = @{}; foreach ($k in $base.Keys) { $e[$k] = $base[$k] }
        $a = Get-AvdConfig -Environment $e -Platform Windows -Architecture Arm64 -NoCreate
        $a.ARCHITECTURE | Should -Be 'Arm64'
        $a.AVD_ABI | Should -Be 'arm64-v8a'
        $a.SOURCES.AVD_ABI | Should -Be 'default'
        (Get-AvdConfig -Environment $e -Platform Windows -Architecture X64 -NoCreate).AVD_ABI | Should -Be 'x86_64'
        $e['AVD_ABI'] = 'x86_64'
        (Get-AvdConfig -Environment $e -Platform Windows -Architecture Arm64 -NoCreate).AVD_ABI | Should -Be 'x86_64'
    }
    It 'asks the machine, through the environment it was given, when no architecture is passed' {
        $e = @{}; foreach ($k in $base.Keys) { $e[$k] = $base[$k] }
        (Get-AvdConfig -Environment $e -Platform Windows -NoCreate).ARCHITECTURE | Should -Be (Get-AvdHostArchitecture -Environment $e).Os
        $e['PROCESSOR_ARCHITECTURE'] = 'x86'
        $e['PROCESSOR_ARCHITEW6432'] = 'ARM64'
        (Get-AvdConfig -Environment $e -Platform Windows -NoCreate).ARCHITECTURE | Should -Be 'Arm64'
    }
}

Describe 'ConvertTo-AvdInt' {
    It 'parses whole numbers and falls back otherwise' {
        ConvertTo-AvdInt '42' 7 | Should -Be 42
        ConvertTo-AvdInt ' 42 ' 7 | Should -Be 42
        ConvertTo-AvdInt '4x' 7 | Should -Be 7
        ConvertTo-AvdInt '' 7 | Should -Be 7
        ConvertTo-AvdInt '-3' 7 | Should -Be 7
    }
}

Describe 'the default config file' {
    It 'parses with no warnings and sets only ICLOUD_USERNAME, to empty, on either architecture' {
        foreach ($arch in 'X64', 'Arm64') {
            $r = ConvertFrom-AvdConfigText -Text (Get-AvdDefaultConfigText -Platform Windows -Architecture $arch) -Seed @{} -Environment @{} -HomeDir 'C:\h'
            $r.Warnings.Count | Should -Be 0 -Because $arch
            @($r.Values.Keys) | Should -Be @('ICLOUD_USERNAME') -Because $arch
            $r.Values.ICLOUD_USERNAME | Should -Be ''
        }
    }
    It 'shows the ABI of the machine''s architecture, commented out' {
        $x = Get-AvdDefaultConfigText -Platform Windows -Architecture X64
        $x | Should -Match '(?m)^#AVD_ABI=x86_64\r?$'
        $x | Should -Not -Match 'arm64-v8a'
        $a = Get-AvdDefaultConfigText -Platform Windows -Architecture Arm64
        $a | Should -Match '(?m)^#AVD_ABI=arm64-v8a\r?$'
        $a | Should -Match 'Windows on Arm'
        $a | Should -Not -Match '@ABI_LINES@'
        # CRLF throughout, the ABI lines included.
        ($a -replace "`r`n", '') | Should -Not -Match "`n"
    }
    It 'uses CRLF on Windows, since it is the one file a person edits by hand' {
        (Get-AvdDefaultConfigText -Platform Windows) | Should -Match "`r`n"
        (Get-AvdDefaultConfigText -Platform Unix) | Should -Not -Match "`r"
    }
    It 'is written owner-only' -Skip:$IsWindows {
        $p = Join-Path $TestDrive 'cfgdir' 'config'
        Write-AvdDefaultConfig -Path $p -Platform Windows
        [System.IO.File]::GetUnixFileMode($p) | Should -Be ([System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
        Protect-AvdFile -Path $p | Should -Be 'already'
    }
}

Describe 'text and ledger files' {
    It 'writes UTF-8 without a BOM, through a rename, LF on request' {
        $p = Join-Path $TestDrive 'w.txt'
        Write-AvdTextFile -Path $p -Text "a`r`nb`r`n" -Lf
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Not -Be 0xEF
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be "a`nb`n"
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'w.txt.tmp-*').Count | Should -Be 0
    }
    It 'reads non-empty lines, dropping CRs and a BOM, and nothing for a missing file' {
        $p = Join-Path $TestDrive 'r.txt'
        [System.IO.File]::WriteAllText($p, [char]0xFEFF + "x`r`n`r`ny`n")
        $l = Read-AvdLine -Path $p
        $l | Should -Be @('x', 'y')
        (Read-AvdLine -Path (Join-Path $TestDrive 'nope')).Count | Should -Be 0
        Measure-AvdLine -Path $p | Should -Be 2
        Measure-AvdLine -Path (Join-Path $TestDrive 'nope') | Should -Be 0
    }
    It 'keeps a single line an array' {
        $p = Join-Path $TestDrive 'one.txt'
        Set-AvdLine -Path $p -Line @('only')
        $l = Read-AvdLine -Path $p
        , $l | Should -BeOfType [string[]]
        $l.Count | Should -Be 1
    }
    It 'appends LF-terminated lines and creates the file for an empty append' {
        $p = Join-Path $TestDrive 'a.txt'
        Add-AvdLine -Path $p -Line @()
        Test-Path $p | Should -BeTrue
        Add-AvdLine -Path $p -Line @('2026/05/IMG_1.HEIC')
        Add-AvdLine -Path $p -Line @(('2026/05/Caf' + [char]0xE9 + '.HEIC'), 'x y & z.PNG')
        [System.IO.File]::ReadAllText($p) | Should -Be ("2026/05/IMG_1.HEIC`n2026/05/Caf" + [char]0xE9 + ".HEIC`nx y & z.PNG`n")
    }
    It 'sorts byte-wise and de-duplicates, as sort -u under the C locale' {
        $s = Get-AvdSortedUnique -Line @('b', 'B', 'a', 'b', '', '_')
        $s | Should -Be @('B', '_', 'a', 'b')
    }
    It 'computes comm -23 in the first list order' {
        $d = Get-AvdLineDifference -Line @('c', 'a', 'b') -Exclude @('a')
        $d | Should -Be @('c', 'b')
        (Get-AvdLineDifference -Line @() -Exclude @('a')).Count | Should -Be 0
    }
}

Describe 'logging' {
    It 'writes "YYYY-MM-DD HH:MM:SS message" lines' {
        $p = Join-Path $TestDrive 'l.log'
        Write-AvdLog -Path $p -Message 'done (0 pushed this run)'
        [System.IO.File]::ReadAllText($p) | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} done \(0 pushed this run\)\n$'
    }
    It 'rotates past the size limit' {
        $p = Join-Path $TestDrive 'big.log'
        [System.IO.File]::WriteAllText($p, ('x' * 100))
        Initialize-AvdLog -Path $p -MaxBytes 50
        Test-Path $p | Should -BeFalse
        Test-Path "$p.1" | Should -BeTrue
    }
}

Describe 'single-flight locks' {
    BeforeEach { $script:lock = Join-Path $TestDrive ('lock-' + [guid]::NewGuid().ToString('N')) }
    It 'is held, then busy for a second taker, then free after release' {
        (Enter-AvdLock -Path $lock).Status | Should -Be 'held'
        (Get-Content (Join-Path $lock 'pid') -Raw).Trim() | Should -Be "$PID"
        $again = Enter-AvdLock -Path $lock
        $again.Status | Should -Be 'busy'
        $again.OwnerId | Should -Be $PID
        Test-AvdLockAlive -Path $lock | Should -BeTrue
        Exit-AvdLock -Path $lock
        Test-Path $lock | Should -BeFalse
        (Enter-AvdLock -Path $lock).Status | Should -Be 'held'
    }
    It 'reclaims a lock whose owner is gone, and says so' {
        $null = New-Item -ItemType Directory -Path $lock
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value '4242'
        (Get-Item (Join-Path $lock 'pid')).LastWriteTime = (Get-Date).AddMinutes(-5)
        Mock -ModuleName AvdPhotos Get-AvdProcessStartTick { $null } -ParameterFilter { $Id -eq 4242 }
        $said = [System.Collections.Generic.List[string]]::new()
        (Enter-AvdLock -Path $lock -Notice { param($m) $said.Add($m) }).Status | Should -Be 'held'
        $said[0] | Should -Match 'stale lock \(pid 4242 is gone\)'
    }
    It 'reclaims a lock whose pid now belongs to a different process (pid reuse)' {
        $null = New-Item -ItemType Directory -Path $lock
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value '4242'
        Set-Content -LiteralPath (Join-Path $lock 'started') -Value '1000'
        Mock -ModuleName AvdPhotos Get-AvdProcessStartTick { 999999999 } -ParameterFilter { $Id -eq 4242 }
        Test-AvdLockAlive -Path $lock | Should -BeFalse
        (Enter-AvdLock -Path $lock).Status | Should -Be 'held'
    }
    It 'treats a fresh empty pid file as an owner still writing it' {
        $null = New-Item -ItemType Directory -Path $lock
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), '')
        (Enter-AvdLock -Path $lock).Status | Should -Be 'busy'
    }
    It 'never releases a lock another process holds' {
        $null = New-Item -ItemType Directory -Path $lock
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value '4242'
        Exit-AvdLock -Path $lock
        Test-Path $lock | Should -BeTrue
    }
}

Describe 'ConvertTo-AvdCommandLine' {
    It 'follows the C runtime quoting rules' {
        ConvertTo-AvdCommandLine @('a') | Should -Be 'a'
        ConvertTo-AvdCommandLine @('a b') | Should -Be '"a b"'
        ConvertTo-AvdCommandLine @('') | Should -Be '""'
        ConvertTo-AvdCommandLine @('a"b') | Should -Be '"a\"b"'
        ConvertTo-AvdCommandLine @('C:\p\') | Should -Be 'C:\p\'
        ConvertTo-AvdCommandLine @('C:\my p\') | Should -Be '"C:\my p\\"'
        ConvertTo-AvdCommandLine @('a\"b') | Should -Be '"a\\\"b"'
        ConvertTo-AvdCommandLine @('a\\b c') | Should -Be '"a\\b c"'
        ConvertTo-AvdCommandLine @('x', 'y z') | Should -Be 'x "y z"'
    }
    It 'survives a real round trip into a child process' {
        $script = Join-Path $TestDrive 'echo-args.ps1'
        # The child reports its argv as the runtime split it, before PowerShell's
        # own parameter handling would reinterpret a value that starts with a dash.
        Set-Content -LiteralPath $script -Value '$a = [Environment]::GetCommandLineArgs(); $i = [Array]::IndexOf($a, ''-File''); ConvertTo-Json -Compress -InputObject @($a[($i + 2)..($a.Count - 1)])'
        $want = @('a b', 'c"d', 'e\', 'f\\"g', 'while IFS= read -r f; do [ -n "$f" ]; done', "it's & <x> | y", '--sdk_root=C:\Users\John Smith\sdk', '-avd')
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $script) + $want) -TimeoutSec 60
        $r.ExitCode | Should -Be 0
        ($r.StdOut | ConvertFrom-Json) | Should -Be $want
    }
}

Describe 'cmd.exe quoting' {
    It 'quotes every argument, doubles trailing backslashes, refuses a double quote' {
        ConvertTo-AvdCmdArgument 'system-images;android-37.0;google_apis;x86_64' | Should -Be '"system-images;android-37.0;google_apis;x86_64"'
        ConvertTo-AvdCmdArgument 'C:\a b\' | Should -Be '"C:\a b\\"'
        ConvertTo-AvdCmdArgument 'a&b' | Should -Be '"a&b"'
        { ConvertTo-AvdCmdArgument 'a"b' } | Should -Throw
    }
    It 'builds /d /s /c with one outer pair of quotes' {
        Get-AvdCmdArgument -BatchFile 'C:\sdk\sdkmanager.bat' -ArgumentList @('--sdk_root=C:\x y', '--list') |
            Should -Be '/d /s /c ""C:\sdk\sdkmanager.bat" "--sdk_root=C:\x y" "--list""'
        Get-AvdCmdArgument -BatchFile 'C:\e.exe' -ArgumentList @('-avd', 'n') -Suffix '>> "C:\l.log" 2>&1' |
            Should -Be '/d /s /c ""C:\e.exe" "-avd" "n" >> "C:\l.log" 2>&1"'
    }
}

Describe 'Invoke-AvdProcess' {
    It 'returns the exit code, stdout and stderr' {
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("out"); [Console]::Error.Write("err"); exit 3') -TimeoutSec 60
        $r.ExitCode | Should -Be 3
        $r.StdOut.TrimEnd() | Should -Be 'out'
        $r.StdErr.TrimEnd() | Should -Be 'err'
        $r.TimedOut | Should -BeFalse
    }
    It 'feeds -StdinText and otherwise an empty stdin' {
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '$x = [Console]::In.ReadToEnd(); [Console]::Out.Write("[" + $x.Trim() + "]")') -StdinText "y`ny`n" -TimeoutSec 60
        $r.StdOut.TrimEnd() | Should -Be "[y`ny]"
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '$x = [Console]::In.ReadToEnd(); [Console]::Out.Write("[" + $x.Trim() + "]")') -TimeoutSec 60
        $r.StdOut.TrimEnd() | Should -Be '[]'
    }
    It 'kills a run past its bound and returns 124' {
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSec 3
        $t.Stop()
        $r.ExitCode | Should -Be 124
        $r.TimedOut | Should -BeTrue
        $t.Elapsed.TotalSeconds | Should -BeLessThan 30
    }
    It 'returns 127 for a program that cannot be started' {
        (Invoke-AvdProcess -FilePath (Join-Path $TestDrive 'no-such-program') -TimeoutSec 5).ExitCode | Should -Be 127
    }
    It 'runs in the working directory it is given' {
        $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write((Get-Location).Path)') -WorkingDirectory $TestDrive -TimeoutSec 60
        (Resolve-Path $r.StdOut.Trim()).Path | Should -Be (Resolve-Path $TestDrive).Path
    }
}

Describe 'Copy-AvdNewByte' {
    It 'copies complete lines, holds back a partial one, and advances the offset' {
        $src = Join-Path $TestDrive 'src.log'; $dst = Join-Path $TestDrive 'dst.log'
        [System.IO.File]::WriteAllText($src, "one`ntwo`nthr")
        $o = Copy-AvdNewByte -Source $src -Destination $dst -Offset 0
        $o | Should -Be 8
        [System.IO.File]::ReadAllText($dst) | Should -Be "one`ntwo`n"
        [System.IO.File]::AppendAllText($src, "ee`n")
        $o = Copy-AvdNewByte -Source $src -Destination $dst -Offset $o
        [System.IO.File]::ReadAllText($dst) | Should -Be "one`ntwo`nthree`n"
        Copy-AvdNewByte -Source $src -Destination $dst -Offset $o | Should -Be $o
        Copy-AvdNewByte -Source (Join-Path $TestDrive 'none') -Destination $dst -Offset 5 | Should -Be 5
    }
}

Describe 'Test-AvdEmulatorCommandLine' {
    It 'matches -avd <name> and @<name> as exact tokens' {
        Test-AvdEmulatorCommandLine '"C:\sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe" -avd gphotos-tablet -no-snapshot' gphotos-tablet | Should -BeTrue
        Test-AvdEmulatorCommandLine 'emulator.exe "-avd" "gphotos-tablet" "-no-window"' gphotos-tablet | Should -BeTrue
        Test-AvdEmulatorCommandLine 'qemu-system-x86_64 @gphotos-tablet' gphotos-tablet | Should -BeTrue
        Test-AvdEmulatorCommandLine 'qemu-system-x86_64 -avd gphotos-tablet-old' gphotos-tablet | Should -BeFalse
        Test-AvdEmulatorCommandLine 'qemu-system-x86_64 -avd phonesky-donor' gphotos-tablet | Should -BeFalse
        Test-AvdEmulatorCommandLine '' gphotos-tablet | Should -BeFalse
    }
}

Describe 'adb helpers' {
    It 'lists every emulator serial from adb devices, whatever its state' {
        $t = "List of devices attached`r`nemulator-5554`tdevice`r`nemulator-5556`toffline`r`nR58M123ABC`tdevice`r`n`r`n"
        $s = ConvertFrom-AvdAdbDevice $t
        $s | Should -Be @('emulator-5554', 'emulator-5556')
        (ConvertFrom-AvdAdbDevice "List of devices attached`n").Count | Should -Be 0
    }
    It 'resolves the serial by AVD name, never by port' {
        Mock -ModuleName AvdPhotos Invoke-AvdAdb {
            $a = $ArgumentList -join ' '
            $out = switch -Regex ($a) {
                '^devices$' { "List of devices attached`nemulator-5554`tdevice`nemulator-5556`tdevice`n" }
                'emulator-5554 emu avd name' { "someone-elses-avd`r`nOK`r`n" }
                'emulator-5556 emu avd name' { "gphotos-tablet`r`nOK`r`n" }
            }
            [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = $out; StdErr = '' }
        }
        Get-AvdEmulatorSerial -AvdName gphotos-tablet | Should -Be 'emulator-5556'
        Get-AvdEmulatorSerial -AvdName nobody | Should -BeNullOrEmpty
    }
    It 'treats a console that does not answer as no name' {
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { [pscustomobject]@{ ExitCode = 124; TimedOut = $true; StdOut = ''; StdErr = '' } }
        Get-AvdNameOfSerial -Serial emulator-5554 | Should -BeNullOrEmpty
    }
    It 'refuses a shell call with no serial, and strips CRs' {
        { Invoke-AvdAdbShell -Serial '' -Command 'ls' } | Should -Throw
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = "a`r`nb`r`n"; StdErr = 'e' } }
        $r = Invoke-AvdAdbShell -Serial emulator-5554 -Command 'ls'
        $r.Output | Should -Be "a`nb`n"
        (Invoke-AvdAdbShell -Serial emulator-5554 -Command 'ls' -MergeStderr).Output | Should -Be "a`nb`ne"
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -ParameterFilter { ($ArgumentList -join ' ') -eq '-s emulator-5554 shell ls' }
    }
    It 'single-quotes a device path so an apostrophe cannot end the quote' {
        ConvertTo-AvdShellQuoted "/sdcard/DCIM/Camera/it's.jpg" | Should -Be "'/sdcard/DCIM/Camera/it'\''s.jpg'"
    }
}

Describe 'icloudpd helpers' {
    It 'reads the version from icloudpd --version' {
        Get-AvdIcloudpdVersion 'version:1.32.3, commit sha:0123abcd, commit timestamp:Sat Sep 12 2026' | Should -Be '1.32.3'
        Get-AvdIcloudpdVersion "noise`nversion:1.7, x" | Should -Be '1.7'
        Get-AvdIcloudpdVersion 'icloudpd 1.32.3' | Should -BeNullOrEmpty
    }
    It 'pins the library to the tool version' {
        Get-AvdIcloudpdSpec -Version '1.32.3' | Should -Be 'icloudpd @ git+https://github.com/icloud-photos-downloader/icloud_photos_downloader@v1.32.3'
    }
}

Describe 'small helpers' {
    It 'ages a missing file as the epoch and a fresh file as seconds' {
        $p = Join-Path $TestDrive 'age'
        (Get-AvdFileAge -Path $p) | Should -BeGreaterThan 1000000000
        Set-Content -LiteralPath $p -Value x
        (Get-AvdFileAge -Path $p) | Should -BeLessThan 60
    }
    It 'spots a non-ASCII path' {
        Test-AvdAsciiPath 'C:\Users\me\AppData' | Should -BeTrue
        Test-AvdAsciiPath ('C:\Users\Jos' + [char]0xE9) | Should -BeFalse
    }
    It 'finds the shared reclaim script in this checkout' {
        Get-AvdReclaimScript | Should -Match 'avd-photos-reclaim\.py$'
    }
    It 'puts the uv tool directory first on PATH, once' {
        $saved = $env:PATH
        try {
            Add-AvdToolPath -Directory @('/extra/platform-tools')
            Add-AvdToolPath -Directory @('/extra/platform-tools')
            $parts = $env:PATH.Split([System.IO.Path]::PathSeparator)
            $parts[0] | Should -Match '[\\/]\.local[\\/]bin$'
            @($parts | Where-Object { $_ -eq '/extra/platform-tools' }).Count | Should -Be 1
        } finally { $env:PATH = $saved }
    }
}
