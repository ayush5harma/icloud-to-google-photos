#Requires -Version 7.2
<#
.SYNOPSIS
One JSON blob describing the pipeline, the same fields as bin/avd-photos-status
on macOS.

.DESCRIPTION
Prints the JSON, or with -OutFile writes it to that file atomically (a temp
file and a rename) and prints nothing. The tray launches this without a window
and reads the file, never a pipe: a windowless child's stdout is a pipe the
tray would have to drain while it waits, and a half-written file is never seen.
Never starts an emulator; at most one bounded adb call.

.PARAMETER OutFile
Write the JSON here instead of printing it.
#>
[CmdletBinding()]
param([string]$OutFile)
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AvdPhotos.psm1') -Force
$json = Get-AvdPhotosStatus
if ($OutFile) {
    Write-AvdTextFile -Path $OutFile -Text "$json`n"
    exit 0
}
$json
