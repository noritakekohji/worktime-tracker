# ReportViewer.ps1 — ローカル集計 GUI ビューア
#
# 設定済みの GitLab 接続 (またはローカルモード) からデータを取得し、
# 期間/メンバー/プロジェクトでフィルタ → 明細・集計表示・CSV エクスポート

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ---- 致命エラーログ (Tracker と共用) ----
$Script:LogDir = Join-Path $env:APPDATA 'worktime-tracker'
if (-not (Test-Path -LiteralPath $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}
$Script:LogPath = Join-Path $Script:LogDir 'last_error.log'

function Write-FatalLog {
    param([string]$Text)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] [Report] $Text`r`n" -Encoding UTF8
    } catch { }
}

trap {
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)`n`n--- 詳細: $Script:LogPath"
    Write-FatalLog "FATAL: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n$($_.Exception | Format-List * -Force | Out-String)"
    try {
        [System.Windows.MessageBox]::Show($msg, 'ReportViewer - 致命的エラー', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host $msg -ForegroundColor Red
    }
    exit 1
}

# WPF Dispatcher の未捕捉例外も last_error.log へ
# (UI イベントハンドラの例外は trap では拾えないため、別途フックを張る)
# PowerShell から WPF を使う場合 Application.Current は null になることがあるため
# Dispatcher.CurrentDispatcher を直接フックする
try {
    $Script:UiDispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $Script:UiDispatcher.add_UnhandledException({
        param($s, $e)
        try {
            Write-FatalLog ("DispatcherUnhandled: {0}`r`n{1}" -f $e.Exception.Message, $e.Exception.StackTrace)
        } catch { }
        # 致命でない限りウインドウ存続 (UI 操作は継続可能)
        $e.Handled = $true
    })
} catch {
    Write-FatalLog ("Dispatcher hook failed: $($_.Exception.Message)")
}

Write-FatalLog ("==== START $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====")
Write-FatalLog ("PSVersion: $($PSVersionTable.PSVersion) | PSScriptRoot: $PSScriptRoot")

$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'client/lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'Version.ps1')
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
$Script:Categories    = $ctx.Categories
$Script:TaskPatterns  = $ctx.TaskPatterns
$Script:CurrentMember = $ctx.CurrentMember
$Script:AllEntries    = @()

# ---- 名称解決ヘルパ ----
# Report は ID/Code を集計キーに使うが、画面表示には名称を併記する。
# パターン経由の名称 (process/task_group/task) は project_code から特定。
function Resolve-MemberName {
    param([string]$Id)
    if (-not $Id) { return '' }
    $m = $Script:Members | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
    if ($m -and $m.name) { return [string]$m.name }
    return ''
}
function Resolve-MemberDisplay {
    param([string]$Id)
    if (-not $Id) { return '' }
    $n = Resolve-MemberName $Id
    if ($n) { return "$Id  $n" } else { return $Id }
}
function Resolve-ProjectName {
    param([string]$Code)
    if (-not $Code) { return '' }
    $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq $Code } | Select-Object -First 1
    if ($p -and $p.project_name) { return [string]$p.project_name }
    return ''
}
function Resolve-ProjectDisplay {
    param([string]$Code)
    if (-not $Code) { return '' }
    $n = Resolve-ProjectName $Code
    if ($n) { return "$Code  $n" } else { return $Code }
}
function Resolve-MemberCompany {
    param([string]$Id)
    if (-not $Id) { return '' }
    $m = $Script:Members | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
    if ($m -and $m.company) { return [string]$m.company }
    return ''
}
function Resolve-ProjectTargetSystem {
    param([string]$Code)
    if (-not $Code) { return '' }
    $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq $Code } | Select-Object -First 1
    if ($p -and $p.target_system) { return [string]$p.target_system }
    return ''
}
function Resolve-CategoryName {
    param([string]$Code)
    if (-not $Code) { return '' }
    $c = $Script:Categories | Where-Object { [string]$_.code -eq $Code } | Select-Object -First 1
    if ($c -and $c.name) { return [string]$c.name }
    return ''
}
function Resolve-CategoryDisplay {
    param([string]$Code)
    if (-not $Code) { return '' }
    $n = Resolve-CategoryName $Code
    if ($n) { return "$Code  $n" } else { return $Code }
}
# task pattern 経由: process_code → name (どこかのパターンで一致したらそれを採用)
$Script:_PatternNameCache = $null
function _BuildPatternNameMap {
    if ($null -ne $Script:_PatternNameCache) { return $Script:_PatternNameCache }
    $m = @{}  # 'process|code' / 'group|code' / 'task|code' → name
    foreach ($pt in @($Script:TaskPatterns)) {
        if (-not $pt) { continue }
        foreach ($pr in @($pt.processes)) {
            if (-not $pr -or -not $pr.code) { continue }
            $m["process|$([string]$pr.code)"] = [string]$pr.name
            foreach ($tg in @($pr.task_groups)) {
                if (-not $tg -or -not $tg.code) { continue }
                $m["group|$([string]$tg.code)"] = [string]$tg.name
                foreach ($tk in @($tg.tasks)) {
                    if (-not $tk -or -not $tk.code) { continue }
                    $m["task|$([string]$tk.code)"] = [string]$tk.name
                }
            }
        }
    }
    $Script:_PatternNameCache = $m
    return $m
}
function Resolve-ProcessName    { param([string]$Code); $m = _BuildPatternNameMap; if ($Code -and $m.ContainsKey("process|$Code")) { return $m["process|$Code"] }; return '' }
function Resolve-TaskGroupName  { param([string]$Code); $m = _BuildPatternNameMap; if ($Code -and $m.ContainsKey("group|$Code"))   { return $m["group|$Code"]   }; return '' }
function Resolve-TaskName       { param([string]$Code); $m = _BuildPatternNameMap; if ($Code -and $m.ContainsKey("task|$Code"))    { return $m["task|$Code"]    }; return '' }
function _MergeCodeName {
    param([string]$Code, [string]$Name)
    if (-not $Code) { return '' }
    if ($Name) { return "$Code  $Name" } else { return $Code }
}

# ---- XAML ----
$xamlPath = Join-Path $PSScriptRoot 'ReportViewer.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$win.Title = Format-WindowTitle -ScreenName 'Report'
$u = @{}
foreach ($n in 'FromDate','ToDate','PeriodThisMonthBtn','PeriodPrevMonthBtn','PeriodThisFYBtn','MemberFilter','ApplyBtn','ReloadBtn','LoadAllBtn','ExportBtn','AdminBtn',
              'DetailGrid','MemberSummaryGrid','ProjectSummaryGrid','CategorySummaryGrid','SystemSummaryGrid','CompanySummaryGrid','SummaryText','StatusText','AnalysisPanel',
              'ChartAxisCombo','ChartTypeCombo','ChartSortCombo','ChartTopCombo','ChartRedrawBtn','ChartCanvas',
              'HeatmapCanvas','HeatmapAxisCombo','HeatmapDescText','AnomalyGrid','DashboardPanel',
              'LoadOverThresholdTxt','LoadTargetTxt','LoadRefreshBtn','LoadWeeklyGrid','MissingEntriesGrid',
              'MemberProjectGrid','WorkTypeKpiPanel','WorkTypeByMemberGrid','WorkTypePieCanvas','WorkTypePieLegend',
              'WorkTypeSystemFilter','WorkTypeProjectFilter',
              'CaseAxisCombo','CaseAnalysisGrid','OpsAxisCombo','OpsAnalysisGrid',
              'CasePieCanvas','CasePieLegend','CaseBarCanvas',
              'OpsPieCanvas','OpsPieLegend','OpsBarCanvas') {
    $u[$n] = $win.FindName($n)
}

# 管理者ロールなら管理者ボタン表示 (CurrentMember は Bootstrap で解決済み)
if ($Script:CurrentMember -and (Has-Role -Member $Script:CurrentMember -Role 'admin') -and $u.AdminBtn) {
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
# 期間クイック選択ヘルパ
function _SetPeriodThisMonth {
    $t = [datetime]::Today
    $u.FromDate.SelectedDate = (Get-Date -Year $t.Year -Month $t.Month -Day 1)
    $end = ((Get-Date -Year $t.Year -Month $t.Month -Day 1).AddMonths(1)).AddDays(-1)
    $u.ToDate.SelectedDate = $end
}
function _SetPeriodPrevMonth {
    $t = [datetime]::Today
    $prev = (Get-Date -Year $t.Year -Month $t.Month -Day 1).AddMonths(-1)
    $u.FromDate.SelectedDate = $prev
    $u.ToDate.SelectedDate   = ($prev.AddMonths(1)).AddDays(-1)
}
function _SetPeriodThisFY {
    # 会計年度: 4 月始まり〜翌 3 月末
    $t = [datetime]::Today
    $fyStartYear = if ($t.Month -ge 4) { $t.Year } else { $t.Year - 1 }
    $u.FromDate.SelectedDate = (Get-Date -Year $fyStartYear      -Month 4 -Day 1)
    $u.ToDate.SelectedDate   = (Get-Date -Year ($fyStartYear+1)  -Month 3 -Day 31)
}
# 初期は当月
_SetPeriodThisMonth

# メンバーフィルタの items を構築 ((全メンバー) + active メンバー)
function _RefreshMemberFilter {
    $items = New-Object 'System.Collections.Generic.List[object]'
    [void]$items.Add([pscustomobject]@{ id = ''; display = '(全メンバー)' })
    foreach ($m in $Script:Members) {
        if (-not $m) { continue }
        if ($null -ne $m.active -and -not $m.active) { continue }
        [void]$items.Add([pscustomobject]@{
            id      = [string]$m.id
            display = "$([string]$m.id)  $([string]$m.name)"
        })
    }
    $cur = if ($u.MemberFilter) { $u.MemberFilter.SelectedValue } else { '' }
    $u.MemberFilter.ItemsSource = $items
    if ($cur) {
        $u.MemberFilter.SelectedValue = $cur
        if ($u.MemberFilter.SelectedIndex -lt 0) { $u.MemberFilter.SelectedIndex = 0 }
    } else {
        $u.MemberFilter.SelectedIndex = 0
    }
}
_RefreshMemberFilter

# ---- 業務種別比率タブ専用フィルタ (システム / プロジェクト) ----
function _RefreshWorkTypeFilters {
    if (-not $u.WorkTypeSystemFilter -or -not $u.WorkTypeProjectFilter) { return }
    # システム一覧 (target_system のユニーク集合)
    $sysSet = New-Object 'System.Collections.Generic.SortedSet[string]'
    $projItems = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in @($Script:Projects)) {
        if (-not $p) { continue }
        if ($null -ne $p.active -and -not $p.active) { continue }
        $sys = [string]$p.target_system
        if ($sys) { [void]$sysSet.Add($sys) }
        [void]$projItems.Add([pscustomobject]@{
            key     = [string]$p.unit_code
            display = (Resolve-ProjectDisplay ([string]$p.unit_code))
        })
    }
    $sysItems = New-Object 'System.Collections.Generic.List[object]'
    [void]$sysItems.Add([pscustomobject]@{ key=''; display='(全システム)' })
    foreach ($s in $sysSet) {
        [void]$sysItems.Add([pscustomobject]@{ key=$s; display=$s })
    }
    $projAll = New-Object 'System.Collections.Generic.List[object]'
    [void]$projAll.Add([pscustomobject]@{ key=''; display='(全プロジェクト)' })
    foreach ($pi in ($projItems | Sort-Object key)) { [void]$projAll.Add($pi) }

    $curSys  = if ($u.WorkTypeSystemFilter)  { $u.WorkTypeSystemFilter.SelectedValue }  else { '' }
    $curProj = if ($u.WorkTypeProjectFilter) { $u.WorkTypeProjectFilter.SelectedValue } else { '' }
    $u.WorkTypeSystemFilter.ItemsSource  = $sysItems
    $u.WorkTypeProjectFilter.ItemsSource = $projAll
    if ($curSys)  { $u.WorkTypeSystemFilter.SelectedValue  = $curSys;  if ($u.WorkTypeSystemFilter.SelectedIndex  -lt 0) { $u.WorkTypeSystemFilter.SelectedIndex  = 0 } } else { $u.WorkTypeSystemFilter.SelectedIndex  = 0 }
    if ($curProj) { $u.WorkTypeProjectFilter.SelectedValue = $curProj; if ($u.WorkTypeProjectFilter.SelectedIndex -lt 0) { $u.WorkTypeProjectFilter.SelectedIndex = 0 } } else { $u.WorkTypeProjectFilter.SelectedIndex = 0 }
}
_RefreshWorkTypeFilters

# 選択中のフィルタを適用して rows を絞る
function _ApplyWorkTypeFilters {
    param($Rows)
    if (-not $Rows) { return @() }
    $sysSel  = if ($u.WorkTypeSystemFilter)  { [string]$u.WorkTypeSystemFilter.SelectedValue }  else { '' }
    $projSel = if ($u.WorkTypeProjectFilter) { [string]$u.WorkTypeProjectFilter.SelectedValue } else { '' }
    if (-not $sysSel -and -not $projSel) { return $Rows }
    $filtered = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $Rows) {
        $pc = [string]$r.project_code
        if ($projSel -and $pc -ne $projSel) { continue }
        if ($sysSel) {
            $s = Resolve-ProjectTargetSystem $pc
            if ($s -ne $sysSel) { continue }
        }
        [void]$filtered.Add($r)
    }
    return $filtered.ToArray()
}

function Reload-Entries {
    # 「📋 読込」: ローカルから読込のみ (Gitlab モードでも remote にアクセスしない)
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $u.SummaryText.Text = ("ローカルから読込中...")
        $Script:AllEntries = @(Load-AllEntries-Local -Source $Script:Source)
        $u.SummaryText.Text = "ローカル読込: $($Script:AllEntries.Count) 件"
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
    # ヘッダのメンバーフィルタ ((全メンバー) = 空文字)
    $mid  = if ($u.MemberFilter) { [string]$u.MemberFilter.SelectedValue } else { '' }

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
        if ($mid  -and $memberId -ne $mid) { $ok = $false }
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

    # メンバー別 (ID + 氏名)
    $byMember = $rows | Group-Object member_id | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ メンバー = (Resolve-MemberDisplay $_.Name); 件数 = $_.Count; 工数 = [Math]::Round($sum, 2) }
    } | Sort-Object -Property 工数 -Descending
    $u.MemberSummaryGrid.ItemsSource = @($byMember)

    # プロジェクト別 (Code + 名称)
    $byProject = $rows | Group-Object project_code | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ プロジェクト = (Resolve-ProjectDisplay $_.Name); 件数 = $_.Count; 工数 = [Math]::Round($sum, 2) }
    } | Sort-Object -Property 工数 -Descending
    $u.ProjectSummaryGrid.ItemsSource = @($byProject)

    # カテゴリ別 (Code + 名称)
    $byCat = $rows | Group-Object category | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ カテゴリ = (Resolve-CategoryDisplay $_.Name); 件数 = $_.Count; 工数 = [Math]::Round($sum, 2) }
    } | Sort-Object -Property 工数 -Descending
    $u.CategorySummaryGrid.ItemsSource = @($byCat)

    # システム別 (projects.target_system 解決)
    $sysRows = $rows | ForEach-Object {
        $sys = Resolve-ProjectTargetSystem ([string]$_.project_code)
        if (-not $sys) { $sys = '(未設定)' }
        [pscustomobject]@{ _sys = $sys; hours = $_.hours }
    }
    $bySys = $sysRows | Group-Object _sys | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ 対象システム = $_.Name; 件数 = $_.Count; 工数 = [Math]::Round($sum, 2) }
    } | Sort-Object -Property 工数 -Descending
    $u.SystemSummaryGrid.ItemsSource = @($bySys)

    # 会社別 (members.company 解決)
    $coRows = $rows | ForEach-Object {
        $co = Resolve-MemberCompany ([string]$_.member_id)
        if (-not $co) { $co = '(未設定)' }
        [pscustomobject]@{ _co = $co; hours = $_.hours }
    }
    $byCo = $coRows | Group-Object _co | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += [double]$r.hours }
        [pscustomobject]@{ 会社 = $_.Name; 件数 = $_.Count; 工数 = [Math]::Round($sum, 2) }
    } | Sort-Object -Property 工数 -Descending
    $u.CompanySummaryGrid.ItemsSource = @($byCo)

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
        # コードではなく "コード 名称" 形式で表示
        $lbl.Text = (Resolve-ProjectDisplay ([string]$e.Key)); $lbl.VerticalAlignment = 'Center'
        $lbl.ToolTip = $lbl.Text
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
        # メンバーは "ID 氏名" 形式で表示
        $lbl.Text = (Resolve-MemberDisplay ([string]$e.Key)); $lbl.VerticalAlignment = 'Center'
        $lbl.ToolTip = $lbl.Text
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
            $rowDisp = { param($v) $m = $Script:Members | Where-Object { [string]$_.id -eq [string]$v } | Select-Object -First 1
                         if ($m) { "$($m.id)  $($m.name)" } else { [string]$v } }
            $colDisp = { param($v) $d = [datetime]::MinValue
                         if ([datetime]::TryParse([string]$v, [ref]$d)) { $d.ToString('M/d') } else { [string]$v } }
            $colW = 22
        }
        'メンバー × プロジェクト' {
            $rowKey  = 'member_id'
            $colKey  = 'project_code'
            $rowDisp = { param($v) $m = $Script:Members | Where-Object { [string]$_.id -eq [string]$v } | Select-Object -First 1
                         if ($m) { "$($m.id)  $($m.name)" } else { [string]$v } }
            $colDisp = { param($v) $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq [string]$v } | Select-Object -First 1
                         if ($p) { [string]$p.unit_code } else { [string]$v } }
            $colW = 80
        }
        default {
            $rowKey  = 'project_code'
            $colKey  = 'date'
            $rowDisp = { param($v) [string]$v }
            $colDisp = { param($v) $d = [datetime]::MinValue
                         if ([datetime]::TryParse([string]$v, [ref]$d)) { $d.ToString('M/d') } else { [string]$v } }
            $colW = 22
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
        # 名称併記で表示
        (_AnalysisRow ("{0}:" -f (Resolve-ProjectDisplay $p.code)) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $p.h, $pct, $p.cnt))
    }
    $panel.Children.Add( (_AnalysisCard '🏆 プロジェクト Top 5' $projRows) ) | Out-Null

    # カテゴリ Top
    $topCat = $rowsArr | Group-Object category | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending | Select-Object -First 5
    $catRows = foreach ($c in $topCat) {
        $pct = if ($totalHours -gt 0) { ($c.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f (Resolve-CategoryDisplay $c.code)) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $c.h, $pct, $c.cnt))
    }
    $panel.Children.Add( (_AnalysisCard '🏷 カテゴリ Top 5' $catRows) ) | Out-Null

    # メンバー Top
    $topMem = $rowsArr | Group-Object member_id | ForEach-Object {
        $h = ($_.Group | Measure-Object hours -Sum).Sum
        [pscustomobject]@{ code = $_.Name; h = $h; cnt = $_.Count }
    } | Sort-Object h -Descending | Select-Object -First 5
    $memRows = foreach ($m in $topMem) {
        $pct = if ($totalHours -gt 0) { ($m.h / $totalHours) * 100 } else { 0 }
        (_AnalysisRow ("{0}:" -f (Resolve-MemberDisplay $m.code)) ("{0,6:N1} h  ({1:N1}%, {2} 件)" -f $m.h, $pct, $m.cnt))
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
        $Script:Members    = @(Get-MasterMembers    -Source $Script:Source)
        $Script:Projects   = @(Get-MasterProjects   -Source $Script:Source)
        $Script:Categories = @(Get-MasterCategories -Source $Script:Source)
        $Script:TaskPatterns = @(Get-MasterTaskPatterns -Source $Script:Source)
        $Script:_PatternNameCache = $null   # 名称キャッシュを破棄
        _RefreshMemberFilter
        _RefreshWorkTypeFilters
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

$u.LoadAllBtn.Add_Click({
    # 📋 読込 = ローカルから読込のみ
    _Diag "LoadAllBtn click (local only)"
    Reload-Masters
    Reload-Entries
})
$u.ReloadBtn.Add_Click({
    # 📥 取得 = リモートから全データ pull → ローカル読込
    _Diag "ReloadBtn click (pull)"
    if (-not $Script:Source.RemoteCtx) {
        [System.Windows.MessageBox]::Show('スタンドアローンモードでは「取得」は使えません。「読込」を使ってください。', '取得', 'OK', 'Information') | Out-Null
        return
    }
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $u.SummaryText.Text = 'Gitlab から取得中...'
        $pullM = Sync-Pull-Masters -Source $Script:Source
        $pullD = Sync-Pull-AllData -Source $Script:Source
        _Diag ("取得 master={0}/{1} data={2} errors_m={3} errors_d={4}" -f $pullM.Pulled, $pullM.Missing, $pullD.Pulled, $pullM.Errors.Count, $pullD.Errors.Count)
        Reload-Masters
        Reload-Entries
        $u.SummaryText.Text = ("取得完了: master={0} / data={1} 件 → ローカル読込 ({2} 件)" -f $pullM.Pulled, $pullD.Pulled, $Script:AllEntries.Count)
    } catch {
        $u.SummaryText.Text = ("取得失敗: $($_.Exception.Message)")
        [System.Windows.MessageBox]::Show("Gitlab からの取得に失敗:`n$($_.Exception.Message)", '取得エラー', 'OK', 'Error') | Out-Null
    } finally {
        $win.Cursor = $null
    }
})
$u.ApplyBtn.Add_Click({ _Diag "ApplyBtn click"; _SafeApplyFilters })

# 期間クイック選択ボタン → 期間を設定して即フィルタ適用
$u.PeriodThisMonthBtn.Add_Click({ _SetPeriodThisMonth; if ($Script:AllEntries) { _SafeApplyFilters } })
$u.PeriodPrevMonthBtn.Add_Click({ _SetPeriodPrevMonth; if ($Script:AllEntries) { _SafeApplyFilters } })
$u.PeriodThisFYBtn.Add_Click({    _SetPeriodThisFY;    if ($Script:AllEntries) { _SafeApplyFilters } })
# メンバーフィルタ変更 → 即フィルタ適用
$u.MemberFilter.Add_SelectionChanged({ if ($Script:AllEntries) { _SafeApplyFilters } })

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

# WPF DataGrid に [ordered]@{ '日本語ヘッダ' = '値' ... } のリストを安全に流し込む。
# プロパティ名に `/` `(` `)` ` ` `~` 等が含まれると AutoGenerateColumns の Binding
# パス解析が失敗するため、内部プロパティ名は col0..colN にリネームし、ヘッダだけ
# 元の日本語を保持する。
function Set-PivotGrid {
    param(
        [System.Windows.Controls.DataGrid]$Grid,
        $Rows,
        [int]$FirstColWidth = 180
    )
    if (-not $Grid) { return }
    try { _TraceMgr 'Set-PivotGrid' 'enter' } catch { }
    $Grid.Columns.Clear()
    $Grid.ItemsSource = $null
    if (-not $Rows) { _TraceMgr 'Set-PivotGrid' 'rows=null'; return }
    # PS 5.1: @() で List[object] of PSCustomObject を包むと
    # "引数の型が一致しません" 例外。foreach で逐次コピーする。
    $rowArr = New-Object System.Collections.Generic.List[object]
    if ($Rows -is [System.Collections.IEnumerable] -and -not ($Rows -is [string])) {
        foreach ($r in $Rows) { [void]$rowArr.Add($r) }
    } else {
        [void]$rowArr.Add($Rows)
    }
    if ($rowArr.Count -eq 0) { _TraceMgr 'Set-PivotGrid' 'rows=0'; return }
    _TraceMgr 'Set-PivotGrid' ("rows=$($rowArr.Count)")

    # 全行のキーをマージ (先頭行が代表だが、念のため union)
    $orderedHeaders = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $rowArr) {
        if ($null -eq $r) { continue }
        $keys = if ($r -is [System.Collections.IDictionary]) {
            @($r.Keys)
        } else {
            @($r.PSObject.Properties | ForEach-Object { $_.Name })
        }
        foreach ($k in $keys) {
            $ks = [string]$k
            if (-not $seen.Contains($ks)) { [void]$seen.Add($ks); $orderedHeaders.Add($ks) }
        }
    }
    if ($orderedHeaders.Count -eq 0) { _TraceMgr 'Set-PivotGrid' 'no headers'; return }
    _TraceMgr 'Set-PivotGrid' ("headers=$($orderedHeaders.Count): " + (($orderedHeaders | Select-Object -First 6) -join ' | '))

    # セーフ列名を生成
    $headerToSafe = @{}
    for ($i = 0; $i -lt $orderedHeaders.Count; $i++) {
        $headerToSafe[$orderedHeaders[$i]] = "col$i"
    }

    # DataGrid 列を構築
    for ($i = 0; $i -lt $orderedHeaders.Count; $i++) {
        try {
            $col = New-Object System.Windows.Controls.DataGridTextColumn
            $col.Header   = [string]$orderedHeaders[$i]
            # Binding は -ArgumentList で明示 (位置引数だと型推論で詰まる場合あり)
            $col.Binding  = New-Object System.Windows.Data.Binding -ArgumentList ("col$i")
            if ($i -eq 0) {
                # DataGridLength は double から implicit conversion
                $col.Width = New-Object System.Windows.Controls.DataGridLength -ArgumentList ([double]$FirstColWidth)
            }
            $col.IsReadOnly = $true
            $col.CanUserSort = $false
            [void]$Grid.Columns.Add($col)
        } catch {
            _TraceMgr 'Set-PivotGrid' ("col[$i] header='$($orderedHeaders[$i])' ERROR: $($_.Exception.Message)")
            throw
        }
    }
    _TraceMgr 'Set-PivotGrid' 'columns built'

    # 行を PSCustomObject (col0..colN) に変換
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rowArr) {
        if ($null -eq $r) { continue }
        $obj = [ordered]@{}
        foreach ($h in $orderedHeaders) {
            $safe = $headerToSafe[$h]
            $val = $null
            if ($r -is [System.Collections.IDictionary]) {
                if ($r.Contains($h)) { $val = $r[$h] }
            } else {
                $p = $r.PSObject.Properties[$h]
                if ($p) { $val = $p.Value }
            }
            $obj[$safe] = if ($null -eq $val) { '' } else { [string]$val }
        }
        $items.Add([pscustomobject]$obj)
    }
    try {
        $Grid.ItemsSource = $items.ToArray()
        _TraceMgr 'Set-PivotGrid' ("items={0} ok" -f $items.Count)
    } catch {
        _TraceMgr 'Set-PivotGrid' ("ItemsSource ERROR: $($_.Exception.Message)")
        throw
    }
}

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
    Set-PivotGrid -Grid $u.LoadWeeklyGrid -Rows $weeklyRows

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

    Set-PivotGrid -Grid $u.MemberProjectGrid -Rows $out
}

# ---- 業務種別 (案件対応 / 維持運用 / その他) 稼働比率 ----
function _DrawPieChart {
    # 円グラフを Canvas に描く (3 セクター対応・360°)
    # $Slices: 順序を保つ [ordered]@{ Label=hex色 } 形式 + $Values: 同順 double[]
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [string[]]$Labels,
        [double[]]$Values,
        [string[]]$Colors
    )
    if (-not $Canvas) { return }
    $Canvas.Children.Clear()
    $total = 0.0; foreach ($v in $Values) { $total += $v }
    if ($total -le 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '(データなし)'; $tb.Foreground = [System.Windows.Media.Brushes]::Gray
        [System.Windows.Controls.Canvas]::SetLeft($tb, 70)
        [System.Windows.Controls.Canvas]::SetTop($tb, 100)
        [void]$Canvas.Children.Add($tb)
        return
    }
    $w = [double]$Canvas.Width; $h = [double]$Canvas.Height
    if ($w -le 0) { $w = 220 }; if ($h -le 0) { $h = 220 }
    $cx = $w / 2.0; $cy = $h / 2.0
    $radius = ([Math]::Min($cx, $cy)) - 6
    $startAngle = -90.0  # 12 時方向から開始
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $v = [double]$Values[$i]
        if ($v -le 0) { continue }
        $sweep = ($v / $total) * 360.0
        # Path で扇形を作成: M cx,cy → L 始点 → ArcSegment → Z
        $rad1 = $startAngle * [Math]::PI / 180.0
        $rad2 = ($startAngle + $sweep) * [Math]::PI / 180.0
        $p1 = New-Object System.Windows.Point ($cx + $radius * [Math]::Cos($rad1)), ($cy + $radius * [Math]::Sin($rad1))
        $p2 = New-Object System.Windows.Point ($cx + $radius * [Math]::Cos($rad2)), ($cy + $radius * [Math]::Sin($rad2))
        $fig = New-Object System.Windows.Media.PathFigure
        $fig.StartPoint = New-Object System.Windows.Point $cx, $cy
        $segL = New-Object System.Windows.Media.LineSegment $p1, $true
        $segA = New-Object System.Windows.Media.ArcSegment
        $segA.Point = $p2
        $segA.Size  = New-Object System.Windows.Size $radius, $radius
        $segA.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
        $segA.IsLargeArc = ($sweep -gt 180.0)
        $segA.IsStroked = $true
        [void]$fig.Segments.Add($segL)
        [void]$fig.Segments.Add($segA)
        $fig.IsClosed = $true
        $geom = New-Object System.Windows.Media.PathGeometry
        [void]$geom.Figures.Add($fig)
        $path = New-Object System.Windows.Shapes.Path
        $path.Data = $geom
        $brush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Colors[$i])
        $path.Fill = $brush
        $path.Stroke = [System.Windows.Media.Brushes]::White
        $path.StrokeThickness = 2
        $pct = ($v / $total) * 100.0
        $path.ToolTip = ("{0}  {1:N1}h  ({2:N1}%)" -f $Labels[$i], $v, $pct)
        [void]$Canvas.Children.Add($path)
        # ラベル (10% 以上のときだけ描画)
        if ($pct -ge 10) {
            $midRad = ($startAngle + $sweep / 2.0) * [Math]::PI / 180.0
            $lx = $cx + ($radius * 0.6) * [Math]::Cos($midRad)
            $ly = $cy + ($radius * 0.6) * [Math]::Sin($midRad)
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "{0:N0}%" -f $pct
            $tb.Foreground = [System.Windows.Media.Brushes]::White
            $tb.FontWeight = 'Bold'
            [System.Windows.Controls.Canvas]::SetLeft($tb, $lx - 14)
            [System.Windows.Controls.Canvas]::SetTop($tb, $ly - 9)
            [void]$Canvas.Children.Add($tb)
        }
        $startAngle += $sweep
    }
}

function _DrawPieLegend {
    param(
        [System.Windows.Controls.Panel]$Panel,
        [string[]]$Labels,
        [double[]]$Values,
        [string[]]$Colors
    )
    if (-not $Panel) { return }
    $Panel.Children.Clear()
    $total = 0.0; foreach ($v in $Values) { $total += $v }
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.Margin = '0,3,0,3'
        $sw = New-Object System.Windows.Shapes.Rectangle
        $sw.Width = 16; $sw.Height = 16; $sw.Margin = '0,0,6,0'
        $sw.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Colors[$i])
        $sw.Stroke = [System.Windows.Media.Brushes]::Gainsboro
        [void]$sp.Children.Add($sw)
        $tb = New-Object System.Windows.Controls.TextBlock
        $v = [double]$Values[$i]
        $pct = if ($total -gt 0) { ($v / $total) * 100.0 } else { 0.0 }
        $tb.Text = "{0} : {1:N1} h ({2:N1}%)" -f $Labels[$i], $v, $pct
        $tb.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($tb)
        [void]$Panel.Children.Add($sp)
    }
}

# ---- 共通カラーパレット ----
$Script:_ChartPalette = @(
    '#0369a1','#059669','#d97706','#7c3aed','#db2777',
    '#0891b2','#16a34a','#ea580c','#9333ea','#0284c7',
    '#65a30d','#c2410c','#a16207','#4338ca','#be123c'
)

# 大量のシリーズを Top N + 「その他」に丸める
function _TopNCollapse {
    param([string[]]$Labels, [double[]]$Values, [int]$TopN = 8)
    if ($Labels.Count -le $TopN) {
        return @{ Labels = $Labels; Values = $Values }
    }
    # hours 降順で並べ、Top-1 件を採用し、残りを「その他」に合算
    $pairs = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        [void]$pairs.Add([pscustomobject]@{ Label = $Labels[$i]; Value = [double]$Values[$i] })
    }
    $sorted = @($pairs | Sort-Object -Property Value -Descending)
    $head = $sorted | Select-Object -First ($TopN - 1)
    $tail = $sorted | Select-Object -Skip ($TopN - 1)
    $otherSum = 0.0; foreach ($t in $tail) { $otherSum += [double]$t.Value }
    $newLabels = New-Object 'System.Collections.Generic.List[string]'
    $newValues = New-Object 'System.Collections.Generic.List[double]'
    foreach ($h in $head) { [void]$newLabels.Add([string]$h.Label); [void]$newValues.Add([double]$h.Value) }
    [void]$newLabels.Add('(その他)')
    [void]$newValues.Add($otherSum)
    return @{ Labels = $newLabels.ToArray(); Values = $newValues.ToArray() }
}

# ---- 月別 積上棒グラフ ----
# $Data: hashtable[xLabel][seriesLabel] = double 工数
function _DrawStackedBarChart {
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [string[]]$XLabels,        # 並び順を保持
        [string[]]$SeriesLabels,   # 系列順 (色配列と対応)
        $Data,                     # @{ x -> @{ series -> hours } }
        [string[]]$Colors
    )
    if (-not $Canvas) { return }
    $Canvas.Children.Clear()
    if ($XLabels.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '(該当月なし)'; $tb.Foreground = [System.Windows.Media.Brushes]::Gray
        [System.Windows.Controls.Canvas]::SetLeft($tb, 10); [System.Windows.Controls.Canvas]::SetTop($tb, 80)
        [void]$Canvas.Children.Add($tb)
        return
    }
    $w = [double]$Canvas.Width;  if ($w -le 0) { $w = 600 }
    $h = [double]$Canvas.Height; if ($h -le 0) { $h = 200 }
    $padLeft = 36; $padBottom = 30; $padTop = 8; $padRight = 8
    $plotW = $w - $padLeft - $padRight
    $plotH = $h - $padTop - $padBottom

    # 各 X の合計を出して最大値スケール
    $sums = @{}
    $maxSum = 0.0
    foreach ($x in $XLabels) {
        $s = 0.0
        if ($Data.ContainsKey($x)) {
            foreach ($k in $Data[$x].Keys) { $s += [double]$Data[$x][$k] }
        }
        $sums[$x] = $s
        if ($s -gt $maxSum) { $maxSum = $s }
    }
    if ($maxSum -le 0) { $maxSum = 1 }

    # 軸 (Y 0 と最大ライン)
    $axis = New-Object System.Windows.Shapes.Line
    $axis.X1 = $padLeft; $axis.X2 = $padLeft; $axis.Y1 = $padTop; $axis.Y2 = $padTop + $plotH
    $axis.Stroke = [System.Windows.Media.Brushes]::Gray; $axis.StrokeThickness = 1
    [void]$Canvas.Children.Add($axis)
    $base = New-Object System.Windows.Shapes.Line
    $base.X1 = $padLeft; $base.X2 = $padLeft + $plotW; $base.Y1 = $padTop + $plotH; $base.Y2 = $padTop + $plotH
    $base.Stroke = [System.Windows.Media.Brushes]::Gray; $base.StrokeThickness = 1
    [void]$Canvas.Children.Add($base)
    # Y 軸目盛 (max + max/2)
    foreach ($r in @(0.0, 0.5, 1.0)) {
        $yy = $padTop + (1 - $r) * $plotH
        $val = $maxSum * $r
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "{0:N0}" -f $val; $tb.FontSize = 9; $tb.Foreground = [System.Windows.Media.Brushes]::Gray
        [System.Windows.Controls.Canvas]::SetLeft($tb, 0); [System.Windows.Controls.Canvas]::SetTop($tb, $yy - 6)
        [void]$Canvas.Children.Add($tb)
        if ($r -gt 0 -and $r -lt 1) {
            $ln = New-Object System.Windows.Shapes.Line
            $ln.X1 = $padLeft; $ln.X2 = $padLeft + $plotW; $ln.Y1 = $yy; $ln.Y2 = $yy
            $ln.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#e5e7eb')
            $ln.StrokeThickness = 1; $ln.StrokeDashArray = '2,3'
            [void]$Canvas.Children.Add($ln)
        }
    }

    $barGap = 6
    $barW = ($plotW - ($XLabels.Count - 1) * $barGap) / [Math]::Max(1, $XLabels.Count)
    if ($barW -gt 40) { $barW = 40 }
    if ($barW -lt 8) { $barW = 8 }

    for ($i = 0; $i -lt $XLabels.Count; $i++) {
        $x = $XLabels[$i]
        $bx = $padLeft + $i * ($barW + $barGap)
        $stackTop = $padTop + $plotH    # 下から積み上げ
        if ($Data.ContainsKey($x)) {
            for ($s = 0; $s -lt $SeriesLabels.Count; $s++) {
                $sl = $SeriesLabels[$s]
                $hv = 0.0
                if ($Data[$x].ContainsKey($sl)) { $hv = [double]$Data[$x][$sl] }
                if ($hv -le 0) { continue }
                $segH = ($hv / $maxSum) * $plotH
                $rect = New-Object System.Windows.Shapes.Rectangle
                $rect.Width = $barW; $rect.Height = $segH
                $rect.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Colors[$s % $Colors.Count])
                $rect.Stroke = [System.Windows.Media.Brushes]::White; $rect.StrokeThickness = 0.5
                $rect.ToolTip = ("{0}  {1}  {2:N1}h" -f $x, $sl, $hv)
                [System.Windows.Controls.Canvas]::SetLeft($rect, $bx)
                [System.Windows.Controls.Canvas]::SetTop($rect, $stackTop - $segH)
                [void]$Canvas.Children.Add($rect)
                $stackTop -= $segH
            }
        }
        # X ラベル
        $lab = New-Object System.Windows.Controls.TextBlock
        $lab.Text = $x; $lab.FontSize = 9; $lab.TextAlignment = 'Center'; $lab.Width = $barW
        [System.Windows.Controls.Canvas]::SetLeft($lab, $bx)
        [System.Windows.Controls.Canvas]::SetTop($lab, $padTop + $plotH + 3)
        [void]$Canvas.Children.Add($lab)
        # 合計値ラベル (上部)
        if ($sums[$x] -gt 0) {
            $sumLab = New-Object System.Windows.Controls.TextBlock
            $sumLab.Text = ("{0:N0}" -f $sums[$x]); $sumLab.FontSize = 9
            $sumLab.Foreground = [System.Windows.Media.Brushes]::DimGray
            $sumLab.TextAlignment = 'Center'; $sumLab.Width = $barW
            [System.Windows.Controls.Canvas]::SetLeft($sumLab, $bx)
            [System.Windows.Controls.Canvas]::SetTop($sumLab, $stackTop - 12)
            [void]$Canvas.Children.Add($sumLab)
        }
    }
}

function Build-WorkTypeMix {
    param($Rows)
    if (-not $u.WorkTypeKpiPanel -or -not $u.WorkTypeByMemberGrid) { return }
    $u.WorkTypeKpiPanel.Children.Clear()
    if ($u.WorkTypePieCanvas)  { $u.WorkTypePieCanvas.Children.Clear() }
    if ($u.WorkTypePieLegend) { $u.WorkTypePieLegend.Children.Clear() }
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

    # 円グラフ (チーム全体の業務種別比率)
    $pieLabels = @('案件対応','維持運用','その他')
    $vCase  = if ($byType.ContainsKey('案件対応')) { [double]$byType['案件対応'] } else { 0.0 }
    $vOps   = if ($byType.ContainsKey('維持運用')) { [double]$byType['維持運用'] } else { 0.0 }
    $vOther = if ($byType.ContainsKey('その他'))   { [double]$byType['その他']   } else { 0.0 }
    $pieValues = @([double]$vCase, [double]$vOps, [double]$vOther)
    $pieColors = @('#0369a1','#059669','#7c3aed')
    if ($u.WorkTypePieCanvas)  { _DrawPieChart  -Canvas $u.WorkTypePieCanvas -Labels $pieLabels -Values $pieValues -Colors $pieColors }
    if ($u.WorkTypePieLegend) { _DrawPieLegend -Panel  $u.WorkTypePieLegend -Labels $pieLabels -Values $pieValues -Colors $pieColors }

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
    Set-PivotGrid -Grid $u.WorkTypeByMemberGrid -Rows $rowsOut
}

# ---- 業務種別ドリルダウン共通ヘルパ ----
# プロジェクトコードから work_type / project_name / target_system を解決
function _ProjectAttr {
    param([string]$ProjCode, [string]$Attr)
    $p = $Script:Projects | Where-Object { [string]$_.unit_code -eq $ProjCode } | Select-Object -First 1
    if (-not $p) { return '' }
    return [string]$p.$Attr
}

# 行ラベルの表示文字列
function _RowLabelForCase {
    param([string]$Code)
    $n = _ProjectAttr -ProjCode $Code -Attr 'project_name'
    if ($n) { return "$Code  $n" }
    return $Code
}
function _RowLabelForOps {
    param([string]$System)
    if ([string]::IsNullOrWhiteSpace($System)) { return '(target_system 未設定)' }
    return $System
}

# 業務種別 × 任意軸 (工程 or タスクグループ) のクロス集計を共通生成
function _BuildWorkTypeDrillDown {
    param(
        $Rows,
        [string]$WorkType,         # '案件対応' または '維持運用'
        [string]$ColAxis,          # '工程' or 'タスクグループ' or 'タスク'
        [scriptblock]$RowKeyFn,    # entry → 行キー (code)
        [scriptblock]$RowLabelFn,  # row key → 表示
        $Grid,
        $PieCanvas = $null,        # 軸別 工数比率の円グラフ (任意)
        $PieLegend = $null,        # 円グラフ凡例 (任意)
        $BarCanvas = $null         # 月別 積上棒グラフ (任意)
    )
    # 描画キャンバスはクリアしておく
    if ($PieCanvas) { $PieCanvas.Children.Clear() }
    if ($PieLegend) { $PieLegend.Children.Clear() }
    if ($BarCanvas) { $BarCanvas.Children.Clear() }
    if (-not $Grid) { return }
    $Grid.Columns.Clear()
    $Grid.ItemsSource = $null
    if (-not $Rows -or $Rows.Count -eq 0) { return }

    # 列キー: entries の process_code / task_group_code / task_code
    # ヘッダ表示は code → 名称も併記
    $colKey = switch ($ColAxis) {
        'タスクグループ' { 'task_group_code' }
        'タスク'         { 'task_code' }
        default          { 'process_code' }
    }
    $colNameFn = switch ($ColAxis) {
        'タスクグループ' { { param($c) Resolve-TaskGroupName $c } }
        'タスク'         { { param($c) Resolve-TaskName $c } }
        default          { { param($c) Resolve-ProcessName $c } }
    }

    # フィルタ: 業務種別が一致するエントリのみ
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        $wt = _ProjectWorkType ([string]$r.project_code)
        if ($wt -eq $WorkType) { [void]$filtered.Add($r) }
    }
    if ($filtered.Count -eq 0) {
        Set-PivotGrid -Grid $Grid -Rows @([ordered]@{ '行' = "($WorkType の実績なし)" })
        return
    }

    $rowKeys = @($filtered | ForEach-Object { & $RowKeyFn $_ } | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $colKeys = @($filtered | ForEach-Object { [string]$_.$colKey } | Where-Object { $_ } | Sort-Object -Unique)
    if ($rowKeys.Count -eq 0 -or $colKeys.Count -eq 0) { return }

    # 集計
    $cell = @{}  # rowKey -> { colKey -> hours }
    foreach ($r in $filtered) {
        $rk = [string](& $RowKeyFn $r); $ck = [string]$r.$colKey
        if (-not $rk -or -not $ck) { continue }
        if (-not $cell.ContainsKey($rk)) { $cell[$rk] = @{} }
        if (-not $cell[$rk].ContainsKey($ck)) { $cell[$rk][$ck] = 0.0 }
        $cell[$rk][$ck] += [double]$r.hours
    }

    $rowLabel = if ($WorkType -eq '案件対応') { 'プロジェクト' } else { '対象システム' }
    # 列表示ヘッダ: code + name 形式 (Resolve-* で名称を引く)
    $colHeaders = @{}
    foreach ($ck in $colKeys) {
        $name = & $colNameFn $ck
        $colHeaders[$ck] = _MergeCodeName $ck $name
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rk in $rowKeys) {
        $row = [ordered]@{ $rowLabel = (& $RowLabelFn $rk) }
        $tot = 0.0
        foreach ($ck in $colKeys) {
            $h = if ($cell[$rk] -and $cell[$rk].ContainsKey($ck)) { [double]$cell[$rk][$ck] } else { 0.0 }
            $row[$colHeaders[$ck]] = if ($h -gt 0) { "{0:N1}" -f $h } else { '' }
            $tot += $h
        }
        $row['合計'] = "{0:N1}" -f $tot
        $out.Add([pscustomobject]$row)
    }
    # フッタ: 列合計
    $footer = [ordered]@{ $rowLabel = '◆ 列合計' }
    $grand = 0.0
    foreach ($ck in $colKeys) {
        $sum = 0.0
        foreach ($rk in $rowKeys) {
            if ($cell[$rk] -and $cell[$rk].ContainsKey($ck)) { $sum += [double]$cell[$rk][$ck] }
        }
        $footer[$colHeaders[$ck]] = "{0:N1}" -f $sum
        $grand += $sum
    }
    $footer['合計'] = "{0:N1}" -f $grand
    $out.Add([pscustomobject]$footer)

    Set-PivotGrid -Grid $Grid -Rows $out

    # ---- 円グラフ: 軸 (列) ごとの工数比率 (Top 8 + その他) ----
    if ($PieCanvas -or $PieLegend) {
        $colTotals = New-Object 'System.Collections.Generic.List[double]'
        $colLbls   = New-Object 'System.Collections.Generic.List[string]'
        foreach ($ck in $colKeys) {
            $sum = 0.0
            foreach ($rk in $rowKeys) {
                if ($cell[$rk] -and $cell[$rk].ContainsKey($ck)) { $sum += [double]$cell[$rk][$ck] }
            }
            if ($sum -gt 0) {
                [void]$colLbls.Add($colHeaders[$ck])
                [void]$colTotals.Add($sum)
            }
        }
        $collapsed = _TopNCollapse -Labels $colLbls.ToArray() -Values $colTotals.ToArray() -TopN 8
        $palette = $Script:_ChartPalette
        $usedColors = @()
        for ($i = 0; $i -lt $collapsed.Labels.Count; $i++) {
            $usedColors += $palette[$i % $palette.Count]
        }
        if ($PieCanvas) { _DrawPieChart  -Canvas $PieCanvas -Labels $collapsed.Labels -Values $collapsed.Values -Colors $usedColors }
        if ($PieLegend) { _DrawPieLegend -Panel  $PieLegend -Labels $collapsed.Labels -Values $collapsed.Values -Colors $usedColors }
    }

    # ---- 月別 積上棒グラフ: X=月 / 系列=軸 (col) ----
    if ($BarCanvas) {
        # 月キー + 軸別集計
        $byMonth = @{}    # ym -> @{ colHeader -> hours }
        $monthSet = New-Object 'System.Collections.Generic.SortedSet[string]'
        foreach ($r in $filtered) {
            $d = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$r.date, [ref]$d)) { continue }
            $ym = $d.ToString('yyyy-MM')
            $ck = [string]$r.$colKey
            if (-not $ck) { continue }
            $colDisplay = $colHeaders[$ck]
            if (-not $byMonth.ContainsKey($ym)) { $byMonth[$ym] = @{} }
            if (-not $byMonth[$ym].ContainsKey($colDisplay)) { $byMonth[$ym][$colDisplay] = 0.0 }
            $byMonth[$ym][$colDisplay] += [double]$r.hours
            [void]$monthSet.Add($ym)
        }
        # 系列は colHeaders の値だが、Top N に合わせて絞る
        $allSeriesLbls = $colKeys | ForEach-Object { $colHeaders[$_] }
        # 系列ごとの合計
        $seriesTotals = @{}
        foreach ($sl in $allSeriesLbls) { $seriesTotals[$sl] = 0.0 }
        foreach ($ym in $byMonth.Keys) {
            foreach ($k in $byMonth[$ym].Keys) {
                if ($seriesTotals.ContainsKey($k)) { $seriesTotals[$k] += [double]$byMonth[$ym][$k] }
            }
        }
        # Top 8 系列 + その他
        $topSeries = @($seriesTotals.GetEnumerator() | Where-Object { $_.Value -gt 0 } |
                       Sort-Object -Property Value -Descending | Select-Object -First 8 |
                       ForEach-Object { $_.Key })
        $hasOther = ($allSeriesLbls.Count -gt $topSeries.Count)
        $seriesLabels = if ($hasOther) { $topSeries + '(その他)' } else { $topSeries }
        # データを丸める: topSeries に含まれないものは「(その他)」に合算
        $barData = @{}
        foreach ($ym in $monthSet) {
            $barData[$ym] = @{}
            foreach ($sl in $seriesLabels) { $barData[$ym][$sl] = 0.0 }
            if ($byMonth.ContainsKey($ym)) {
                foreach ($k in $byMonth[$ym].Keys) {
                    if ($topSeries -contains $k) {
                        $barData[$ym][$k] += [double]$byMonth[$ym][$k]
                    } elseif ($hasOther) {
                        $barData[$ym]['(その他)'] += [double]$byMonth[$ym][$k]
                    }
                }
            }
        }
        $palette = $Script:_ChartPalette
        $colors = @()
        for ($i = 0; $i -lt $seriesLabels.Count; $i++) {
            $colors += $palette[$i % $palette.Count]
        }
        _DrawStackedBarChart -Canvas $BarCanvas `
            -XLabels @($monthSet) -SeriesLabels $seriesLabels -Data $barData -Colors $colors
    }
}

# 案件対応 (行=プロジェクト)
function Build-CaseAnalysis {
    param($Rows)
    $axis = '工程'
    if ($u.CaseAxisCombo -and $u.CaseAxisCombo.SelectedItem) {
        $axis = [string]$u.CaseAxisCombo.SelectedItem.Content
    }
    _BuildWorkTypeDrillDown -Rows $Rows -WorkType '案件対応' -ColAxis $axis `
        -RowKeyFn   { param($e) [string]$e.project_code } `
        -RowLabelFn { param($k) _RowLabelForCase $k } `
        -Grid $u.CaseAnalysisGrid `
        -PieCanvas $u.CasePieCanvas -PieLegend $u.CasePieLegend -BarCanvas $u.CaseBarCanvas
}

# 維持運用 (行=対象システム)
function Build-OpsAnalysis {
    param($Rows)
    $axis = '工程'
    if ($u.OpsAxisCombo -and $u.OpsAxisCombo.SelectedItem) {
        $axis = [string]$u.OpsAxisCombo.SelectedItem.Content
    }
    _BuildWorkTypeDrillDown -Rows $Rows -WorkType '維持運用' -ColAxis $axis `
        -RowKeyFn   { param($e) _ProjectAttr -ProjCode ([string]$e.project_code) -Attr 'target_system' } `
        -RowLabelFn { param($k) _RowLabelForOps $k } `
        -Grid $u.OpsAnalysisGrid `
        -PieCanvas $u.OpsPieCanvas -PieLegend $u.OpsPieLegend -BarCanvas $u.OpsBarCanvas
}

# ---- イベントフック ----
# WPF イベント中で未捕捉例外が出ると Dispatcher が落ちてウインドウが消える。
# 全ハンドラを try/catch で包み、エラーは StatusText / MessageBox に出すだけにする。
function _SafeRun {
    param([string]$Tag, [scriptblock]$Body)
    try {
        if ($null -eq $Script:ChartRows) { return }
        & $Body
    } catch {
        $msg = "[$Tag] $($_.Exception.Message)"
        try { $u.SummaryText.Text = $msg } catch { }
        $detail = "$msg`n`n$($_.InvocationInfo.PositionMessage)`n`n$($_.ScriptStackTrace)"
        [System.Windows.MessageBox]::Show($detail, "$Tag エラー", 'OK', 'Error') | Out-Null
    }
}

if ($u.HeatmapAxisCombo) {
    $u.HeatmapAxisCombo.Add_SelectionChanged({ _SafeRun 'Heatmap'        { Build-Heatmap          -Rows $Script:ChartRows } })
}
if ($u.LoadRefreshBtn) {
    $u.LoadRefreshBtn.Add_Click({          _SafeRun 'MemberLoad'     { Build-MemberLoad       -Rows $Script:ChartRows } })
}
if ($u.CaseAxisCombo) {
    $u.CaseAxisCombo.Add_SelectionChanged({ _SafeRun 'CaseAnalysis'   { Build-CaseAnalysis     -Rows (_ApplyWorkTypeFilters $Script:ChartRows) } })
}
if ($u.OpsAxisCombo) {
    $u.OpsAxisCombo.Add_SelectionChanged({  _SafeRun 'OpsAnalysis'    { Build-OpsAnalysis      -Rows (_ApplyWorkTypeFilters $Script:ChartRows) } })
}
# 業務種別比率タブ内 専用 フィルタ変更 → 3 集計を再描画
if ($u.WorkTypeSystemFilter) {
    $u.WorkTypeSystemFilter.Add_SelectionChanged({ _SafeRun 'WorkTypeFilter' {
        $r = _ApplyWorkTypeFilters $Script:ChartRows
        Build-WorkTypeMix    -Rows $r
        Build-CaseAnalysis   -Rows $r
        Build-OpsAnalysis    -Rows $r
    } })
}
if ($u.WorkTypeProjectFilter) {
    $u.WorkTypeProjectFilter.Add_SelectionChanged({ _SafeRun 'WorkTypeFilter' {
        $r = _ApplyWorkTypeFilters $Script:ChartRows
        Build-WorkTypeMix    -Rows $r
        Build-CaseAnalysis   -Rows $r
        Build-OpsAnalysis    -Rows $r
    } })
}

# Apply-Filters の Step 配列を呼べないので、Apply-Filters の末尾で再描画するために
# wrapper を新設する。元の Apply-Filters は ChartRows をセットするので、その後に
# 拡張集計を呼ぶ。
# wrapper 用の module-level トレース (Apply-Filters 内の nested _Trace と同じ
# ファイルに書く。どこで落ちているか確実に追跡するため try で囲まない)
function _TraceMgr {
    param([string]$Tag, [string]$Msg)
    try {
        $logDir = Join-Path $env:APPDATA 'worktime-tracker'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $logDir 'report_trace.log') `
            -Value ("[{0}] [mgr] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
    } catch { }
}

$origApply = ${function:Apply-Filters}
function Apply-Filters {
    & $origApply
    _TraceMgr 'wrapper' 'begin'
    foreach ($step in @(
        @{N='MemberLoad';          S={ Build-MemberLoad          -Rows $Script:ChartRows }},
        @{N='MemberProjectMatrix'; S={ Build-MemberProjectMatrix -Rows $Script:ChartRows }},
        @{N='WorkTypeMix';         S={ Build-WorkTypeMix         -Rows (_ApplyWorkTypeFilters $Script:ChartRows) }},
        @{N='CaseAnalysis';        S={ Build-CaseAnalysis        -Rows (_ApplyWorkTypeFilters $Script:ChartRows) }},
        @{N='OpsAnalysis';         S={ Build-OpsAnalysis         -Rows (_ApplyWorkTypeFilters $Script:ChartRows) }}
    )) {
        _TraceMgr $step.N 'begin'
        try { & $step.S; _TraceMgr $step.N 'ok' }
        catch {
            _TraceMgr $step.N ("ERROR: $($_.Exception.Message) / $($_.ScriptStackTrace)")
            Write-FatalLog ("[$($step.N)] $($_.Exception.Message)`r`n$($_.ScriptStackTrace)")
            try {
                $u.SummaryText.Text = "[$($step.N)] $($_.Exception.Message)"
            } catch { }
        }
    }
    _TraceMgr 'wrapper' 'end'
}

Reload-Entries

[void]$win.ShowDialog()
