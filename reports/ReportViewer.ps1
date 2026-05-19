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
              'DetailGrid','MemberSummaryGrid','ProjectSummaryGrid','CategorySummaryGrid','SummaryText','StatusText','AnalysisPanel',
              'ChartAxisCombo','ChartTypeCombo','ChartSortCombo','ChartTopCombo','ChartRedrawBtn','ChartCanvas') {
    $u[$n] = $win.FindName($n)
}

# データソース表示 (フッタ)
$u.StatusText.Text = "保存先: {0}  |  local={1}{2}" -f $Script:Config.mode, $Script:Config.local_store, $(switch ($Script:Config.mode) {
    'gitlab' { " | remote=$($Script:Config.gitlab_url)/$($Script:Config.project_id) @ $($Script:Config.branch)" }
    default  { '' }
})

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
    [pscustomobject]@{ code = [string]$_.unit_code; name = [string]$_.project_name }
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
    $Script:ChartRows = $rows
    Build-Chart
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

function _GroupKey {
    param($Row, [string]$Axis)
    $dt = [datetime]::MinValue
    switch ($Axis) {
        'プロジェクト'    { return [string]$Row.project_code }
        '工程'            { return [string]$Row.process_code }
        'タスクグループ'  { return [string]$Row.task_group_code }
        'タスク'          { return [string]$Row.task_code }
        'カテゴリ'        { return [string]$Row.category }
        'メンバー'        { return [string]$Row.member_id }
        '日付'            {
            if ([datetime]::TryParse([string]$Row.date, [ref]$dt)) { return $dt.ToString('yyyy-MM-dd') }
            return ''
        }
        '曜日'            {
            $dow = @('日','月','火','水','木','金','土')
            if ([datetime]::TryParse([string]$Row.date, [ref]$dt)) { return $dow[[int]$dt.DayOfWeek] }
            return ''
        }
    }
    return ''
}

function Build-Chart {
    $canvas = $u.ChartCanvas
    if (-not $canvas) { return }
    $canvas.Children.Clear()

    $rows = @($Script:ChartRows)
    if ($rows.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '(対象データなし)'
        $tb.Foreground = [System.Windows.Media.Brushes]::SlateGray
        $tb.FontSize = 14
        [System.Windows.Controls.Canvas]::SetLeft($tb, 20)
        [System.Windows.Controls.Canvas]::SetTop($tb, 20)
        [void]$canvas.Children.Add($tb)
        return
    }

    $axis = $u.ChartAxisCombo.SelectedItem.Content
    $type = $u.ChartTypeCombo.SelectedItem.Content
    $sort = $u.ChartSortCombo.SelectedItem.Content
    $topC = $u.ChartTopCombo.SelectedItem.Content

    $groups = @{}
    foreach ($r in $rows) {
        $k = _GroupKey -Row $r -Axis $axis
        if ([string]::IsNullOrEmpty($k)) { continue }
        if (-not $groups.ContainsKey($k)) { $groups[$k] = 0.0 }
        $groups[$k] += [double]$r.hours
    }
    if ($groups.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "(集計軸『$axis』の値がありません)"
        $tb.Foreground = [System.Windows.Media.Brushes]::SlateGray
        $tb.FontSize = 14
        [System.Windows.Controls.Canvas]::SetLeft($tb, 20)
        [System.Windows.Controls.Canvas]::SetTop($tb, 20)
        [void]$canvas.Children.Add($tb)
        return
    }

    $items = $groups.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ key = [string]$_.Key; value = [double]$_.Value }
    }
    switch ($sort) {
        '工数 降順' { $items = $items | Sort-Object value -Descending }
        '工数 昇順' { $items = $items | Sort-Object value }
        '名前順'    { $items = $items | Sort-Object key }
    }
    $items = @($items)
    if ($topC -ne '全件') {
        $n = [int]$topC
        if ($items.Count -gt $n) { $items = $items[0..($n-1)] }
    }

    # 描画パラメータ
    $maxVal  = ($items | Measure-Object -Property value -Maximum).Maximum
    if ($maxVal -le 0) { $maxVal = 1 }
    $totalVal = ($items | Measure-Object -Property value -Sum).Sum

    $title = "{0} ({1}) — {2} 件 / 合計 {3:N1} h" -f $axis, $type, $items.Count, $totalVal

    if ($type -eq '横棒') {
        # 横棒: 各行 = ラベル(120px) + バー + 値
        $rowH = 26; $gap = 6; $labelW = 140; $valueW = 90
        $chartH = 50 + $items.Count * ($rowH + $gap)
        $chartW = 900
        $canvas.Height = $chartH
        $canvas.Width  = $chartW
        $barAreaW = $chartW - $labelW - $valueW - 60

        # タイトル
        $tt = New-Object System.Windows.Controls.TextBlock
        $tt.Text = $title; $tt.FontSize = 14; $tt.FontWeight = 'Bold'
        $tt.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
        [System.Windows.Controls.Canvas]::SetLeft($tt, 20)
        [System.Windows.Controls.Canvas]::SetTop($tt,  10)
        [void]$canvas.Children.Add($tt)

        $y = 40
        $i = 0
        foreach ($it in $items) {
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $it.key
            $lbl.Width = $labelW
            $lbl.TextTrimming = 'CharacterEllipsis'
            $lbl.Foreground = [System.Windows.Media.Brushes]::Black
            $lbl.FontSize = 12
            $lbl.VerticalAlignment = 'Center'
            [System.Windows.Controls.Canvas]::SetLeft($lbl, 20)
            [System.Windows.Controls.Canvas]::SetTop($lbl,  $y + 4)
            [void]$canvas.Children.Add($lbl)

            $bar = New-Object System.Windows.Shapes.Rectangle
            $w = [Math]::Max(2, ($it.value / $maxVal) * $barAreaW)
            $bar.Width  = $w
            $bar.Height = $rowH - 6
            $hue = ($i * 35) % 360
            $color = _Hsl2Rgb $hue 0.55 0.55
            $bar.Fill = (New-Object System.Windows.Media.SolidColorBrush $color)
            $bar.RadiusX = 4; $bar.RadiusY = 4
            [System.Windows.Controls.Canvas]::SetLeft($bar, $labelW + 30)
            [System.Windows.Controls.Canvas]::SetTop($bar,  $y + 3)
            [void]$canvas.Children.Add($bar)

            $val = New-Object System.Windows.Controls.TextBlock
            $pct = if ($totalVal -gt 0) { ($it.value / $totalVal) * 100 } else { 0 }
            $val.Text = "{0:N1} h ({1:N1}%)" -f $it.value, $pct
            $val.Foreground = [System.Windows.Media.Brushes]::Black
            $val.FontSize = 12
            [System.Windows.Controls.Canvas]::SetLeft($val, $labelW + 30 + $w + 8)
            [System.Windows.Controls.Canvas]::SetTop($val,  $y + 6)
            [void]$canvas.Children.Add($val)

            $y += $rowH + $gap
            $i++
        }
    } else {
        # 縦棒
        $barW = 50; $gap = 16
        $chartW = 60 + $items.Count * ($barW + $gap) + 40
        $chartH = 520
        $canvas.Width = $chartW
        $canvas.Height = $chartH
        $baseY = $chartH - 90
        $maxBarH = $chartH - 130

        $tt = New-Object System.Windows.Controls.TextBlock
        $tt.Text = $title; $tt.FontSize = 14; $tt.FontWeight = 'Bold'
        $tt.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
        [System.Windows.Controls.Canvas]::SetLeft($tt, 20)
        [System.Windows.Controls.Canvas]::SetTop($tt,  10)
        [void]$canvas.Children.Add($tt)

        # 軸線
        $axisLine = New-Object System.Windows.Shapes.Line
        $axisLine.X1 = 40; $axisLine.Y1 = $baseY
        $axisLine.X2 = $chartW - 20; $axisLine.Y2 = $baseY
        $axisLine.Stroke = [System.Windows.Media.Brushes]::LightGray
        $axisLine.StrokeThickness = 1
        [void]$canvas.Children.Add($axisLine)

        $x = 60; $i = 0
        foreach ($it in $items) {
            $h = ($it.value / $maxVal) * $maxBarH
            if ($h -lt 2) { $h = 2 }
            $bar = New-Object System.Windows.Shapes.Rectangle
            $bar.Width = $barW; $bar.Height = $h
            $hue = ($i * 35) % 360
            $color = _Hsl2Rgb $hue 0.55 0.55
            $bar.Fill = (New-Object System.Windows.Media.SolidColorBrush $color)
            $bar.RadiusX = 4; $bar.RadiusY = 4
            [System.Windows.Controls.Canvas]::SetLeft($bar, $x)
            [System.Windows.Controls.Canvas]::SetTop($bar, $baseY - $h)
            [void]$canvas.Children.Add($bar)

            $val = New-Object System.Windows.Controls.TextBlock
            $val.Text = "{0:N1}" -f $it.value
            $val.FontSize = 11
            $val.Foreground = [System.Windows.Media.Brushes]::Black
            [System.Windows.Controls.Canvas]::SetLeft($val, $x)
            [System.Windows.Controls.Canvas]::SetTop($val,  $baseY - $h - 18)
            [void]$canvas.Children.Add($val)

            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $it.key
            $lbl.Width = $barW + 8
            $lbl.TextTrimming = 'CharacterEllipsis'
            $lbl.FontSize = 11
            $lbl.Foreground = [System.Windows.Media.Brushes]::Black
            $lbl.TextAlignment = 'Center'
            [System.Windows.Controls.Canvas]::SetLeft($lbl, $x - 4)
            [System.Windows.Controls.Canvas]::SetTop($lbl,  $baseY + 6)
            [void]$canvas.Children.Add($lbl)

            $x += $barW + $gap
            $i++
        }
    }
}

function _Hsl2Rgb {
    param([double]$H,[double]$S,[double]$L)
    $c = (1 - [Math]::Abs(2*$L - 1)) * $S
    $x = $c * (1 - [Math]::Abs( (($H/60) % 2) - 1 ))
    $m = $L - $c/2
    $r = 0.0; $g = 0.0; $b = 0.0
    if     ($H -lt  60) { $r = $c; $g = $x; $b = 0  }
    elseif ($H -lt 120) { $r = $x; $g = $c; $b = 0  }
    elseif ($H -lt 180) { $r = 0;  $g = $c; $b = $x }
    elseif ($H -lt 240) { $r = 0;  $g = $x; $b = $c }
    elseif ($H -lt 300) { $r = $x; $g = 0;  $b = $c }
    else                { $r = $c; $g = 0;  $b = $x }
    return [System.Windows.Media.Color]::FromRgb(
        [byte]([Math]::Round(($r+$m)*255)),
        [byte]([Math]::Round(($g+$m)*255)),
        [byte]([Math]::Round(($b+$m)*255)))
}

$u.ChartRedrawBtn.Add_Click({ Build-Chart })
$u.ChartAxisCombo.Add_SelectionChanged({ Build-Chart })
$u.ChartTypeCombo.Add_SelectionChanged({ Build-Chart })
$u.ChartSortCombo.Add_SelectionChanged({ Build-Chart })
$u.ChartTopCombo.Add_SelectionChanged({ Build-Chart })

function Reload-Masters {
    try {
        $Script:Members  = @(Get-MasterMembers  -Source $Script:Source)
        $Script:Projects = @(Get-MasterProjects -Source $Script:Source)
        # フィルタ コンボを再構築
        $newMembers = @([pscustomobject]@{ id = ''; display = '(全員)' }) + @($Script:Members | ForEach-Object {
            [pscustomobject]@{ id = [string]$_.id; display = "$($_.id) - $($_.name)" }
        })
        $selMid = $u.MemberFilter.SelectedValue
        $u.MemberFilter.ItemsSource = $newMembers
        if ($selMid) { $u.MemberFilter.SelectedValue = $selMid } else { $u.MemberFilter.SelectedIndex = 0 }
        $newProjs = @([pscustomobject]@{ code = ''; name = '(全プロジェクト)' }) + @($Script:Projects | ForEach-Object {
            [pscustomobject]@{ code = [string]$_.unit_code; name = [string]$_.project_name }
        })
        $selPid = $u.ProjectFilter.SelectedValue
        $u.ProjectFilter.ItemsSource = $newProjs
        if ($selPid) { $u.ProjectFilter.SelectedValue = $selPid } else { $u.ProjectFilter.SelectedIndex = 0 }
    } catch {
        $u.SummaryText.Text = "マスタ再読込失敗: $_"
    }
}

$u.ReloadBtn.Add_Click({ Reload-Masters; Reload-Entries })
$u.ApplyBtn.Add_Click({ Apply-Filters })
$u.MemberFilter.Add_SelectionChanged({ if ($Script:AllEntries) { Apply-Filters } })
$u.ProjectFilter.Add_SelectionChanged({ if ($Script:AllEntries) { Apply-Filters } })

function Show-ColumnPicker {
    param([string[]]$AllColumns, [string[]]$Selected)
    $w = New-Object System.Windows.Window
    $w.Title = '出力カラムを選択'
    $w.Width = 360; $w.Height = 520
    $w.WindowStartupLocation = 'CenterScreen'
    $w.Background = [System.Windows.Media.Brushes]::White
    $w.FontFamily = 'Meiryo UI'
    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.Margin = '14'
    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text = '出力に含めるカラムを選択 (順序はそのまま)'
    $hdr.FontWeight = 'Bold'
    $hdr.FontSize = 14
    $hdr.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
    $hdr.Margin = '0,0,0,10'
    [System.Windows.Controls.DockPanel]::SetDock($hdr,'Top')
    [void]$dp.Children.Add($hdr)

    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    $btns.HorizontalAlignment = 'Right'
    $btns.Margin = '0,10,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($btns,'Bottom')
    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'キャンセル'; $cancelBtn.Padding = '14,6'; $cancelBtn.Margin = '4,0'
    $okBtn = New-Object System.Windows.Controls.Button
    $okBtn.Content = '出力'; $okBtn.Padding = '14,6'; $okBtn.Margin = '4,0'
    $okBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0284c7')
    $okBtn.Foreground = [System.Windows.Media.Brushes]::White
    $okBtn.FontWeight = 'Bold'
    $okBtn.MinWidth = 80
    [void]$btns.Children.Add($cancelBtn)
    [void]$btns.Children.Add($okBtn)
    [void]$dp.Children.Add($btns)

    $quick = New-Object System.Windows.Controls.StackPanel
    $quick.Orientation = 'Horizontal'
    $quick.Margin = '0,0,0,8'
    [System.Windows.Controls.DockPanel]::SetDock($quick,'Top')
    $selAll = New-Object System.Windows.Controls.Button
    $selAll.Content = '全選択'; $selAll.Padding = '10,4'; $selAll.Margin = '0,0,4,0'
    $selNone = New-Object System.Windows.Controls.Button
    $selNone.Content = '全解除'; $selNone.Padding = '10,4'
    [void]$quick.Children.Add($selAll)
    [void]$quick.Children.Add($selNone)
    [void]$dp.Children.Add($quick)

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sv.Content = $sp
    [void]$dp.Children.Add($sv)

    $checks = @{}
    foreach ($col in $AllColumns) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $col
        $cb.Margin = '4'
        $cb.IsChecked = ($Selected -contains $col)
        $checks[$col] = $cb
        [void]$sp.Children.Add($cb)
    }
    $selAll.Add_Click({ foreach ($k in $checks.Keys) { $checks[$k].IsChecked = $true } })
    $selNone.Add_Click({ foreach ($k in $checks.Keys) { $checks[$k].IsChecked = $false } })

    $script:Picked = $null
    $okBtn.Add_Click({
        $script:Picked = @($AllColumns | Where-Object { $checks[$_].IsChecked })
        $w.Close()
    })
    $cancelBtn.Add_Click({ $script:Picked = $null; $w.Close() })

    $w.Content = $dp
    [void]$w.ShowDialog()
    return $script:Picked
}

$Script:LastExportCols = $null

$u.ExportBtn.Add_Click({
    $rows = $u.DetailGrid.ItemsSource
    if (-not $rows -or @($rows).Count -eq 0) {
        [System.Windows.MessageBox]::Show('エクスポート対象のデータがありません。', 'CSV', 'OK', 'Information') | Out-Null
        return
    }
    $allCols = @('date','member_id','project_code','process_code','task_group_code','task_code','category','hours','comment')
    $preset  = if ($Script:LastExportCols) { $Script:LastExportCols } else { $allCols }
    $picked  = Show-ColumnPicker -AllColumns $allCols -Selected $preset
    if (-not $picked -or $picked.Count -eq 0) { return }
    $Script:LastExportCols = $picked

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'worktime_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date)
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $rows | Select-Object -Property $picked | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
    [System.Windows.MessageBox]::Show("エクスポート完了 ($($picked.Count) 列):`n$($dlg.FileName)", 'CSV', 'OK', 'Information') | Out-Null
})

Reload-Entries

[void]$win.ShowDialog()
