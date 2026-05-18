# setup.ps1 — 作業者 PC への初回セットアップ
# TODO:
#   1. git CLI が無ければ winget でインストール案内
#   2. %LOCALAPPDATA%\worktime-tracker に git clone
#   3. GitLab Project Access Token を入力させ Windows 資格情報マネージャに登録
#   4. デスクトップにショートカット作成
#   5. member_id を選択させ local.config.json に保存

param(
  [string]$RepoUrl = "https://gitlab.example.com/team/worktime-data.git",
  [string]$InstallDir = "$env:LOCALAPPDATA\worktime-tracker"
)

Write-Host "worktime-tracker setup (stub)" -ForegroundColor Cyan
Write-Host "Repo: $RepoUrl"
Write-Host "Install dir: $InstallDir"
Write-Host "TODO: 実装中"
