# ReportViewer.ps1 — ローカル集計 GUI ビューア
#
# 設定済みの GitLab 接続 (またはローカルモード) からデータを取得し、
# 期間/メンバー/プロジェクトでフィルタ → 明細・集計表示・CSV エクスポート

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'client/lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')

$Script:Config = Load-Config
if (-not (Test-ConfigComplete -Config $Script:Config)) {
    [System.Windows.MessageBox]::Show('クライアントの初回設定が完了していません。WorkTimeTracker.ps1 を先に起動して設定してください。', 'ReportViewer', 'OK', 'Warning') | Out-Null
    return
}
$Script:Token = if ($Script:Config.mode -eq 'gitlab') { Get-GitLabToken } else { $null }
$Script:Source = New-DataSource -Config $Script:Config -Token $Script:Token

$Script:Members = @(Get-MasterMembers -Source $Script:Source)
$Script:Projects = @(Get-MasterProjects -Source $Script:Source)
$Script:AllEntries = @()

# ---- XAML ----
$xamlPath = Join-Path $PSScriptRoot 'ReportViewer.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$u = @{}
foreach ($n in 'FromDate','ToDate','MemberFilter','ProjectFilter','ApplyBtn','ReloadBtn','ExportBtn',
              'DetailGrid','MemberSummaryGrid','ProjectSummaryGrid','CategorySummaryGrid','SummaryText') {
    $u[$n] = $win.FindName($n)
}

# 既定期間: 当月
$today = [datetime]::Today
$u.FromDate.SelectedDate = (Get-Date -Year $today.Year -Month $today.Month -Day 1)
$u.ToDate.SelectedDate   = $today

# フィルタ コンボ
$memberItems = @([pscustomobject]@{ id = ''; display = '(全員)' }) + @($Script:Members | ForEach-Object {
    [pscustomobject]@{ id = $_.id; display = "$($_.id) - $($_.name)" }
})
$u.MemberFilter.ItemsSource = $memberItems
$u.MemberFilter.SelectedIndex = 0

$projItems = @([pscustomobject]@{ code = ''; name = '(全プロジェクト)' }) + @($Script:Projects | ForEach-Object {
    [pscustomobject]@{ code = $_.code; name = $_.name }
})
$u.ProjectFilter.ItemsSource = $projItems
$u.ProjectFilter.SelectedIndex = 0

function Reload-Entries {
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $u.SummaryText.Text = '読込中...'
        $Script:AllEntries = @(Load-AllEntries -Source $Script:Source)
        $u.SummaryText.Text = "全データ読込: $($Script:AllEntries.Count) 件"
        Apply-Filters
    } catch {
        $u.SummaryText.Text = "読込失敗: $_"
    } finally {
        $win.Cursor = $null
    }
}

function Apply-Filters {
    $from = $u.FromDate.SelectedDate
    $to   = $u.ToDate.SelectedDate
    $mid  = $u.MemberFilter.SelectedValue
    $pjc  = $u.ProjectFilter.SelectedValue

    $rows = $Script:AllEntries | Where-Object {
        $d = [datetime]::Parse($_.date)
        $ok = $true
        if ($from -and $d -lt $from) { $ok = $false }
        if ($to   -and $d -gt $to)   { $ok = $false }
        if ($mid  -and $_.member_id   -ne $mid)  { $ok = $false }
        if ($pjc  -and $_.project_code -ne $pjc) { $ok = $false }
        $ok
    }

    $u.DetailGrid.ItemsSource = @($rows)

    $total = 0.0
    foreach ($r in $rows) { $total += [double]$r.hours }
    $u.SummaryText.Text = "明細 $($rows.Count) 件 / 合計 {0:N1} h" -f $total

    # メンバー別
    $byMember = $rows | Group-Object member_id | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ member_id = $_.Name; entries = $_.Count; hours = [Math]::Round($sum, 2) }
    } | Sort-Object -Property hours -Descending
    $u.MemberSummaryGrid.ItemsSource = @($byMember)

    # プロジェクト別
    $byProject = $rows | Group-Object project_code | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ project_code = $_.Name; entries = $_.Count; hours = [Math]::Round($sum, 2) }
    } | Sort-Object -Property hours -Descending
    $u.ProjectSummaryGrid.ItemsSource = @($byProject)

    # カテゴリ別
    $byCat = $rows | Group-Object category | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ category = $_.Name; entries = $_.Count; hours = [Math]::Round($sum, 2) }
    } | Sort-Object -Property hours -Descending
    $u.CategorySummaryGrid.ItemsSource = @($byCat)
}

$u.ReloadBtn.Add_Click({ Reload-Entries })
$u.ApplyBtn.Add_Click({ Apply-Filters })
$u.MemberFilter.Add_SelectionChanged({ if ($Script:AllEntries) { Apply-Filters } })
$u.ProjectFilter.Add_SelectionChanged({ if ($Script:AllEntries) { Apply-Filters } })

$u.ExportBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'worktime_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date)
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $rows = $u.DetailGrid.ItemsSource
    if (-not $rows) { return }
    $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
    [System.Windows.MessageBox]::Show("エクスポート完了: $($dlg.FileName)", 'CSV', 'OK', 'Information') | Out-Null
})

Reload-Entries

[void]$win.ShowDialog()
