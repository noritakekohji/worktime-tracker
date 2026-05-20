# WbsInput.ps1 — WBS 形式実績入力
#
# 起動: client\WbsInput.cmd  または
#        powershell -ExecutionPolicy Bypass -File client\WbsInput.ps1
#
# WorkTimeTracker.ps1 と同じ設定ファイル/ストアを共有する。
# WorkTimeTracker.ps1 で設定済みであることが前提。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')

trap {
    $msg = "$($_.Exception.Message)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
    try { [System.Windows.MessageBox]::Show($msg, 'WBS 入力 - エラー', 'OK', 'Error') | Out-Null }
    catch { Write-Host $msg -ForegroundColor Red; Read-Host '終了するには Enter を押してください' }
    exit 1
}

# ---- 設定読込 ----
$cfg = Load-Config
if (-not (Test-ConfigComplete -Config $cfg)) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "設定が未完了です。`nWorkTimeTracker を起動して設定を完了させてから再度起動してください。",
        '設定未完了', 'OK', 'Warning') | Out-Null
    exit 1
}
$token = $null
if ($cfg.mode -eq 'gitlab') { $token = Get-GitLabToken }
$Script:Source = New-DataSource -Config $cfg -Token $token
$Script:Config = $cfg

# ---- マスタ読込 ----
function _LoadMasters {
    $Script:Members      = @(Get-MasterMembers      -Source $Script:Source)
    $Script:Projects     = @(Get-MasterProjects     -Source $Script:Source | Where-Object { $_.active })
    $Script:Categories   = @(Get-MasterCategories   -Source $Script:Source)
    $Script:TaskPatterns = @(Get-MasterTaskPatterns -Source $Script:Source)
}
_LoadMasters

# ---- XAML 読込 ----
$xamlPath = Join-Path $PSScriptRoot 'WbsInput.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in @('ProjectCombo','YearCombo','MonthCombo','MemberCombo','LoadBtn',
                  'SaveBtn','PushBtn','WbsTree','WbsGrid','AddRowBtn','GridTitle','StatusText')) {
    $ui[$n] = $Script:Window.FindName($n)
}

function Set-Status {
    param([string]$Msg, [string]$Color = '#6b7280')
    $ui.StatusText.Text = $Msg
    $ui.StatusText.Foreground = $Color
}

# ---- 初期 UI セット ----
$now = Get-Date
$ui.YearCombo.ItemsSource  = ($now.Year - 2)..($now.Year + 1)
$ui.YearCombo.SelectedItem = $now.Year
$ui.MonthCombo.ItemsSource  = 1..12
$ui.MonthCombo.SelectedItem = $now.Month

# プロジェクト ComboBox
# PS 5.1: 文字列内の "$var (..." は $var(...) と誤解析されるため文字列連結を使う
#         文字列内の "[$var]" も型キャストと誤解析されるため同様
$projItems = @($Script:Projects | ForEach-Object {
    $uc   = if ($_.unit_code)    { [string]$_.unit_code }    else { [string]$_.id }
    $pn   = if ($_.project_name) { [string]$_.project_name } else { [string]$_.name }
    $un   = [string]$_.unit_name
    $disp = if ($un) { '[' + $uc + '] ' + $pn + ' (' + $un + ')' } else { '[' + $uc + '] ' + $pn }
    [pscustomobject]@{
        unit_code       = $uc
        project_name    = $pn
        unit_name       = $un
        task_pattern_id = [string]$_.task_pattern_id
        display         = $disp
    }
})
$ui.ProjectCombo.ItemsSource = $projItems

# 担当者 ComboBox — 全メンバーを表示 (WBS は担当者を選んで閲覧するため)
$currentMember = $Script:Members | Where-Object { $_.id -eq $cfg.member_id -and $_.active } | Select-Object -First 1
$memberItems = @($Script:Members | Where-Object { $_.active } | ForEach-Object {
    $mid = [string]$_.id; $mnm = [string]$_.name; $mdisp = $mid + '  ' + $mnm
    [pscustomobject]@{ id=$mid; name=$mnm; display=$mdisp }
})
if ($memberItems.Count -eq 0) {
    # マスタになければ設定値から自分だけ追加
    $mid = $cfg.member_id; $mnm = '(自分)'
    $memberItems = @([pscustomobject]@{ id=$mid; name=$mnm; display="$mid  $mnm" })
}
$ui.MemberCombo.ItemsSource = $memberItems
# 現在のメンバーを初期選択
$selIdx = 0
for ($i = 0; $i -lt $memberItems.Count; $i++) {
    if ($memberItems[$i].id -eq $cfg.member_id) { $selIdx = $i; break }
}
$ui.MemberCombo.SelectedIndex = $selIdx

# Gitlab モードなら送信ボタン表示
if ($Script:Source.RemoteCtx) { $ui.PushBtn.Visibility = 'Visible' }

# ---- 状態変数 ----
$Script:DataTable   = $null
$Script:CurrentProj = $null
$Script:CurrentPtn  = $null

# ---- ヘルパ関数 ----
function Get-TaskPatternFor {
    param($Project)
    if (-not $Project) { return $null }
    $ptnId = [string]$Project.task_pattern_id
    if (-not $ptnId) { return $null }
    return ($Script:TaskPatterns | Where-Object { $_.id -eq $ptnId } | Select-Object -First 1)
}

function Build-DataTable {
    param([int]$Year, [int]$Month)
    $tbl = New-Object 'System.Data.DataTable'
    if ($null -eq $tbl) { throw 'New-Object System.Data.DataTable returned null' }

    $stringType = [System.String]
    $allCols = @('_pc','_tgc','_tc','工程','タスクグループ','タスク','カテゴリ','合計')
    foreach ($name in $allCols) {
        $dc = New-Object 'System.Data.DataColumn' -ArgumentList $name, $stringType
        $null = $tbl.Columns.Add($dc)
    }
    $days = [DateTime]::DaysInMonth($Year, $Month)
    for ($d = 1; $d -le $days; $d++) {
        $key = '{0:D4}-{1:D2}-{2:D2}' -f $Year, $Month, $d
        $dc = New-Object 'System.Data.DataColumn' -ArgumentList $key, $stringType
        $null = $tbl.Columns.Add($dc)
    }
    # 戻り値の auto-unroll を防止
    Write-Output -NoEnumerate $tbl
}

function Update-AllTotals {
    if (-not $Script:DataTable) { return }
    $dateCols = @($Script:DataTable.Columns | Where-Object { $_.ColumnName -match '^\d{4}-\d{2}-\d{2}$' })
    foreach ($row in $Script:DataTable.Rows) {
        $total = 0.0
        foreach ($col in $dateCols) {
            $v = $row[$col.ColumnName]; $d = 0.0
            if (-not [string]::IsNullOrWhiteSpace($v) -and [double]::TryParse([string]$v, [ref]$d)) { $total += $d }
        }
        $row["合計"] = if ($total -gt 0) { $total.ToString("N1") } else { "" }
    }
}

function Build-GridColumns {
    param($Grid, [int]$Year, [int]$Month)
    $Grid.Columns.Clear()

    # ---- 固定列 (Style/Setter を使わずシンプルに) ----
    $fixedDef = @(
        @{H="工程";           B="[工程]";           W=80;  RO=$true  },
        @{H="タスクグループ"; B="[タスクグループ]"; W=110; RO=$true  },
        @{H="タスク";         B="[タスク]";         W=110; RO=$true  },
        @{H="カテゴリ";       B="[カテゴリ]";       W=80;  RO=$false },
        @{H="合計";           B="[合計]";           W=52;  RO=$true  }
    )
    foreach ($fd in $fixedDef) {
        $col = New-Object System.Windows.Controls.DataGridTextColumn
        $col.Header     = $fd.H
        $col.Binding    = New-Object System.Windows.Data.Binding $fd.B
        $col.Width      = $fd.W
        $col.IsReadOnly = $fd.RO
        $Grid.Columns.Add($col)
    }
    $Grid.FrozenColumnCount = $fixedDef.Count

    # ---- 日付列 ----
    $days = [DateTime]::DaysInMonth($Year, $Month)
    for ($d = 1; $d -le $days; $d++) {
        $dtObj = [DateTime]::new($Year, $Month, $d)
        $key   = "{0:D4}-{1:D2}-{2:D2}" -f $Year, $Month, $d
        $dow   = $dtObj.DayOfWeek

        $col = New-Object System.Windows.Controls.DataGridTextColumn
        # 土日はヘッダに曜日表示 (スタイルは使わず文字で区別)
        $col.Header     = if ($dow -eq 'Saturday') { "$d(土)" } elseif ($dow -eq 'Sunday') { "$d(日)" } else { $d.ToString() }
        $col.Binding    = New-Object System.Windows.Data.Binding "[$key]"
        $col.Width      = 46
        $col.IsReadOnly = $false
        $Grid.Columns.Add($col)
    }
}

function _MakeRow {
    # PS 5.1: パラメータ名を $dt にすると、呼び出し元ローカル $dt とバインディング衝突する事象があるため $Table に改名
    param($Table, [string]$pc, [string]$pn, [string]$tgc, [string]$tgn, [string]$tc, [string]$tn, [string]$cat)
    if ($null -eq $Table) { throw "_MakeRow: Table パラメータが null" }
    $row = $Table.NewRow()
    $row["_pc"] = $pc; $row["_tgc"] = $tgc; $row["_tc"] = $tc
    $row["工程"] = $pn; $row["タスクグループ"] = $tgn; $row["タスク"] = $tn; $row["カテゴリ"] = $cat
    return $row
}

# ---- WBS データ読込 ----
function Load-WbsData {
    $projItem   = $ui.ProjectCombo.SelectedItem
    $memberItem = $ui.MemberCombo.SelectedItem
    if (-not $projItem)   { Set-Status 'プロジェクトを選択してください' '#f59e0b'; return }
    if (-not $memberItem) { Set-Status '担当者を選択してください'       '#f59e0b'; return }

    $projCode  = [string]$projItem.unit_code
    $year      = [int]$ui.YearCombo.SelectedItem
    $month     = [int]$ui.MonthCombo.SelectedItem
    $memberId  = [string]$memberItem.id

    Set-Status "読込中…" '#f9e2af'
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $Script:CurrentProj = $Script:Projects | Where-Object { $null -ne $_ -and ([string]$_.unit_code) -eq $projCode } | Select-Object -First 1
        $Script:CurrentPtn  = Get-TaskPatternFor -Project $Script:CurrentProj

        $dt = Build-DataTable -Year $year -Month $month
        if ($null -eq $dt) { throw "Build-DataTable returned null (year=$year month=$month)" }
        if ($dt -is [array]) {
            throw ("Build-DataTable returned array (count={0}, type[0]={1}). PSバージョン={2}" -f `
                $dt.Count, ($dt[0].GetType().FullName), $PSVersionTable.PSVersion)
        }

        # 既存エントリ読込
        $loaded      = @(Load-MonthEntries -Source $Script:Source -MemberId $memberId -Year $year -Month $month)
        $projEntries = @($loaded | Where-Object { $null -ne $_ -and ([string]$_.project_code) -eq $projCode })

        $addedKeys = New-Object 'System.Collections.Generic.HashSet[string]'

        # タスクパターンから全タスクを展開
        if ($Script:CurrentPtn -and $Script:CurrentPtn.processes) {
            foreach ($proc in @($Script:CurrentPtn.processes)) {
                if (-not $proc) { continue }
                foreach ($tg in @($proc.task_groups)) {
                    if (-not $tg) { continue }
                    foreach ($tk in @($tg.tasks)) {
                        if (-not $tk) { continue }
                        $pc = [string]$proc.code; $pn = [string]$proc.name
                        $tgc = [string]$tg.code;  $tgn = [string]$tg.name
                        $tc  = [string]$tk.code;  $tn  = [string]$tk.name

                        # このタスクの既存エントリをカテゴリ別に集約
                        $taskEntries = @($projEntries | Where-Object {
                            $null -ne $_ -and
                            ([string]$_.process_code) -eq $pc -and
                            ([string]$_.task_group_code) -eq $tgc -and
                            ([string]$_.task_code) -eq $tc
                        })
                        $catMap = @{}
                        foreach ($e in $taskEntries) {
                            if (-not $e) { continue }
                            $cat = [string]$e.category
                            if (-not $catMap.ContainsKey($cat)) {
                                $catMap[$cat] = New-Object 'System.Collections.Generic.List[object]'
                            }
                            [void]$catMap[$cat].Add($e)
                        }

                        if ($catMap.Count -gt 0) {
                            foreach ($cat in $catMap.Keys) {
                                # インラインで行作成 (関数呼び出し時の $dt スコープ問題を回避)
                                $row = $dt.NewRow()
                                $row["_pc"] = $pc; $row["_tgc"] = $tgc; $row["_tc"] = $tc
                                $row["工程"] = $pn; $row["タスクグループ"] = $tgn; $row["タスク"] = $tn; $row["カテゴリ"] = $cat
                                foreach ($e in $catMap[$cat]) {
                                    $dk = [string]$e.date
                                    if ($dt.Columns.Contains($dk)) {
                                        $h = 0.0; [void][double]::TryParse([string]$e.hours, [ref]$h)
                                        if ($h -gt 0) { $row[$dk] = $h.ToString("N1") }
                                    }
                                }
                                [void]$dt.Rows.Add($row)
                                [void]$addedKeys.Add("$pc|$tgc|$tc|$cat")
                            }
                        } else {
                            # 実績なし → カテゴリ空白行 (インライン)
                            $row = $dt.NewRow()
                            $row["_pc"] = $pc; $row["_tgc"] = $tgc; $row["_tc"] = $tc
                            $row["工程"] = $pn; $row["タスクグループ"] = $tgn; $row["タスク"] = $tn; $row["カテゴリ"] = ''
                            [void]$dt.Rows.Add($row)
                        }
                    }
                }
            }
        }

        # タスクパターンに含まれないエントリ (旧データ / パターンなしプロジェクト)
        foreach ($e in $projEntries) {
            if (-not $e) { continue }
            $pc = [string]$e.process_code; $tgc = [string]$e.task_group_code
            $tc = [string]$e.task_code;    $cat = [string]$e.category
            $key = "$pc|$tgc|$tc|$cat"
            if ($addedKeys.Contains($key)) { continue }
            # インラインで行作成
            $row = $dt.NewRow()
            $row["_pc"] = $pc; $row["_tgc"] = $tgc; $row["_tc"] = $tc
            $row["工程"] = ''; $row["タスクグループ"] = ''; $row["タスク"] = ''; $row["カテゴリ"] = $cat
            $dk = [string]$e.date
            if ($dt.Columns.Contains($dk)) {
                $h = 0.0; [void][double]::TryParse([string]$e.hours, [ref]$h)
                if ($h -gt 0) { $row[$dk] = $h.ToString("N1") }
            }
            [void]$dt.Rows.Add($row)
            [void]$addedKeys.Add($key)
        }

        $Script:DataTable = $dt
        Update-AllTotals

        Build-GridColumns -Grid $ui.WbsGrid -Year $year -Month $month
        $ui.WbsGrid.ItemsSource = $dt.DefaultView

        Build-WbsTree

        $ui.GridTitle.Text = ("📊 {0} — {1:D4}/{2:D2}" -f $projItem.project_name, $year, $month)
        Set-Status ("読込完了: {0} 行" -f $dt.Rows.Count) '#10b981'
    } catch {
        $detail = "$($_.Exception.Message)`n`n--- 位置 ---`n$($_.InvocationInfo.PositionMessage)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
        Set-Status "読込失敗: $($_.Exception.Message)" '#ef4444'
        [System.Windows.MessageBox]::Show($detail, '読込エラー詳細', 'OK', 'Error') | Out-Null
    } finally {
        $Script:Window.Cursor = $null
    }
}

# ---- WBS ツリー構築 ----
function Build-WbsTree {
    $ui.WbsTree.Items.Clear()
    $ui.AddRowBtn.IsEnabled = $false
    if (-not $Script:CurrentPtn -or -not $Script:CurrentPtn.processes) {
        $ti = New-Object System.Windows.Controls.TreeViewItem
        $ti.Header = "(タスクパターンなし)"
        $ti.IsEnabled = $false
        [void]$ui.WbsTree.Items.Add($ti)
        return
    }
    foreach ($proc in @($Script:CurrentPtn.processes)) {
        if (-not $proc) { continue }
        $pi = New-Object System.Windows.Controls.TreeViewItem
        $pi.Header = "⚙ $([string]$proc.name)"; $pi.IsExpanded = $true
        foreach ($tg in @($proc.task_groups)) {
            if (-not $tg) { continue }
            $ti = New-Object System.Windows.Controls.TreeViewItem
            $ti.Header = "🗂 $([string]$tg.name)"; $ti.IsExpanded = $true
            foreach ($tk in @($tg.tasks)) {
                if (-not $tk) { continue }
                $ki = New-Object System.Windows.Controls.TreeViewItem
                $ki.Header = "• $([string]$tk.name)"
                $ki.Tag = [pscustomobject]@{
                    pc=$proc.code; pn=$proc.name
                    tgc=$tg.code;  tgn=$tg.name
                    tc=$tk.code;   tn=$tk.name
                }
                [void]$ti.Items.Add($ki)
            }
            [void]$pi.Items.Add($ti)
        }
        [void]$ui.WbsTree.Items.Add($pi)
    }
}

# ---- イベントハンドラ ----
$ui.LoadBtn.Add_Click({ Load-WbsData })

$ui.WbsTree.Add_SelectedItemChanged({
    $sel = $ui.WbsTree.SelectedItem
    $ui.AddRowBtn.IsEnabled = ($null -ne $sel -and $null -ne $sel.Tag -and $null -ne $Script:DataTable)
})

$ui.AddRowBtn.Add_Click({
    $sel = $ui.WbsTree.SelectedItem
    if (-not $sel -or -not $sel.Tag -or -not $Script:DataTable) { return }
    $info = $sel.Tag
    # インラインで行作成
    $row = $Script:DataTable.NewRow()
    $row["_pc"]  = [string]$info.pc;  $row["_tgc"] = [string]$info.tgc; $row["_tc"] = [string]$info.tc
    $row["工程"] = [string]$info.pn;  $row["タスクグループ"] = [string]$info.tgn
    $row["タスク"] = [string]$info.tn; $row["カテゴリ"] = ''
    [void]$Script:DataTable.Rows.Add($row)
    # 追加行へスクロール
    $ui.WbsGrid.ScrollIntoView($ui.WbsGrid.Items[$ui.WbsGrid.Items.Count - 1])
})

# セル編集後に合計を更新 (CurrentCellChanged は編集確定後に発火)
$ui.WbsGrid.Add_CurrentCellChanged({
    if ($Script:DataTable) { Update-AllTotals }
})

# ---- 保存共通処理 ----
function _BuildEntries {
    param([string]$ProjCode, [int]$Year, [int]$Month, [string]$MemberId)
    $dateCols = @($Script:DataTable.Columns | Where-Object { $_.ColumnName -match '^\d{4}-\d{2}-\d{2}$' })
    $entries  = New-Object System.Collections.Generic.List[object]
    foreach ($drv in $Script:DataTable.DefaultView) {
        $row = $drv.Row
        $pc  = [string]$row["_pc"];  $tgc = [string]$row["_tgc"]
        $tc  = [string]$row["_tc"];  $cat = [string]$row["カテゴリ"]
        foreach ($col in $dateCols) {
            $v = [string]$row[$col.ColumnName]; $h = 0.0
            if ([string]::IsNullOrWhiteSpace($v) -or -not [double]::TryParse($v, [ref]$h) -or $h -le 0) { continue }
            $entries.Add([pscustomobject]@{
                date            = $col.ColumnName
                project_code    = $ProjCode
                process_code    = $pc
                task_group_code = $tgc
                task_code       = $tc
                category        = $cat
                hours           = $h
                comment         = ''
            })
        }
    }
    # 他プロジェクト分を保持してマージ
    $allOld = @(Load-MonthEntries -Source $Script:Source -MemberId $MemberId -Year $Year -Month $Month)
    $other  = @($allOld | Where-Object { [string]$_.project_code -ne $ProjCode })
    return @{
        Merged    = @($other) + @($entries.ToArray())
        NewCount  = $entries.Count
        MemberId  = $MemberId
        Year      = $Year
        Month     = $Month
    }
}

function _DoSave {
    if (-not $Script:DataTable) { throw 'データが読み込まれていません' }
    $projCode   = [string]$ui.ProjectCombo.SelectedItem.unit_code
    $year       = [int]$ui.YearCombo.SelectedItem
    $month      = [int]$ui.MonthCombo.SelectedItem
    $memberItem = $ui.MemberCombo.SelectedItem
    $memberId   = [string]$memberItem.id
    $memberName = [string]$memberItem.name

    $r = _BuildEntries -ProjCode $projCode -Year $year -Month $month -MemberId $memberId
    Save-EntriesGrouped -Source $Script:Source -MemberId $memberId `
        -AllEntries $r.Merged -ViewYear $year -ViewMonth $month `
        -AuthorName $memberName -AuthorEmail "$memberId@worktime-tracker.local"
    return $r
}

$ui.SaveBtn.Add_Click({
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $r = _DoSave
        Set-Status ("保存完了: {0} 件エントリ" -f $r.NewCount) '#10b981'
        [System.Windows.MessageBox]::Show(
            "ローカルに保存しました。`nGitlab にも反映するには「送信」を押してください。",
            '保存完了', 'OK', 'Information') | Out-Null
        Load-WbsData
    } catch {
        Set-Status "保存失敗: $_" '#ef4444'
        [System.Windows.MessageBox]::Show("保存に失敗しました:`n$_", '保存失敗', 'OK', 'Error') | Out-Null
    } finally {
        $Script:Window.Cursor = $null
    }
})

$ui.PushBtn.Add_Click({
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $r = _DoSave
        Set-Status "リモートへ送信中…" '#f9e2af'
        Sync-Push-MyData -Source $Script:Source -MemberId $r.MemberId `
                         -AuthorName $r.MemberId -AuthorEmail "$($r.MemberId)@worktime-tracker.local"
        Set-Status ("送信完了: {0} 件エントリ" -f $r.NewCount) '#10b981'
        [System.Windows.MessageBox]::Show("Gitlab に送信しました。", '送信完了', 'OK', 'Information') | Out-Null
        Load-WbsData
    } catch {
        Set-Status "送信失敗: $_" '#ef4444'
        [System.Windows.MessageBox]::Show("送信に失敗しました:`n$_", '送信失敗', 'OK', 'Error') | Out-Null
    } finally {
        $Script:Window.Cursor = $null
    }
})

[void]$Script:Window.ShowDialog()
