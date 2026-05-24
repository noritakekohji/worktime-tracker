@echo off
rem ============================================================
rem  WorkTime Tracker - デモデータ投入ランチャ
rem
rem  config.json から local_store を読み取り、master + data を生成
rem ============================================================
setlocal EnableExtensions

echo.
echo === WorkTime Tracker デモデータ投入 ===
echo.
echo 投入対象 (local_store):
echo   - master/members.json / projects.json / task_patterns.json
echo   - master/categories.json / holidays.json
echo   - data/YYYY/MM/E001..E004.json (前月 + 当月)
echo.
echo 既存ファイルは上書きされます。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0load-demo.ps1" %*
set RC=%ERRORLEVEL%

if not "%RC%"=="0" (
    echo.
    echo ============================================================
    echo  デモデータ投入失敗 ^(終了コード %RC%^)
    echo  考えられる原因:
    echo   1. config.json が未作成 ^(Tracker を一度起動して初回設定を完了させる^)
    echo   2. local_store パスが存在しない / 書込権限なし
    echo ============================================================
)
echo.
pause