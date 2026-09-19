@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0gui\QiehaoGui.ps1"
exit /b %ERRORLEVEL%
