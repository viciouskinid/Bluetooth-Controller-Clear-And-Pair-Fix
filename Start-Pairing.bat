@echo off
setlocal
cd /d "%~dp0"

title Five Bluetooth Controller Pairing Utility

echo.
echo ============================================
echo   FIVE BLUETOOTH CONTROLLER PAIRING UTILITY
echo ============================================
echo.
echo This utility uses the Windows Bluetooth pairing API.
echo Make sure the controllers are in pairing mode.
echo.
echo Starting Windows PowerShell 5.1...
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo ERROR: Windows PowerShell was not found.
    pause
    exit /b 1
)

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Pair-Controllers.ps1"
set "RESULT=%ERRORLEVEL%"

echo.
echo ============================================
if not "%RESULT%"=="0" echo PowerShell exited with code %RESULT%.
echo SCRIPT FINISHED
echo ============================================
echo.
echo Check Pairing-Log.txt for results.
pause
exit /b %RESULT%
