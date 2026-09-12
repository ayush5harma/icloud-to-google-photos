#Requires -Version 7.2
# The setup port (windows\lib\Setup.ps1). Pure helpers against fixtures; the
# stateful parts against $TestDrive with every process, adb call, download and
# sleep mocked -- no emulator, no SDK, no network. What these cannot prove (an
# emulator booting under WHPX, the patch on a real x86_64 ramdisk) is listed in
# windows\DESIGN.md.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures' 'setup'
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Get-Fixture([string]$Name) { [System.IO.File]::ReadAllText((Join-Path $Fixtures $Name)) }

    # A config and an environment under a fresh $TestDrive directory, built
    # from a hashtable (never the process environment), on the host platform.
    # The machine's architecture is x64 unless a test says otherwise, so these
    # suites mean the same on an Arm64 runner (and on this Mac) as on an x64 one.
    function New-TestSetup {
        param([string]$Mode = 'Full', [hashtable]$Extra = @{}, [switch]$Headless, [string]$Architecture = 'X64')
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $envs = @{
            HOME                  = $base
            USERPROFILE           = $base
            AVD_PHOTOS_CONFIG_DIR = (Join-Path $base 'config')
            AVD_PHOTOS_STATE_DIR  = (Join-Path $base 'state')
            AVD_PHOTOS_LOG_DIR    = (Join-Path $base 'logs')
            AVD_SDK_ROOT          = (Join-Path $base 'sdk')
            ANDROID_AVD_HOME      = (Join-Path $base 'avd')
            AVD_ABI               = 'x86_64'
            ICLOUD_DIR            = (Join-Path $base 'no-icloud')
        }
        foreach ($k in $Extra.Keys) { $envs[$k] = $Extra[$k] }
        $cfg = Get-AvdConfig -Environment $envs -Platform (Get-AvdPlatform) -Architecture $Architecture
        $s = Initialize-AvdSetupState -Config $cfg -Environment $envs -Mode $Mode -Headless:$Headless
        $s.SerialWaitSec = 1; $s.DonorWaitSec = 1; $s.KillWaitSec = 1; $s.RebootDownSec = 1; $s.StopWaitTries = 1
        $null = New-Item -ItemType Directory -Force -Path $s.Stamps
        [pscustomobject]@{ State = $s; Config = $cfg; Environment = $envs; Base = $base }
    }

    function Get-SetupLog([object]$State) {
        if (Test-Path -LiteralPath $State.Log) { [System.IO.File]::ReadAllText($State.Log) } else { '' }
    }

    function New-File([string]$Path, [string]$Text = 'x') {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
        [System.IO.File]::WriteAllText($Path, $Text)
    }

    function New-Result([string]$Out = '', [int]$Code = 0, [string]$Err = '') {
        [pscustomobject]@{ ExitCode = $Code; TimedOut = $false; StdOut = $Out; StdErr = $Err }
    }

    # THE SAFETY NET. Nothing the module starts may reach a real program, a
    # device or the network from this file: a test that forgets a mock fails
    # here instead of running the host's sdkmanager (an early draft of the
    # bin-script test did exactly that, 2026-09-13, and sdkmanager rewrote its
    # manifest cache under the real ~/.android). Tests override these.
    Mock -ModuleName AvdPhotos Invoke-AvdProcess { throw "unmocked process: $FilePath $($ArgumentList -join ' ')" }
    Mock -ModuleName AvdPhotos Invoke-AvdAdb { throw "unmocked adb: $($ArgumentList -join ' ')" }
    Mock -ModuleName AvdPhotos Invoke-WebRequest { throw "unmocked web request: $Uri" }
    Mock -ModuleName AvdPhotos Start-AvdEmulatorProcess { throw 'unmocked emulator launch' }
    Mock -ModuleName AvdPhotos Stop-AvdEmulatorProcess { throw 'unmocked emulator stop' }
    Mock -ModuleName AvdPhotos Add-AvdToolPath {}
    Mock -ModuleName AvdPhotos Start-Sleep {}
}

Describe 'the safety net' {
    It 'turns an unmocked process, adb call, download or emulator launch inside the module into a failure' {
        InModuleScope AvdPhotos {
            { Invoke-AvdProcess -FilePath 'sdkmanager' -ArgumentList @('--list') } | Should -Throw 'unmocked process*'
            { Invoke-AvdAdb -ArgumentList @('devices') } | Should -Throw 'unmocked adb*'
            { Invoke-WebRequest -Uri 'https://example.invalid/' } | Should -Throw 'unmocked web request*'
            { Start-AvdEmulatorProcess -EmulatorPath 'e' -ArgumentList @('-avd', 'x') -LogPath 'l' -SdkRoot 's' } | Should -Throw 'unmocked emulator*'
        }
    }
}

Describe 'Get-AvdSdkToolPath' {
    It 'names the Windows .bat and .exe tools' {
        Get-AvdSdkToolPath -SdkRoot 'C:\sdk' -Name emulator -Platform Windows | Should -Be 'C:\sdk\emulator\emulator.exe'
        Get-AvdSdkToolPath -SdkRoot 'C:\sdk' -Name sdkmanager -Platform Windows | Should -Be 'C:\sdk\cmdline-tools\latest\bin\sdkmanager.bat'
        Get-AvdSdkToolPath -SdkRoot 'C:\sdk' -Name avdmanager -Platform Windows | Should -Be 'C:\sdk\cmdline-tools\latest\bin\avdmanager.bat'
        Get-AvdSdkToolPath -SdkRoot 'C:\sdk' -Name adb -Platform Windows | Should -Be 'C:\sdk\platform-tools\adb.exe'
    }
    It 'names them without extensions elsewhere' {
        Get-AvdSdkToolPath -SdkRoot '/sdk' -Name sdkmanager -Platform Unix | Should -Be '/sdk/cmdline-tools/latest/bin/sdkmanager'
        Get-AvdSdkToolPath -SdkRoot '/sdk' -Name adb -Platform Unix | Should -Be '/sdk/platform-tools/adb'
    }
}

Describe 'ConvertFrom-AvdSdkRepositoryXml' {
    BeforeAll { $script:Manifest = Get-Fixture 'repository2-3-cmdline-tools.xml' }
    It 'finds the Windows archive of cmdline-tools;latest with its size, sha1 and absolute URL' {
        $p = ConvertFrom-AvdSdkRepositoryXml -Xml $Manifest
        $p.Url | Should -Be 'https://dl.google.com/android/repository/commandlinetools-win-16111833_latest.zip'
        $p.Sha1 | Should -Be '57d04f2d75eb8e8fffc5000a987e5de4b5a63e9d'
        $p.Size | Should -Be 154957218
        $p.Revision | Should -Be '23.0'
    }
    It 'matches the exact package path, not the cmdline-tools;2.1 before it' {
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Manifest -PackagePath 'cmdline-tools;2.1').Url |
            Should -Be 'https://dl.google.com/android/repository/commandlinetools-win-6609375_latest.zip'
        ConvertFrom-AvdSdkRepositoryXml -Xml $Manifest -PackagePath 'cmdline-tools' | Should -BeNullOrEmpty
    }
    It 'picks by host OS and returns nothing for an OS it does not list' {
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Manifest -HostOs linux).Sha1 | Should -Be 'e025545c62a8e64c7559119566a569fb1dec5f60'
        ConvertFrom-AvdSdkRepositoryXml -Xml $Manifest -HostOs solaris | Should -BeNullOrEmpty
    }
}

Describe 'Google''s SDK index by host architecture and channel' {
    BeforeAll { $script:Index = Get-Fixture 'repository2-3-emulator.xml' }
    It 'lists no emulator for Windows on Arm, on the stable channel or any other' {
        ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath emulator -HostOs windows -HostArch aarch64 -Channel channel-0 | Should -BeNullOrEmpty
        ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath emulator -HostOs windows -HostArch aarch64 | Should -BeNullOrEmpty
    }
    It 'lists the x64 emulator for Windows, stable by default of the channel asked for' {
        $s = ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath emulator -HostOs windows -HostArch x64 -Channel channel-0
        $s.Url | Should -Be 'https://dl.google.com/android/repository/emulator-windows_x64-15917651.zip'
        $s.Revision | Should -Be '37.1.11'
        $s.HostArch | Should -Be 'x64'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath emulator -HostOs windows -HostArch x64 -Channel channel-2).Revision | Should -Be '37.2.8'
        # No channel asked: the first package listed, which is the dev one.
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath emulator -HostOs windows -HostArch x64).Revision | Should -Be '37.2.8'
    }
    It 'gives an Arm64 Mac the arm64 command-line tools, not the first macOS archive' {
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Index -HostOs macosx -HostArch aarch64).Url | Should -Match 'commandlinetools-mac_arm64-'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Index -HostOs macosx -HostArch x64).Url | Should -Match 'commandlinetools-mac_x86_64-'
    }
    It 'serves Windows on Arm the architecture-neutral archives: the Java command-line tools and platform-tools' {
        $t = ConvertFrom-AvdSdkRepositoryXml -Xml $Index -HostOs windows -HostArch aarch64 -Channel channel-0
        $t.Url | Should -Be 'https://dl.google.com/android/repository/commandlinetools-win-16111833_latest.zip'
        $t.HostArch | Should -Be ''
        # One Windows archive for every architecture; its adb.exe is a 32-bit
        # x86 program (read from the r37.0.1 zip, 2026-09-13), which Windows on
        # Arm runs under emulation.
        (ConvertFrom-AvdSdkRepositoryXml -Xml $Index -PackagePath platform-tools -HostOs windows -HostArch aarch64).Url |
            Should -Be 'https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip'
    }
    It 'prefers an exact architecture to a neutral archive, and never takes another architecture''s' {
        $xml = '<r><remotePackage path="p"><archives>' +
            '<archive><complete><size>1</size><checksum type="sha1">aa</checksum><url>any.zip</url></complete><host-os>windows</host-os></archive>' +
            '<archive><complete><size>2</size><checksum type="sha1">bb</checksum><url>x64.zip</url></complete><host-os>windows</host-os><host-arch>x64</host-arch></archive>' +
            '<archive><complete><size>3</size><checksum type="sha1">cc</checksum><url>arm.zip</url></complete><host-os>windows</host-os><host-arch>aarch64</host-arch></archive>' +
            '</archives></remotePackage></r>'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p -HostArch aarch64).Url | Should -Match 'arm\.zip$'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p -HostArch x64).Url | Should -Match 'x64\.zip$'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p -HostArch riscv64).Url | Should -Match 'any\.zip$'
        (ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p).Url | Should -Match 'any\.zip$'
        $only = $xml -replace '<archive><complete><size>1</size>.*?</archive>', ''
        ConvertFrom-AvdSdkRepositoryXml -Xml $only -PackagePath p -HostArch riscv64 | Should -BeNullOrEmpty
    }
    It 'counts a package with no channelRef as stable' {
        $xml = '<r><remotePackage path="p"><archives><archive><complete><size>1</size><checksum type="sha1">aa</checksum><url>a.zip</url></complete><host-os>windows</host-os></archive></archives></remotePackage></r>'
        ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p -Channel channel-0 | Should -Not -BeNullOrEmpty
        ConvertFrom-AvdSdkRepositoryXml -Xml $xml -PackagePath p -Channel channel-3 | Should -BeNullOrEmpty
    }
    It 'spells a machine architecture as the index does' {
        ConvertTo-AvdSdkHostArch X64 | Should -Be 'x64'
        ConvertTo-AvdSdkHostArch Arm64 | Should -Be 'aarch64'
        ConvertTo-AvdSdkHostArch AMD64 | Should -Be 'x64'
        ConvertTo-AvdSdkHostArch X86 | Should -Be ''
        ConvertTo-AvdSdkHostArch '' | Should -Be ''
    }
}

Describe 'Windows on Arm: the emulator gate' {
    BeforeAll {
        $script:Index = Get-Fixture 'repository2-3-emulator.xml'
        # The index with the STABLE emulator's Windows archive retagged for
        # aarch64: the day Google publishes one.
        $script:IndexWithArm = [regex]::Replace($Index, '(emulator-windows_x64-15917651\.zip</url>\s*</complete>\s*<host-os>windows</host-os>\s*<host-arch>)x64', '${1}aarch64')
        # The same build listed with no host-arch, as the older repository2-1.xml does.
        $script:IndexUntagged = [regex]::Replace($Index, '(emulator-windows_x64-15917651\.zip</url>\s*</complete>\s*<host-os>windows</host-os>)\s*<host-arch>x64</host-arch>', '$1')
    }
    BeforeEach {
        Mock -ModuleName AvdPhotos Add-AvdToolPath {}
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { throw "unmocked process: $FilePath" }
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { throw 'unmocked adb' }
        $script:Served = $Index
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:Served } }
    }
    It 'is never asked on an x64 PC: no request to Google' {
        $null = New-TestSetup -Architecture X64
        Get-AvdSetupEmulatorBlocker | Should -BeNullOrEmpty
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 0 -Exactly
    }
    It 'stops a setup on Windows on Arm with the one message, before any download, process or device call' {
        $t = New-TestSetup -Architecture Arm64
        Invoke-AvdSetup -Mode Full -Config $t.Config -Environment $t.Environment 6>$null | Should -Be 1
        $log = Get-SetupLog $t.State
        $log | Should -Match 'Windows on Arm: no Android Emulator'
        $log | Should -Match 'Everything else runs natively'
        $log | Should -Match 'ERROR no Android Emulator for Windows on Arm -- nothing was downloaded or changed'
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { "$Uri" -eq 'https://dl.google.com/android/repository/repository2-3.xml' }
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly
        Test-Path -LiteralPath $t.State.SdkRoot | Should -BeFalse
        Test-Path -LiteralPath $t.State.Lock | Should -BeFalse
    }
    It 'says the same to -Check and -Start, which exit 1 too' {
        foreach ($m in 'Check', 'Start') {
            $t = New-TestSetup -Architecture Arm64 -Mode $m
            Invoke-AvdSetup -Mode $m -Config $t.Config -Environment $t.Environment 6>$null | Should -Be 1 -Because $m
            Get-SetupLog $t.State | Should -Match 'Windows on Arm: no Android Emulator'
        }
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
    }
    It 'ends a background run (the logon bootstrap, the weekly task) with exit 0 and the reason in setup.log' {
        $t = New-TestSetup -Architecture Arm64 -Mode Bootstrap
        Invoke-AvdSetup -Mode Bootstrap -Config $t.Config -Environment $t.Environment 6>$null | Should -Be 0
        $log = Get-SetupLog $t.State
        $log | Should -Match 'Windows on Arm: no Android Emulator'
        $log | Should -Not -Match 'ERROR'
        $w = New-TestSetup -Architecture Arm64 -Headless
        Invoke-AvdSetup -Mode Full -Headless -Config $w.Config -Environment $w.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
        Test-Path -LiteralPath $w.State.SetupDone | Should -BeFalse
    }
    It 'leaves -Stop alone: nothing to ask of Google to stop what runs' {
        $t = New-TestSetup -Architecture Arm64 -Mode Stop
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $false }
        Invoke-AvdSetup -Mode Stop -Config $t.Config -Environment $t.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 0 -Exactly
        Get-SetupLog $t.State | Should -Match '   not running'
    }
    It 'goes ahead, saying it is a first run, once the stable channel lists an aarch64 emulator for Windows' {
        $script:Served = $IndexWithArm
        $t = New-TestSetup -Architecture Arm64
        Get-AvdSetupEmulatorBlocker 6>$null | Should -BeNullOrEmpty
        Get-SetupLog $t.State | Should -Match 'now lists Android Emulator 37\.1\.11 for Windows on Arm'
    }
    It 'does not take an untagged Windows emulator archive for an Arm64 one' {
        $script:Served = $IndexUntagged
        $null = New-TestSetup -Architecture Arm64
        $b = Get-AvdSetupEmulatorBlocker
        $b | Should -Not -BeNullOrEmpty
        $b[0] | Should -Match '^Windows on Arm: no Android Emulator'
    }
    It 'stops with the same message, and why the index was not read, when it cannot be read' {
        Mock -ModuleName AvdPhotos Invoke-WebRequest { throw 'No such host is known.' }
        $t = New-TestSetup -Architecture Arm64
        Invoke-AvdSetup -Mode Full -Config $t.Config -Environment $t.Environment 6>$null | Should -Be 1
        $log = Get-SetupLog $t.State
        $log | Should -Match 'Windows on Arm: no Android Emulator'
        $log | Should -Match 'could not be read either \(No such host is known\.\)'
    }
    It 'reads the index once a run, for the gate and the command-line tools alike' {
        $null = New-TestSetup -Architecture Arm64
        $a = Get-AvdSetupSdkManifest
        $b = Get-AvdSetupSdkManifest
        $a | Should -BeExactly $b
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 1 -Exactly
    }
}

Describe 'API levels' {
    It 'version-sorts newest first: 37.0 > 36.1 > 36.0 > 36' {
        $a = Get-AvdSortedApi -Version @('36', '37.0', '36.1', '36.0', '37.0', 'x', '')
        $a | Should -Be @('37.0', '36.1', '36.0', '36')
    }
    It 'returns an empty array, not $null, for nothing' {
        $a = Get-AvdSortedApi -Version @()
        , $a | Should -BeOfType [string[]]
        $a.Count | Should -Be 0
    }
    It 'reads sdkmanager --list for the exact tag and ABI, excluding previews, 16 KB and ext images' {
        $a = Get-AvdSystemImageApi -Text (Get-Fixture 'sdkmanager-list.txt') -Tag google_apis -Abi x86_64
        $a | Should -Be @('37.0', '36.1', '36.0', '36')
    }
    It 'keeps the ABI exact (x86 does not pick up x86_64) and the tag exact' {
        $list = Get-Fixture 'sdkmanager-list.txt'
        $x86 = Get-AvdSystemImageApi -Text $list -Tag google_apis -Abi x86
        $x86 | Should -Be @('9')
        $arm = Get-AvdSystemImageApi -Text $list -Tag google_apis -Abi arm64-v8a
        $arm | Should -Be @('37.0', '36')
        $store = Get-AvdSystemImageApi -Text $list -Tag google_apis_playstore -Abi x86_64
        $store | Should -Be @('38.0', '36')
        (Get-AvdSystemImageApi -Text '' -Tag google_apis -Abi x86_64).Count | Should -Be 0
    }
    It 'reads the API from image.sysdir.1 with either separator, keeping 37.0 distinct from 37' {
        Get-AvdSysdirApi "x=1`nimage.sysdir.1=system-images/android-37.0/google_apis/arm64-v8a/`n" | Should -Be '37.0'
        Get-AvdSysdirApi "image.sysdir.1=system-images\android-37.0\google_apis\x86_64\`r`n" | Should -Be '37.0'
        Get-AvdSysdirApi "image.sysdir.1=system-images\android-37\google_apis\x86_64\" | Should -Be '37'
        Get-AvdSysdirApi "image.sysdir.1=system-images/android-36.1/google_apis/x86_64/" | Should -Be '36.1'
        Get-AvdSysdirApi 'hw.ramSize=2048' | Should -Be ''
    }
}

Describe 'ConvertTo-AvdTunedConfigIni' {
    BeforeAll {
        $script:Tune = @{ Width = '2560'; Height = '1440'; Dpi = '210'; Ram = '6144'; Cores = '4'; Disk = '16384M'; Heap = '512M'; Gpu = 'host' }
        $script:Expected = Get-Fixture 'config.ini.expected'
    }
    It 'writes exactly what the macOS inline Python writes (expected output generated by that Python)' {
        ConvertTo-AvdTunedConfigIni -Text (Get-Fixture 'config.ini') @Tune | Should -BeExactly $Expected
    }
    It 'reads a CRLF config.ini the same, keeps backslash paths, writes LF with a final LF' {
        $crlf = (ConvertTo-AvdLf (Get-Fixture 'config.ini')).Replace("`n", "`r`n")
        $out = ConvertTo-AvdTunedConfigIni -Text $crlf @Tune
        $out | Should -BeExactly $Expected
        $out | Should -Not -Match "`r"
        $out.EndsWith("`n") | Should -BeTrue
        $out | Should -Match ([regex]::Escape('image.sysdir.1=system-images\android-37.0\google_apis\x86_64\'))
    }
}

Describe 'small parsers' {
    It 'reads emulator -accel-check: usable, and not' {
        $ok = ConvertFrom-AvdAccelCheck "accel:`n0`nWHPX(10.0.26100) is installed and usable.`naccel`n"
        $ok.Status | Should -Be 0
        $ok.Message | Should -Be 'WHPX(10.0.26100) is installed and usable.'
        $no = ConvertFrom-AvdAccelCheck "accel:`r`n11`r`nAEHD is not installed on this machine`r`naccel`r`n"
        $no.Status | Should -Be 11
        $no.Message | Should -Be 'AEHD is not installed on this machine'
        $raw = ConvertFrom-AvdAccelCheck "emulator: ERROR: something else`n"
        $raw.Status | Should -BeNullOrEmpty
        $raw.Message | Should -Be 'emulator: ERROR: something else'
    }
    It 'reads the Java major version' {
        Get-AvdJavaMajorVersion "openjdk version `"21.0.4`" 2024-07-16 LTS`nOpenJDK Runtime Environment Microsoft-9889606" | Should -Be 21
        Get-AvdJavaMajorVersion 'openjdk version "17" 2021-09-14' | Should -Be 17
        Get-AvdJavaMajorVersion 'java version "1.8.0_401"' | Should -Be 8
        Get-AvdJavaMajorVersion "Picked up JAVA_TOOL_OPTIONS: -Xmx1g`nopenjdk version `"25`"" | Should -Be 25
        Get-AvdJavaMajorVersion 'java: command not found' | Should -BeNullOrEmpty
    }
    It 'reads the android_id from GMS Checkin.xml' {
        ConvertFrom-AvdCheckinXml (Get-Fixture 'Checkin.xml') | Should -Be '4012345678901234567'
        ConvertFrom-AvdCheckinXml '<map></map>' | Should -Be ''
    }
    It 'reads release tags and matches asset names case-sensitively, as jq test() does' {
        $rel = '{"tag_name":"v28.1","assets":[{"name":"magisk-v28.1.apk","browser_download_url":"https://x/lower"},{"name":"Magisk-v28.1.apk","browser_download_url":"https://x/upper"}]}' | ConvertFrom-Json
        Get-AvdReleaseTag $rel | Should -Be 'v28.1'
        Get-AvdReleaseAssetUrl $rel '^Magisk-v.*\.apk$' | Should -Be 'https://x/upper'
        Get-AvdReleaseAssetUrl $rel '\.zip$' | Should -Be ''
        Get-AvdReleaseTag $null | Should -Be ''
        Get-AvdReleaseAssetUrl ('{"message":"Not Found"}' | ConvertFrom-Json) '\.zip$' | Should -Be ''
    }
    It 'takes head and tail lines and spots an exact ok line' {
        $l = Select-AvdLine "a`nb`nc`n" -Last 2
        $l | Should -Be @('b', 'c')
        (Select-AvdLine "a`r`nb`r`n" -First 1) | Should -Be @('a')
        (Select-AvdLine '' -Last 3).Count | Should -Be 0
        Test-AvdOkLine "x`nok`n" | Should -BeTrue
        Test-AvdOkLine 'ls: /dev/block/vdd1: No such file or directory (ok)' | Should -BeFalse
    }
}

Describe 'the on-device patch script' {
    It 'is byte-identical to the heredoc in bin/avd-photos-setup' {
        $bash = ConvertTo-AvdLf ([System.IO.File]::ReadAllText((Join-Path $Root 'bin' 'avd-photos-setup')))
        $m = [regex]::Match($bash, "(?s)\n  cat <<'PATCH_EOS'\n(.*?\n)PATCH_EOS\n")
        $m.Success | Should -BeTrue
        $dev = [System.IO.File]::ReadAllText((Join-Path $Root 'windows' 'device' 'patch-ramdisk.sh'))
        (ConvertTo-AvdLf $dev) | Should -BeExactly $m.Groups[1].Value
    }
    It 'is handed to the device LF-only and without a BOM' {
        $t = Get-AvdOnDevicePatchScript
        $t | Should -Not -Match "`r"
        $t[0] | Should -Not -Be ([char]0xFEFF)
        $t | Should -Match '^#!/system/bin/sh\n'
    }
}

Describe 'stamps and asset pinning (verify_asset)' {
    BeforeEach {
        $script:T = New-TestSetup
        $script:Asset = Join-Path $T.Base 'asset.zip'
        New-File $Asset 'first bytes'
    }
    It 'records the hash on first sight, then passes the same bytes' {
        Test-AvdSetupAsset -Key 'mod-x' -Tag 'v1' -Path $Asset 6>$null | Should -BeTrue
        $want = (Get-FileHash -LiteralPath $Asset -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::ReadAllText((Join-Path $T.State.Stamps 'sha-mod-x-v1')) | Should -BeExactly $want
        Get-SetupLog $T.State | Should -Match '\(recorded\)'
        Test-AvdSetupAsset -Key 'mod-x' -Tag 'v1' -Path $Asset 6>$null | Should -BeTrue
        Get-SetupLog $T.State | Should -Match 'matches the recorded hash'
    }
    It 'refuses changed bytes under the same tag, and says how to accept them' {
        Test-AvdSetupAsset -Key 'mod-x' -Tag 'v1' -Path $Asset 6>$null | Should -BeTrue
        New-File $Asset 'reuploaded bytes'
        Test-AvdSetupAsset -Key 'mod-x' -Tag 'v1' -Path $Asset 6>$null | Should -BeFalse
        $log = Get-SetupLog $T.State
        $log | Should -Match 'REFUSING mod-x v1: its bytes changed since this machine first saw that tag'
        $log | Should -Match 'delete .*sha-mod-x-v1 to accept the new bytes deliberately'
        # A new tag is a new first sight.
        Test-AvdSetupAsset -Key 'mod-x' -Tag 'v2' -Path $Asset 6>$null | Should -BeTrue
    }
    It 'refuses an asset whose hash cannot be recorded, rather than pinning nothing' {
        $blocker = Join-Path $T.Base 'not-a-dir'
        New-File $blocker 'a file where the stamps directory should be'
        $T.State.Stamps = $blocker
        Test-AvdSetupAsset -Key 'magisk' -Tag '28.1' -Path $Asset 6>$null | Should -BeFalse
        Get-SetupLog $T.State | Should -Match "could not record magisk 28.1's hash .* refusing it rather than pinning nothing"
    }
    It 'refuses an empty download and files an untagged asset under "untagged"' {
        New-File $Asset ''
        Test-AvdSetupAsset -Key 'k' -Tag '' -Path $Asset 6>$null | Should -BeFalse
        New-File $Asset 'x'
        Test-AvdSetupAsset -Key 'k' -Tag '' -Path $Asset 6>$null | Should -BeTrue
        Test-Path (Join-Path $T.State.Stamps 'sha-k-untagged') | Should -BeTrue
    }
    It 'reads a stamp back without its trailing newline, and an absent one as empty' {
        Set-AvdSetupStamp -Key 'mod-a' -Value 'v3' | Should -BeTrue
        Get-AvdSetupStamp -Key 'mod-a' | Should -BeExactly 'v3'
        [System.IO.File]::WriteAllText((Join-Path $T.State.Stamps 'mod-b'), "v4`n")
        Get-AvdSetupStamp -Key 'mod-b' | Should -BeExactly 'v4'
        Get-AvdSetupStamp -Key 'none' | Should -BeExactly ''
    }
}

Describe 'GitHub release lookups (gh_latest)' {
    BeforeEach {
        $script:T = New-TestSetup
        $script:Cache = Join-Path $T.Config.STATE_DIR 'gh-topjohnwu_Magisk.json'
        Mock -ModuleName AvdPhotos Start-Sleep {}
    }
    It 'answers from a fresh cache without a request' {
        New-File $Cache '{"tag_name":"v28.1"}'
        Mock -ModuleName AvdPhotos Invoke-WebRequest { throw 'no request expected' }
        (Get-AvdSetupRelease -Repo 'topjohnwu/Magisk').tag_name | Should -Be 'v28.1'
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 0 -Exactly
    }
    It 'fetches, writes the cache, and sends the token only in a header' {
        $T.Config.GITHUB_TOKEN = 'ghp_secret'
        Mock -ModuleName AvdPhotos Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"tag_name":"v29.0","assets":[]}' }
        }
        (Get-AvdSetupRelease -Repo 'topjohnwu/Magisk').tag_name | Should -Be 'v29.0'
        [System.IO.File]::ReadAllText($Cache) | Should -Match 'v29.0'
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/topjohnwu/Magisk/releases/latest' -and
            $Headers['Authorization'] -eq 'Bearer ghp_secret' -and
            $Headers['Accept'] -eq 'application/vnd.github+json' -and
            $Uri -notmatch 'ghp_secret'
        }
    }
    It 'refetches a cache older than an hour' {
        New-File $Cache '{"tag_name":"v1"}'
        (Get-Item $Cache).LastWriteTime = (Get-Date).AddMinutes(-61)
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"tag_name":"v2"}' } }
        (Get-AvdSetupRelease -Repo 'topjohnwu/Magisk').tag_name | Should -Be 'v2'
    }
    It 'falls back to a stale cache when the API fails, and says so' {
        New-File $Cache '{"tag_name":"v1"}'
        (Get-Item $Cache).LastWriteTime = (Get-Date).AddHours(-3)
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [pscustomobject]@{ StatusCode = 403; Content = '{"message":"rate limited"}' } }
        (Get-AvdSetupRelease -Repo 'topjohnwu/Magisk' 6>$null).tag_name | Should -Be 'v1'
        Get-SetupLog $T.State | Should -Match 'GitHub API answered 403 for topjohnwu/Magisk -- using the cached release info \(3h old\)'
        # 403 is not retried: it would spend the hourly limit three times over.
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 1 -Exactly
    }
    It 'returns nothing with no cache, and warns once per run' {
        Mock -ModuleName AvdPhotos Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
        Get-AvdSetupRelease -Repo 'topjohnwu/Magisk' 6>$null | Should -BeNullOrEmpty
        Get-AvdSetupRelease -Repo 'JingMatrix/NeoZygisk' 6>$null | Should -BeNullOrEmpty
        $log = Get-SetupLog $T.State
        ([regex]::Matches($log, 'GitHub API unreachable \(HTTP none\)')).Count | Should -Be 1
        Test-Path $Cache | Should -BeFalse
        # Three attempts per lookup, as curl --retry 2.
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -Times 6 -Exactly
    }
    It 'names the rate limit when that is what failed' {
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [pscustomobject]@{ StatusCode = 429; Content = '' } }
        Get-AvdSetupRelease -Repo 'topjohnwu/Magisk' 6>$null | Should -BeNullOrEmpty
        Get-SetupLog $T.State | Should -Match '(?s)rate limit reached .* set GITHUB_TOKEN in the config'
    }
    It 'retries a 503 and takes the answer that follows' {
        $script:n = 0
        Mock -ModuleName AvdPhotos Invoke-WebRequest {
            $script:n++
            if ($script:n -eq 1) { [pscustomobject]@{ StatusCode = 503; Content = '' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '{"tag_name":"v3"}' } }
        }
        (Get-AvdSetupRelease -Repo 'topjohnwu/Magisk').tag_name | Should -Be 'v3'
    }
}

Describe 'downloads (fetch)' {
    BeforeEach { $script:T = New-TestSetup }
    It 'writes through a temp name and renames only on success' {
        $dest = Join-Path $T.Base 'dl' 'x.zip'
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [System.IO.File]::WriteAllText($OutFile, 'payload') }
        Save-AvdSetupDownload -Path $dest -Uri 'https://example.invalid/x.zip' | Should -BeTrue
        [System.IO.File]::ReadAllText($dest) | Should -Be 'payload'
        @(Get-ChildItem -LiteralPath (Split-Path $dest) -Filter '*.part-*').Count | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-WebRequest -ParameterFilter { $OutFile -like '*.part-*' -and $TimeoutSec -eq 900 }
    }
    It 'leaves the previous file and no partial one when the download fails' {
        $dest = Join-Path $T.Base 'y.zip'
        New-File $dest 'old'
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [System.IO.File]::WriteAllText($OutFile, 'half'); throw 'connection reset' }
        Save-AvdSetupDownload -Path $dest -Uri 'https://example.invalid/y.zip' | Should -BeFalse
        [System.IO.File]::ReadAllText($dest) | Should -Be 'old'
        @(Get-ChildItem -LiteralPath $T.Base -Filter 'y.zip.part-*').Count | Should -Be 0
    }
}

Describe 'the command-line tools bootstrap' {
    BeforeEach {
        $script:T = New-TestSetup
        # A zip laid out as Google's: a top-level cmdline-tools\ folder.
        $src = Join-Path $T.Base 'zipsrc'
        $bin = Join-Path $src 'cmdline-tools' 'bin'
        New-File (Join-Path $bin (Split-Path -Leaf $T.State.SdkManager)) 'sdkmanager'
        New-File (Join-Path $bin (Split-Path -Leaf $T.State.AvdManager)) 'avdmanager'
        New-File (Join-Path $src 'cmdline-tools' 'source.properties') 'Pkg.Revision=23.0'
        $script:Zip = Join-Path $T.Base 'tools.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $Zip)
        # What Google's manifest would publish for this archive.
        $sha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData([System.IO.File]::ReadAllBytes($Zip))).ToLowerInvariant()
        $size = (Get-Item -LiteralPath $Zip).Length
        $archives = foreach ($os in 'linux', 'macosx', 'windows') {
            "<archive><complete><size>$size</size><checksum type=`"sha1`">$sha</checksum><url>tools-$os.zip</url></complete><host-os>$os</host-os></archive>"
        }
        $script:Xml = '<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">' +
            '<remotePackage path="cmdline-tools;latest"><revision><major>23</major><minor>0</minor></revision><archives>' +
            ($archives -join '') + '</archives></remotePackage></sdk:sdk-repository>'
        Mock -ModuleName AvdPhotos Invoke-WebRequest {
            if ($OutFile) { Copy-Item -LiteralPath $Zip -Destination $OutFile; return }
            [pscustomobject]@{ StatusCode = 200; Content = $Xml }
        }
    }
    It 'puts the contents of the zip''s cmdline-tools folder in cmdline-tools\latest' {
        Install-AvdSetupCmdlineTool 6>$null
        Test-Path -LiteralPath $T.State.SdkManager -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $T.State.AvdManager -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $T.State.SdkRoot 'cmdline-tools' 'cmdline-tools') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $T.State.SdkRoot 'cmdline-tools') -Force).Name | Should -Be @('latest')
    }
    It 'refuses a download whose sha1 does not match the manifest' {
        $script:Xml = $Xml -replace '<checksum type="sha1">[0-9a-f]+', '<checksum type="sha1">0000000000000000000000000000000000000000'
        { Install-AvdSetupCmdlineTool 6>$null } | Should -Throw '*did not verify*'
        Test-Path -LiteralPath (Join-Path $T.State.SdkRoot 'cmdline-tools' 'latest') | Should -BeFalse
    }
}

Describe 'Java, acceleration and path guards' {
    BeforeEach { $script:T = New-TestSetup }
    It 'refuses a Java older than 17, naming the winget fix' {
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { '/fake/java' }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result -Err 'java version "1.8.0_401"' }
        { Assert-AvdSetupJava 6>$null } | Should -Throw '*Java 8*winget install Microsoft.OpenJDK.21*'
    }
    It 'refuses a missing Java, and accepts 21 once per run' {
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { $null }
        { Assert-AvdSetupJava 6>$null } | Should -Throw '*winget install Microsoft.OpenJDK.21*'
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { '/fake/java' }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result -Err 'openjdk version "21.0.4" 2024-07-16 LTS' }
        Assert-AvdSetupJava
        Assert-AvdSetupJava
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 1 -Exactly
    }
    It 'on Windows on Arm, refuses an x64 Java (sdkmanager would fetch x64 packages) and takes an arm64 one' {
        function New-Exe([string]$Path, [int]$Machine) {
            $b = [byte[]]::new(0x100)
            $b[0] = 0x4D; $b[1] = 0x5A
            [System.BitConverter]::GetBytes([int]0x80).CopyTo($b, 0x3C)
            $b[0x80] = 0x50; $b[0x81] = 0x45
            [System.BitConverter]::GetBytes([uint16]$Machine).CopyTo($b, 0x84)
            New-File $Path ''
            [System.IO.File]::WriteAllBytes($Path, $b)
        }
        $a = New-TestSetup -Architecture Arm64
        $script:JavaExe = Join-Path $a.Base 'jdk-x64' 'java.exe'
        New-Exe $JavaExe 0x8664
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { $script:JavaExe }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result -Err 'openjdk version "21.0.12" 2026-07-21 LTS' }
        { Assert-AvdSetupJava 6>$null } | Should -Throw '*the X64 build of Java*winget install Microsoft.OpenJDK.21 --architecture arm64*'
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
        $script:JavaExe = Join-Path $a.Base 'jdk-arm64' 'java.exe'
        New-Exe $JavaExe 0xAA64
        Assert-AvdSetupJava
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 1 -Exactly
        # The same x64 Java on an x64 PC is simply Java.
        $null = New-TestSetup -Architecture X64
        $script:JavaExe = Join-Path $a.Base 'jdk-x64' 'java.exe'
        Assert-AvdSetupJava
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { $null }
        $null = New-TestSetup -Architecture Arm64
        { Assert-AvdSetupJava 6>$null } | Should -Throw '*Java not found*winget install Microsoft.OpenJDK.21 --architecture arm64*'
    }
    It 'dies on an unusable hypervisor in a full run and only reports it in -Check' {
        New-File $T.State.Emulator 'emu'
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result -Out "accel:`n11`nAEHD is not installed on this machine`naccel`n" -Code 1 }
        # The wording the README's Troubleshooting quotes.
        { Assert-AvdSetupAcceleration 6>$null } | Should -Throw '*no hardware acceleration*'
        Get-SetupLog $T.State | Should -Match 'Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All'
        $c = New-TestSetup -Mode Check
        New-File $c.State.Emulator 'emu'
        { Assert-AvdSetupAcceleration 6>$null } | Should -Not -Throw
        Get-SetupLog $c.State | Should -Match 'acceleration: AEHD is not installed'
    }
    It 'refuses a non-ASCII SDK root or AVD home, naming the fix' {
        $u = New-TestSetup -Extra @{ AVD_SDK_ROOT = (Join-Path $TestDrive ('Jos' + [char]0xE9) 'sdk') }
        { Assert-AvdSetupPath 6>$null } | Should -Throw '*AVD_SDK_ROOT*non-ASCII*ANDROID_AVD_HOME*C:\avd*'
        $v = New-TestSetup -Extra @{ ANDROID_AVD_HOME = (Join-Path $TestDrive ('M' + [char]0xFC + 'ller') 'avd') }
        { Assert-AvdSetupPath 6>$null } | Should -Throw '*AVD home*non-ASCII*'
        $null = $u, $v
    }
}

Describe 'the root phase on a recorded device' {
    BeforeEach {
        $script:T = New-TestSetup
        $s = $T.State
        $s.Api = '37.0'
        $script:Rd = Join-Path $s.SdkRoot 'system-images' 'android-37.0' 'google_apis' 'x86_64' 'ramdisk.img'
        New-File $Rd 'ORIGINAL'
        New-File $s.Emulator 'emu'
        $script:Dev = @{ Calls = [System.Collections.Generic.List[object]]::new(); Killed = $false; Launched = 0 }
        Mock -ModuleName AvdPhotos Start-Sleep {}
        Mock -ModuleName AvdPhotos Get-AvdAdbPath { '/fake/adb' }
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { -not $script:Dev.Killed }
        Mock -ModuleName AvdPhotos Start-AvdEmulatorProcess { $script:Dev.Killed = $false; $script:Dev.Launched++ }
        Mock -ModuleName AvdPhotos Stop-AvdEmulatorProcess {}
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result -Out "accel:`n0`nWHPX(10.0.26100) is installed and usable.`naccel`n" }
        Mock -ModuleName AvdPhotos Get-AvdSetupRelease {
            [pscustomobject]@{ tag_name = 'v28.1'; assets = @([pscustomobject]@{ name = 'Magisk-v28.1.apk'; browser_download_url = 'https://example.invalid/Magisk-v28.1.apk' }) }
        }
        Mock -ModuleName AvdPhotos Save-AvdSetupDownload { [System.IO.File]::WriteAllText($Path, 'APK BYTES'); $true }
        Mock -ModuleName AvdPhotos Invoke-AvdAdb {
            $a = [string[]]@($ArgumentList)
            $rec = [pscustomobject]@{ Args = $a; Bytes = $null }
            $out = ''
            if ($a.Count -ge 5 -and $a[2] -eq 'push') {
                $rec.Bytes = [System.IO.File]::ReadAllBytes($a[3])
            } elseif ($a.Count -ge 5 -and $a[2] -eq 'pull') {
                [System.IO.File]::WriteAllText($a[4], 'PATCHED')
            } elseif ($a.Count -ge 4 -and $a[2] -eq 'emu' -and $a[3] -eq 'kill') {
                $script:Dev.Killed = $true
            } elseif ($a.Count -ge 4 -and $a[2] -eq 'emu' -and $a[3] -eq 'avd') {
                $out = "gphotos-tablet`r`nOK`r`n"
            } elseif (($a -join ' ') -eq 'devices') {
                $out = "List of devices attached`nemulator-5556`tdevice`n"
            } elseif ($a.Count -ge 4 -and $a[2] -eq 'shell') {
                $cmd = $a[3]
                if ($cmd -match 'magisk -v$') { $out = if ($script:Dev.Launched -gt 0) { "28.1:MAGISK:R`n" } else { "magisk: inaccessible or not found`n" } }
                elseif ($cmd -match '\[ -e /dev/block/vdd1 \]') { $out = "ok`n" }
                elseif ($cmd -eq 'getprop sys.boot_completed') { $out = "1`n" }
                elseif ($cmd -eq 'id -u') { $out = "0`n" }
                elseif ($cmd -match 'patch-ramdisk.sh$') { $out = "codec: lz4_legacy`n-rw-r--r-- 1 root root 9 ramdiskpatched.img`n" }
            }
            $script:Dev.Calls.Add($rec)
            [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = $out; StdErr = '' }
        }
        function script:Find-Call([scriptblock]$Where) { @($script:Dev.Calls | Where-Object $Where) }
        function script:Get-CallIndex([scriptblock]$Where) {
            for ($i = 0; $i -lt $script:Dev.Calls.Count; $i++) { if (& $Where $script:Dev.Calls[$i]) { return $i } }
            -1
        }
    }

    It 'patches the backup on the device and installs the result by stage-then-rename' {
        Invoke-AvdSetupRootPhase 6>$null
        $W = '/data/local/tmp/magiskpatch'
        $apk = Join-Path $T.Config.STATE_DIR 'magisk-latest.apk'

        (Find-Call { $_.Args[2] -eq 'push' -and $_.Args[3] -eq $apk -and $_.Args[4] -eq "$W/magisk.apk" }).Count | Should -Be 1
        # The pristine backup goes to the device, never the live ramdisk.img.
        (Find-Call { $_.Args[2] -eq 'push' -and $_.Args[3] -eq "$Rd.backup" -and $_.Args[4] -eq "$W/ramdisk.img" }).Count | Should -Be 1
        (Find-Call { $_.Args[2] -eq 'push' -and $_.Args[3] -eq $Rd }).Count | Should -Be 0
        [System.IO.File]::ReadAllText("$Rd.backup") | Should -Be 'ORIGINAL'

        $unzip = Find-Call { $_.Args[2] -eq 'shell' -and $_.Args[3] -match 'unzip' }
        $unzip.Count | Should -Be 1
        $unzip[0].Args[3] | Should -Match ([regex]::Escape("unzip -o -q magisk.apk 'assets/*' 'lib/x86_64/*'"))
        $unzip[0].Args[3] | Should -Match ([regex]::Escape('cp lib/x86_64/libmagiskboot.so magiskboot'))
        $unzip[0].Args[3] | Should -Not -Match 'arm64'

        $push = Find-Call { $_.Args[2] -eq 'push' -and $_.Args[4] -eq "$W/patch-ramdisk.sh" }
        $push.Count | Should -Be 1
        $bytes = $push[0].Bytes
        $bytes -contains [byte]13 | Should -BeFalse
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly (Get-AvdOnDevicePatchScript)

        (Find-Call { $_.Args[2] -eq 'shell' -and $_.Args[3] -eq "chmod 755 $W/patch-ramdisk.sh; PREINITDEVICE='vdd1' sh $W/patch-ramdisk.sh" }).Count | Should -Be 1
        (Find-Call { $_.Args[2] -eq 'pull' -and $_.Args[3] -eq "$W/ramdiskpatched.img" -and $_.Args[4] -eq "$Rd.new" }).Count | Should -Be 1
        [System.IO.File]::ReadAllText($Rd) | Should -Be 'PATCHED'
        Test-Path "$Rd.new" | Should -BeFalse
    }

    It 'installs the APK, then restarts the VM (not a guest reboot), then completes Magisk''s environment for x86_64' {
        Invoke-AvdSetupRootPhase 6>$null
        $pull = Get-CallIndex { param($c) $c.Args[2] -eq 'pull' }
        $install = Get-CallIndex { param($c) $c.Args[2] -eq 'install' -and $c.Args[3] -eq '-r' }
        $kill = Get-CallIndex { param($c) $c.Args[2] -eq 'emu' -and $c.Args[3] -eq 'kill' }
        $pull | Should -BeGreaterThan -1
        $install | Should -BeGreaterThan $pull
        $kill | Should -BeGreaterThan $install
        (Find-Call { $_.Args[2] -eq 'reboot' }).Count | Should -Be 0
        $script:Dev.Launched | Should -Be 1
        (Find-Call { $_.Args[2] -eq 'emu' -and $_.Args[3] -eq 'kill' })[0].Args[1] | Should -Be 'emulator-5556'
        $envCall = Find-Call { $_.Args[2] -eq 'shell' -and $_.Args[3] -match 'libmagiskpolicy' }
        $envCall.Count | Should -Be 1
        $envCall[0].Args[3] | Should -Match ([regex]::Escape('cat lib/x86_64/libmagisk.so'))
        $envCall[0].Args[3] | Should -Not -Match "`r"
        $envCall[0].Args[3] | Should -Match ([regex]::Escape('MT=$(/debug_ramdisk/magisk --path 2>/dev/null)'))
        Get-SetupLog $T.State | Should -Match 'Magisk active: 28.1:MAGISK:R'
    }

    It 'installs the patch while the VM is down when Windows refuses to replace a ramdisk the VM holds' {
        $script:Dev.Tries = 0
        $script:Dev.InstalledWhileDown = $false
        Mock -ModuleName AvdPhotos Install-AvdSetupRamdisk {
            $script:Dev.Tries++
            if (-not $script:Dev.Killed) { throw [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.') }
            [System.IO.File]::Move($From, $To, $true)
            $script:Dev.InstalledWhileDown = $true
        }
        Invoke-AvdSetupRootPhase 6>$null
        $script:Dev.Tries | Should -Be 2
        $script:Dev.InstalledWhileDown | Should -BeTrue
        [System.IO.File]::ReadAllText($Rd) | Should -Be 'PATCHED'
        Test-Path "$Rd.new" | Should -BeFalse
        $script:Dev.Launched | Should -Be 1
        Get-SetupLog $T.State | Should -Match 'replaced once the VM is down'
        Get-SetupLog $T.State | Should -Match 'installed the patched ramdisk with the emulator stopped'
    }

    It 'stops, leaving the original ramdisk, when the patch cannot be installed even with the VM down' {
        Mock -ModuleName AvdPhotos Install-AvdSetupRamdisk { throw [System.IO.IOException]::new('denied') }
        { Invoke-AvdSetupRootPhase 6>$null } | Should -Throw '*even with the emulator stopped*'
        [System.IO.File]::ReadAllText($Rd) | Should -Be 'ORIGINAL'
        $script:Dev.Launched | Should -Be 0
    }

    It 'refuses to patch when the Magisk APK does not verify' {
        [System.IO.File]::WriteAllText((Join-Path $T.State.Stamps 'sha-magisk-28.1'), ('0' * 64))
        { Invoke-AvdSetupRootPhase 6>$null } | Should -Throw '*did not verify*'
        (Find-Call { $_.Args[2] -eq 'push' }).Count | Should -Be 0
        [System.IO.File]::ReadAllText($Rd) | Should -Be 'ORIGINAL'
    }
}

Describe 'modes' {
    BeforeEach {
        $script:T = New-TestSetup
        Mock -ModuleName AvdPhotos Add-AvdToolPath {}
        Mock -ModuleName AvdPhotos Start-Sleep {}
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { New-Result }
        Mock -ModuleName AvdPhotos Invoke-AvdProcess { New-Result }
        Mock -ModuleName AvdPhotos Start-AvdEmulatorProcess {}
        Mock -ModuleName AvdPhotos Stop-AvdEmulatorProcess {}
        Mock -ModuleName AvdPhotos Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"tag_name":"v1","assets":[]}' } }
    }
    It '-Bootstrap with setup-complete present is a no-op: no process, no adb, no lock, no log' {
        New-File $T.State.SetupDone '1757740000'
        Invoke-AvdSetup -Mode Bootstrap -Config $T.Config -Environment $T.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Start-AvdEmulatorProcess -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Add-AvdToolPath -Times 0 -Exactly
        Test-Path $T.State.Lock | Should -BeFalse
        Test-Path $T.State.Log | Should -BeFalse
    }
    It '-Check with the emulator stopped makes no device call and writes nothing' {
        $s = $T.State
        New-File $s.SdkManager 'sdkmanager'
        New-File $s.Emulator 'emu'
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { $false }
        Mock -ModuleName AvdPhotos Get-AvdSetupJavaPath { '/fake/java' }
        $list = Get-Fixture 'sdkmanager-list.txt'
        Mock -ModuleName AvdPhotos Invoke-AvdProcess {
            if ($ArgumentList -contains '--list') { return (New-Result -Out $list) }
            if ($ArgumentList -contains '-version' -and $FilePath -eq '/fake/java') { return (New-Result -Err 'openjdk version "21.0.4"') }
            if ($ArgumentList -contains '-version') { return (New-Result -Out 'Android emulator version 36.1.9.0 (build_id 13823996) (CL:N/A)') }
            if ($ArgumentList -contains '-accel-check') { return (New-Result -Out "accel:`n0`nWHPX(10.0.26100) is installed and usable.`naccel`n") }
            New-Result -Code 1
        }
        Invoke-AvdSetup -Mode Check -Config $T.Config -Environment $T.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Start-AvdEmulatorProcess -Times 0 -Exactly
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains '--install' -or $ArgumentList -contains '--licenses' -or $ArgumentList -contains 'create' }
        $log = Get-SetupLog $s
        $log | Should -Match 'newest available API: 37.0'
        $log | Should -Match 'emulator: 36.1.9.0'
        $log | Should -Match 'emulator not running -- on-device checks skipped'
        Test-Path $s.SetupDone | Should -BeFalse
        Test-Path $T.Config.CONFIG_FILE | Should -BeFalse
        Test-Path $s.Lock | Should -BeFalse
    }
    It 'exits 0 without touching anything while another setup holds the lock' {
        $null = New-Item -ItemType Directory -Force -Path $T.Config.STATE_DIR
        (Enter-AvdLock -Path $T.State.Lock).Status | Should -Be 'held'
        try {
            Invoke-AvdSetup -Mode Full -Config $T.Config -Environment $T.Environment 6>$null | Should -Be 0
            Should -Invoke -ModuleName AvdPhotos Invoke-AvdProcess -Times 0 -Exactly
            Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly
            Test-Path $T.State.Lock | Should -BeTrue
        } finally { Exit-AvdLock -Path $T.State.Lock }
    }
    It 'returns 1 on an ERROR, logs it, and releases the lock' {
        $bad = New-TestSetup -Extra @{ AVD_SDK_ROOT = (Join-Path $TestDrive ('Jos' + [char]0xE9)) }
        Invoke-AvdSetup -Mode Full -Config $bad.Config -Environment $bad.Environment 6>$null | Should -Be 1
        Get-SetupLog $bad.State | Should -Match '   ERROR AVD_SDK_ROOT .* non-ASCII'
        Test-Path $bad.State.Lock | Should -BeFalse
    }
    It '-Stop resolves the serial by name and never addresses an unnamed device' {
        $script:Stopped = $false
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { -not $script:Stopped }
        Mock -ModuleName AvdPhotos Stop-AvdEmulatorProcess { $script:Stopped = $true }
        Mock -ModuleName AvdPhotos Invoke-AvdAdb {
            if (($ArgumentList -join ' ') -eq 'devices') { return (New-Result -Out "List of devices attached`nemulator-5554`tdevice`n") }
            if (($ArgumentList -join ' ') -eq '-s emulator-5554 emu avd name') { return (New-Result -Out "someone-elses-avd`nOK`n") }
            New-Result
        }
        Invoke-AvdSetup -Mode Stop -Config $T.Config -Environment $T.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Stop-AvdEmulatorProcess -Times 1 -Exactly
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'kill' -or $ArgumentList -contains 'shell' }
        Get-SetupLog $T.State | Should -Match 'no adb serial answers to the name gphotos-tablet'
    }
    It '-Stop syncs and kills our emulator by its resolved serial' {
        $script:Killed = $false
        Mock -ModuleName AvdPhotos Test-AvdEmulatorRunning { -not $script:Killed }
        Mock -ModuleName AvdPhotos Invoke-AvdAdb {
            $a = $ArgumentList -join ' '
            if ($a -eq 'devices') { return (New-Result -Out "List of devices attached`nemulator-5554`tdevice`nemulator-5556`tdevice`n") }
            if ($a -eq '-s emulator-5554 emu avd name') { return (New-Result -Out "someone-elses-avd`nOK`n") }
            if ($a -eq '-s emulator-5556 emu avd name') { return (New-Result -Out "gphotos-tablet`nOK`n") }
            if ($a -eq '-s emulator-5556 emu kill') { $script:Killed = $true }
            New-Result
        }
        Invoke-AvdSetup -Mode Stop -Config $T.Config -Environment $T.Environment 6>$null | Should -Be 0
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '-s emulator-5556 shell sync' }
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'emulator-5554 (shell|emu kill)' }
        Should -Invoke -ModuleName AvdPhotos Stop-AvdEmulatorProcess -Times 0 -Exactly
        Get-SetupLog $T.State | Should -Match '   stopped'
    }
}

Describe 'cleanup (the EXIT trap)' {
    BeforeEach {
        $script:T = New-TestSetup -Headless
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { New-Result }
    }
    It 'syncs and kills an emulator this headless run started, by its serial' {
        $T.State.EmuStartedByUs = $true; $T.State.Serial = 'emulator-5556'
        Invoke-AvdSetupCleanup
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '-s emulator-5556 shell sync' }
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '-s emulator-5556 emu kill' }
    }
    It 'leaves alone an emulator it did not start, a -Start one, a windowed one, and an unresolved serial' {
        $T.State.EmuStartedByUs = $false; $T.State.Serial = 'emulator-5556'
        Invoke-AvdSetupCleanup
        $s = (New-TestSetup -Mode Start -Headless).State
        $s.EmuStartedByUs = $true; $s.Serial = 'emulator-5556'
        Invoke-AvdSetupCleanup
        $s = (New-TestSetup).State
        $s.EmuStartedByUs = $true; $s.Serial = 'emulator-5556'
        Invoke-AvdSetupCleanup
        $s = (New-TestSetup -Headless).State
        $s.EmuStartedByUs = $true; $s.Serial = ''
        Invoke-AvdSetupCleanup
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly
    }
}

Describe 'the summary' {
    It 'reports the device id in -Check while the emulator runs, read-only' {
        $c = New-TestSetup -Mode Check
        $c.State.Serial = 'emulator-5556'
        Mock -ModuleName AvdPhotos Invoke-AvdAdb { New-Result }
        Mock -ModuleName AvdPhotos Get-AvdSetupGsfDeviceId { '4012345678901234567' }
        Write-AvdSetupSummary 6>$null
        Get-SetupLog $c.State | Should -Match 'device id: 4012345678901234567'
        # Only `adb -s <serial> shell <read>`: no push, install, reboot or kill,
        # and no device command that writes.
        Should -Invoke -ModuleName AvdPhotos Invoke-AvdAdb -Times 0 -Exactly -ParameterFilter {
            $ArgumentList[2] -ne 'shell' -or $ArgumentList[3] -match 'touch |rm -|>>|> /|--install-module|--restorecon|--sqlite| disable '
        }
    }
    It 'does not look for it with no serial resolved' {
        $c = New-TestSetup -Mode Check
        Mock -ModuleName AvdPhotos Get-AvdSetupGsfDeviceId { throw 'not expected' }
        Write-AvdSetupSummary 6>$null
        Get-SetupLog $c.State | Should -Not -Match 'device id'
    }
}

Describe 'the end of a full run: config seed, done marker, epilogue' {
    BeforeEach {
        $script:T = New-TestSetup
        New-File $T.State.ConfigIni 'image.sysdir.1=system-images\android-37.0\google_apis\x86_64\'
        $T.State.Serial = 'emulator-5556'
        Mock -ModuleName AvdPhotos Get-AvdSetupGsfDeviceId { '4012345678901234567' }
        Mock -ModuleName AvdPhotos Get-AvdAdbPath { 'C:\sdk\platform-tools\adb.exe' }
    }
    It 'seeds the config, writes the marker when everything held, and prints the device id and check-in line' {
        $T.State.PlaystoreOk = $true
        Mock -ModuleName AvdPhotos Get-AvdSetupMagiskVersion { '28.1:MAGISK:R' }
        $shown = Complete-AvdSetupRun 6>&1 | Out-String
        Test-Path $T.Config.CONFIG_FILE | Should -BeTrue
        [System.IO.File]::ReadAllText($T.State.SetupDone) | Should -Match '^\d{10}\n$'
        $shown | Should -Match 'device id:  4012345678901234567'
        $shown | Should -Match ([regex]::Escape("& 'C:\sdk\platform-tools\adb.exe' -s emulator-5556 shell am broadcast -a android.server.checkin.CHECKIN"))
        $shown | Should -Match "use 'avd-signin', not 'avd-start'"
        $shown | Should -Match "'avd-photos-arm'"
    }
    It 'removes the marker and says so when the Play Store did not take, and never overwrites a config' {
        New-File $T.State.SetupDone 'old'
        New-File $T.Config.CONFIG_FILE 'ICLOUD_USERNAME=me@example.com'
        $T.State.PlaystoreOk = $false
        Mock -ModuleName AvdPhotos Get-AvdSetupMagiskVersion { '28.1:MAGISK:R' }
        $null = Complete-AvdSetupRun 6>&1
        Test-Path $T.State.SetupDone | Should -BeFalse
        [System.IO.File]::ReadAllText($T.Config.CONFIG_FILE) | Should -Be 'ICLOUD_USERNAME=me@example.com'
        Get-SetupLog $T.State | Should -Match 'setup did not complete -- the next login \(or another run\) resumes it'
    }
    It 'writes no marker for an unrooted emulator' {
        $T.State.PlaystoreOk = $true
        Mock -ModuleName AvdPhotos Get-AvdSetupMagiskVersion { '' }
        $null = Complete-AvdSetupRun 6>&1
        Test-Path $T.State.SetupDone | Should -BeFalse
    }
}

Describe 'the command scripts' {
    BeforeAll {
        $script:Bin = Join-Path $Root 'windows' 'bin'
        # A child pwsh that could do no harm even if an argument set were
        # wrongly accepted: no PATH (no sdkmanager, adb or java to find),
        # config, state and SDK under $TestDrive, and a proxy that refuses
        # every connection. Only argument sets refused BEFORE the module loads
        # are passed. Note pwsh -File binds `--check` to -Check (and `-che`
        # by prefix), so the macOS spellings are valid calls, not errors.
        function Invoke-BinScript([string]$Name, [string]$ArgText) {
            $d = Join-Path $TestDrive ('bin-' + [guid]::NewGuid().ToString('N'))
            $cmd = "`$env:PATH = ''; `$env:HOME = '$d'; `$env:USERPROFILE = '$d'; " +
                "`$env:AVD_PHOTOS_CONFIG_DIR = '$d/config'; `$env:AVD_PHOTOS_STATE_DIR = '$d/state'; " +
                "`$env:AVD_SDK_ROOT = '$d/sdk'; `$env:ANDROID_AVD_HOME = '$d/avd'; " +
                "`$env:HTTPS_PROXY = 'http://127.0.0.1:9'; `$env:HTTP_PROXY = 'http://127.0.0.1:9'; " +
                "& '$(Join-Path $Bin $Name)' $ArgText; exit `$LASTEXITCODE"
            $r = Invoke-AvdProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) -TimeoutSec 60
            $r | Add-Member -NotePropertyName StateDir -NotePropertyValue (Join-Path $d 'state') -PassThru
        }
    }
    It 'rejects conflicting modes and unknown arguments with the usage line and exit 2, before doing anything' {
        foreach ($argText in @('-Start -Stop', '-Check -Bootstrap', '-Check -Start -Headless', '-Bogus', '-Start extra')) {
            $r = Invoke-BinScript 'avd-photos-setup.ps1' $argText
            $r.ExitCode | Should -Be 2 -Because $argText
            $r.StdErr | Should -Match 'usage: avd-photos-setup \[-Check\] \[-Headless\] \[-Start\|-Stop\] \[-Bootstrap\]'
            Test-Path $r.StateDir | Should -BeFalse -Because "$argText must be refused before the config is even read"
        }
    }
    It 'passes a bad argument through each wrapper to the same refusal' {
        foreach ($w in 'avd-start.ps1', 'avd-stop.ps1', 'avd-photos-check.ps1', 'avd-signin.ps1') {
            $r = Invoke-BinScript $w '-Bootstrap'
            $r.ExitCode | Should -Be 2 -Because $w
            Test-Path $r.StateDir | Should -BeFalse
        }
    }
}
