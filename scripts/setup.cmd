@echo off
rem ============================================================
rem  WorkTime Tracker - 社内 PC 向けセットアップ起動ラッパ
rem
rem  - Mark of the Web (ダウンロード制限) を全ファイルから解除
rem  - PowerShell の ExecutionPolicy を一時 Bypass で setup.ps1 実行
rem  - 失敗時はコンソールを残して原因表示
rem ============================================================
setlocal EnableExtensions

set "SRC=%~dp0.."
pushd "%SRC%" >nul 2>&1

echo.
echo === WorkTime Tracker セットアップ ===
echo.
echo [1/2] Mark of the Web (ファイルブロック) を解除中...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -Path '%SRC%' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue; 'done'"
if errorlevel 1 (
    echo   ※ Unblock-File に失敗しましたが続行します
)

echo.
echo [2/2] setup.ps1 を起動...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
set RC=%ERRORLEVEL%

popd >nul 2>&1

if not "%RC%"=="0" (
    echo.
    echo ============================================================
    echo  セットアップ失敗 ^(終了コード %RC%^)
    echo  考えられる原因:
    echo   1. ExecutionPolicy が GPO で AllSigned に固定されている
    echo   2. AntiVirus / EDR がスクリプトをブロック
    echo   3. 別ユーザがインストール先を使用中
    echo.
    echo  対処:
    echo   - 上の赤字エラーをそのまま管理者に共有してください
    echo   - GPO の場合は無理。社内 IT に相談 ^(or 社内署名で配布^)
    echo ============================================================
)
echo.
pause
