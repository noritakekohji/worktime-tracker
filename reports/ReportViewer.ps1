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
. (Join-Path $libDir 'AdminDialog.ps1')
. (Join-Path $libDir 'Bootstrap.ps1')

$ctx = Initialize-DataContext -AppName 'ReportViewer'
if (-not $ctx) { return }
$Script:Config        = $ctx.Config
$Script:Token         = $ctx.Token
$Script:Source        = $ctx.Source
$Script:Members       = $ctx.Members
$Script:Projects      = $ctx.Projects
$Script:CurrentMember = $ctx.CurrentMember
$Script:AllEntries    = @()

# ---- XAML ----
$xamlPath = Join-Path $PSScriptRoot 'ReportViewer.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$u = @{}
foreach ($n in 'FromDate','ToDate','MemberFilter','ProjectFilter','ApplyBtn','ReloadBtn','ExportBtn','AdminBtn',
              'DetailGrid','MemberSummaryGrid','ProjectSummaryGrid','CategorySummaryGrid','SummaryText','StatusText','AnalysisPanel',
              'ChartAxisCombo','ChartTypeCombo','ChartSortCombo','ChartTopCombo','ChartRedrawBtn','ChartCanvas',
              'HeatmapCanvas','HeatmapAxisCombo','HeatmapDescText','AnomalyGrid','DashboardPanel',
              'LoadOverThresholdTxt','LoadTargetTxt','LoadRefreshBtn','LoadWeeklyGrid','MissingEntriesGrid',
              'MemberProjectGrid','WorkTypeKpiPanel','WorkTypeByMemberGrid') {
    $u[$n] = $win.FindName($n)
}

# 管理者ロールなら管理者ボタン表示 (CurrentMember は Bootstrap で解決済み)
if ($Script:CurrentMember -and $Script:CurrentMember.role -eq 'admin' -and $u.AdminBtn) {
    $u.AdminBtn.Visibility = 'Visible'
    $u.AdminBtn.Add_Click({
        try {
            $mid  = [string]$Script:CurrentMember.id
            $mnm  = [string]$Script:CurrentMember.name
            $changed = Show-AdminDialog -Source $Script:Source -MemberId $mid -MemberName $mnm
            if ($changed) {
                # マスタ再読込 + データ再読込
                $Script:Members  = @(Get-MasterMembers  -Source $Script:Source)
                $Script:Projects = @(Get-MasterProjects -Source $Script:Source)
                Reload-Entries
            }
        } catch {
            [System.Windows.MessageBox]::Show("管理者画面エラー:`n$_", 'エラー', 'OK', 'Error') | Out-Null
        }
    })
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

    # 各 Build を隔離。1つが落ちても他は続行。ログにも残す。
    function _Trace {
        param([string]$Tag, [string]$Msg)
        try {
            $logDir = Join-Path $env:APPDATA 'worktime-tracker'
            if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $logDir 'report_trace.log') `
                -Value ("[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
        } catch { }
    }
    _Trace 'apply' ("rows=$($rows.Count)")
    foreach ($step in @(
        @{N='Analysis';  S={ Build-Analysis -Rows $rows; $Script:ChartRows = $rows; Build-Chart }},
        @{N='Heatmap';   S={ Build-Heatmap -Rows $rows }},
        @{N='Anomalies'; S={ Build-Anomalies -Rows $rows }},
        @{N='Dashboard'; S={ Build-Dashboard -Rows $rows }}
    )) {
        _Trace $step.N 'begin'
        try { & $step.S; _Trace $step.N 'ok' }
        catch {
            _Trace $step.N ("ERROR: $($_.Exception.Message) / $($_.ScriptStackTrace)")
            [System.Windows.MessageBox]::Show(
                "$($step.N) でエラー:`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)`n`n$($_.ScriptStackTrace)",
                "$($step.N) エラー", 'OK', 'Error') | Out-Null
        }
    }
}

# ---- C3: ダッシュボード (KPI カード + Top 一覧) ----
function Build-Dashboard {
    param($Rows)
    if (-not $u.DashboardPanel) { return }
    $u.DashboardPanel.Children.Clear()
    if (-not $Rows -or $Rows.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "(該当データなし)"
        $tb.Foreground = [System.Windows.Media.Brushes]::Gray
        [void]$u.DashboardPanel.Children.Add($tb)
        return
    }

    # KPI 計算
    $total = 0.0
    $members = @{}
    $projects = @{}
    $days = @{}
    foreach ($r in $Rows) {
        $h = [double]$r.hours
        $total += $h
        $m = [string]$r.member_id;    if ($m)   { if (-not $members.ContainsKey($m))  { $members[$m]  = 0.0 }; $members[$m]  += $h }
        $p = [string]$r.project_code; if ($p)   { if (-not $projects.ContainsKey($p)) { $projects[$p] = 0.0 }; $projects[$p] += $h }
        $d = [string]$r.date;         if ($d)   { if (-not $days.ContainsKey($d))     { $days[$d]     = 0.0 }; $days[$d]     += $h }
    }
    $memberCount  = $members.Count
    $projectCount = $projects.Count
    $dayCount     = $days.Count
    $avgPerDay    = if ($dayCount -gt 0)   { $total / $dayCount }   else { 0 }
    $avgPerMember = if ($memberCount -gt 0){ $total / $memberCount } else { 0 }

    # ヘッダ
    $h1 = New-Object System.Windows.Controls.TextBlock
    $h1.Text = "📊 ダッシュボード"
    $h1.FontSize = 18; $h1.FontWeight = 'Bold'
    $h1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
    $h1.Margin = '0,0,0,12'
    [void]$u.DashboardPanel.Children.Add($h1)

    # KPI カード (横並び)
    $kpiPanel = New-Object System.Windows.Controls.WrapPanel
    $kpiPanel.Orientation = 'Horizontal'
    $kpiPanel.Margin = '0,0,0,18'

    $makeCard = {
        param([string]$Title, [string]$Value, [string]$Color)
        $b = New-Object System.Windows.Controls.Border
        $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#f0f9ff')
        $b.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#bae6fd')
        $b.BorderThickness = '1'
        $b.CornerRadius = '8'
        $b.Padding = '14'
        $b.Margin = '0,0,10,10'
        $b.MinWidth = 160
        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = $Title; $t1.FontSize = 11
        $t1.Foreground = [System.Windows.Media.Brushes]::SlateGray
        $sp.Children.Add($t1) | Out-Null
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = $Value; $t2.FontSize = 22; $t2.FontWeight = 'Bold'
        $t2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
        $sp.Children.Add($t2) | Out-Null
        $b.Child = $sp
        return $b
    }

    [void]$kpiPanel.Children.Add((& $makeCard '総工数'         ("{0:N1} h" -f $total)        '#0369a1'))
    [void]$kpiPanel.Children.Add((& $makeCard 'メンバー数'     ("{0}" -f $memberCount)       '#059669'))
    [void]$kpiPanel.Children.Add((& $makeCard 'プロジェクト数' ("{0}" -f $projectCount)      '#d97706'))
    [void]$kpiPanel.Children.Add((& $makeCard '実績日数'       ("{0} 日" -f $dayCount)       '#7c3aed'))
    [void]$kpiPanel.Children.Add((& $makeCard '日平均'         ("{0:N1} h/日" -f $avgPerDay) '#0891b2'))
    [void]$kpiPanel.Children.Add((& $makeCard '一人平均'       ("{0:N1} h/人" -f $avgPerMember) '#db2777'))
    [void]$u.DashboardPanel.Children.Add($kpiPanel)

    # Top プロジェクト (上位 5)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "🔝 工数 Top プロジェクト"
    $tb.FontSize = 14; $tb.FontWeight = 'Bold'; $tb.Margin = '0,4,0,6'
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
    [void]$u.DashboardPanel.Children.Add($tb)

    $top = $projects.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    $maxV = 1.0
    foreach ($e in $top) { if ($e.Value -gt $maxV) { $maxV = $e.Value } }
    foreach ($e in $top) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,2'
        $cd1 = New-Object System.Windows.Controls.ColumnDefinition; $cd1.Width = '180'
        $cd2 = New-Object System.Windows.Controls.ColumnDefinition; $cd2.Width = '*'
        $cd3 = New-Object System.Windows.Controls.ColumnDefinition; $cd3.Width = '80'
        $row.ColumnDefinitions.Add($cd1); $row.ColumnDefinitions.Add($cd2); $row.ColumnDefinitions.Add($cd3)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = [string]$e.Key; $lbl.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $row.Children.Add($lbl) | Out-Null

        $bg = New-Object System.Windows.Controls.Border
        $bg.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#dbeafe')
        $bg.HorizontalAlignment = 'Left'
        $bg.Height = 16; $bg.CornerRadius = '4'
        $bg.Width = [Math]::Max(20, [double](($e.Value / $maxV) * 400))
        [System.Windows.Controls.Grid]::SetColumn($bg, 1)
        $row.Children.Add($bg) | Out-Null

        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = ("{0:N1} h" -f $e.Value); $val.VerticalAlignment = 'Center'
        $val.HorizontalAlignment = 'Right'
        $val.FontWeight = 'Bold'
        [System.Windows.Controls.Grid]::SetColumn($val, 2)
        $row.Children.Add($val) | Out-Null

        [void]$u.DashboardPanel.Children.Add($row)
    }

    # Top メンバー (上位 5)
    $tb2 = New-Object System.Windows.Controls.TextBlock
    $tb2.Text = "👥 工数 Top メンバー"
    $tb2.FontSize = 14; $tb2.FontWeight = 'Bold'; $tb2.Margin = '0,16,0,6'
    $tb2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0c4a6e')
    [void]$u.DashboardPanel.Children.Add($tb2)

    $topM = $members.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    $maxM = 1.0
    foreach ($e in $topM) { if ($e.Value -gt $maxM) { $maxM = $e.Value } }
    foreach ($e in $topM) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,2'
        $cd1 = New-Object System.Windows.Controls.ColumnDefinition; $cd1.Width = '180'
        $cd2 = New-Object System.Windows.Controls.ColumnDefinition; $cd2.Width = '*'
        $cd3 = New-Object System.Windows.Controls.ColumnDefinition; $cd3.Width = '80'
        $row.ColumnDefinitions.Add($cd1); $row.ColumnDefinitions.Add($cd2); $row.ColumnDefinitions.Add($cd3)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = [string]$e.Key; $lbl.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $row.Children.Add($lbl) | Out-Null

        $bg = New-Object System.Windows.Controls.Border
        $bg.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#dcfce7')
        $bg.HorizontalAlignment = 'Left'
        $bg.Height = 16; $bg.CornerRadius = '4'
        $bg.Width = [Math]::Max(20, [double](($e.Value / $maxM) * 400))
        [System.Windows.Controls.Grid]::SetColumn($bg, 1)
        $row.Children.Add($bg) | Out-Null

        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = ("{0:N1} h" -f $e.Value); $val.VerticalAlignment = 'Center'
        $val.HorizontalAlignment = 'Right'
        $val.FontWeight = 'Bold'
        [System.Windows.Controls.Grid]::SetColumn($val, 2)
        $row.Children.Add($val) | Out-Null

        [void]$u.DashboardPanel.Children.Add($row)
    }
}

# ---- C1: 日付 × プロジェクト ヒートマップ ----
function Build-Heatmap {
    param($Rows)
    $cv = $u.HeatmapCanvas
    if (-not $cv) { return }
    $cv.Children.Clear()
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    # 軸選択 (HeatmapAxisCombo) — 3 種類
    $axisSel = '日付 × プロジェクト'
    if ($u.HeatmapAxisCombo -and $u.HeatmapAxisCombo.SelectedItem) {
        $axisSel = [string]$u.HeatmapAxisCombo.SelectedItem.Content
    }

    # 行軸 / 列軸 のキー抽出
    switch ($axisSel) {
        '日付 × メンバー (個人別)' {
            $rowKey  = 'member_id'
            $colKey  = 'date'
            $rowLbl  = '👤 メンバー'
            $colLbl  = '日付'
            $rowDisp = { param($v) $m = $Script:Members | Where-Object { [string]$_.id -eq [string]$v } | Select-Object -First 1
                         if ($m) { "$($m.id)  $($m.name)" } else { [string]$v } }
            $colDisp = { param($v) $d = [datetime]::MinValue
                         if ([datetime]::TryParse([string]$v, [ref]$d)) { $d.ToString('M/d') } else { [string]$v } }
            $colW = 22; $useDateGap = $true
        }
        'メンバー × プロジェクト' {
            $rowKey  = 'member_id'
            $colKey  = 'project_code'
            $rowLbl  = '👤 メンバー'
            $colLbl  = '📁 プロジェクト'
            $rowDisp = { param($v) $m = $Script:Members | Where-Object { [string]$_.id -eq [string]$v } | Select-Object -First 1
                         if ($m) { "$($m.id)  $($m.name)" } else { [string]$v } }
            $colDisp = { param($v) $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq [string]$v } | Select-Object -First 1
                         if ($p) { [string]$p.unit_code } else { [string]$v } }
            $colW = 80; $useDateGap = $false
        }
        default {
            $rowKey  = 'project_code'
            $colKey  = 'date'
            $rowLbl  = '📁 プロジェクト'
            $colLbl  = '日付'
            $rowDisp = { param($v) [string]$v }
            $colDisp = { param($v) $d = [datetime]::MinValue
                         if ([datetime]::TryParse([string]$v, [ref]$d)) { $d.ToString('M/d') } else { [string]$v } }
            $colW = 22; $useDateGap = $true
        }
    }

    $rowVals = @($Rows | ForEach-Object { [string]$_.$rowKey } | Where-Object { $_ } | Sort-Object -Unique)
    $colVals = @($Rows | ForEach-Object { [string]$_.$colKey } | Where-Object { $_ } | Sort-Object -Unique)
    if ($rowVals.Count -eq 0 -or $colVals.Count -eq 0) { return }

    # 集計: row|col → hours
    $cell = @{}
    $maxH = 0.0
    foreach ($r in $Rows) {
        $rk = [string]$r.$rowKey; $ck = [string]$r.$colKey
        if (-not $rk -or -not $ck) { continue }
        $k = "$rk|$ck"
        if (-not $cell.ContainsKey($k)) { $cell[$k] = 0.0 }
        $cell[$k] += [double]$r.hours
        if ($cell[$k] -gt $maxH) { $maxH = $cell[$k] }
    }
    if ($maxH -le 0) { $maxH = 1.0 }

    $rowH = 22
    $lblW = 200
    $lblH = 60
    $cv.Width  = $lblW + ($colVals.Count * $colW) + 20
    $cv.Height = $lblH + ($rowVals.Count * $rowH) + 20

    # 列ヘッダ
    for ($i = 0; $i -lt $colVals.Count; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = & $colDisp $colVals[$i]
        $tb.FontSize = 9
        [System.Windows.Controls.Canvas]::SetLeft($tb, $lblW + ($i * $colW))
        [System.Windows.Controls.Canvas]::SetTop($tb, 30)
        $tb.Width = $colW; $tb.TextAlignment = 'Center'
        [void]$cv.Children.Add($tb)
    }

    # 行ラベル + セル
    for ($r = 0; $r -lt $rowVals.Count; $r++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = & $rowDisp $rowVals[$r]
        $tb.FontSize = 11
        $tb.FontWeight = 'SemiBold'
        [System.Windows.Controls.Canvas]::SetLeft($tb, 4)
        [System.Windows.Controls.Canvas]::SetTop($tb, $lblH + ($r * $rowH) + 4)
        $tb.Width = $lblW - 8
        [void]$cv.Children.Add($tb)

        for ($i = 0; $i -lt $colVals.Count; $i++) {
            $k = "$($rowVals[$r])|$($colVals[$i])"
            $h = 0.0
            if ($cell.ContainsKey($k)) { $h = $cell[$k] }
            if ($h -le 0) { continue }
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Width = $colW - 1; $rect.Height = $rowH - 1
            $intensity = [Math]::Min(1.0, $h / $maxH)
            $light = [int](240 - (200 * $intensity))
            $r1 = [int]($light * 0.6); $g1 = [int]$light; $b1 = [int]($light * 0.8)
            $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r1, $g1, $b1))
            $rect.Fill = $bg
            $rect.ToolTip = ("{0}  {1}  {2:N1}h" -f (& $rowDisp $rowVals[$r]), (& $colDisp $colVals[$i]), $h)
            [System.Windows.Controls.Canvas]::SetLeft($rect, $lblW + ($i * $colW))
            [System.Windows.Controls.Canvas]::SetTop($rect, $lblH + ($r * $rowH))
            [void]$cv.Children.Add($rect)
        }
    }
}

# ---- C4: 異常検知 (過剰入力 / 高負荷 / 入力ゼロ日) ----
function Build-Anomalies {
    param($Rows)
    if (-not $u.AnomalyGrid) { return }
    $items = New-Object 'System.Collections.Generic.List[object]'

    # 1) 日次 12h 超 = 過剰入力候補
    $byMemberDay = $Rows | Group-Object member_id, date
    foreach ($g in $byMemberDay) {
        $sum = 0.0; foreach ($r in $g.Group) { $sum += [double]$r.hours }
        if ($sum -gt 12.0) {
            $items.Add([pscustomobject]@{
                kind    = '⚠ 過剰入力'
                target  = $g.Name
                hours   = [Math]::Round($sum, 1)
                message = ("1日に {0:N1} h は通常を超える可能性があります" -f $sum)
            })
        }
    }

    # 2) プロジェクト別合計 > 200h
    $byProj = $Rows | Group-Object project_code
    foreach ($g in $byProj) {
        if ([string]::IsNullOrWhiteSpace($g.Name)) { continue }
        $sum = 0.0; foreach ($r in $g.Group) { $sum += [double]$r.hours }
        if ($sum -gt 200.0) {
            $items.Add([pscustomobject]@{
                kind    = '🔥 高負荷'
                target  = $g.Name
                hours   = [Math]::Round($sum, 1)
                message = ("プロジェクト合計 {0:N1} h: スコープ見直しを検討" -f $sum)
            })
        }
    }

    # 3) 平日に実績ゼロ (1人) — 期間内で「平日 かつ そのメンバーの実績合計 0h」の日
    $byMember = $Rows | Group-Object member_id
    $from = $u.FromDate.SelectedDate
    $to   = $u.ToDate.SelectedDate
    if ($from -and $to) {
        foreach ($mg in $byMember) {
            $memberDates = @($mg.Group | ForEach-Object { [string]$_.date } | Sort-Object -Unique)
            $missing = 0
            for ($d = $from; $d -le $to; $d = $d.AddDays(1)) {
                if ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday') { continue }
                $ds = $d.ToString('yyyy-MM-dd')
                if ($memberDates -notcontains $ds) { $missing++ }
            }
            if ($missing -ge 3) {
                $items.Add([pscustomobject]@{
                    kind    = '📭 入力漏れ候補'
                    target  = $mg.Name
                    hours   = 0
                    message = ("平日 {0} 日分の実績入力が見当たりません" -f $missing)
                })
            }
        }
    }

    # PS 5.1: List[object] of PSCustomObject に @(...) すると ArgumentException が出るため ToArray()
    $u.AnomalyGrid.ItemsSource = $items.ToArray()
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

# 必ず書ける場所に診断ログを出す (Desktop に固定)
$Script:DiagLogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'report_trace.log'
function _Diag {
    param([string]$Msg)
    try {
        Add-Content -LiteralPath $Script:DiagLogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) -Encoding UTF8
    } catch { }
}
_Diag "===== ReportViewer start ====="

function _SafeApplyFilters {
    _Diag "_SafeApplyFilters called"
    try { Apply-Filters; _Diag "_SafeApplyFilters done" }
    catch {
        _Diag "_SafeApplyFilters CAUGHT: $($_.Exception.Message) / $($_.ScriptStackTrace)"
        $detail = "$($_.Exception.Message)`n`n--- 位置 ---`n$($_.InvocationInfo.PositionMessage)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
        [System.Windows.MessageBox]::Show($detail, 'フィルタ適用エラー', 'OK', 'Error') | Out-Null
    }
}

$u.ReloadBtn.Add_Click({ _Diag "ReloadBtn click"; Reload-Masters; Reload-Entries })
$u.ApplyBtn.Add_Click({ _Diag "ApplyBtn click"; _SafeApplyFilters })
$u.MemberFilter.Add_SelectionChanged({
    $val = if ($Script:AllEntries) { "entries=$($Script:AllEntries.Count)" } else { "no entries" }
    _Diag "MemberFilter changed sel=$($u.MemberFilter.SelectedValue) $val"
    if ($Script:AllEntries) { _SafeApplyFilters }
})
$u.ProjectFilter.Add_SelectionChanged({
    $val = if ($Script:AllEntries) { "entries=$($Script:AllEntries.Count)" } else { "no entries" }
    _Diag "ProjectFilter changed sel=$($u.ProjectFilter.SelectedValue) $val"
    if ($Script:AllEntries) { _SafeApplyFilters }
})

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

# ===== チームマネージャ向け 拡張集計 =====

# プロジェクトコード → 業務種別 (案件対応 / 維持運用 / その他) 解決ヘルパ
function _ProjectWorkType {
    param([string]$ProjCode)
    $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq $ProjCode } | Select-Object -First 1
    if ($p -and $p.work_type) { return [string]$p.work_type }
    return 'その他'
}

# 日付文字列の月曜日を取得 (ISO 週始まり = 月曜)
function _MondayOf {
    param([datetime]$D)
    $diff = [int]$D.DayOfWeek - [int][System.DayOfWeek]::Monday
    if ($diff -lt 0) { $diff += 7 }
    return $D.Date.AddDays(-$diff)
}

# メンバー名解決 (members.json + entries の member_id) 統合リスト
function _ResolveMember {
    param([string]$Id)
    $m = $Script:Members | Where-Object { [string]$_.id -eq $Id -and $_.active } | Select-Object -First 1
    if ($m) { return "$($m.id)  $($m.name)" }
    return $Id
}

# ---- メンバー負荷バランス ----
function Build-MemberLoad {
    param($Rows)
    if (-not $u.LoadWeeklyGrid -or -not $u.MissingEntriesGrid) { return }
    $u.LoadWeeklyGrid.Columns.Clear()
    $u.LoadWeeklyGrid.ItemsSource = $null
    $u.MissingEntriesGrid.ItemsSource = $null
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    # しきい値
    $over = 45.0
    [void][double]::TryParse([string]$u.LoadOverThresholdTxt.Text, [ref]$over)
    $target = 40.0
    [void][double]::TryParse([string]$u.LoadTargetTxt.Text, [ref]$target)

    # week start (月曜) ごとのキー: yyyy-MM-dd (月曜の日付)
    $byMemberWeek = @{}  # memberId -> { weekKey -> hours }
    $weekKeys = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($r in $Rows) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$r.date, [ref]$d)) { continue }
        $wk = (_MondayOf $d).ToString('yyyy-MM-dd')
        $mid = [string]$r.member_id
        if (-not $mid) { continue }
        if (-not $byMemberWeek.ContainsKey($mid)) { $byMemberWeek[$mid] = @{} }
        if (-not $byMemberWeek[$mid].ContainsKey($wk)) { $byMemberWeek[$mid][$wk] = 0.0 }
        $byMemberWeek[$mid][$wk] += [double]$r.hours
        [void]$weekKeys.Add($wk)
    }

    $weekArr = @($weekKeys)
    # 動的列: メンバー + 各週 + 合計 + 平均
    $weeklyRows = New-Object System.Collections.Generic.List[object]
    foreach ($mid in ($byMemberWeek.Keys | Sort-Object)) {
        $row = [ordered]@{ 'メンバー' = (_ResolveMember $mid) }
        $tot = 0.0; $cnt = 0; $overCnt = 0
        foreach ($wk in $weekArr) {
            $h = if ($byMemberWeek[$mid].ContainsKey($wk)) { [double]$byMemberWeek[$mid][$wk] } else { 0.0 }
            $marker = ''
            if ($h -gt $over)   { $marker = '🔴 ' }
            elseif ($h -gt $target) { $marker = '🟡 ' }
            $col = ([datetime]::Parse($wk)).ToString('M/d~')
            $row[$col] = if ($h -gt 0) { "{0}{1:N1}" -f $marker, $h } else { '' }
            $tot += $h
            if ($h -gt 0) { $cnt++ }
            if ($h -gt $over) { $overCnt++ }
        }
        $row['合計']     = "{0:N1}" -f $tot
        $row['週平均']   = if ($cnt -gt 0) { "{0:N1}" -f ($tot / $cnt) } else { '' }
        $row['超過週']   = if ($overCnt -gt 0) { "$overCnt 週" } else { '' }
        $weeklyRows.Add([pscustomobject]$row)
    }
    $u.LoadWeeklyGrid.ItemsSource = @($weeklyRows)

    # ---- 未入力検知: 期間内の平日で 0h の日 (active メンバーのみ) ----
    $from = $u.FromDate.SelectedDate
    $to   = $u.ToDate.SelectedDate
    if (-not $from -or -not $to) { return }
    $activeMembers = @($Script:Members | Where-Object { $_.active } | ForEach-Object { [string]$_.id })
    if ($activeMembers.Count -eq 0) { return }

    # 平日リスト (土日除外)
    $weekdays = New-Object System.Collections.Generic.List[datetime]
    $cur = $from.Date
    while ($cur -le $to.Date) {
        if ($cur.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $cur.DayOfWeek -ne [System.DayOfWeek]::Sunday) {
            $weekdays.Add($cur)
        }
        $cur = $cur.AddDays(1)
    }

    # 日付セット per member
    $hasEntry = @{}
    foreach ($r in $Rows) {
        $mid = [string]$r.member_id
        if (-not $hasEntry.ContainsKey($mid)) { $hasEntry[$mid] = New-Object 'System.Collections.Generic.HashSet[string]' }
        [void]$hasEntry[$mid].Add([string]$r.date)
    }

    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($mid in $activeMembers) {
        $missDates = New-Object System.Collections.Generic.List[string]
        foreach ($d in $weekdays) {
            $k = $d.ToString('yyyy-MM-dd')
            if (-not $hasEntry.ContainsKey($mid) -or -not $hasEntry[$mid].Contains($k)) {
                $missDates.Add($d.ToString('M/d(ddd)'))
            }
        }
        if ($missDates.Count -eq 0) { continue }
        $shown = if ($missDates.Count -le 10) { $missDates -join ', ' } else {
            (($missDates | Select-Object -First 10) -join ', ') + " ... 他 $($missDates.Count - 10) 件"
        }
        $missing.Add([pscustomobject]@{
            member        = (_ResolveMember $mid)
            missing_count = $missDates.Count
            missing_dates = $shown
        })
    }
    $u.MissingEntriesGrid.ItemsSource = @($missing | Sort-Object -Property missing_count -Descending)
}

# ---- メンバー × プロジェクト クロス集計 ----
function Build-MemberProjectMatrix {
    param($Rows)
    if (-not $u.MemberProjectGrid) { return }
    $u.MemberProjectGrid.Columns.Clear()
    $u.MemberProjectGrid.ItemsSource = $null
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $projs = @($Rows | ForEach-Object { [string]$_.project_code } | Where-Object { $_ } | Sort-Object -Unique)
    $members = @($Rows | ForEach-Object { [string]$_.member_id } | Where-Object { $_ } | Sort-Object -Unique)

    $matrix = @{}  # member -> { project -> hours }
    foreach ($r in $Rows) {
        $mid = [string]$r.member_id; $pc = [string]$r.project_code
        if (-not $mid -or -not $pc) { continue }
        if (-not $matrix.ContainsKey($mid)) { $matrix[$mid] = @{} }
        if (-not $matrix[$mid].ContainsKey($pc)) { $matrix[$mid][$pc] = 0.0 }
        $matrix[$mid][$pc] += [double]$r.hours
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($mid in $members) {
        $row = [ordered]@{ 'メンバー' = (_ResolveMember $mid) }
        $tot = 0.0
        foreach ($pc in $projs) {
            $h = if ($matrix.ContainsKey($mid) -and $matrix[$mid].ContainsKey($pc)) { [double]$matrix[$mid][$pc] } else { 0.0 }
            $row[$pc] = if ($h -gt 0) { "{0:N1}" -f $h } else { '' }
            $tot += $h
        }
        $row['合計'] = "{0:N1}" -f $tot
        $out.Add([pscustomobject]$row)
    }
    # フッタ風: プロジェクト合計行
    $footer = [ordered]@{ 'メンバー' = '◆ プロジェクト合計' }
    $grand = 0.0
    foreach ($pc in $projs) {
        $sum = 0.0
        foreach ($mid in $members) {
            if ($matrix.ContainsKey($mid) -and $matrix[$mid].ContainsKey($pc)) {
                $sum += [double]$matrix[$mid][$pc]
            }
        }
        $footer[$pc] = "{0:N1}" -f $sum
        $grand += $sum
    }
    $footer['合計'] = "{0:N1}" -f $grand
    $out.Add([pscustomobject]$footer)

    $u.MemberProjectGrid.ItemsSource = @($out)
}

# ---- 業務種別 (案件対応 / 維持運用 / その他) 稼働比率 ----
function Build-WorkTypeMix {
    param($Rows)
    if (-not $u.WorkTypeKpiPanel -or -not $u.WorkTypeByMemberGrid) { return }
    $u.WorkTypeKpiPanel.Children.Clear()
    $u.WorkTypeByMemberGrid.Columns.Clear()
    $u.WorkTypeByMemberGrid.ItemsSource = $null
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    # チーム全体集計
    $byType = @{}
    $total = 0.0
    foreach ($r in $Rows) {
        $wt = _ProjectWorkType ([string]$r.project_code)
        if (-not $byType.ContainsKey($wt)) { $byType[$wt] = 0.0 }
        $byType[$wt] += [double]$r.hours
        $total += [double]$r.hours
    }

    # KPI カード (チーム全体の業務種別比率)
    $colorMap = @{
        '案件対応' = '#0369a1'
        '維持運用' = '#059669'
        'その他'   = '#7c3aed'
    }
    foreach ($wt in @('案件対応','維持運用','その他')) {
        $h = if ($byType.ContainsKey($wt)) { [double]$byType[$wt] } else { 0.0 }
        $pct = if ($total -gt 0) { ($h / $total) * 100.0 } else { 0.0 }
        $col = if ($colorMap.ContainsKey($wt)) { $colorMap[$wt] } else { '#6b7280' }
        $b = New-Object System.Windows.Controls.Border
        $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#f8fafc')
        $b.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($col)
        $b.BorderThickness = '2'; $b.CornerRadius = '8'
        $b.Padding = '14'; $b.Margin = '0,0,10,0'; $b.MinWidth = 180
        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = $wt; $t1.FontSize = 12; $t1.Foreground = [System.Windows.Media.Brushes]::SlateGray
        $sp.Children.Add($t1) | Out-Null
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = "{0:N1} h  ({1:N1}%)" -f $h, $pct
        $t2.FontSize = 18; $t2.FontWeight = 'Bold'
        $t2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($col)
        $sp.Children.Add($t2) | Out-Null
        $b.Child = $sp
        [void]$u.WorkTypeKpiPanel.Children.Add($b)
    }

    # メンバー別 × 業務種別 集計
    $byMember = @{}
    foreach ($r in $Rows) {
        $mid = [string]$r.member_id
        if (-not $mid) { continue }
        $wt = _ProjectWorkType ([string]$r.project_code)
        if (-not $byMember.ContainsKey($mid)) { $byMember[$mid] = @{} }
        if (-not $byMember[$mid].ContainsKey($wt)) { $byMember[$mid][$wt] = 0.0 }
        $byMember[$mid][$wt] += [double]$r.hours
    }
    $rowsOut = New-Object System.Collections.Generic.List[object]
    foreach ($mid in ($byMember.Keys | Sort-Object)) {
        $tot = 0.0
        foreach ($wt in @('案件対応','維持運用','その他')) {
            if ($byMember[$mid].ContainsKey($wt)) { $tot += [double]$byMember[$mid][$wt] }
        }
        $row = [ordered]@{ 'メンバー' = (_ResolveMember $mid) }
        foreach ($wt in @('案件対応','維持運用','その他')) {
            $h = if ($byMember[$mid].ContainsKey($wt)) { [double]$byMember[$mid][$wt] } else { 0.0 }
            $pct = if ($tot -gt 0) { ($h / $tot) * 100.0 } else { 0.0 }
            $row["$wt (h)"]  = if ($h -gt 0) { "{0:N1}" -f $h } else { '' }
            $row["$wt (%)"]  = if ($h -gt 0) { "{0:N0}" -f $pct } else { '' }
        }
        $row['合計'] = "{0:N1}" -f $tot
        $rowsOut.Add([pscustomobject]$row)
    }
    $u.WorkTypeByMemberGrid.ItemsSource = @($rowsOut)
}

# ---- イベントフック ----
if ($u.HeatmapAxisCombo) {
    $u.HeatmapAxisCombo.Add_SelectionChanged({ Build-Heatmap -Rows $Script:ChartRows })
}
if ($u.LoadRefreshBtn) {
    $u.LoadRefreshBtn.Add_Click({ Build-MemberLoad -Rows $Script:ChartRows })
}

# Apply-Filters の Step 配列を呼べないので、Apply-Filters の末尾で再描画するために
# wrapper を新設する。元の Apply-Filters は ChartRows をセットするので、その後に
# 拡張集計を呼ぶ。
$origApply = ${function:Apply-Filters}
function Apply-Filters {
    & $origApply
    try { Build-MemberLoad           -Rows $Script:ChartRows } catch { }
    try { Build-MemberProjectMatrix  -Rows $Script:ChartRows } catch { }
    try { Build-WorkTypeMix          -Rows $Script:ChartRows } catch { }
}

Reload-Entries

[void]$win.ShowDialog()
