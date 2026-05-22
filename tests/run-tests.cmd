@echo off
chcp 65001 > nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Tests.ps1" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo === テスト失敗 ^(exit=%RC%^) ===
)
pause
exit /b %RC%
