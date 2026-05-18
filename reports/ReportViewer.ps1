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
              'DetailGrid','MemberSummaryGrid','ProjectSummaryGrid','CategorySummaryGrid','SummaryText','StatusText','AnalysisPanel') {
    $u[$n] = $win.FindName($n)
}

# データソース表示 (フッタ)
$u.StatusText.Text = "保存先: {0}  |  {1}" -f $Script:Config.mode, $(if ($Script:Config.mode -eq 'gitlab') { "$($Script:Config.gitlab_url) / $($Script:Config.project_id) @ $($Script:Config.branch)" } else { $Script:Config.local_root })

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
        $u.SummaryText.Text = ("読込中... ({0})" -f $Script:Source.Mode)
        $Script:AllEntries = @(Load-AllEntries -Source $Script:Source)
        $u.SummaryText.Text = "全データ読込: $($Script:AllEntries.Count) 件 (source=$($Script:Source.Mode))"
        Apply-Filters
    } catch {
        $u.SummaryText.Text = "読込失敗: $_"
    } finally {
        $win.Cursor = $null
    }
}

function _Sc { param($v) if ($v -is [array]) { if ($v.Count -gt 0) { $v[0] } else { $null } } else { $v } }
function _Str { param($v) [string](_Sc $v) }
function _Num { param($v) $s = (_Sc $v); $d = 0.0; [void][double]::TryParse([string]$s, [ref]$d); $d }

function Apply-Filters {
    $from = $u.FromDate.SelectedDate
    $to   = $u.ToDate.SelectedDate
    $mid  = $u.MemberFilter.SelectedValue
    $pjc  = $u.ProjectFilter.SelectedValue

    $rows = $Script:AllEntries | ForEach-Object {
        $dStr = _Str $_.date
        if ([string]::IsNullOrWhiteSpace($dStr)) { return }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse($dStr, [ref]$d)) { return }
        $memberId    = _Str $_.member_id
        $projectCode = _Str $_.project_code

        $ok = $true
        if ($from -and $d -lt $from) { $ok = $false }
        if ($to   -and $d -gt $to)   { $ok = $false }
        if ($mid  -and $memberId    -ne $mid)  { $ok = $false }
        if ($pjc  -and $projectCode -ne $pjc) { $ok = $false }
        if (-not $ok) { return }

        [pscustomobject]@{
            date            = $dStr
            member_id       = $memberId
            project_code    = $projectCode
            process_code    = _Str $_.process_code
            task_group_code = _Str $_.task_group_code
            task_code       = _Str $_.task_code
            category        = _Str $_.category
            hours           = _Num $_.hours
            comment         = _Str $_.comment
        }
    }
    $rows = @($rows)

    $u.DetailGrid.ItemsSource = $rows

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

    Build-Analysis -Rows $rows
}

function _AnalysisRow {
    param([string]$Label,[string]$Value,[string]$Color = '#0c4a6e')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $sp.Margin = '0,2'
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label
    $l.Width = 220
    $l.Foreground = [System.Windows.Media.Brushes]::SlateGray
    $v = New-Object System.Windows.Controls.TextBlock
    $v.Text = $Value
    $v.FontWeight = 'Bold'
    $v.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
    $sp.Children.Add($l) | Out-Null
    $sp.Children.Add($v) | Out-Null
    return $sp
}

function _AnalysisCard {
    param([string]$Title, $Children, [string]$Accent='#0284c7')
    $b = New-Object System.Windows.Controls.Border
    $b.Background     = [System.Windows.Media.Brushes]::White
    $b.BorderBrush    = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#bae6fd')
    $b.BorderThickness = '1'
    $b.CornerRadius   = '10'
    $b.Padding        = '14'
    $b.Margin         = '0,0,0,12'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title
    $t.FontWeight = 'Bold'
    $t.FontSize = 14
    $t.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Accent)
    $t.Margin = '0,0,0,8'
    $sp.Children.Add($t) | Out-Null
    foreach ($c in @($Children)) {
        if ($null -ne $c) { $sp.Children.Add($c) | Out-Null }
    }
    $b.Child = $sp
    return $b
}

function Build-Analysis {
    param($Rows)
    $panel = $u.AnalysisPanel
    $panel.Children.Clear()

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = '(対象データなし)'
        $t.Foreground = [System.Windows.Media.Brushes]::SlateGray
        $t.Margin = '8'
        $panel.Children.Add($t) | Out-Null
        return
    }

    $rowsArr = @($Rows)
    $totalHours = ($rowsArr | Measure-Object -Property hours -Sum).Sum
    $days       = @($rowsArr | Group-Object date).Count
    $members    = @($rowsArr | Group-Object member_id).Count
    $projects   = @($rowsArr | Group-Object project_code).Count
    $avgPerDay      = if ($days -gt 0)    { $totalHours / $days }    else { 0 }
    $avgPerMember   = if ($members -gt 0) { $totalHours / $members } else { 0 }
    $maxDay = $rowsArr | Group-Object date    | ForEach-Object { [pscustomobject]@{ key=$_.Name; h=($_.Group | Measure-Object hours -Sum).Sum } } | Sort-Object h -Descending | Select-Object -First 1
    $minDay = $rowsArr | Group-Object date    | ForEach-Object { [pscustomobject]@{ key=$_.Name; h=($_.Group | Measure-Object hours -Sum).Sum } } | Sort-Object h          | Select-Object -First 1

    # サマリ
    $sum = @(
        (_AnalysisRow '対象件数:' ("$($rowsArr.Count) 件"))
        (_AnalysisRow '総工数:'   ("{0:N1} h" -f $totalHours))
        (_AnalysisRow '対象日数:' ("{0} 日"   -f $days))
        (_AnalysisRow '対象メンバー:' ("{0} 名" -f $members))
        (_AnalysisRow '対象プロジェクト:' ("{0} 件" -f $projects))
        (_AnalysisRow '1 日平均:'     ("{0:N2} h" -f $avgPerDay))
        (_AnalysisRow '1 メンバー平均:' ("{0:N2} h" -f $avgPerMember))
    )
    if ($maxDay) { $sum += (_AnalysisRow '最大稼働日:' ("{0}  ({1:N1} h)" -f $maxDay.key, $maxDay.h) '#0369a1') }
    if ($minDay -and $minDay.key -ne $maxDay.key) { $sum += (_AnalysisRow '最小稼働日:' ("{0}  ({1:N1} h)" -f $minDay.key, $minDay.h) '#0369a1') }
    $panel.Children.Add( (_AnalysisCard '📊 サマリ' $sum) ) | Out-Null

    # 曜日別
    $dow = @('日','月','火','水','木','金','土')
    $byDow = @{}; foreach ($d in $dow) { $byDow[$d] = 0.0 }
    foreach ($r in $rowsArr) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$r.date, [ref]$dt)) {
            $byDow[ $dow[[int]$dt.DayOfWeek] ] += [double]$r.hours
        }
    }
    $dowRows = foreach ($d in $dow) {
        $h = [double]$byDow[$d]
        $bar = if ($totalHours -gt 0) { ('█' * [int]([Math]::Round( ($h / $totalHours) * 30 ))) } else { '' }
        (_AnalysisRow ("{0}曜:" -f $d) ("{0,6:N1} h  {1}" -f $h, $bar))
    }
    $panel.Children.Add( (_AnalysisCard '📅 曜日別工数' $dowRows) ) | Out-Null

    # プロジェクト Top
    $topProj = $rowsArr | Group-Object project_code | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending | Select-Object -First 5
    $projRows = foreach ($p in $topProj) {
        $pct = if ($totalHours -gt 0) { ($p.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f $p.code) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $p.h, $pct, $p.cnt))
    }
    $panel.Children.Add( (_AnalysisCard '🏆 プロジェクト Top 5' $projRows) ) | Out-Null

    # カテゴリ Top
    $topCat = $rowsArr | Group-Object category | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending | Select-Object -First 5
    $catRows = foreach ($c in $topCat) {
        $pct = if ($totalHours -gt 0) { ($c.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f $c.code) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $c.h, $pct, $c.cnt))
    }
    $panel.Children.Add( (_AnalysisCard '🏷 カテゴリ Top 5' $catRows) ) | Out-Null

    # メンバー Top
    $topMem = $rowsArr | Group-Object member_id | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending | Select-Object -First 5
    $memRows = foreach ($m in $topMem) {
        $pct = if ($totalHours -gt 0) { ($m.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f $m.code) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $m.h, $pct, $m.cnt))
    }
    $panel.Children.Add( (_AnalysisCard '👥 メンバー Top 5' $memRows) ) | Out-Null

    # 工程別
    $topProc = $rowsArr | Group-Object process_code | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending
    $procRows = foreach ($p in $topProc) {
        $pct = if ($totalHours -gt 0) { ($p.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f $p.code) ("{0,6:N1} h  ({1:N1}%)" -f $p.h, $pct))
    }
    $panel.Children.Add( (_AnalysisCard '⚙ 工程別工数' $procRows) ) | Out-Null
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
