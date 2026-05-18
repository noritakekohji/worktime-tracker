# WorkTimeTracker.ps1 — クライアント エントリポイント
#
# 動作要件: Windows + PowerShell 5.1 のみ (追加モジュールのインストール不要)
# ストレージ: GitLab REST API (Project Access Token 認証)
#
# 起動: client\launch.cmd または powershell -ExecutionPolicy Bypass -File client\WorkTimeTracker.ps1

param([switch]$ForceConfig)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')
. (Join-Path $libDir 'ConfigDialog.ps1')
. (Join-Path $libDir 'AdminDialog.ps1')

# ---- 設定ロード / 初回設定 ----
$Script:Config = Load-Config
if ($ForceConfig -or -not (Test-ConfigComplete -Config $Script:Config)) {
    $ok = Show-ConfigDialog -Config $Script:Config
    if (-not $ok) {
        Write-Host "設定がキャンセルされました。終了します。" -ForegroundColor Yellow
        return
    }
    $Script:Config = Load-Config
    if (-not (Test-ConfigComplete -Config $Script:Config)) {
        [System.Windows.MessageBox]::Show('設定が不完全です。アプリを終了します。', 'WorkTime Tracker', 'OK', 'Warning') | Out-Null
        return
    }
}

# ---- DataSource 作成 ----
$Script:Token = $null
if ($Script:Config.mode -eq 'gitlab') { $Script:Token = Get-GitLabToken }
$Script:Source = New-DataSource -Config $Script:Config -Token $Script:Token

# ---- マスタ読込 (with retry on auth failure) ----
function Reload-Masters {
    try {
        $Script:Members    = @(Get-MasterMembers    -Source $Script:Source)
        $Script:Projects   = @(Get-MasterProjects   -Source $Script:Source)
        $Script:Categories = @(Get-MasterCategories -Source $Script:Source)
        if (-not $Script:Members)    { throw "members.json が空またはパース失敗" }
        if (-not $Script:Projects)   { throw "projects.json が空またはパース失敗" }
        if (-not $Script:Categories) { throw "categories.json が空またはパース失敗" }
    } catch {
        [System.Windows.MessageBox]::Show("マスタ読込に失敗しました:`n$_`n`n設定を開きます。", 'エラー', 'OK', 'Error') | Out-Null
        throw
    }
}
Reload-Masters

# ---- XAML 読込 ----
$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'MemberCombo','YearCombo','MonthCombo','ReloadBtn','StatusText',
    'EntryDate','ProjectCombo','ProcessCombo','TaskGroupCombo','TaskCombo',
    'CategoryCombo','HoursBox','CommentBox','ClearBtn','AddBtn','UpdateBtn',
    'EntriesGrid','EditRowBtn','DeleteRowBtn','SaveBtn','HoursTotalText',
    'AdminBtn','SettingsBtn','FormHeader','ModeText'
)
$ui = @{}
foreach ($n in $names) { $ui[$n] = $Script:Window.FindName($n) }

$ui.ModeText.Text = "mode: $($Script:Config.mode) | $($Script:Config.gitlab_url) | branch: $($Script:Config.branch)"

# ---- 状態 ----
$Script:Entries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.EntriesGrid.ItemsSource = $Script:Entries
$Script:EditingItem = $null   # 編集モード時に格納

function Update-HoursTotal {
    $sum = 0.0
    foreach ($e in $Script:Entries) { $sum += [double]$e.hours }
    $ui.HoursTotalText.Text = '月合計: {0:N1} h' -f $sum
}

function Set-Status {
    param([string]$Text, [string]$Color = '#f9e2af')
    $ui.StatusText.Text = $Text
    $ui.StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
}

# ---- 作業者コンボ ----
$memberItems = $Script:Members | Where-Object { $_.active } | ForEach-Object {
    [pscustomobject]@{ id = $_.id; name = $_.name; role = $_.role; display = "$($_.id) - $($_.name)" }
}
$ui.MemberCombo.ItemsSource = $memberItems
if ($Script:Config.member_id) {
    $ui.MemberCombo.SelectedValue = $Script:Config.member_id
} elseif ($memberItems.Count -gt 0) {
    $ui.MemberCombo.SelectedIndex = 0
}

function Get-SelectedMember {
    $id = $ui.MemberCombo.SelectedValue
    return ($memberItems | Where-Object { $_.id -eq $id } | Select-Object -First 1)
}

function Update-AdminBtnVisibility {
    $m = Get-SelectedMember
    if ($m -and $m.role -eq 'admin') {
        $ui.AdminBtn.Visibility = 'Visible'
    } else {
        $ui.AdminBtn.Visibility = 'Collapsed'
    }
}
Update-AdminBtnVisibility

# ---- 年/月コンボ ----
$now = Get-Date
$ui.YearCombo.ItemsSource = ($now.Year - 2)..($now.Year + 1)
$ui.YearCombo.SelectedItem = $now.Year
$ui.MonthCombo.ItemsSource = 1..12
$ui.MonthCombo.SelectedItem = $now.Month

# ---- カテゴリコンボ ----
$ui.CategoryCombo.ItemsSource = $Script:Categories

# ---- 4段カスケード ----
function Reset-Cascade {
    param([string[]]$From)
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
    if ($p -and $p.processes) { $ui.ProcessCombo.ItemsSource = @($p.processes) }
})
$ui.ProcessCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task_group','task')
    $p = $ui.ProcessCombo.SelectedItem
    if ($p -and $p.task_groups) { $ui.TaskGroupCombo.ItemsSource = @($p.task_groups) }
})
$ui.TaskGroupCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task')
    $g = $ui.TaskGroupCombo.SelectedItem
    if ($g -and $g.tasks) { $ui.TaskCombo.ItemsSource = @($g.tasks) }
})

# ---- 表示月ロード ----
function Load-ViewMonth {
    $mid = $ui.MemberCombo.SelectedValue
    if (-not $mid) { return }
    $y = [int]$ui.YearCombo.SelectedItem
    $m = [int]$ui.MonthCombo.SelectedItem
    Set-Status "読込中: $mid $y/$m..." '#f9e2af'
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $Script:Entries.Clear()
        $loaded = @(Load-MonthEntries -Source $Script:Source -MemberId $mid -Year $y -Month $m)
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
        Set-Status "$mid の $y/$m を読込 ($($loaded.Count) 件)" '#a6e3a1'
    } catch {
        Set-Status "読込失敗: $_" '#f38ba8'
    } finally {
        $Script:Window.Cursor = $null
    }
}

$ui.MemberCombo.Add_SelectionChanged({ Update-AdminBtnVisibility; Load-ViewMonth })
$ui.YearCombo.Add_SelectionChanged({ Load-ViewMonth })
$ui.MonthCombo.Add_SelectionChanged({ Load-ViewMonth })

$ui.EntryDate.SelectedDate = [datetime]::Today

# ---- フォーム → エントリ ----
function Get-EntryFromForm {
    $d = $ui.EntryDate.SelectedDate
    if (-not $d) { throw '日付を選択してください' }
    $proj = $ui.ProjectCombo.SelectedItem
    $proc = $ui.ProcessCombo.SelectedItem
    $tg   = $ui.TaskGroupCombo.SelectedItem
    $task = $ui.TaskCombo.SelectedItem
    $cat  = $ui.CategoryCombo.SelectedItem
    if (-not $proj) { throw 'プロジェクトを選択してください' }
    if (-not $proc) { throw '工程を選択してください' }
    $hours = 0.0
    if (-not [double]::TryParse($ui.HoursBox.Text, [ref]$hours) -or $hours -le 0) {
        throw '工数は正の数値で入力してください'
    }
    return [pscustomobject]@{
        date            = $d.ToString('yyyy-MM-dd')
        project_code    = $proj.code
        process_code    = $proc.code
        task_group_code = if ($tg)   { $tg.code }   else { '' }
        task_code       = if ($task) { $task.code } else { '' }
        category        = if ($cat)  { $cat.code }  else { '' }
        hours           = $hours
        comment         = $ui.CommentBox.Text
    }
}

# ---- フォーム → エントリ反映 (編集) ----
function Set-FormFromEntry {
    param($Entry)
    $ui.EntryDate.SelectedDate = [datetime]::Parse($Entry.date)
    # カスケード: 一旦 nil
    $ui.ProjectCombo.SelectedValue = $Entry.project_code
    # SelectionChanged で processes が入った後に process を選ぶ必要があるので Dispatcher 経由
    $Script:Window.Dispatcher.BeginInvoke([action]{
        $ui.ProcessCombo.SelectedValue = $Entry.process_code
        $Script:Window.Dispatcher.BeginInvoke([action]{
            $ui.TaskGroupCombo.SelectedValue = $Entry.task_group_code
            $Script:Window.Dispatcher.BeginInvoke([action]{
                $ui.TaskCombo.SelectedValue = $Entry.task_code
            }, 'Background')
        }, 'Background')
    }, 'Background')
    $ui.CategoryCombo.SelectedValue = $Entry.category
    $ui.HoursBox.Text = [string]$Entry.hours
    $ui.CommentBox.Text = $Entry.comment
}

function Clear-Form {
    $ui.EntryDate.SelectedDate = [datetime]::Today
    $ui.ProjectCombo.SelectedIndex = -1
    Reset-Cascade -From @('process','task_group','task')
    $ui.CategoryCombo.SelectedIndex = -1
    $ui.HoursBox.Text = '1.0'
    $ui.CommentBox.Text = ''
    $Script:EditingItem = $null
    $ui.FormHeader.Text = '新規エントリ'
    $ui.AddBtn.Visibility = 'Visible'
    $ui.UpdateBtn.Visibility = 'Collapsed'
}

# ---- 追加 ----
$ui.AddBtn.Add_Click({
    try {
        $entry = Get-EntryFromForm
        $d = [datetime]::Parse($entry.date)
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
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, '入力エラー', 'OK', 'Warning') | Out-Null
    }
})

$ui.ClearBtn.Add_Click({ Clear-Form })

# ---- 編集 ----
$ui.EditRowBtn.Add_Click({
    $sel = $ui.EntriesGrid.SelectedItem
    if ($null -eq $sel) { return }
    $Script:EditingItem = $sel
    $ui.FormHeader.Text = "編集中: $($sel.date) (元の行は更新ボタンで上書き)"
    $ui.AddBtn.Visibility = 'Collapsed'
    $ui.UpdateBtn.Visibility = 'Visible'
    Set-FormFromEntry -Entry $sel
})

$ui.UpdateBtn.Add_Click({
    if ($null -eq $Script:EditingItem) { return }
    try {
        $newEntry = Get-EntryFromForm
        $idx = $Script:Entries.IndexOf($Script:EditingItem)
        if ($idx -ge 0) {
            $Script:Entries[$idx] = $newEntry
            Update-HoursTotal
            Set-Status "更新: $($newEntry.date) $($newEntry.project_code)" '#a6e3a1'
        }
        Clear-Form
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, '入力エラー', 'OK', 'Warning') | Out-Null
    }
})

# ---- 削除 ----
$ui.DeleteRowBtn.Add_Click({
    $sel = $ui.EntriesGrid.SelectedItem
    if ($null -eq $sel) { return }
    $r = [System.Windows.MessageBox]::Show("削除しますか？`n$($sel.date) $($sel.project_code) $($sel.hours)h", '確認', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }
    [void]$Script:Entries.Remove($sel)
    Update-HoursTotal
    if ($sel -eq $Script:EditingItem) { Clear-Form }
})

# ---- 保存 ----
$ui.SaveBtn.Add_Click({
    $m = Get-SelectedMember
    if (-not $m) { return }
    $vy = [int]$ui.YearCombo.SelectedItem
    $vm = [int]$ui.MonthCombo.SelectedItem
    Set-Status "保存中..." '#f9e2af'
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        Save-EntriesGrouped -Source $Script:Source -MemberId $m.id `
                            -AllEntries @($Script:Entries) `
                            -ViewYear $vy -ViewMonth $vm `
                            -AuthorName $m.name -AuthorEmail "$($m.id)@worktime-tracker.local"
        Set-Status "保存完了 ($($m.id) $vy/$vm)" '#a6e3a1'
        [System.Windows.MessageBox]::Show("保存しました。", '保存完了', 'OK', 'Information') | Out-Null
    } catch {
        Set-Status "保存失敗: $_" '#f38ba8'
        [System.Windows.MessageBox]::Show("保存失敗:`n$_", 'エラー', 'OK', 'Error') | Out-Null
    } finally {
        $Script:Window.Cursor = $null
    }
})

# ---- 再読込 / 設定 / 管理者 ----
$ui.ReloadBtn.Add_Click({ Reload-Masters; Load-ViewMonth })

$ui.SettingsBtn.Add_Click({
    $ok = Show-ConfigDialog -Config $Script:Config
    if ($ok) {
        $Script:Config = Load-Config
        $Script:Token = if ($Script:Config.mode -eq 'gitlab') { Get-GitLabToken } else { $null }
        $Script:Source = New-DataSource -Config $Script:Config -Token $Script:Token
        $ui.ModeText.Text = "mode: $($Script:Config.mode) | $($Script:Config.gitlab_url) | branch: $($Script:Config.branch)"
        Reload-Masters
        Load-ViewMonth
    }
})

$ui.AdminBtn.Add_Click({
    $m = Get-SelectedMember
    if (-not $m -or $m.role -ne 'admin') { return }
    Show-AdminDialog -Source $Script:Source -MemberId $m.id -MemberName $m.name
    Reload-Masters
})

# ---- 初回ロード ----
Load-ViewMonth

[void]$Script:Window.ShowDialog()
