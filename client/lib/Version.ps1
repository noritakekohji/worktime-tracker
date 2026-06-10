# Version.ps1 — worktime-tracker のバージョン情報 (Semantic Versioning)
#
# SemVer (MAJOR.MINOR.PATCH):
#   MAJOR: 既存データ/設定との互換性を壊す変更
#   MINOR: 後方互換のある機能追加
#   PATCH: 後方互換のあるバグ修正
#
# ここを 1 箇所変更すると、Tracker / WbsInput / ReportViewer / AdminDialog の
# タイトルバー表示が同時に変わる。
# 変更履歴は CHANGELOG.md を参照。

$Script:AppVersion       = '1.0.0'
$Script:AppName          = 'WorkTime Tracker'
$Script:AppVersionTag    = "v$Script:AppVersion"

function Get-AppVersion {
    return $Script:AppVersion
}

function Format-WindowTitle {
    param([string]$ScreenName = '')
    if ([string]::IsNullOrWhiteSpace($ScreenName)) {
        return "$Script:AppName  $Script:AppVersionTag"
    }
    return "$Script:AppName  -  $ScreenName  $Script:AppVersionTag"
}

# CHANGELOG.md の所在を解決 (Version.ps1 → client/lib/ → 1 階層上 = install root)
function Resolve-ChangelogPath {
    $here  = Split-Path $PSCommandPath -Parent
    $libUp = Split-Path $here  -Parent
    $root  = Split-Path $libUp -Parent
    $p = Join-Path $root 'CHANGELOG.md'
    if (Test-Path -LiteralPath $p) { return $p }
    # フォールバック (開発時の worktree などで階層が変わったケース)
    foreach ($up in @($libUp, (Split-Path $root -Parent))) {
        if ($up) {
            $cand = Join-Path $up 'CHANGELOG.md'
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
    }
    return $null
}

# CHANGELOG.md をスクロール可能な読み取り専用ダイアログで表示
function Show-ChangelogDialog {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    $path = Resolve-ChangelogPath
    if (-not $path) {
        [System.Windows.MessageBox]::Show(
            "CHANGELOG.md が見つかりませんでした。",
            "$Script:AppName  $Script:AppVersionTag", 'OK', 'Information') | Out-Null
        return
    }
    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($true))
    } catch {
        [System.Windows.MessageBox]::Show(
            "CHANGELOG.md の読込に失敗しました:`n$($_.Exception.Message)",
            $Script:AppName, 'OK', 'Error') | Out-Null
        return
    }

    $win = New-Object System.Windows.Window
    $win.Title  = "📋 CHANGELOG  -  $Script:AppName  $Script:AppVersionTag"
    $win.Width  = 760
    $win.Height = 600
    $win.WindowStartupLocation = 'CenterScreen'

    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.Margin = '10'

    # ヘッダ
    $headerText = New-Object System.Windows.Controls.TextBlock
    $headerText.Text = "📋 変更履歴  ($Script:AppVersionTag)"
    $headerText.FontSize = 16; $headerText.FontWeight = 'Bold'
    $headerText.Margin = '0,0,0,10'
    $headerText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
    [System.Windows.Controls.DockPanel]::SetDock($headerText, 'Top')
    [void]$dp.Children.Add($headerText)

    # フッタ ([閉じる] ボタン)
    $footer = New-Object System.Windows.Controls.StackPanel
    $footer.Orientation = 'Horizontal'
    $footer.HorizontalAlignment = 'Right'
    [System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')
    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = '閉じる'
    $closeBtn.MinWidth = 80; $closeBtn.Margin = '0,8,0,0'; $closeBtn.Padding = '12,4'
    $closeBtn.Add_Click({ $win.Close() })
    [void]$footer.Children.Add($closeBtn)
    [void]$dp.Children.Add($footer)

    # 本文 (読み取り専用 TextBox, 等幅 + Markdown 生表示)
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text         = $text
    $box.IsReadOnly   = $true
    $box.AcceptsReturn = $true
    $box.TextWrapping = 'NoWrap'
    $box.VerticalScrollBarVisibility   = 'Auto'
    $box.HorizontalScrollBarVisibility = 'Auto'
    $box.FontFamily   = New-Object System.Windows.Media.FontFamily 'Consolas, Yu Gothic UI, MS Gothic'
    $box.FontSize     = 12
    $box.Background   = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#f8fafc')
    [void]$dp.Children.Add($box)

    $win.Content = $dp
    [void]$win.ShowDialog()
}
