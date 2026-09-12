#Requires -Version 7.2
# Invariants between the Windows tree and the macOS one it mirrors. Each test
# fails when one side changes and the other did not, which is the point: the
# README documents ONE contract for both platforms.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ConfigSh = [System.IO.File]::ReadAllText((Join-Path $Root 'lib' 'config.sh'))
    # The files this repository ships under windows\: text only, never the
    # scratch tree or a Python or pytest cache a local run leaves behind.
    $script:WindowsFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'windows') -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](\.scratch|__pycache__|\.pytest_cache)[\\/]' })
}

Describe 'the config contract matches lib/config.sh' {
    It 'has the same keys as AP_KEYS, in the same order' {
        $m = [regex]::Match($ConfigSh, 'AP_KEYS="([^"]*)"')
        $m.Success | Should -BeTrue
        $shKeys = @($m.Groups[1].Value -split '\s+' | Where-Object { $_ })
        $k = Get-AvdConfigKey
        $k | Should -Be $shKeys
    }
    It 'has the same label prefix as AP_LABEL_PREFIX' {
        $m = [regex]::Match($ConfigSh, 'AP_LABEL_PREFIX="([^"]*)"')
        Get-AvdLabelPrefix | Should -Be $m.Groups[1].Value
    }
    It 'has the same literal defaults as ap_defaults on Unix' {
        $d = Get-AvdDefault -Platform Unix -Environment @{ HOME = '/Users/me' }
        $n = 0
        foreach ($m in [regex]::Matches($ConfigSh, '(?m)^\s*([A-Z_]+)="\$\{\1:?-([^"$}]*)\}"')) {
            $d[$m.Groups[1].Value] | Should -Be $m.Groups[2].Value -Because $m.Groups[1].Value
            $n++
        }
        $n | Should -BeGreaterThan 20
    }
}

Describe 'the module parts' {
    It 'define every function once (they share one scope, where a second definition silently wins)' {
        $names = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Root 'windows' 'lib') -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                ForEach-Object { $_.Name }
        }
        $dupes = @($names | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name)
        $dupes | Should -BeNullOrEmpty
    }
}

Describe 'the Windows tree' {
    It 'is ASCII only (no emoji, no typographic dashes; Windows PowerShell reads BOM-less UTF-8 as ANSI)' {
        foreach ($f in $WindowsFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
            $bad | Should -Be 0 -Because $f.FullName
        }
    }
    It 'keeps the device scripts LF on this checkout (.gitattributes on a Windows checkout)' {
        $device = @($WindowsFiles | Where-Object { $_.DirectoryName -match '[\\/]device$' })
        foreach ($f in $device) {
            [System.IO.File]::ReadAllBytes($f.FullName) -contains [byte]13 | Should -BeFalse -Because $f.FullName
        }
    }
}
