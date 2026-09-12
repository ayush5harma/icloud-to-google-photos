#Requires -Version 7.2
<#
.SYNOPSIS
Set up and keep current the pipeline's rooted Android emulator (Magisk,
NeoZygisk, the Google Photos spoof, the Play Store), or check, start or stop it.

.DESCRIPTION
The Windows port of bin/avd-photos-setup. The work is Invoke-AvdSetup in
windows\lib\Setup.ps1; this script only reads the switches.

  (none)      set up and update             -Check   report versions, change nothing
  -Headless   no emulator window            -Start   boot it and leave it running
  -Bootstrap  resume an unfinished setup    -Stop    graceful shutdown
              (a no-op once setup completed)

Environment-only knobs, as on macOS: AVD_RECREATE=1, AVD_REROOT=1,
PLAYSTORE_DONOR_API, DEV_TIMEOUT, BOOT_WAIT.
#>
param(
    [switch]$Check,
    [switch]$Headless,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Bootstrap,
    # Anything else lands here, so an unknown argument gets the usage line and
    # exit 2, as the bash script's does, rather than a parameter-binding error.
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$usage = 'usage: avd-photos-setup [-Check] [-Headless] [-Start|-Stop] [-Bootstrap]'
$modes = @($Check.IsPresent, $Start.IsPresent, $Stop.IsPresent, $Bootstrap.IsPresent | Where-Object { $_ })
if (($null -ne $Rest -and $Rest.Count -gt 0) -or $modes.Count -gt 1) {
    [Console]::Error.WriteLine($usage)
    exit 2
}
$mode = if ($Check) { 'Check' } elseif ($Start) { 'Start' } elseif ($Stop) { 'Stop' } elseif ($Bootstrap) { 'Bootstrap' } else { 'Full' }

Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
$rc = Invoke-AvdSetup -Mode $mode -Headless:$Headless
exit ([int]($rc | Select-Object -Last 1))
