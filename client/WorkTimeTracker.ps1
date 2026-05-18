# WorkTimeTracker.ps1 — クライアント エントリポイント
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File client\WorkTimeTracker.ps1
#
# オプション:
#   -RepoRoot <path>  リポジトリのルート (省略時は自動検出)
#   -MemberId <id>    起動時に選択する作業者 (省略時は1人目)

param(
    [string]$RepoRoot,
    [string]$MemberId
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'lib/Yaml.ps1')
. (Join-Path $PSScriptRoot 'lib/DataStore.ps1')

Initialize-YamlModule

if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath $PSScriptRoot }
Write-Host "Repo root: $RepoRoot" -ForegroundColor Cyan

# ---- マスタ読込 ----
$Script:Members    = @(Get-MasterMembers    -RepoRoot $RepoRoot)
$Script:Projects   = @(Get-MasterProjects   -RepoRoot $RepoRoot)
$Script:Categories = @(Get-MasterCategories -RepoRoot $RepoRoot)

# ---- XAML 読込 ----
$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

# 名前付き要素を変数化
$names = @(
    'MemberCombo','YearCombo','MonthCombo','ReloadBtn','StatusText',
    'EntryDate','ProjectCombo','ProcessCombo','TaskGroupCombo','TaskCombo',
    'CategoryCombo','HoursBox','CommentBox','ClearBtn','AddBtn',
    'EntriesGrid','DeleteRowBtn','SaveBtn','HoursTotalText'
)
$ui = @{}
foreach ($n in $names) { $ui[$n] = $Script:Window.FindName($n) }

# ---- 状態 ----
$Script:Entries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.EntriesGrid.ItemsSource = $Script:Entries

function Update-HoursTotal {
    $sum = 0.0
    foreach ($e in $Script:Entries) {
        $sum += [double]$e.hours
    }
    $ui.HoursTotalText.Text = '月合計: {0:N1} h' -f $sum
}

function Set-Status {
    param([string]$Text, [string]$Color = '#f9e2af')
    $ui.StatusText.Text = $Text
    $ui.StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
}

# ---- 作業者コンボ ----
$memberItems = $Script:Members | Where-Object { $_.active } | ForEach-Object {
    [pscustomobject]@{ id = $_.id; display = "$($_.id) - $($_.name)" }
}
$ui.MemberCombo.ItemsSource = $memberItems
if ($MemberId) {
    $ui.MemberCombo.SelectedValue = $MemberId
} elseif ($memberItems.Count -gt 0) {
    $ui.MemberCombo.SelectedIndex = 0
}

# ---- 年/月コンボ ----
$now = Get-Date
$years = ($now.Year - 2)..($now.Year + 1)
$ui.YearCombo.ItemsSource = $years
$ui.YearCombo.SelectedItem = $now.Year
$ui.MonthCombo.ItemsSource = 1..12
$ui.MonthCombo.SelectedItem = $now.Month

# ---- カテゴリコンボ ----
$ui.CategoryCombo.ItemsSource = $Script:Categories

# ---- 4段カスケード ----
function Reset-Cascade {
    param([string[]]$From)  # 'process','task_group','task' のいずれか以降
    foreach ($n in $From) {
        switch ($n) {
            'process'    { $ui.ProcessCombo.ItemsSource   = $null }
            'task_group' { $ui.TaskGroupCombo.ItemsSource = $null }
            'task'       { $ui.TaskCombo.ItemsSource      = $null }
        }
    }
}

$ui.ProjectCombo.ItemsSource = ($Script:Projects | Where-Object { $_.active })

$ui.ProjectCombo.Add_SelectionChanged({
    Reset-Cascade -From @('process','task_group','task')
    $p = $ui.ProjectCombo.SelectedItem
    if ($p -and $p.processes) {
        $ui.ProcessCombo.ItemsSource = @($p.processes)
    }
})

$ui.ProcessCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task_group','task')
    $p = $ui.ProcessCombo.SelectedItem
    if ($p -and $p.task_groups) {
        $ui.TaskGroupCombo.ItemsSource = @($p.task_groups)
    }
})

$ui.TaskGroupCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task')
    $g = $ui.TaskGroupCombo.SelectedItem
    if ($g -and $g.tasks) {
        $ui.TaskCombo.ItemsSource = @($g.tasks)
    }
})

# ---- 表示月のロード ----
function Load-ViewMonth {
    $mid = $ui.MemberCombo.SelectedValue
    if (-not $mid) { return }
    $y = [int]$ui.YearCombo.SelectedItem
    $m = [int]$ui.MonthCombo.SelectedItem
    $Script:Entries.Clear()
    $loaded = @(Load-MonthEntries -RepoRoot $RepoRoot -MemberId $mid -Year $y -Month $m)
    foreach ($e in $loaded) {
        $Script:Entries.Add([pscustomobject]@{
            date            = [string]$e.date
            project_code    = [string]$e.project_code
            process_code    = [string]$e.process_code
            task_group_code = [string]$e.task_group_code
            task_code       = [string]$e.task_code
            category        = [string]$e.category
            hours           = [double]$e.hours
            comment         = [string]$e.comment
        })
    }
    Update-HoursTotal
    Set-Status "$mid の $y/$m を読み込みました (${($loaded.Count)} 件)" '#a6e3a1'
}

$ui.MemberCombo.Add_SelectionChanged({ Load-ViewMonth })
$ui.YearCombo.Add_SelectionChanged({ Load-ViewMonth })
$ui.MonthCombo.Add_SelectionChanged({ Load-ViewMonth })

# 初期日付: 今日
$ui.EntryDate.SelectedDate = [datetime]::Today

# ---- 追加ボタン ----
function Add-EntryFromForm {
    $d = $ui.EntryDate.SelectedDate
    if (-not $d) { [System.Windows.MessageBox]::Show('日付を選択してください') | Out-Null; return }
    $proj = $ui.ProjectCombo.SelectedItem
    $proc = $ui.ProcessCombo.SelectedItem
    $tg   = $ui.TaskGroupCombo.SelectedItem
    $task = $ui.TaskCombo.SelectedItem
    $cat  = $ui.CategoryCombo.SelectedItem
    if (-not $proj) { [System.Windows.MessageBox]::Show('プロジェクトを選択してください') | Out-Null; return }
    if (-not $proc) { [System.Windows.MessageBox]::Show('工程を選択してください') | Out-Null; return }
    # task_group / task は無いプロジェクトもあり得るので任意
    $hours = 0.0
    if (-not [double]::TryParse($ui.HoursBox.Text, [ref]$hours) -or $hours -le 0) {
        [System.Windows.MessageBox]::Show('工数は正の数値で入力してください') | Out-Null; return
    }

    $entry = [pscustomobject]@{
        date            = $d.ToString('yyyy-MM-dd')
        project_code    = $proj.code
        process_code    = $proc.code
        task_group_code = if ($tg)   { $tg.code }   else { '' }
        task_code       = if ($task) { $task.code } else { '' }
        category        = if ($cat)  { $cat.code }  else { '' }
        hours           = $hours
        comment         = $ui.CommentBox.Text
    }

    # 表示月と異なる日付ならアラート (バックデートOKだが念のため)
    $vy = [int]$ui.YearCombo.SelectedItem
    $vm = [int]$ui.MonthCombo.SelectedItem
    if ($d.Year -ne $vy -or $d.Month -ne $vm) {
        $msg = "日付 $($entry.date) は表示中の $vy/$vm と異なります。保存時にそちらの月ファイルに追記されます。続行しますか？"
        $r = [System.Windows.MessageBox]::Show($msg, '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
    }

    $Script:Entries.Add($entry)
    Update-HoursTotal
    Set-Status "追加: $($entry.date) $($entry.project_code) $($entry.hours)h" '#89b4fa'
}

$ui.AddBtn.Add_Click({ Add-EntryFromForm })

$ui.ClearBtn.Add_Click({
    $ui.EntryDate.SelectedDate = [datetime]::Today
    $ui.ProjectCombo.SelectedIndex = -1
    Reset-Cascade -From @('process','task_group','task')
    $ui.CategoryCombo.SelectedIndex = -1
    $ui.HoursBox.Text = '1.0'
    $ui.CommentBox.Text = ''
})

# ---- 削除ボタン ----
$ui.DeleteRowBtn.Add_Click({
    $sel = $ui.EntriesGrid.SelectedItem
    if ($null -eq $sel) { return }
    [void]$Script:Entries.Remove($sel)
    Update-HoursTotal
})

# ---- 保存ボタン ----
$ui.SaveBtn.Add_Click({
    $mid = $ui.MemberCombo.SelectedValue
    if (-not $mid) { return }
    $vy = [int]$ui.YearCombo.SelectedItem
    $vm = [int]$ui.MonthCombo.SelectedItem
    try {
        Save-EntriesGrouped -RepoRoot $RepoRoot -MemberId $mid `
                            -AllEntries @($Script:Entries) `
                            -ViewYear $vy -ViewMonth $vm
        Set-Status "保存しました ($mid)" '#a6e3a1'
        [System.Windows.MessageBox]::Show("ローカル保存完了。`n(git pull/commit/push 機能は次フェーズで実装)", '保存完了', 'OK', 'Information') | Out-Null
    } catch {
        Set-Status "保存失敗: $_" '#f38ba8'
        [System.Windows.MessageBox]::Show("保存失敗:`n$_", 'エラー', 'OK', 'Error') | Out-Null
    }
})

# ---- 再読込ボタン (今は git pull なしでファイル再読込のみ) ----
$ui.ReloadBtn.Add_Click({ Load-ViewMonth })

# ---- 初回ロード ----
Load-ViewMonth

# ---- 起動 ----
[void]$Script:Window.ShowDialog()
