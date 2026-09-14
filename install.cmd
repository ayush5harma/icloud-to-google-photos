@echo off
rem Double-clickable entry point for install.ps1. A stock Windows refuses to run
rem PowerShell scripts at all (execution policy "Restricted"), so this runs the
rem installer with the policy bypassed for that one process only, and passes
rem any arguments through: install.cmd -ToolsDir D:\avd-tools
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 pause
