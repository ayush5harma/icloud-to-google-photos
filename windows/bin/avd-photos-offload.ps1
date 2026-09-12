#Requires -Version 7.2
<#
.SYNOPSIS
Reclaim iCloud space on demand: the command-line twin of the tray's "Offload
from iCloud" (bin/avd-photos-offload on macOS).

.DESCRIPTION
Runs the sync with DELETE_FROM_ICLOUD forced on for this one run. The sync
still deletes nothing unless the last verify pass confirmed its batch cleanly,
so this is safe to run before the pipeline has proven itself: it says so and
does nothing.

.PARAMETER DryRun
Report what WOULD leave iCloud and stop: no emulator, no downloads, no
deletions, no ledger changes. Run this before arming.
#>
[CmdletBinding()]
param([switch]$DryRun)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
if ($DryRun) { exit (Invoke-AvdPhotosSync -ReclaimDryRun) }
exit (Invoke-AvdPhotosSync -Offload)
