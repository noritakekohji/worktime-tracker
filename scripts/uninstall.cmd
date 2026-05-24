@echo off
rem ============================================================
rem  WorkTime Tracker - アンインストールランチャ
rem
rem  - PowerShell を ExecutionPolicy 一時 Bypass で uninstall.ps1 実行
rem  - 確認プロンプト付き (-Force で全スキップ)
rem ============================================================
setlocal EnableExtensions

echo.
echo === WorkTime Tracker アンインストール ===
echo.
echo このスクリプトは以下を削除します:
echo   - %%LOCALAPPDATA%%\worktime-tracker (インストール先)
echo   - デスクトップショートカット 3 個
echo   - %%APPDATA%%\worktime-tracker (設定/ログ ※質問あり)
echo   - ローカルデータキャッシュ (※質問あり)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
    echo.
    echo ============================================================
    echo  アンインストール失敗 ^(終了コード %RC%^)
    echo  考えられる原因:
    echo   1. WorkTime のウインドウが開いたまま ^(ファイルロック^)
    echo   2. ExecutionPolicy が GPO で AllSigned に固定
    echo   3. AntiVirus / EDR がスクリプトをブロック
    echo ============================================================
)
echo.
pause