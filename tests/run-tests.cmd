@echo off
chcp 65001 > nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Smoke.ps1"
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo === 失敗 ^(exit=%RC%^) ===
)
pause
exit /b %RC%
