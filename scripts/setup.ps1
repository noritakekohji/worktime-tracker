# setup.ps1 — 作業者 PC への初回セットアップ (社内 PC, 追加インストールなし)
#
# 動作要件: Windows 10/11 + PowerShell 5.1 (どちらも標準搭載)
# 必要なのは zip 展開先のフォルダのみ。追加モジュール・git CLI は不要。

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\worktime-tracker",
    [switch]$Force
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
    if (-not $Force) {
        $r = Read-Host "$InstallDir は既に存在します。上書きしますか? (y/n)"
        if ($r -ne 'y') { exit 0 }
    }
} else {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path (Join-Path $srcDir '*') -Destination $InstallDir -Recurse -Force

# .cmd は CRLF + Shift-JIS 必須 (cmd.exe が LF/UTF-8 BOM を誤解釈する)
Get-ChildItem -Path $InstallDir -Recurse -Filter *.cmd | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    # 既存エンコーディング判定
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        $text = [System.Text.UTF8Encoding]::new($true).GetString($b)
    } elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2)
    } else {
        # BOM 無し: UTF-8 / SJIS どちらかを推定。日本語含むなら UTF-8 として扱う。
        try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($b) }
        catch { $text = [System.Text.Encoding]::GetEncoding('shift_jis').GetString($b) }
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $crlf = $text -replace "`r?`n","`r`n"
    [System.IO.File]::WriteAllText($_.FullName, $crlf, [System.Text.Encoding]::GetEncoding('shift_jis'))
}

# 3. デスクトップにショートカット作成
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

# powershell.exe を直接起動する (launch.cmd 経由だと黒いコンソールが残って邪魔になる)。
# Hidden を powershell 側とショートカット側の両方に指定し、WPF ウィンドウだけが出るようにする。
# エラー内容は MessageBox と %APPDATA%\worktime-tracker\last_error.log で確認できる。
# コンソール付きで起動して確認したい場合は client\launch.cmd / client\WbsInput.cmd を直接実行する。
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$sc1 = $shell.CreateShortcut((Join-Path $desktop 'WorkTime Tracker.lnk'))
$sc1.TargetPath = $psExe
$sc1.Arguments = '-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{0}\client\WorkTimeTracker.ps1"' -f $InstallDir
$sc1.WorkingDirectory = "$InstallDir\client"
$sc1.IconLocation = "$env:WINDIR\System32\imageres.dll,109"
$sc1.WindowStyle = 7   # minimized
$sc1.Save()

$sc2 = $shell.CreateShortcut((Join-Path $desktop 'WorkTime Report.lnk'))
$sc2.TargetPath = $psExe
$sc2.Arguments = '-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "{0}\reports\ReportViewer.ps1"' -f $InstallDir
$sc2.WorkingDirectory = "$InstallDir\reports"
$sc2.IconLocation = "$env:WINDIR\System32\imageres.dll,114"
$sc2.WindowStyle = 7
$sc2.Save()

# 旧名の WBS ショートカットがあれば削除 (WBS 画面は Tracker / Report から相互起動)
foreach ($oldLnkName in 'WorkTime WBS.lnk', 'WorkTime WBS入力.lnk') {
    $oldLnk = Join-Path $desktop $oldLnkName
    if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force -ErrorAction SilentlyContinue }
}

Write-Host "完了。デスクトップのショートカットから起動してください。" -ForegroundColor Green
Write-Host "  - WorkTime Tracker  (実績入力)"
Write-Host "  - WorkTime Report   (集計ビューア)"
Write-Host ""
Write-Host "初回起動時に GitLab URL / Project ID / Project Access Token を入力してください。"
