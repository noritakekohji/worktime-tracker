@echo off
rem ============================================================
rem  WorkTime Tracker - Gitlab 診断 (読み取り専用)
rem
rem  - Gitlab への書き込みは一切行いません
rem  - 「取得したのに明細が無い」等の切り分けに使います
rem  - 引数はそのまま test-gitlab.ps1 に渡されます
rem      例) test-gitlab.cmd -Detail
rem          test-gitlab.cmd -FixState
rem ============================================================
setlocal
set "PS1=%~dp0test-gitlab.ps1"
if not exist "%PS1%" (
    echo [ERROR] test-gitlab.ps1 が見つかりません: "%PS1%"
    pause
    exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
