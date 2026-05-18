# setup.ps1 — 作業者 PC への初回セットアップ (社内 PC, 追加インストールなし)
#
# 動作要件: Windows 10/11 + PowerShell 5.1 (どちらも標準搭載)
# 必要なのは zip 展開先のフォルダのみ。追加モジュール・git CLI は不要。

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\worktime-tracker"
)

$ErrorActionPreference = 'Stop'

Write-Host "worktime-tracker セットアップ" -ForegroundColor Cyan
Write-Host "Install dir: $InstallDir"

# 1. zip 展開先のチェック
$srcDir = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $srcDir 'client/WorkTimeTracker.ps1'))) {
    Write-Host "ERROR: client/WorkTimeTracker.ps1 が見つかりません。zip 展開後のフォルダから実行してください。" -ForegroundColor Red
    exit 1
}

# 2. インストール先にコピー
if (Test-Path $InstallDir) {
    $r = Read-Host "$InstallDir は既に存在します。上書きしますか? (y/n)"
    if ($r -ne 'y') { exit 0 }
} else {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path (Join-Path $srcDir '*') -Destination $InstallDir -Recurse -Force

# 3. デスクトップにショートカット作成
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

$sc1 = $shell.CreateShortcut((Join-Path $desktop 'WorkTime Tracker.lnk'))
$sc1.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc1.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$InstallDir\client\WorkTimeTracker.ps1`""
$sc1.WorkingDirectory = "$InstallDir\client"
$sc1.IconLocation = "$env:WINDIR\System32\imageres.dll,109"
$sc1.Save()

$sc2 = $shell.CreateShortcut((Join-Path $desktop 'WorkTime Report.lnk'))
$sc2.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc2.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$InstallDir\reports\ReportViewer.ps1`""
$sc2.WorkingDirectory = "$InstallDir\reports"
$sc2.IconLocation = "$env:WINDIR\System32\imageres.dll,114"
$sc2.Save()

Write-Host "完了。デスクトップのショートカットから起動してください。" -ForegroundColor Green
Write-Host "  - WorkTime Tracker (実績入力)"
Write-Host "  - WorkTime Report  (集計ビューア)"
Write-Host ""
Write-Host "初回起動時に GitLab URL / Project ID / Project Access Token を入力してください。"
