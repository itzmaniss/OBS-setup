@echo off
setlocal
title itzmaniss - Terminal Lab OBS setup
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Install-TerminalLab.ps1" %*
set "setup_exit=%errorlevel%"
echo.
if not "%setup_exit%"=="0" echo Setup did not finish. See the message above.
pause
exit /b %setup_exit%
