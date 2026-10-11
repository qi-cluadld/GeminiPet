@echo off
chcp 65001 >nul
rem Re-render the pose preview images into the preview\ folder
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GeminiPet.ps1" -Preview "%~dp0preview"
echo.
echo Preview images written to: %~dp0preview
pause
