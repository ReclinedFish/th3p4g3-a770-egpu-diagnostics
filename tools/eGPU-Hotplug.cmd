@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -File "%~dp0eGPU-Hotplug.ps1" %*
set "hotplugExitCode=%errorlevel%"
if %hotplugExitCode% neq 0 pause
exit /b %hotplugExitCode%
