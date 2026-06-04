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
