# uninstall.ps1 — 作業者 PC からの worktime-tracker 削除
#
# 削除対象:
#   1. インストールディレクトリ (%LOCALAPPDATA%\worktime-tracker, またはオプション指定)
#   2. デスクトップのショートカット 3 つ
#   3. (任意) ユーザ設定・キャッシュ・ログ (%APPDATA%\worktime-tracker)
#   4. (任意) ローカルデータキャッシュ (config.local_store のパス)
#
# 動作要件: Windows 10/11 + PowerShell 5.1 (どちらも標準搭載)

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\worktime-tracker",
    [switch]$KeepUserData,    # 指定時は %APPDATA%\worktime-tracker を削除しない
    [switch]$Force            # 全プロンプトをスキップして実行
)

$ErrorActionPreference = 'Stop'

function _Confirm {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    if ($Force) { return $true }
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $r = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($r)) { return $DefaultYes }
    return ($r -match '^[yY]')
}

function _RemovePath {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  - $Label : 存在しません ($Path)" -ForegroundColor DarkGray
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Host "  ✔ $Label を削除: $Path" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  ✖ $Label 削除失敗: $Path" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ' WorkTime Tracker  アンインストール' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''

# ---- 事前確認: 起動中のプロセスがいないか ----
$running = Get-Process -Name 'powershell','pwsh','wbsinput','worktimetracker','reportviewer' -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowTitle -match '(WorkTime|WBS|Report)' }
if ($running) {
    Write-Host '⚠ WorkTime 関連のウインドウが開いている可能性があります。閉じてから再実行してください:' -ForegroundColor Yellow
    $running | ForEach-Object { Write-Host "    PID $($_.Id)  $($_.MainWindowTitle)" }
    if (-not (_Confirm '無視して続行しますか?' $false)) { exit 0 }
}

# ---- 削除対象を提示 ----
$desktop = [Environment]::GetFolderPath('Desktop')
$appData = Join-Path $env:APPDATA 'worktime-tracker'

# config から local_store パスを読み (削除候補として提示)
$localStore = $null
$cfgPath = Join-Path $appData 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg -and $cfg.local_store) { $localStore = [string]$cfg.local_store }
    } catch { }
}

Write-Host '削除対象 (確認):' -ForegroundColor White
Write-Host "  1. インストール先  : $InstallDir"
Write-Host "  2. デスクトップショートカット 3 個 ($desktop\WorkTime *.lnk)"
if (-not $KeepUserData) {
    Write-Host "  3. ユーザ設定/ログ : $appData"
    Write-Host "                       (config.json / token.dat / user_prefs.json /"
    Write-Host "                        last_error.log / report_trace.log)"
}
if ($localStore -and (Test-Path -LiteralPath $localStore)) {
    Write-Host ''
    Write-Host "(参考) ローカルデータキャッシュ:" -ForegroundColor Yellow
    Write-Host "  $localStore"
    Write-Host '  → 個別に質問します (重要データが入っている可能性あり)' -ForegroundColor Yellow
}
Write-Host ''

if (-not (_Confirm '上記を削除して続行しますか?' $false)) {
    Write-Host '中断しました。' -ForegroundColor Yellow
    exit 0
}

# ---- 1. インストールディレクトリ ----
Write-Host ''
Write-Host '[1/4] インストールディレクトリ' -ForegroundColor Cyan
[void](_RemovePath -Path $InstallDir -Label 'インストール先')

# ---- 2. デスクトップショートカット ----
Write-Host ''
Write-Host '[2/4] デスクトップショートカット' -ForegroundColor Cyan
foreach ($name in 'WorkTime Tracker.lnk','WorkTime Report.lnk','WorkTime WBS.lnk','WorkTime WBS入力.lnk') {
    [void](_RemovePath -Path (Join-Path $desktop $name) -Label "ショートカット ($name)")
}

# ---- 3. ユーザ設定/ログ ----
Write-Host ''
if ($KeepUserData) {
    Write-Host '[3/4] ユーザ設定/ログ : -KeepUserData 指定のためスキップ' -ForegroundColor DarkGray
} else {
    Write-Host '[3/4] ユーザ設定/ログ' -ForegroundColor Cyan
    [void](_RemovePath -Path $appData -Label 'AppData (worktime-tracker)')
}

# ---- 4. ローカルデータキャッシュ (オプション) ----
Write-Host ''
Write-Host '[4/4] ローカルデータキャッシュ (任意)' -ForegroundColor Cyan
if (-not $localStore) {
    Write-Host '  - (config.json が無いため検出不可) スキップ' -ForegroundColor DarkGray
} elseif (-not (Test-Path -LiteralPath $localStore)) {
    Write-Host "  - $localStore : 既に存在しません" -ForegroundColor DarkGray
} else {
    Write-Host "  パス: $localStore"
    Write-Host '  ↑ ここにはマスタ JSON / 実績データのキャッシュが入っています。'
    Write-Host '    Gitlab モードならリモートから再取得できますが、スタンドアローンの'
    Write-Host '    場合はここが唯一のデータ保管場所です。'
    if (_Confirm 'このローカルキャッシュも削除しますか?' $false) {
        [void](_RemovePath -Path $localStore -Label 'local_store')
    } else {
        Write-Host '  - スキップ' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ' アンインストール完了' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
