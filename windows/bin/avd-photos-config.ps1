#Requires -Version 7.4
<#
.SYNOPSIS
Write the commented default configuration, and say where every file lives.
The Windows twin of bin/avd-photos-config.

.DESCRIPTION
  avd-photos-config            write it if it does not exist, then print it
  avd-photos-config -Force     overwrite an existing one (the old one is kept
                               beside it as config.bak)
  avd-photos-config -Paths     print the resolved locations and change nothing

Every form also prints what the config parser could not use (a line that is
not KEY=value, an unterminated quote, a number that is not one): on Windows
the file is read rather than sourced, and a value that silently went missing
is the failure the macOS config comment warns about.
#>
[CmdletBinding()]
param([switch]$Force, [switch]$Paths)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
if ($Force -and $Paths) {
    [Console]::Error.WriteLine('usage: avd-photos-config [-Force|-Paths]')
    exit 2
}
$cfg = Get-AvdConfig

if ($Paths) {
    $armed = if (Test-Path -LiteralPath $cfg.SENTINEL) { ' (present)' } else { ' (absent: the pipeline is dormant)' }
    Write-Host ('{0,-10} {1}' -f 'config', $cfg.CONFIG_FILE)
    Write-Host ('{0,-10} {1}{2}' -f 'armed', $cfg.SENTINEL, $armed)
    Write-Host ('{0,-10} {1}' -f 'state', $cfg.STATE_DIR)
    Write-Host ('{0,-10} {1}' -f 'logs', $cfg.LOG_DIR)
    Write-Host ('{0,-10} {1}' -f 'staging', $cfg.STAGING)
    Write-Host ('{0,-10} {1}' -f 'sdk root', $cfg.AVD_SDK_ROOT)
    Write-Host ('{0,-10} {1}' -f 'emulator', $cfg.AVD_NAME)
    Write-Host ('{0,-10} {1}' -f 'avd home', $cfg.AVD_HOME)
    Write-Host ('{0,-10} {1} (system image ABI {2})' -f 'machine', $cfg.ARCHITECTURE, $cfg.AVD_ABI)
    foreach ($w in $cfg.WARNINGS) { Write-Host "config: $w" }
    exit 0
}

if ($Force) {
    if (Test-Path -LiteralPath $cfg.CONFIG_FILE) {
        Copy-Item -LiteralPath $cfg.CONFIG_FILE -Destination "$($cfg.CONFIG_FILE).bak" -Force
        $null = Protect-AvdFile -Path "$($cfg.CONFIG_FILE).bak"
        Write-Host "kept the previous config as $($cfg.CONFIG_FILE).bak"
    }
    Write-AvdDefaultConfig -Path $cfg.CONFIG_FILE -Architecture $cfg.ARCHITECTURE
    Write-Host "wrote $($cfg.CONFIG_FILE)"
    exit 0
}

if (Test-Path -LiteralPath $cfg.CONFIG_FILE) {
    Write-Host "$($cfg.CONFIG_FILE) already exists (-Force overwrites it, keeping a .bak)`n"
} else {
    Write-AvdDefaultConfig -Path $cfg.CONFIG_FILE -Architecture $cfg.ARCHITECTURE
    Write-Host "wrote $($cfg.CONFIG_FILE)`n"
}
Write-Host ([System.IO.File]::ReadAllText($cfg.CONFIG_FILE))
foreach ($w in $cfg.WARNINGS) { Write-Host "config: $w" }
exit 0
