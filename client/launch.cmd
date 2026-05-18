@echo off
rem WorkTime Tracker launcher
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0WorkTimeTracker.ps1" %*
if errorlevel 1 (
    echo.
    echo === エラー終了しました。詳細は %APPDATA%\worktime-tracker\last_error.log ===
    pause
)