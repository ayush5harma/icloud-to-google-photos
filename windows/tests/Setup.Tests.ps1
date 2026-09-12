#Requires -Version 7.2
# The setup port (windows\lib\Setup.ps1). Pure helpers against fixtures; the
# stateful parts against $TestDrive with every process, adb call, download and
# sleep mocked -- no emulator, no SDK, no network. What these cannot prove (an
# emulator booting under WHPX, the patch on a real x86_64 ramdisk) is listed in
# windows\DESIGN.md.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'the on-device patch script' {
    It 'is byte-identical to the heredoc in bin/avd-photos-setup' {
        $bash = ConvertTo-AvdLf ([System.IO.File]::ReadAllText((Join-Path $Root 'bin' 'avd-photos-setup')))
        $m = [regex]::Match($bash, "(?s)\n  cat <<'PATCH_EOS'\n(.*?\n)PATCH_EOS\n")
        $m.Success | Should -BeTrue
        $dev = [System.IO.File]::ReadAllText((Join-Path $Root 'windows' 'device' 'patch-ramdisk.sh'))
        (ConvertTo-AvdLf $dev) | Should -BeExactly $m.Groups[1].Value
    }
}
