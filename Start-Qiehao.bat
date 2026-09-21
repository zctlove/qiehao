@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0gui\QiehaoGui.ps1"
set "QIEHAO_EXIT=%ERRORLEVEL%"
if not "%QIEHAO_EXIT%"=="0" (
    echo.
    echo Qiehao failed to start or exited with an error.
    echo Exit code: %QIEHAO_EXIT%
    echo.
    pause
)
exit /b %QIEHAO_EXIT%
