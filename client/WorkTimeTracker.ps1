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

# ---- 致命エラーログ + 持続表示 ----
$Script:LogDir = Join-Path $env:APPDATA 'worktime-tracker'
if (-not (Test-Path -LiteralPath $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}
$Script:LogPath = Join-Path $Script:LogDir 'last_error.log'

function Write-FatalLog {
    param([string]$Text)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] $Text`r`n" -Encoding UTF8
    } catch { }
}

function Show-FatalDialog {
    param([string]$Title, [string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
    } catch {
        # WPF さえ使えない最悪ケース: コンソールに出してキー待ち
        Write-Host "[$Title]" -ForegroundColor Red
        Write-Host $Message -ForegroundColor Red
        Read-Host '何かキーを押すと終了します'
    }
}

trap {
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)`n`n--- 詳細はログ: $Script:LogPath"
    Write-FatalLog "FATAL: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n$($_.Exception | Format-List * -Force | Out-String)"
    Show-FatalDialog -Title 'WorkTime Tracker - 致命的エラー' -Message $msg
    exit 1
}

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')
. (Join-Path $libDir 'ConfigDialog.ps1')
. (Join-Path $libDir 'AdminDialog.ps1')

Write-FatalLog "==== START $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
Write-FatalLog "PSVersion: $($PSVersionTable.PSVersion) | PSScriptRoot: $PSScriptRoot"

# ---- 同梱マスタを GitLab にアップロード (リポジトリが空のとき用) ----
function Push-BundledMasters {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)]$Config)
    $bundle = Join-Path (Split-Path $PSScriptRoot -Parent) 'master'
    foreach ($name in @('members.json','projects.json','categories.json')) {
        $local = Join-Path $bundle $name
        if (-not (Test-Path -LiteralPath $local)) {
            throw "同梱の $name が見つかりません: $local"
        }
        $content = [System.IO.File]::ReadAllText($local, [System.Text.UTF8Encoding]::new($false))
        Set-DataFile -Source $Source -RelPath "master/$name" -Content $content `
                     -CommitMessage "bootstrap: initial $name" `
                     -AuthorName $Config.member_id -AuthorEmail "$($Config.member_id)@worktime-tracker.local"
    }
}

# ---- 接続 + マスタ読込 (詳細エラー付き) ----
function Try-LoadAll {
    param($Source)
    # 配列を PSCustomObject プロパティに格納するとスカラ化する PS 5.1 のクセを避けるため
    # ハッシュテーブルで保持する。
    $result = @{ Members=$null; Projects=$null; Categories=$null; MissingCount=0; Error=$null; ErrorAt=$null }
    foreach ($pair in @(
        @{ Key='Members';    File='master/members.json'    },
        @{ Key='Projects';   File='master/projects.json'   },
        @{ Key='Categories'; File='master/categories.json' }
    )) {
        try {
            $raw = Get-DataFile -Source $Source -RelPath $pair.File
            if (-not $raw) { $result.MissingCount++; continue }
            # ConvertFrom-Json の戻りをパイプラインに通すとスカラ化することがあるため
            # InputObject 指定 + ,(comma) でラップして配列保持。
            $parsed = ConvertFrom-Json -InputObject ([string]$raw)
            if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
                $result[$pair.Key] = @($parsed)
            } else {
                $result[$pair.Key] = ,$parsed
            }
        } catch {
            $result.Error = $_
            $result.ErrorAt = $pair.File
            return $result
        }
    }
    return $result
}

function Show-ErrorDialog {
    param([string]$Title, [string]$Message, [string]$Detail)
    Add-Type -AssemblyName PresentationFramework
    $w = New-Object System.Windows.Window
    $w.Title = $Title
    $w.Width = 640; $w.Height = 480
    $w.WindowStartupLocation = 'CenterScreen'
    $w.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1e1e2e')
    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.Margin = '12'
    $tb1 = New-Object System.Windows.Controls.TextBlock
    $tb1.Text = $Message
    $tb1.Foreground = [System.Windows.Media.Brushes]::White
    $tb1.FontWeight = 'Bold'
    $tb1.Margin = '0,0,0,8'
    $tb1.TextWrapping = 'Wrap'
    [System.Windows.Controls.DockPanel]::SetDock($tb1, 'Top')
    $dp.Children.Add($tb1) | Out-Null

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $sp.HorizontalAlignment = 'Right'
    $sp.Margin = '0,8,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($sp, 'Bottom')
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'OK'; $btn.Padding = '20,4'; $btn.MinWidth = 80
    $btn.Add_Click({ $w.Close() })
    $sp.Children.Add($btn) | Out-Null
    $dp.Children.Add($sp) | Out-Null

    $txt = New-Object System.Windows.Controls.TextBox
    $txt.Text = $Detail
    $txt.IsReadOnly = $true
    $txt.AcceptsReturn = $true
    $txt.TextWrapping = 'Wrap'
    $txt.VerticalScrollBarVisibility = 'Auto'
    $txt.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#181825')
    $txt.Foreground = [System.Windows.Media.Brushes]::Salmon
    $txt.FontFamily = 'Consolas'
    $txt.Padding = '6'
    $dp.Children.Add($txt) | Out-Null

    $w.Content = $dp
    [void]$w.ShowDialog()
}

# ---- 設定 + 接続 (失敗時は ConfigDialog 再オープン or マスタ bootstrap) ----
function Initialize-AppContext {
    param([switch]$ForceDialog)
    $cfg = Load-Config
    while ($true) {
        $needDialog = $ForceDialog -or -not (Test-ConfigComplete -Config $cfg)
        if ($needDialog) {
            $ok = Show-ConfigDialog -Config $cfg
            if (-not $ok) { return $null }
            $cfg = Load-Config
            $ForceDialog = $false
        }
        $token = $null
        if ($cfg.mode -eq 'gitlab') { $token = Get-GitLabToken }
        $source = New-DataSource -Config $cfg -Token $token

        $r = Try-LoadAll -Source $source

        if ($r['Error']) {
            $detail = "ファイル: $($r['ErrorAt'])`n`n$($r['Error'].Exception.Message)`n`n$($r['Error'].ScriptStackTrace)"
            Show-ErrorDialog -Title 'WorkTime Tracker - 接続エラー' `
                             -Message "マスタ取得に失敗しました。設定を見直してください。" `
                             -Detail $detail
            $confirm = [System.Windows.MessageBox]::Show('設定ダイアログを開きますか? (いいえで終了)', '確認', 'YesNo', 'Question')
            if ($confirm -ne 'Yes') { return $null }
            $ForceDialog = $true
            continue
        }

        if ($r['MissingCount'] -gt 0) {
            $msg = "GitLab リポジトリに master/ 配下のマスタファイルが $($r['MissingCount']) 個ありません。`n`n" +
                   "同梱のサンプルマスタを GitLab にアップロードして開始しますか?`n" +
                   "  [はい] 同梱マスタを push して開始`n" +
                   "  [いいえ] 設定を見直す"
            $r2 = [System.Windows.MessageBox]::Show($msg, 'マスタ未登録', 'YesNo', 'Question')
            if ($r2 -eq 'Yes') {
                try {
                    Push-BundledMasters -Source $source -Config $cfg
                    [System.Windows.MessageBox]::Show('マスタを push しました。再読込します。', '完了', 'OK', 'Information') | Out-Null
                    continue   # 再試行
                } catch {
                    Show-ErrorDialog -Title 'マスタ push 失敗' `
                                     -Message '同梱マスタの push に失敗しました。' `
                                     -Detail "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
                    $ForceDialog = $true
                    continue
                }
            } else {
                $ForceDialog = $true
                continue
            }
        }

        # ハッシュテーブルで返す (PSCustomObject NoteProperty 経由で配列がスカラ化する事例を回避)
        return @{
            Config     = $cfg
            Source     = $source
            Token      = $token
            Members    = $r['Members']
            Projects   = $r['Projects']
            Categories = $r['Categories']
        }
    }
}

$ctx = Initialize-AppContext -ForceDialog:$ForceConfig
if (-not $ctx) {
    Write-Host "設定/接続が完了しなかったため終了します。" -ForegroundColor Yellow
    return
}
$Script:Config     = $ctx['Config']
$Script:Source     = $ctx['Source']
$Script:Token      = $ctx['Token']
$Script:Members    = @($ctx['Members'])
$Script:Projects   = @($ctx['Projects'])
$Script:Categories = @($ctx['Categories'])
Write-FatalLog ("Loaded: Members={0} Projects={1} Categories={2}" -f $Script:Members.Count, $Script:Projects.Count, $Script:Categories.Count)

function Reload-Masters {
    try {
        $Script:Members    = @(Get-MasterMembers    -Source $Script:Source)
        $Script:Projects   = @(Get-MasterProjects   -Source $Script:Source)
        $Script:Categories = @(Get-MasterCategories -Source $Script:Source)
    } catch {
        [System.Windows.MessageBox]::Show("マスタ再読込に失敗:`n$_", 'エラー', 'OK', 'Error') | Out-Null
    }
}

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
# 配列強制 (@()): PSCustomObject プロパティ経由で渡ると配列がスカラ化することがあるため
$Script:Members    = @($Script:Members)
$Script:Projects   = @($Script:Projects)
$Script:Categories = @($Script:Categories)
Write-FatalLog ("Members count={0} | shape={1}" -f $Script:Members.Count, ($Script:Members[0] | Out-String))

$memberItems = @($Script:Members | Where-Object { $_.active } | ForEach-Object {
    [pscustomobject]@{ id = $_.id; name = $_.name; role = $_.role; display = "$($_.id) - $($_.name)" }
})
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
    $newCtx = Initialize-AppContext -ForceDialog
    if ($newCtx) {
        $Script:Config     = $newCtx['Config']
        $Script:Source     = $newCtx['Source']
        $Script:Token      = $newCtx['Token']
        $Script:Members    = @($newCtx['Members'])
        $Script:Projects   = @($newCtx['Projects'])
        $Script:Categories = @($newCtx['Categories'])
        $ui.ModeText.Text = "mode: $($Script:Config.mode) | $($Script:Config.gitlab_url) | branch: $($Script:Config.branch)"
        # マスタ更新でコンボを再構築
        $script:memberItems = $Script:Members | Where-Object { $_.active } | ForEach-Object {
            [pscustomobject]@{ id = $_.id; name = $_.name; role = $_.role; display = "$($_.id) - $($_.name)" }
        }
        $ui.MemberCombo.ItemsSource = $script:memberItems
        if ($Script:Config.member_id) { $ui.MemberCombo.SelectedValue = $Script:Config.member_id }
        $ui.CategoryCombo.ItemsSource = $Script:Categories
        $ui.ProjectCombo.ItemsSource = ($Script:Projects | Where-Object { $_.active })
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
