#Requires -Version 7.2
# Boot the emulator in SOFTWARE GL, which is the only mode that can render
# Google's account sign-in page. Use this for the one-time sign-in and nothing
# else: everything after is much faster on the default GPU path (avd-start).
#
# The symptom this exists for (measured on macOS): the login screen never
# appears, or the Sign in button does nothing at all, with no error anywhere.
# GMS renders the login in a Chromium WebView, which cannot create a GL context
# under `-gpu auto` (EGL_BAD_CONFIG, then "Application Error:
# com.google.android.gms" before a single pixel is drawn) and stalls forever on
# the Play Services splash under `-gpu host`. It reads exactly like Google
# refusing an uncertified device, which sends you off chasing Play
# certification instead. Whether `-gpu host` renders it on Windows is not
# known; software GL is used regardless.
#
# AVD_GPU is set in the ENVIRONMENT because the environment beats the config
# file, so this wins over an AVD_GPU there.
param(
    [switch]$Headless,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$more = if ($null -ne $Rest) { $Rest } else { @() }
$hadGpu = Test-Path -LiteralPath Env:AVD_GPU
$previousGpu = $env:AVD_GPU
$env:AVD_GPU = if ($env:AVD_SIGNIN_GPU) { $env:AVD_SIGNIN_GPU } else { 'swiftshader_indirect' }
try {
    & (Join-Path $PSScriptRoot 'avd-photos-setup.ps1') -Start -Headless:$Headless @more
    $rc = $LASTEXITCODE
} finally {
    # Put it back. Run from an interactive pwsh, a script shares the session's
    # environment, and a leftover AVD_GPU would beat the config for every later
    # avd-start in that session. Removed, never set to $null: PowerShell turns
    # $null into '' for a .NET string argument, and an EMPTY variable counts as
    # SET under the config precedence rule.
    if ($hadGpu) { $env:AVD_GPU = $previousGpu } else { Remove-Item -LiteralPath Env:AVD_GPU -ErrorAction SilentlyContinue }
}
exit $rc
