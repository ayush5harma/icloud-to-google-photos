#Requires -Version 7.4
<#
.SYNOPSIS
Arm (or disarm) the sync. The Windows twin of bin/avd-photos-arm.

.DESCRIPTION
ARM ONLY AFTER a signed-in emulator with the spoof active has been verified:
from this moment the job downloads originals, pushes them into the emulator
and -- once Google Photos' own database confirms them, and only then --
DELETES THEM FROM iCLOUD.

  avd-photos-arm           print what arming would switch on; arm if reclaim is
                           off, otherwise ask for -Yes
  avd-photos-arm -Yes      arm, deletions included
  avd-photos-arm -Off      disarm; the task keeps ticking and every tick exits
  avd-photos-arm -Status   say which it is

WHY THE EXTRA WORD. Every other command here is reversible. This one turns on
a process whose last step deletes photographs from the only library most
people have, on a schedule, with no further prompt -- so the settings that
decide what leaves iCloud are printed first, and turning it on with reclaim
enabled takes a deliberate second word.
#>
[CmdletBinding()]
param([switch]$Yes, [switch]$Off, [switch]$Status)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
if (@($Yes, $Off, $Status | Where-Object { $_ }).Count -gt 1) {
    [Console]::Error.WriteLine('usage: avd-photos-arm [-Yes|-Off|-Status]')
    exit 2
}
$cfg = Get-AvdConfig

if ($Status) {
    if (Test-Path -LiteralPath $cfg.SENTINEL) { Write-Host "armed ($($cfg.SENTINEL))" }
    else { Write-Host "dormant (no $($cfg.SENTINEL))" }
    exit 0
}
if ($Off) {
    Remove-Item -LiteralPath $cfg.SENTINEL -Force -ErrorAction SilentlyContinue
    Write-Host 'disarmed -- every sync tick now exits immediately'
    exit 0
}

if (-not $cfg.ICLOUD_USERNAME) {
    [Console]::Error.WriteLine("ICLOUD_USERNAME is unset in $($cfg.CONFIG_FILE) -- set it before arming")
    exit 1
}
foreach ($w in $cfg.WARNINGS) { Write-Host "config: $w" }

$keep = Get-AvdConfigInt -Config $cfg -Key KEEP_ICLOUD_DAYS
Write-Host "Arming will run the sync every 15 minutes with these settings:`n"
Write-Host ('  {0,-21} {1}' -f 'Apple ID', $cfg.ICLOUD_USERNAME)
Write-Host ('  {0,-21} {1}' -f 'staging', $cfg.STAGING)
Write-Host ('  {0,-21} {1}' -f 'emulator', $cfg.AVD_NAME)
if ($cfg.DELETE_FROM_ICLOUD -eq '1') {
    Write-Host ('  {0,-21} {1}' -f 'delete from iCloud', 'YES, once Google Photos has confirmed each file')
    if ($keep -gt 0) { Write-Host ('  {0,-21} {1}' -f 'keep the newest', "$keep day(s), never deleted whatever their state") }
    else { Write-Host ('  {0,-21} {1}' -f 'keep the newest', 'NOTHING -- a photo can leave iCloud as soon as it is confirmed') }
    Write-Host "`n  Deleted photos go to iCloud's Recently Deleted for 30 days."
    Write-Host "  Set DELETE_FROM_ICLOUD=0 in $($cfg.CONFIG_FILE) to copy without deleting."
    Write-Host '  Dry run first: avd-photos-offload -DryRun'
} else {
    Write-Host ('  {0,-21} {1}' -f 'delete from iCloud', 'no (DELETE_FROM_ICLOUD=0) -- this copies only')
}
Write-Host ''

if ($cfg.DELETE_FROM_ICLOUD -eq '1' -and -not $Yes) {
    Write-Host 'Not armed. Re-run as: avd-photos-arm -Yes'
    exit 1
}

$null = New-Item -ItemType Directory -Force -Path $cfg.CONFIG_DIR
[System.IO.File]::WriteAllText($cfg.SENTINEL, '')
# Start the task so the first run is now rather than up to 15 minutes away. A
# failure here is not an error (the tasks may not be registered).
$task = "\$($cfg.LABEL_PREFIX).sync"
$r = Invoke-AvdProcess -FilePath (Get-AvdSystemToolPath -Name 'schtasks.exe') -ArgumentList @('/Run', '/TN', $task) -TimeoutSec 30
if ($r.ExitCode -eq 0) {
    Write-Host "armed, and the sync task was started -- watch $(Join-Path $cfg.LOG_DIR 'sync.log')"
} else {
    Write-Host 'armed -- the sync task is not registered, so nothing is scheduled (run windows\install.ps1)'
}
exit 0
