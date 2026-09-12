#Requires -Version 7.2
# Report the version of everything in the stack and change nothing: the SDK and
# emulator, the hypervisor, the system image, Magisk, Zygisk, the spoof module,
# Google Photos and the Play Store. Read-only by construction -- it never boots
# the emulator, never takes root, and never writes to the device.
#
# On-device lines are only meaningful while the emulator is running, so start
# it first (avd-start) if you want them.
param(
    [switch]$Headless,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$more = if ($null -ne $Rest) { $Rest } else { @() }
& (Join-Path $PSScriptRoot 'avd-photos-setup.ps1') -Check -Headless:$Headless @more
exit $LASTEXITCODE
