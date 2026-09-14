@echo off
REM Double-click this file to remove SpeakIt.
cd /d "%~dp0"
title Uninstalling SpeakIt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
echo.
echo Press any key to close this window.
pause >nul
