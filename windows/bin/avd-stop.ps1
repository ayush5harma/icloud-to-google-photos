#Requires -Version 7.2
# Graceful shutdown: sync, then `emu kill` by the emulator's resolved serial,
# then wait for the process to go (and stop the process if it will not).
param(
    [switch]$Headless,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$more = if ($null -ne $Rest) { $Rest } else { @() }
& (Join-Path $PSScriptRoot 'avd-photos-setup.ps1') -Stop -Headless:$Headless @more
exit $LASTEXITCODE
