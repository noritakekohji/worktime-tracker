@echo off
rem WorkTime Tracker setup launcher.
rem /force overwrites an existing install without a prompt.
rem /quiet suppresses the final pause for the automatic updater.
setlocal EnableExtensions

set "SETUP_ARGS="
set "QUIET=0"
if /I "%~1"=="/force" set "SETUP_ARGS=-Force"
if /I "%~2"=="/quiet" set "QUIET=1"

set "SRC=%~dp0.."
pushd "%SRC%" >nul 2>&1

echo.
echo === WorkTime Tracker Setup ===
echo.
echo [1/2] Removing Mark of the Web from package files...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -Path '%SRC%' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; 'done'"

echo.
echo [2/2] Starting setup.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %SETUP_ARGS%
set RC=%ERRORLEVEL%

popd >nul 2>&1

if not "%RC%"=="0" (
    echo.
    echo ============================================================
    echo  Setup failed (exit code %RC%)
    echo ============================================================
)
echo.
if "%QUIET%"=="1" exit /b %RC%
pause
