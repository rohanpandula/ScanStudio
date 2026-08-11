@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-ScanStudio-Hardware-Session.ps1"
set "ScanStudioSessionExit=%ERRORLEVEL%"
echo.
echo Review the session result above, then press any key to close this window.
pause >nul
exit /b %ScanStudioSessionExit%
