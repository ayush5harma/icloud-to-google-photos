#Requires -Version 7.2
# Boot the emulator and leave it running. NEVER hand-type
# `emulator -avd <name>`: the launch flags are load-bearing and fail SILENTLY
# when missing (the GPU one above all). The setup owns them; this reuses it.
param(
    [switch]$Headless,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$more = if ($null -ne $Rest) { $Rest } else { @() }
& (Join-Path $PSScriptRoot 'avd-photos-setup.ps1') -Start -Headless:$Headless @more
exit $LASTEXITCODE
