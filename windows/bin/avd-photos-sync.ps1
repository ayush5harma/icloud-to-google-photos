#Requires -Version 7.2
<#
.SYNOPSIS
The sync job: new iCloud photos into Google Photos through the emulator,
verified, then reclaimed from iCloud (bin/avd-photos-sync on macOS).

.DESCRIPTION
Run every 15 minutes and at login by the sync scheduled task, and from the
tray's "Check iCloud now". Dormant until armed (avd-photos-arm). Exits 0 for a
completed or skipped run and 1 for a failure, which is also left in the phase
file as "failed: <why>" for the tray. The work is Invoke-AvdPhotosSync in
windows\lib\Sync.ps1; this file only parses the switches.

.PARAMETER Offload
Reclaim iCloud space in this run whatever DELETE_FROM_ICLOUD says. Still only
files the last verify pass confirmed (the macOS --offload).

.PARAMETER ReclaimDryRun
Report what the reclaim WOULD delete and stop: no emulator, no arming needed,
no deletions, no ledger changes (the macOS --reclaim-dry-run).
#>
[CmdletBinding()]
param([switch]$Offload, [switch]$ReclaimDryRun)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
exit (Invoke-AvdPhotosSync -Offload:$Offload -ReclaimDryRun:$ReclaimDryRun)
