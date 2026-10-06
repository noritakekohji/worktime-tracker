# WorkTimeTracker.ps1 — クライアント エントリポイント
#
# 動作要件: Windows + PowerShell 5.1 のみ (追加モジュールのインストール不要)
# ストレージ: GitLab REST API (Project Access Token 認証)
#
# 起動: client\launch.cmd または powershell -ExecutionPolicy Bypass -File client\WorkTimeTracker.ps1

param(
    [switch]$ForceConfig,
    # Pester から設定・保存データを変更せず、実ウィンドウの生成まで確認する。
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---- 致命エラーログ ----
# Config ロード前は $null (出力なし)。Initialize-AppContext 後に Update-LogPath で確定。
$Script:LogPath = $null

function Write-FatalLog {
    param([string]$Text)
    if (-not $Script:LogPath) { return }
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] $Text`r`n" -Encoding UTF8
    } catch { }
}

function Update-LogPath {
    param([Parameter(Mandatory)]$Config)
    $dir = if ($Config.PSObject.Properties['log_dir']) { $Config.log_dir } else { '' }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        # 初回設定前・旧設定でも、launch.cmd が案内する標準ログを必ず残す。
        $dir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'worktime-tracker'
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { $Script:LogPath = $null; return }
    }
    $Script:LogPath = Join-Path $dir 'last_error.log'
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
    $logNote = if ($Script:LogPath) { "`n`n--- 詳細はログ: $Script:LogPath" } else { '' }
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)$logNote"
    Write-FatalLog "FATAL: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n$($_.Exception | Format-List * -Force | Out-String)"
    Show-FatalDialog -Title 'WorkTime Tracker - 致命的エラー' -Message $msg
    exit 1
}

# 依存スクリプトの読込や設定読込で失敗した場合にも、launch.cmd の案内先に
# 原因を残せるよう、設定の確定前から標準ログを有効化する。
try {
    $earlyLogDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'worktime-tracker'
    New-Item -ItemType Directory -Path $earlyLogDir -Force | Out-Null
    $Script:LogPath = Join-Path $earlyLogDir 'last_error.log'
} catch { }

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Version.ps1')
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')
. (Join-Path $libDir 'EntryAssist.ps1')
. (Join-Path $libDir 'SyncMonitor.ps1')
. (Join-Path $libDir 'AutoUpdate.ps1')
. (Join-Path $libDir 'ConfigDialog.ps1')
. (Join-Path $libDir 'AdminDialog.ps1')
. (Join-Path $libDir 'UserPrefs.ps1')
. (Join-Path $libDir 'UserPrefsDialog.ps1')
. (Join-Path $libDir 'Bootstrap.ps1')

# ---- 起動スモークテスト ----
# 設定ダイアログやユーザーの local_store に依存せず、実際に MainWindow を表示して
# Dispatcher が動作することまで確認する。タイマーで即時に閉じるため自動テストで安全に使える。
function Invoke-TrackerStartupSmokeTest {
    $xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
    [xml]$smokeXaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $smokeReader = New-Object System.Xml.XmlNodeReader $smokeXaml
    $smokeWindow = [Windows.Markup.XamlReader]::Load($smokeReader)
    if (-not ($smokeWindow -is [System.Windows.Window])) {
        throw "MainWindow.xaml did not create a Window: $xamlPath"
    }

    $requiredControls = @('ProjectCombo', 'EntriesGrid', 'SaveBtn', 'AddBtn', 'StatusText')
    $missingControls = @($requiredControls | Where-Object { -not $smokeWindow.FindName($_) })
    if ($missingControls.Count -gt 0) {
        throw ('MainWindow.xaml is missing required controls: ' + ($missingControls -join ', '))
    }

    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $smokeWindow.Close()
    })
    $closeTimer.Start()
    [void]$smokeWindow.ShowDialog()
}

if ($SmokeTest) {
    Invoke-TrackerStartupSmokeTest
    exit 0
}

Write-FatalLog "==== START $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
Write-FatalLog "PSVersion: $($PSVersionTable.PSVersion) | PSScriptRoot: $PSScriptRoot"

# ---- 同梱マスタを GitLab にアップロード (リポジトリが空のとき用) ----
function Push-BundledMasters {
    # 同梱の master サンプルを local_store に展開 (初回 bootstrap)
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)]$Config)
    $bundle = Join-Path (Split-Path $PSScriptRoot -Parent) 'master'
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json','holidays.json')) {
        $local = Join-Path $bundle $name
        if (-not (Test-Path -LiteralPath $local)) {
            throw "同梱の $name が見つかりません: $local"
        }
        $content = [System.IO.File]::ReadAllText($local, [System.Text.UTF8Encoding]::new($false))
        Set-DataFile -Source $Source -RelPath "master/$name" -Content $content `
                     -AuthorName $Config.member_id -AuthorEmail "$($Config.member_id)@worktime-tracker.local"
    }
}

# ---- 接続 + マスタ読込 (詳細エラー付き) ----
function Try-LoadAll {
    param($Source)
    # 配列を PSCustomObject プロパティに格納するとスカラ化する PS 5.1 のクセを避けるため
    # ハッシュテーブルで保持する。
    $result = @{ Members=$null; Projects=$null; Categories=$null; TaskPatterns=$null; MissingCount=0; Error=$null; ErrorAt=$null }
    foreach ($pair in @(
        @{ Key='Members';      File='master/members.json'       },
        @{ Key='Projects';     File='master/projects.json'      },
        @{ Key='Categories';   File='master/categories.json'    },
        @{ Key='TaskPatterns'; File='master/task_patterns.json' }
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

        # Gitlab モードなら 「取得」/「読込」 を Yes/No で確認
        # Yes: pull (リモート → ローカル) してから読込
        # No : ローカルキャッシュのみで起動 (オフライン可)
        if ($source.RemoteCtx) {
            $pullChoice = [System.Windows.MessageBox]::Show(
                "共有マスタは作業入力の候補と権限に影響します。最新情報の取得を強く推奨します。`n`n  [はい] GitLab からマスタを取得 → ローカルから読込 (最新)`n  [いいえ] ローカルキャッシュで開始 (更新がある場合は後で通知)",
                'WorkTime Tracker  起動 - マスタ更新を推奨', 'YesNo', 'Warning')
            if ($pullChoice -eq 'Yes') {
                try {
                    $pullResult = Sync-Pull-Masters -Source $source
                    Write-FatalLog ("Master pull: pulled={0} missing={1} errors={2}" -f $pullResult.Pulled, $pullResult.Missing, $pullResult.Errors.Count)
                } catch {
                    Show-ErrorDialog -Title '接続エラー' `
                                     -Message 'リモートマスタの取得に失敗しました。ローカルキャッシュで続行します。' `
                                     -Detail "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
                }
            } else {
                Write-FatalLog 'Master pull skipped (user chose local cache)'
            }
        }

        $r = Try-LoadAll -Source $source

        if ($r['Error']) {
            $detail = "ファイル: $($r['ErrorAt'])`n`n$($r['Error'].Exception.Message)`n`n$($r['Error'].ScriptStackTrace)"
            Show-ErrorDialog -Title 'マスタ読込エラー' `
                             -Message "マスタの読込に失敗しました。" `
                             -Detail $detail
            $confirm = [System.Windows.MessageBox]::Show('設定ダイアログを開きますか? (いいえで終了)', '確認', 'YesNo', 'Question')
            if ($confirm -ne 'Yes') { return $null }
            $ForceDialog = $true
            continue
        }

        if ($r['MissingCount'] -gt 0) {
            $where = if ($source.RemoteCtx) { 'リモート + ローカル' } else { 'ローカル保管先' }
            $msg = ("$where にマスタファイルが $($r['MissingCount']) 個ありません。`n`n" +
                    "同梱のサンプルマスタをローカルに展開して開始しますか?`n" +
                    "  [はい] 展開して開始 (後で『送信』ボタンでリモートに push 可)`n" +
                    "  [いいえ] 設定を見直す")
            $r2 = [System.Windows.MessageBox]::Show($msg, 'マスタ未登録', 'YesNo', 'Question')
            if ($r2 -eq 'Yes') {
                try {
                    Push-BundledMasters -Source $source -Config $cfg
                    [System.Windows.MessageBox]::Show('マスタをローカルに展開しました。再読込します。', '完了', 'OK', 'Information') | Out-Null
                    continue
                } catch {
                    Show-ErrorDialog -Title 'マスタ展開失敗' `
                                     -Message '同梱マスタのローカル展開に失敗しました。' `
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
            Config       = $cfg
            Source       = $source
            Token        = $token
            Members      = $r['Members']
            Projects     = $r['Projects']
            Categories   = $r['Categories']
            TaskPatterns = $r['TaskPatterns']
        }
    }
}

$ctx = Initialize-AppContext -ForceDialog:$ForceConfig
if (-not $ctx) {
    Write-Host "設定/接続が完了しなかったため終了します。" -ForegroundColor Yellow
    return
}
$Script:Config     = $ctx['Config']
Update-LogPath -Config $Script:Config
$Script:Source     = $ctx['Source']
$Script:Token      = $ctx['Token']
$Script:Members      = @($ctx['Members'])
$Script:Projects     = @($ctx['Projects'])
$Script:Categories   = @($ctx['Categories'])
$Script:TaskPatterns = @($ctx['TaskPatterns'])
# 祝日は未入力の平日の判定にだけ使う。読めなくても入力は続けられるので致命扱いにしない
function Load-TrackerHolidays {
    try { $Script:Holidays = @(Get-MasterHolidays -Source $Script:Source) }
    catch { $Script:Holidays = @(); Write-FatalLog "holidays.json 読込失敗: $_" }
}
Load-TrackerHolidays
Write-FatalLog ("Loaded: Members={0} Projects={1} Categories={2} TaskPatterns={3}" -f $Script:Members.Count, $Script:Projects.Count, $Script:Categories.Count, $Script:TaskPatterns.Count)

function Reload-Masters {
    param([switch]$Pull)   # -Pull が指定された場合のみ remote → local pull
    try {
        if ($Pull -and $Script:Source.RemoteCtx) {
            # 注意: $pull / $Pull は PS では同一変数 (大小区別なし)。
            # ここで $Pull をローカルで上書きすると SwitchParameter→PSCustomObject に
            # 化けてしまうため必ず別名 ($pullResult) を使うこと。
            $pullResult = Sync-Pull-Masters -Source $Script:Source
            Write-FatalLog ("Master pull (Reload-Masters -Pull): pulled={0} missing={1} errors={2}" -f $pullResult.Pulled, $pullResult.Missing, $pullResult.Errors.Count)
        }
        $Script:Members      = @(Get-MasterMembers      -Source $Script:Source)
        $Script:Projects     = @(Get-MasterProjects     -Source $Script:Source)
        $Script:Categories   = @(Get-MasterCategories   -Source $Script:Source)
        $Script:TaskPatterns = @(Get-MasterTaskPatterns -Source $Script:Source)
        Load-TrackerHolidays
        # UI 反映: プロジェクト / カテゴリ / 現在の作業者
        if ($ui -and $ui.ProjectCombo) {
            Set-ProjectComboItems -Preserve
        }
        if ($ui -and $ui.CategoryCombo) {
            $ui.CategoryCombo.ItemsSource = @($Script:Categories)
        }
        # 現在ユーザの会社/部署/ランク/役割の変化を反映
        $cur = $Script:Members | Where-Object { $_.id -eq $Script:Config.member_id -and $_.active } | Select-Object -First 1
        if ($cur) {
            $Script:CurrentMember = $cur
            if ($ui -and $ui.CurrentMemberText) {
                $ui.CurrentMemberText.Text = ("{0}  {1}" -f $cur.id, $cur.name)
            }
            if ($ui -and $ui.AdminBtn) {
                $ui.AdminBtn.Visibility = if (Has-Role -Member $cur -Role 'admin') { 'Visible' } else { 'Collapsed' }
            }
        }
        if ($ui -and $ui.StatusText) {
            Set-Status ("マスタ再読込: メンバー={0} / プロジェクト={1} / パターン={2} / カテゴリ={3}" -f `
                $Script:Members.Count, $Script:Projects.Count, $Script:TaskPatterns.Count, $Script:Categories.Count) '#10b981'
        }
    } catch {
        [System.Windows.MessageBox]::Show("マスタ再読込に失敗:`n$_", 'エラー', 'OK', 'Error') | Out-Null
    }
}

# ---- XAML 読込 ----
$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)
$Script:Window.Title = Format-WindowTitle -ScreenName '日次入力'
# UI フッタにバージョンを表示 (FindName 後にセット)

$names = @(
    'CurrentMemberText','YearCombo','MonthCombo','ReloadBtn','PullBtn','StatusText','RemoteNoticeText','SyncProgress',
    'EntryDate','PrevDayBtn','NextDayBtn','TodayBtn','YesterdayBtn','IsLeaveChk',
    'ProjectCombo','ProcessCombo','TaskGroupCombo','TaskCombo',
    'CategoryCombo','HoursBox','CommentBox','ClearBtn','AddBtn','UpdateBtn','TaskDescBorder','TaskDescText',
    'EntriesGrid','EmptyListText','EditRowBtn','DeleteRowBtn','DuplicateBtn','SaveBtn','HoursTotalText','HoursDayText',
    'AdminBtn','SettingsBtn','UserPrefsBtn','OpenFolderBtn','PushBtn','FormHeader','ListTitle','ModeText','VersionText',
    'WbsNavBtn','ReportNavBtn',
    'CopyPrevDayBtn','RecentCombosArea','RecentCombosPanel','FavToggleBtn','SaveDefaultBtn',
    'MissingDaysBorder','MissingDaysPanel'
)
$ui = @{}
foreach ($n in $names) { $ui[$n] = $Script:Window.FindName($n) }

# フッタにバージョン表示 (クリックで CHANGELOG を開く)
if ($ui.VersionText) {
    $ui.VersionText.Text = $Script:AppVersionTag
    $ui.VersionText.Add_MouseLeftButtonUp({ Show-ChangelogDialog })
}

$ui.ModeText.Text = switch ($Script:Config.mode) {
    'gitlab' { "Gitlab モード | {0} / {1} @ {2} | local: {3}" -f $Script:Config.gitlab_url, $Script:Config.project_id, $Script:Config.branch, $Script:Config.local_store }
    default  { "スタンドアローン | {0}" -f $Script:Config.local_store }
}

# ---- 状態 ----
$Script:Entries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.EntriesGrid.ItemsSource = $Script:Entries
$Script:EditingItem = $null

# 休暇 (is_leave) は工数 0 として扱うため合計には現れない。
# 判定と加算は DataStore.ps1 の Test-IsLeaveEntry / Get-EntryHoursSum に集約している。
function Update-HoursTotal {
    $ui.HoursTotalText.Text = '{0:N1} h' -f (Get-EntryHoursSum $Script:Entries)
    Update-EmptyState
    Update-HoursDay
    Update-RecentCombos
    Update-MissingDays
}

# 一覧が 0 件のときは白紙にせず、次にすべきことを案内する
function Update-EmptyState {
    if (-not $ui.EmptyListText) { return }
    $ui.EmptyListText.Visibility = if ($Script:Entries.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Update-HoursDay {
    if (-not $ui.HoursDayText) { return }
    $d = $ui.EntryDate.SelectedDate
    if (-not $d) { $ui.HoursDayText.Text = '0.0 h'; return }
    $dStr = $d.ToString('yyyy-MM-dd')
    $dayEntries = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Script:Entries) {
        if ([string]$e.date -eq $dStr) { [void]$dayEntries.Add($e) }
    }
    $ui.HoursDayText.Text = '{0:N1} h' -f (Get-EntryHoursSum $dayEntries.ToArray())
}

# 最近の組み合わせ (表示月の実績から、個人設定の件数まで)。クリックでプロジェクト〜カテゴリを入力する。
# 件数は保存のたびにファイルを読まないよう Load-RecentComboCount でキャッシュする (0 = 非表示)
$Script:RecentComboCount = 5
function Load-RecentComboCount {
    if (-not $Script:CurrentMember) { return }
    try { $Script:RecentComboCount = Get-RecentComboCount -MemberId ([string]$Script:CurrentMember.id) }
    catch { Write-FatalLog "recent_combo_count 読込失敗: $_" }
}

function Update-RecentCombos {
    if (-not $ui.RecentCombosPanel) { return }
    $ui.RecentCombosPanel.Children.Clear()
    if ($Script:RecentComboCount -le 0) { $ui.RecentCombosArea.Visibility = 'Collapsed'; return }
    $combos = Get-RecentEntryCombos -Entries $Script:Entries -Max $Script:RecentComboCount
    $rowStyle = $Script:Window.FindResource('RecentRow')
    # 行の表示は「ユニットコード + タスク + 工数」。それでも同じ表示が複数あるとき (カテゴリ違い等) だけ
    # カテゴリ名を添えて見分ける
    $rows = foreach ($c in $combos) {
        $n = Resolve-EntryNames -ProjCode $c.project_code -ProcCode $c.process_code -TgCode $c.task_group_code `
                                -TaskCode $c.task_code -CatCode $c.category
        $leaf = @($n.task_name, $n.task_group_name, $n.process_name) | Where-Object { $_ } | Select-Object -First 1
        $text = if ($leaf) { '[{0}] {1}' -f $c.project_code, $leaf } else { '[{0}]' -f $c.project_code }
        [pscustomobject]@{ combo = $c; names = $n; label = $text }
    }
    $dupLabels = @($rows | Group-Object label | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($r in $rows) {
        $c = $r.combo; $n = $r.names
        $label = if ($dupLabels -contains $r.label -and $n.category_name) { '{0} ({1})' -f $r.label, $n.category_name } else { $r.label }
        $dock = New-Object System.Windows.Controls.DockPanel
        $hoursText = New-Object System.Windows.Controls.TextBlock
        $hoursText.Text = if ($c.hours -gt 0) { '{0:0.0#} h' -f $c.hours } else { '' }
        $hoursText.FontWeight = 'Bold'
        $hoursText.Margin = '8,0,0,0'
        [System.Windows.Controls.DockPanel]::SetDock($hoursText, 'Right')
        $taskText = New-Object System.Windows.Controls.TextBlock
        $taskText.Text = $label
        $taskText.TextTrimming = 'CharacterEllipsis'
        [void]$dock.Children.Add($hoursText)
        [void]$dock.Children.Add($taskText)
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $rowStyle
        $b.Content = $dock
        $b.Tag = $c
        $b.ToolTip = ("[{0}] {1}`n{2} / {3} / {4}`nカテゴリ: {5}`n工数: {6}" -f $c.project_code, $n.project_name,
                      $n.process_name, $n.task_group_name, $n.task_name, $n.category_name, $hoursText.Text)
        $b.Add_Click({ param($s, $e) Apply-RecentCombo -Combo $s.Tag })
        [void]$ui.RecentCombosPanel.Children.Add($b)
    }
    $ui.RecentCombosArea.Visibility = if ($combos.Count -gt 0) { 'Visible' } else { 'Collapsed' }
}

function Apply-RecentCombo {
    param($Combo)
    try {
        if ($ui.IsLeaveChk.IsChecked) { $ui.IsLeaveChk.IsChecked = $false }
        Select-ProjectCode $Combo.project_code -ProcessCode $Combo.process_code `
                           -TaskGroupCode $Combo.task_group_code -TaskCode $Combo.task_code
        if (-not $ui.ProjectCombo.SelectedItem) {
            Set-Status ("[{0}] は現在選択できません (無効化された可能性があります)" -f $Combo.project_code) '#f38ba8'
            return
        }
        $lost = Select-CascadeCodes -ProcessCode $Combo.process_code -TaskGroupCode $Combo.task_group_code -TaskCode $Combo.task_code
        if ($Combo.category) { [void](_SelectComboValue $ui.CategoryCombo $Combo.category) }
        if ($Combo.hours -gt 0) { $ui.HoursBox.Text = ([double]$Combo.hours).ToString('0.0#') }
        if ($lost) {
            Set-Status ("最近の組み合わせを入力しました ({0} は現在の候補に無いため先頭を選択)" -f $lost) '#f9e2af'
        } else {
            Set-Status '最近の内容を入力しました。工数を確認して『追加』してください' '#89b4fa'
        }
        $ui.HoursBox.Focus() | Out-Null
        $ui.HoursBox.SelectAll()
    } catch {
        Set-Status "入力に失敗: $($_.Exception.Message)" '#f38ba8'
    }
}

# 表示月の未入力平日 (今日まで)。クリックでフォームの日付をその日にする
function Update-MissingDays {
    if (-not $ui.MissingDaysPanel) { return }
    $ui.MissingDaysPanel.Children.Clear()
    $y = [int]$ui.YearCombo.SelectedItem
    $m = [int]$ui.MonthCombo.SelectedItem
    $days = Get-MissingWeekdays -Entries $Script:Entries -Year $y -Month $m -Holidays $Script:Holidays -Today ([datetime]::Today)
    $ja = [System.Globalization.CultureInfo]::GetCultureInfo('ja-JP')
    $chipStyle = $Script:Window.FindResource('ChipButton')
    $maxShow = 12
    foreach ($d in ($days | Select-Object -First $maxShow)) {
        $dt = [datetime]::ParseExact($d, 'yyyy-MM-dd', $null)
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $chipStyle
        $b.Content = $dt.ToString('M/d(ddd)', $ja)
        $b.Tag = $dt
        $b.ToolTip = 'この日をフォームの日付にする'
        $b.Add_Click({ param($s, $e) $ui.EntryDate.SelectedDate = [datetime]$s.Tag })
        [void]$ui.MissingDaysPanel.Children.Add($b)
    }
    if ($days.Count -gt $maxShow) {
        $more = New-Object System.Windows.Controls.TextBlock
        $more.Text = ('ほか {0} 日' -f ($days.Count - $maxShow))
        $more.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#9a3412')
        $more.Margin = '4,0,0,0'
        [void]$ui.MissingDaysPanel.Children.Add($more)
    }
    $ui.MissingDaysBorder.Visibility = if ($days.Count -gt 0) { 'Visible' } else { 'Collapsed' }
}

function Set-Status {
    param([string]$Text, [string]$Color = '#f9e2af')
    $ui.StatusText.Text = $Text
    $ui.StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
}

function Set-SyncBusy {
    param([bool]$Busy, [string]$Text = '')
    $ui.PushBtn.IsEnabled = -not $Busy
    $ui.PullBtn.IsEnabled = -not $Busy
    $ui.SyncProgress.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    if ($Text) { Set-Status $Text '#f9e2af' }
    $ui.StatusText.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
}

function Get-MonitorDataPath {
    $member = Get-SelectedMember
    if (-not $member) { return '' }
    return ('data/{0:D4}/{1:D2}' -f [int]$ui.YearCombo.SelectedItem, [int]$ui.MonthCombo.SelectedItem)
}

function Show-RemoteUpdateNotice {
    param($Result)
    if (-not $Result) { return }
    $items = @()
    if ($Result.MasterChanged) { $items += 'マスタ' }
    if ($Result.DataChanged) { $items += '自分の表示月の実績' }
    if ($items.Count -eq 0) { return }
    $ui.RemoteNoticeText.Text = ('⚠ GitLab に新しい{0}があります。［📥 取得］で反映してください。' -f ($items -join '・'))
    $ui.RemoteNoticeText.Visibility = 'Visible'
}

# ---- 配列強制 ----
$Script:Members    = @($Script:Members)
$Script:Projects   = @($Script:Projects)
$Script:Categories = @($Script:Categories)

# ---- 現在の作業者 (設定値から解決) ----
$Script:CurrentMember = $Script:Members | Where-Object { $_.id -eq $Script:Config.member_id -and $_.active } | Select-Object -First 1
if (-not $Script:CurrentMember) {
    [System.Windows.MessageBox]::Show(
        ("設定された Member ID '{0}' がマスタに見つかりません。`n設定ダイアログから ID を見直してください。" -f $Script:Config.member_id),
        '作業者未登録', 'OK', 'Warning') | Out-Null
    $Script:CurrentMember = [pscustomobject]@{ id = $Script:Config.member_id; name = '(未登録)'; role = 'member' }
}
$ui.CurrentMemberText.Text = ("{0}  {1}" -f $Script:CurrentMember.id, $Script:CurrentMember.name)
# 診断: ロール判定をログに残す (管理者モードが出ない問題の調査用)
try {
    $rolesNow = (Get-MemberRoles -Member $Script:CurrentMember) -join ','
    $hasAdmin = Has-Role -Member $Script:CurrentMember -Role 'admin'
    $hasRolesProp = $null -ne ($Script:CurrentMember.PSObject.Properties['roles'])
    $hasRoleProp  = $null -ne ($Script:CurrentMember.PSObject.Properties['role'])
    Write-FatalLog ("CurrentMember id={0} name={1} hasRolesProp={2} hasRoleProp={3} roles=[{4}] isAdmin={5}" `
        -f $Script:CurrentMember.id, $Script:CurrentMember.name, $hasRolesProp, $hasRoleProp, $rolesNow, $hasAdmin)
} catch { Write-FatalLog "Role diag failed: $_" }
if (Has-Role -Member $Script:CurrentMember -Role 'admin') {
    $ui.AdminBtn.Visibility = 'Visible'
}

function Get-SelectedMember { return $Script:CurrentMember }

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

function Load-UserPrefsFav {
    # 自分のお気に入りプロジェクト集合を取得
    # PS 関数出力ストリームが IEnumerable を auto-unroll するため Write-Output -NoEnumerate で塊で返す
    $set = New-Object System.Collections.Generic.HashSet[string]
    if (-not $Script:CurrentMember) {
        Write-Output -NoEnumerate -InputObject $set
        return
    }
    $prefs = Get-UserPrefs -MemberId ([string]$Script:CurrentMember.id)
    foreach ($p in @($prefs.favorite_projects)) {
        if ($p) { [void]$set.Add([string]$p) }
    }
    Write-Output -NoEnumerate -InputObject $set
}

function Build-ProjectComboItems {
    # お気に入りを先頭に並べ替え、表示に ⭐ プレフィックス
    $favs = Load-UserPrefsFav
    $defCodes = New-Object System.Collections.Generic.HashSet[string]
    if ($Script:CurrentMember) {
        foreach ($c in (Get-UnitDefaultCodes -MemberId ([string]$Script:CurrentMember.id))) { [void]$defCodes.Add($c) }
    }
    $allActive = @($Script:Projects | Where-Object { $_.active })
    # 同じユニットコードに複数パターンがあるときは、表示にパターン名を添えて見分ける
    $unitCounts = @{}
    foreach ($p in $allActive) { $k = [string]$p.unit_code; $unitCounts[$k] = 1 + [int]$unitCounts[$k] }
    $idx = 0
    $items = foreach ($p in $allActive) {
        $idx++
        $isFav = $favs.Contains([string]$p.unit_code)
        $star  = if ($isFav) { '⭐ ' } else { '' }
        $disp = if ($p.unit_name) {
            "{0}[{1}] {2} ({3})" -f $star, $p.unit_code, $p.unit_name, $p.project_name
        } else {
            "{0}[{1}] {2}" -f $star, $p.unit_code, $p.project_name
        }
        if ($unitCounts[[string]$p.unit_code] -gt 1) {
            # Get-TaskPatternFor はこの関数の初回呼出し (起動時) より後で定義されるため使わない
            $ptn = @($Script:TaskPatterns) | Where-Object { [string]$_.id -eq [string]$p.task_pattern_id } | Select-Object -First 1
            $ptnLabel = if ($ptn -and $ptn.name) { [string]$ptn.name } else { [string]$p.task_pattern_id }
            $disp += ('  ‹{0}›' -f $ptnLabel)
        }
        $hasDefault = $defCodes.Contains([string]$p.unit_code)
        if ($hasDefault) { $disp += '  📌' }
        [pscustomobject]@{
            unit_code       = [string]$p.unit_code
            project_name    = [string]$p.project_name
            unit_name       = [string]$p.unit_name
            target_system   = [string]$p.target_system
            work_type       = [string]$p.work_type
            task_pattern_id = [string]$p.task_pattern_id
            period_from     = [string]$p.period_from
            period_to       = [string]$p.period_to
            display         = $disp
            is_favorite     = $isFav
            has_default     = $hasDefault
            # 同じユニットコードの別パターンと区別する一意キー (選択の維持・復元に使う)
            item_key        = ('{0}|{1}|{2}' -f $p.unit_code, $p.task_pattern_id, $idx)
        }
    }
    # お気に入り優先でソート (お気に入り内は unit_code 順、その他は unit_code 順)
    # PS 5.1: 単一要素は return で自動 unwrap されるため Write-Output -NoEnumerate
    # で配列を保持する (アクティブプロジェクトが 1 件のとき WPF が IEnumerable に
    # キャストできず起動エラーになる事故を防ぐ)
    $sorted = @($items | Sort-Object @{Expression='is_favorite'; Descending=$true}, @{Expression='unit_code'; Descending=$false})
    Write-Output -NoEnumerate -InputObject $sorted
}
# ---- プロジェクト候補の絞り込み / 選択ヘルパ ----
# ProjectCombo は編集可能。入力文字で候補を絞り込む (Test-ProjectFilterMatch: コード・名称の部分一致)。
# 絞り込み中は候補外の項目を SelectedValue で選べないため、コードから選択するときは
# 必ず Select-ProjectCode を通して絞り込みを解除する。
# SuppressTemplate > 0 の間はユニット別デフォルト (テンプレート) を適用しない
# (編集・複製の読込や休暇解除の復元で、入力済みの値を上書きしないため)。
$Script:ProjectFilterText = ''
$Script:SuppressTemplate = 0

function Get-ProjectComboView {
    if (-not $ui.ProjectCombo.ItemsSource) { return $null }
    # ICollectionView は IEnumerable なので、そのまま return すると要素に展開されてしまう
    return ,([System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.ProjectCombo.ItemsSource))
}

function Clear-ProjectFilter {
    if (-not $Script:ProjectFilterText) { return }
    $Script:ProjectFilterText = ''
    $v = Get-ProjectComboView
    if ($null -ne $v) { $v.Refresh() }
}

function Select-ProjectCode {
    # Code のプロジェクトを選ぶ (既定は適用しない)。同じユニットコードに複数パターンがあるときは
    # ItemKey (一意キー) か、工程〜タスクのコードを含むパターンの項目を選ぶ。
    # SelectedValue だと常に先頭の項目になり、A2 の実績を開くと A1 のパターンで表示されてしまう
    param([string]$Code, [string]$ProcessCode, [string]$TaskGroupCode, [string]$TaskCode, [string]$ItemKey)
    $Script:SuppressTemplate++
    try {
        Clear-ProjectFilter
        if (-not $Code) { $ui.ProjectCombo.SelectedIndex = -1; return }
        $items = @($ui.ProjectCombo.ItemsSource)
        $target = $null
        if ($ItemKey) { $target = $items | Where-Object { [string]$_.item_key -eq $ItemKey } | Select-Object -First 1 }
        if (-not $target) {
            $target = Find-ProjectForCodes -Items $items -Patterns $Script:TaskPatterns -UnitCode $Code `
                                           -ProcessCode $ProcessCode -TaskGroupCode $TaskGroupCode -TaskCode $TaskCode
        }
        if ($target) { $ui.ProjectCombo.SelectedItem = $target } else { $ui.ProjectCombo.SelectedIndex = -1 }
    } finally { $Script:SuppressTemplate-- }
}

function _SelectComboValue {
    # Value が候補 (.code) にあれば選択して $true。無ければ選択を変えずに $false
    param($Combo, [string]$Value)
    if (-not $Value) { return $false }
    foreach ($it in $Combo.Items) {
        if ([string]$it.code -eq $Value) { $Combo.SelectedItem = $it; return $true }
    }
    return $false
}

function Select-CascadeCodes {
    # 工程 → タスクグループ → タスク を順に選ぶ。途中で候補に無ければ以降は先頭選択のまま。
    # 戻り値: 見つからなかった段の名前 (無ければ '')
    param([string]$ProcessCode, [string]$TaskGroupCode, [string]$TaskCode)
    foreach ($step in @(
        @{ combo = $ui.ProcessCombo;   value = $ProcessCode;   label = '工程' },
        @{ combo = $ui.TaskGroupCombo; value = $TaskGroupCode; label = 'タスクグループ' },
        @{ combo = $ui.TaskCombo;      value = $TaskCode;      label = 'タスク' }
    )) {
        if (-not $step.value) { continue }
        if (-not (_SelectComboValue $step.combo $step.value)) { return $step.label }
    }
    return ''
}

function Set-ProjectComboItems {
    # 候補を作り直す。-Preserve なら選択中のプロジェクト〜タスクを維持する
    # (ItemsSource 差し替えで選択が外れ、カスケードが先頭に戻るのを防ぐ)
    param([switch]$Preserve)
    $snap = $null
    if ($Preserve -and $ui.ProjectCombo.SelectedItem) {
        $snap = @{
            project = [string]$ui.ProjectCombo.SelectedValue
            key     = [string]$ui.ProjectCombo.SelectedItem.item_key
            process = [string]$ui.ProcessCombo.SelectedValue
            group   = [string]$ui.TaskGroupCombo.SelectedValue
            task    = [string]$ui.TaskCombo.SelectedValue
        }
    }
    $Script:SuppressTemplate++
    try {
        $Script:ProjectFilterText = ''
        $ui.ProjectCombo.ItemsSource = Build-ProjectComboItems
        $v = Get-ProjectComboView
        if ($null -ne $v) {
            $v.Filter = [Predicate[object]]{ param($o) Test-ProjectFilterMatch -Item $o -Text $Script:ProjectFilterText }
        }
        if ($snap) {
            Select-ProjectCode $snap.project -ItemKey $snap.key -ProcessCode $snap.process -TaskGroupCode $snap.group -TaskCode $snap.task
            [void](Select-CascadeCodes -ProcessCode $snap.process -TaskGroupCode $snap.group -TaskCode $snap.task)
        }
    } finally { $Script:SuppressTemplate-- }
    Update-ProjectActionButtons
}

function Update-ProjectActionButtons {
    if (-not $ui.FavToggleBtn) { return }
    $p = $ui.ProjectCombo.SelectedItem
    $enabled = ($null -ne $p) -and -not [bool]$ui.IsLeaveChk.IsChecked
    $ui.FavToggleBtn.IsEnabled   = $enabled
    $ui.SaveDefaultBtn.IsEnabled = $enabled
    # Segoe MDL2 Assets: E735 = FavoriteStarFill / E734 = FavoriteStar
    $ui.FavToggleBtn.Content = if ($p -and $p.is_favorite) { [string][char]0xE735 } else { [string][char]0xE734 }
    $ui.FavToggleBtn.ToolTip = if ($p -and $p.is_favorite) { 'お気に入りを解除' } else { 'お気に入りに登録 (一覧の先頭に表示)' }
}

# ユニット別デフォルト (テンプレート) をフォームに適用する。
# カテゴリ・工数は上書き、コメントは空欄のときだけ入れる (先に書いたメモを消さない)
function Apply-UnitDefault {
    param([string]$UnitCode)
    if (-not $Script:CurrentMember -or -not $UnitCode) { return }
    $def = Get-UnitDefault -MemberId ([string]$Script:CurrentMember.id) -UnitCode $UnitCode
    if (-not $def) { return }
    $missed = New-Object System.Collections.Generic.List[string]
    $lost = Select-CascadeCodes -ProcessCode ([string]$def['process_code']) `
                                -TaskGroupCode ([string]$def['task_group_code']) -TaskCode ([string]$def['task_code'])
    if ($lost) { $missed.Add($lost) }
    $cat = [string]$def['category']
    if ($cat -and -not (_SelectComboValue $ui.CategoryCombo $cat)) { $missed.Add('カテゴリ') }
    $h = 0.0
    if ([double]::TryParse([string]$def['hours'], [ref]$h) -and $h -gt 0) {
        $ui.HoursBox.Text = $h.ToString('0.0#')
    }
    $cmt = [string]$def['comment']
    if ($cmt -and [string]::IsNullOrWhiteSpace($ui.CommentBox.Text)) { $ui.CommentBox.Text = $cmt }
    if ($missed.Count -gt 0) {
        Set-Status ("📌 既定を適用しました。{0} は現在の候補に無いため先頭を選択しています (既定の登録し直しを推奨)" -f ($missed -join '・')) '#f9e2af'
    } else {
        Set-Status ("📌 [{0}] の既定を適用しました" -f $UnitCode) '#a6e3a1'
    }
}

Set-ProjectComboItems
Load-RecentComboCount

# 表示名が欄より長いと末尾側が表示されてコード・名称が読めないため、選択後は先頭から見せる
# (選択の確定より後に走らせないと WPF の全選択で末尾に戻される)
function Show-ProjectTextFromStart {
    $ui.ProjectCombo.Dispatcher.BeginInvoke([action]{
        if (-not $ui.ProjectCombo.SelectedItem) { return }
        $tb = $ui.ProjectCombo.Template.FindName('PART_EditableTextBox', $ui.ProjectCombo)
        if ($tb) { $tb.Select(0, 0); $tb.ScrollToHome() }
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}
$ui.ProjectCombo.Add_DropDownClosed({
    try { Show-ProjectTextFromStart } catch { Write-FatalLog "ProjectCombo DropDownClosed: $_" }
})

# 入力文字で候補を絞り込む。選択済み項目の表示文字列と一致している間は絞り込まない
$ui.ProjectCombo.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
    [System.Windows.Controls.TextChangedEventHandler]{
        try {
            $t = [string]$ui.ProjectCombo.Text
            $sel = $ui.ProjectCombo.SelectedItem
            $ft = if ($sel -and $t -eq [string]$sel.display) { '' } else { $t.Trim() }
            if ($ft -eq $Script:ProjectFilterText) { return }
            $Script:ProjectFilterText = $ft
            $v = Get-ProjectComboView
            if ($null -ne $v) { $v.Refresh() }
            if ($ft -and $ui.ProjectCombo.IsKeyboardFocusWithin -and -not $ui.ProjectCombo.IsDropDownOpen) {
                $ui.ProjectCombo.IsDropDownOpen = $true
                # ドロップダウンを開くと入力欄が全選択され、次の 1 文字で上書きされてしまうため
                # キャレットを末尾に戻す (開く処理の後に走らせる)
                $ui.ProjectCombo.Dispatcher.BeginInvoke([action]{
                    $tb = $ui.ProjectCombo.Template.FindName('PART_EditableTextBox', $ui.ProjectCombo)
                    if ($tb) { $tb.SelectionStart = $tb.Text.Length; $tb.SelectionLength = 0 }
                }, [System.Windows.Threading.DispatcherPriority]::Input) | Out-Null
            }
        } catch { Write-FatalLog "ProjectCombo filter: $_" }
    })

function Get-TaskPatternFor {
    param($Project)
    if (-not $Project) { return $null }
    $ptnId = [string]$Project.task_pattern_id
    if (-not $ptnId) { return $null }
    return ($Script:TaskPatterns | Where-Object { $_.id -eq $ptnId } | Select-Object -First 1)
}

function Find-ProjectByCode {
    param([string]$Code)
    if (-not $Code) { return $null }
    return ($Script:Projects | Where-Object { $_.unit_code -eq $Code } | Select-Object -First 1)
}

# コードから表示名を逆引きするヘルパ (DataGrid 表示用)
function Resolve-EntryNames {
    param([string]$ProjCode, [string]$ProcCode, [string]$TgCode, [string]$TaskCode, [string]$CatCode)
    $projName = $ProjCode; $procName = ''; $tgName = ''; $taskName = ''
    # 同じユニットコードに複数パターンがあるときは、コードを含むパターンのプロジェクトで名前を引く
    $proj = Find-ProjectForCodes -Items $Script:Projects -Patterns $Script:TaskPatterns -UnitCode $ProjCode `
                                 -ProcessCode $ProcCode -TaskGroupCode $TgCode -TaskCode $TaskCode
    if ($proj) {
        if ($proj.unit_name) { $projName = [string]$proj.unit_name }
        elseif ($proj.project_name) { $projName = [string]$proj.project_name }
        $ptn = Get-TaskPatternFor -Project $proj
        if ($ptn -and $ptn.processes) {
            $proc = @($ptn.processes) | Where-Object { $_.code -eq $ProcCode } | Select-Object -First 1
            if ($proc) {
                $procName = [string]$proc.name
                if ($proc.task_groups) {
                    $tg = @($proc.task_groups) | Where-Object { $_.code -eq $TgCode } | Select-Object -First 1
                    if ($tg) {
                        $tgName = [string]$tg.name
                        if ($tg.tasks) {
                            $tk = @($tg.tasks) | Where-Object { $_.code -eq $TaskCode } | Select-Object -First 1
                            if ($tk) { $taskName = [string]$tk.name }
                        }
                    }
                }
            }
        }
    }
    $catName = $CatCode
    $cat = $Script:Categories | Where-Object { $_.code -eq $CatCode } | Select-Object -First 1
    if ($cat) { $catName = [string]$cat.name }
    return [pscustomobject]@{
        project_name    = $projName
        process_name    = $procName
        task_group_name = $tgName
        task_name       = $taskName
        category_name   = $catName
    }
}

# ---- プロジェクト wbs_items によるカスケード絞り込みヘルパ ----
# wbs_items が定義されているプロジェクトでは、Tracker のカスケードもそれに合わせて
# 絞り込み、入力ミスを防ぐ。wbs_items 無しなら従来通り (パターン全項目を表示)。
function _ProjectWbsItems {
    param($Project)
    if (-not $Project) { return @() }
    if (-not $Project.PSObject.Properties['wbs_items']) { return @() }
    if (-not $Project.wbs_items) { return @() }
    return @($Project.wbs_items)
}

function _FilterByWbs-Processes {
    param([array]$AllProcs, $Project)
    $wbs = _ProjectWbsItems -Project $Project
    if ($wbs.Count -eq 0) { return $AllProcs }
    $codes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in $wbs) {
        $c = [string]$w.process_code
        if ($c) { [void]$codes.Add($c) }
    }
    return @($AllProcs | Where-Object { $codes.Contains([string]$_.code) })
}

function _FilterByWbs-TaskGroups {
    param([array]$AllGroups, $Project, [string]$ProcessCode)
    $wbs = _ProjectWbsItems -Project $Project
    if ($wbs.Count -eq 0) { return $AllGroups }
    $codes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in $wbs) {
        if (([string]$w.process_code) -ne $ProcessCode) { continue }
        $c = [string]$w.task_group_code
        if ($c) { [void]$codes.Add($c) }
    }
    return @($AllGroups | Where-Object { $codes.Contains([string]$_.code) })
}

function _FilterByWbs-Tasks {
    param([array]$AllTasks, $Project, [string]$ProcessCode, [string]$TaskGroupCode)
    $wbs = _ProjectWbsItems -Project $Project
    if ($wbs.Count -eq 0) { return $AllTasks }
    $codes = New-Object 'System.Collections.Generic.HashSet[string]'
    $allowGroupLevel = $false
    foreach ($w in $wbs) {
        if (([string]$w.process_code)    -ne $ProcessCode)   { continue }
        if (([string]$w.task_group_code) -ne $TaskGroupCode) { continue }
        $c = [string]$w.task_code
        if (-not $c -or $c -eq '-') { $allowGroupLevel = $true; continue }
        [void]$codes.Add($c)
    }
    $filtered = @($AllTasks | Where-Object { $codes.Contains([string]$_.code) })
    # WBS でグループレベル登録あり (task_code='-' or 空) → 「(タスクグループ全体)」を選択肢に
    if ($allowGroupLevel) {
        $groupItem = [pscustomobject]@{ code = '-'; name = '(タスクグループ全体)' }
        $filtered = @($groupItem) + $filtered
    }
    return $filtered
}

$ui.ProjectCombo.Add_SelectionChanged({
    Reset-Cascade -From @('process','task_group','task')
    $p = $ui.ProjectCombo.SelectedItem
    $pattern = Get-TaskPatternFor -Project $p
    if ($pattern -and $pattern.processes) {
        $filtered = _FilterByWbs-Processes -AllProcs @($pattern.processes) -Project $p
        $ui.ProcessCombo.ItemsSource = @($filtered)
        if ($ui.ProcessCombo.Items.Count -gt 0) { $ui.ProcessCombo.SelectedIndex = 0 }
    }
    Update-ProjectActionButtons
    if ($p -and -not $ui.ProjectCombo.IsDropDownOpen) { Show-ProjectTextFromStart }
    if ($p -and $Script:SuppressTemplate -le 0) {
        try { Apply-UnitDefault -UnitCode ([string]$p.unit_code) }
        catch { Write-FatalLog "Apply-UnitDefault: $_"; Set-Status "既定の適用に失敗: $($_.Exception.Message)" '#f38ba8' }
    }
})
$ui.ProcessCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task_group','task')
    $proj = $ui.ProjectCombo.SelectedItem
    $p = $ui.ProcessCombo.SelectedItem
    if ($p -and $p.task_groups) {
        $filtered = _FilterByWbs-TaskGroups -AllGroups @($p.task_groups) -Project $proj -ProcessCode ([string]$p.code)
        $ui.TaskGroupCombo.ItemsSource = @($filtered)
        if ($ui.TaskGroupCombo.Items.Count -gt 0) { $ui.TaskGroupCombo.SelectedIndex = 0 }
    }
    Update-TaskDesc
})
$ui.TaskGroupCombo.Add_SelectionChanged({
    Reset-Cascade -From @('task')
    $proj = $ui.ProjectCombo.SelectedItem
    $proc = $ui.ProcessCombo.SelectedItem
    $g = $ui.TaskGroupCombo.SelectedItem
    if ($g -and $g.tasks) {
        $filtered = _FilterByWbs-Tasks -AllTasks @($g.tasks) -Project $proj `
                                       -ProcessCode ([string]$proc.code) -TaskGroupCode ([string]$g.code)
        $ui.TaskCombo.ItemsSource = @($filtered)
        if ($ui.TaskCombo.Items.Count -gt 0) { $ui.TaskCombo.SelectedIndex = 0 }
    }
    Update-TaskDesc
})
$ui.TaskCombo.Add_SelectionChanged({ Update-TaskDesc })

# 選択中の 工程 / タスクグループ / タスク に説明があれば黄帯で表示
function Update-TaskDesc {
    if (-not $ui.TaskDescBorder) { return }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
        @{ label='工程';           item=$ui.ProcessCombo.SelectedItem },
        @{ label='タスクグループ'; item=$ui.TaskGroupCombo.SelectedItem },
        @{ label='タスク';         item=$ui.TaskCombo.SelectedItem }
    )) {
        $it = $pair.item
        if ($it -and $it.PSObject.Properties['desc']) {
            $d = [string]$it.desc
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                $parts.Add(("【{0}】 {1}" -f $pair.label, $d))
            }
        }
    }
    if ($parts.Count -gt 0) {
        $ui.TaskDescText.Text = ($parts -join "`n")
        $ui.TaskDescBorder.Visibility = 'Visible'
    } else {
        $ui.TaskDescText.Text = ''
        $ui.TaskDescBorder.Visibility = 'Collapsed'
    }
}

# ---- 表示月ロード ----
function Load-ViewMonth {
    # PSCustomObject から取り出した値が配列化していても安全に文字列化
    $raw = $Script:CurrentMember.id
    if ($raw -is [array]) { $raw = $raw[0] }
    $mid = [string]$raw
    if ([string]::IsNullOrWhiteSpace($mid)) { return }
    $y = [int]$ui.YearCombo.SelectedItem
    $m = [int]$ui.MonthCombo.SelectedItem
    $ui.ListTitle.Text = ("📋 {0:D4}/{1:D2} の実績" -f $y, $m)
    Set-Status "読込中: $mid $y/$m..." '#f9e2af'
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        # 値が配列化されている古いデータも安全に取り出せるようヘルパで包む
        function _Scalar { param($v) if ($v -is [array]) { if ($v.Count -gt 0) { $v[0] } else { $null } } else { $v } }
        function _Str    { param($v) [string](_Scalar $v) }
        function _Num    { param($v)
            $s = (_Scalar $v); if ($null -eq $s -or $s -eq '') { return 0.0 }
            $d = 0.0; if ([double]::TryParse([string]$s, [ref]$d)) { return $d } else { return 0.0 }
        }
        $Script:Entries.Clear()
        $loaded = @(Load-MonthEntries -Source $Script:Source -MemberId $mid -Year $y -Month $m)
        foreach ($e in $loaded) {
            $pc  = _Str $e.project_code
            $prc = _Str $e.process_code
            $tgc = _Str $e.task_group_code
            $tkc = _Str $e.task_code
            $ctc = _Str $e.category
            $names = Resolve-EntryNames -ProjCode $pc -ProcCode $prc -TgCode $tgc -TaskCode $tkc -CatCode $ctc
            $isLeaveLoaded = $false
            if ($e.PSObject.Properties['is_leave']) { $isLeaveLoaded = [bool]$e.is_leave }
            $projDisp = $names.project_name
            if ($isLeaveLoaded -and -not $projDisp) { $projDisp = '(休暇)' }
            $Script:Entries.Add([pscustomobject]@{
                date            = _Str $e.date
                project_code    = $pc
                project_name    = $projDisp
                process_code    = $prc
                process_name    = $names.process_name
                task_group_code = $tgc
                task_group_name = $names.task_group_name
                task_code       = $tkc
                task_name       = $names.task_name
                category        = $ctc
                category_name   = $names.category_name
                is_leave        = $isLeaveLoaded
                # 休暇は工数 0 で扱う (旧データに工数が入っていても 0 に正規化し、保存し直せばファイルも直る)
                hours           = if ($isLeaveLoaded) { 0.0 } else { _Num $e.hours }
                comment         = _Str $e.comment
                dirty           = ''
                dirty_mark      = ''
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

$ui.YearCombo.Add_SelectionChanged({ Load-ViewMonth })
$ui.MonthCombo.Add_SelectionChanged({ Load-ViewMonth })

$ui.EntryDate.SelectedDate = [datetime]::Today
if ($ui.PrevDayBtn) {
    $ui.PrevDayBtn.Add_Click({
        $curr = if ($ui.EntryDate.SelectedDate) { [datetime]$ui.EntryDate.SelectedDate } else { [datetime]::Today }
        $ui.EntryDate.SelectedDate = $curr.AddDays(-1)
    })
}
if ($ui.NextDayBtn) {
    $ui.NextDayBtn.Add_Click({
        $curr = if ($ui.EntryDate.SelectedDate) { [datetime]$ui.EntryDate.SelectedDate } else { [datetime]::Today }
        $ui.EntryDate.SelectedDate = $curr.AddDays(1)
    })
}
$ui.TodayBtn.Add_Click({ $ui.EntryDate.SelectedDate = [datetime]::Today })
$ui.YesterdayBtn.Add_Click({ $ui.EntryDate.SelectedDate = ([datetime]::Today).AddDays(-1) })
$ui.EntryDate.Add_SelectedDateChanged({ Update-HoursDay })

if ($ui.WbsNavBtn) {
    $ui.WbsNavBtn.Add_Click({ Start-AppScreen (Join-Path $PSScriptRoot 'WbsInput.ps1') })
}
if ($ui.ReportNavBtn) {
    $ui.ReportNavBtn.Add_Click({ Start-AppScreen (Join-Path (Split-Path -Parent $PSScriptRoot) 'reports\ReportViewer.ps1') })
}

# クイック工数ボタン
$Script:HoursQuickBtns = New-Object System.Collections.Generic.List[object]
foreach ($n in 'H025','H05','H1','H2','H4','H8') {
    $b = $Script:Window.FindName($n)
    if ($b) {
        $b.Add_Click({ param($s,$e) $ui.HoursBox.Text = [string]$s.Tag; $ui.HoursBox.Focus() | Out-Null }.GetNewClosure())
        [void]$Script:HoursQuickBtns.Add($b)
    }
}

# 休暇は作業工数ではないため、チェック中は工数を 0 に固定し入力させない。
# 解除時は直前の値 (無ければ 1.0) に戻す。
$Script:HoursBeforeLeave = '1.0'
# 休暇チェック時に退避したプロジェクト (チェックを外したら選び直さずに済むよう戻す)
$Script:ProjectBeforeLeave = ''
function Set-LeaveFormState {
    param([bool]$IsLeave)
    if ($IsLeave) {
        if ($ui.HoursBox.Text -ne '0.0') { $Script:HoursBeforeLeave = $ui.HoursBox.Text }
        $ui.HoursBox.Text = '0.0'
        # 休暇はプロジェクト/工程/タスクを持たない (チェックボックスの表記どおり)。
        # 選択したままにすると、そのプロジェクトがエントリに紛れ込んでしまうため
        # 退避してから選択を外す。工数欄と同じ「退避して戻す」方式に揃えている
        $Script:ProjectBeforeLeave = [string]$ui.ProjectCombo.SelectedValue
        $Script:ProjectKeyBeforeLeave = if ($ui.ProjectCombo.SelectedItem) { [string]$ui.ProjectCombo.SelectedItem.item_key } else { '' }
        $Script:CascadeBeforeLeave = @{
            process = [string]$ui.ProcessCombo.SelectedValue
            group   = [string]$ui.TaskGroupCombo.SelectedValue
            task    = [string]$ui.TaskCombo.SelectedValue
        }
        $ui.ProjectCombo.SelectedIndex = -1
        Reset-Cascade -From @('process','task_group','task')
    } else {
        if ($ui.HoursBox.Text -eq '0.0') { $ui.HoursBox.Text = $Script:HoursBeforeLeave }
        if ($Script:ProjectBeforeLeave) {
            Select-ProjectCode $Script:ProjectBeforeLeave -ItemKey $Script:ProjectKeyBeforeLeave
            # 工程〜タスクも休暇チェック前の選択に戻す (先頭に戻ると選び直しになるため)
            $cb = $Script:CascadeBeforeLeave
            if ($cb) { [void](Select-CascadeCodes -ProcessCode $cb.process -TaskGroupCode $cb.group -TaskCode $cb.task) }
        }
        $Script:ProjectBeforeLeave = ''
    }
    $ui.HoursBox.IsEnabled = (-not $IsLeave)
    foreach ($btn in $Script:HoursQuickBtns) { $btn.IsEnabled = (-not $IsLeave) }
    # 選択できてしまうと「入らないはずのプロジェクトを選んだ」状態になるので操作自体を塞ぐ
    foreach ($cb in @($ui.ProjectCombo, $ui.ProcessCombo, $ui.TaskGroupCombo, $ui.TaskCombo)) {
        $cb.IsEnabled = (-not $IsLeave)
    }
    Update-ProjectActionButtons
}
$ui.IsLeaveChk.Add_Checked({   Set-LeaveFormState $true })
$ui.IsLeaveChk.Add_Unchecked({ Set-LeaveFormState $false })

# ---- フォーム → エントリ ----
function Get-EntryFromForm {
    $d = $ui.EntryDate.SelectedDate
    if (-not $d) { throw '日付を選択してください' }
    $proj = $ui.ProjectCombo.SelectedItem
    $proc = $ui.ProcessCombo.SelectedItem
    $tg   = $ui.TaskGroupCombo.SelectedItem
    $task = $ui.TaskCombo.SelectedItem
    $cat  = $ui.CategoryCombo.SelectedItem

    # 休暇チェック (フォームの IsLeaveChk) — エントリ属性として扱う
    $isLeave = [bool]$ui.IsLeaveChk.IsChecked

    if ($isLeave) {
        # 休暇はプロジェクト/工程/タスクを持たない。UI 側 (Set-LeaveFormState) でも
        # 選択を外しているが、編集経路やコンボの状態に依存せず必ず空にする。
        # ここを省くと、プロジェクト選択後に休暇へ切り替えたエントリに
        # そのプロジェクトが残る (2026-08-22 の不具合)
        $proj = $null; $proc = $null; $tg = $null; $task = $null
    }

    if (-not $isLeave) {
        if (-not $proj) { throw 'プロジェクトを選択してください (休暇は ☑ 休暇 をチェック)' }
        if (-not $proc -and $ui.ProcessCombo.Items.Count -gt 0) { throw '工程を選択してください' }
        if (-not $tg   -and $ui.TaskGroupCombo.Items.Count -gt 0) { throw 'タスクグループを選択してください' }
        if (-not $task -and $ui.TaskCombo.Items.Count -gt 0) { throw 'タスクを選択してください' }
    }
    # 休暇のときは proj/proc/tg/task すべて任意。カテゴリは無くても OK。
    # 休暇は作業工数ではないため常に 0 とし、工数欄は見ない。
    $hours = 0.0
    if (-not $isLeave) {
        if (-not [double]::TryParse($ui.HoursBox.Text, [ref]$hours) -or $hours -le 0) {
            throw '工数は正の数値で入力してください'
        }
    }

    # 対象期間チェック (period_from / period_to を持つプロジェクトのみ; 休暇は対象外)
    if (-not $isLeave -and $proj) {
        if ($proj.period_from) {
            $pf = [datetime]::MinValue
            if ([datetime]::TryParse([string]$proj.period_from, [ref]$pf) -and $d -lt $pf) {
                throw ("日付 {0} は対象期間 (FROM: {1}) より前です" -f $d.ToString('yyyy-MM-dd'), $proj.period_from)
            }
        }
        if ($proj.period_to) {
            $pt = [datetime]::MinValue
            if ([datetime]::TryParse([string]$proj.period_to, [ref]$pt) -and $d -gt $pt) {
                throw ("日付 {0} は対象期間 (TO: {1}) より後です" -f $d.ToString('yyyy-MM-dd'), $proj.period_to)
            }
        }
    }

    return [pscustomobject]@{
        date            = $d.ToString('yyyy-MM-dd')
        project_code    = if ($proj) { [string]$proj.unit_code }    else { '' }
        project_name    = if ($proj) { if ($proj.unit_name) { [string]$proj.unit_name } else { [string]$proj.project_name } } else { if ($isLeave) { '(休暇)' } else { '' } }
        process_code    = if ($proc) { [string]$proc.code } else { '' }
        process_name    = if ($proc) { [string]$proc.name } else { '' }
        task_group_code = if ($tg)   { [string]$tg.code }   else { '' }
        task_group_name = if ($tg)   { [string]$tg.name }   else { '' }
        task_code       = if ($task) { [string]$task.code } else { '' }
        task_name       = if ($task) { [string]$task.name } else { '' }
        category        = if ($cat)  { [string]$cat.code }  else { '' }
        category_name   = if ($cat)  { [string]$cat.name }  else { '' }
        is_leave        = $isLeave
        hours           = $hours
        dirty           = 'yes'
        dirty_mark      = '●'
        comment         = [string]$ui.CommentBox.Text
    }
}

# ---- フォーム → エントリ反映 (編集) ----
# WPF の SelectionChanged は同期的に発火するので、SelectedValue を順に設定するだけで
# カスケード ItemsSource が逐次セットされる。Dispatcher.BeginInvoke は不要。
function Set-FormFromEntry {
    param($Entry)
    try { $ui.EntryDate.SelectedDate = [datetime]::Parse($Entry.date) } catch {}
    # 既定 (テンプレート) は適用しない: 行の値をそのまま復元する
    Select-ProjectCode ([string]$Entry.project_code) -ProcessCode ([string]$Entry.process_code) `
                       -TaskGroupCode ([string]$Entry.task_group_code) -TaskCode ([string]$Entry.task_code)
    $ui.ProcessCombo.SelectedValue   = $Entry.process_code
    $ui.TaskGroupCombo.SelectedValue = $Entry.task_group_code
    $ui.TaskCombo.SelectedValue      = $Entry.task_code
    $ui.CategoryCombo.SelectedValue  = $Entry.category
    $ui.HoursBox.Text = [string]$Entry.hours
    $ui.CommentBox.Text = $Entry.comment
    # 休暇フラグも復元
    $leaveVal = $false
    if ($Entry.PSObject.Properties['is_leave']) { $leaveVal = [bool]$Entry.is_leave }
    $ui.IsLeaveChk.IsChecked = $leaveVal
}

function Clear-Form {
    $ui.EntryDate.SelectedDate = [datetime]::Today
    Select-ProjectCode ''
    $ui.ProjectCombo.Text = ''
    Reset-Cascade -From @('process','task_group','task')
    $ui.CategoryCombo.SelectedIndex = -1
    $ui.HoursBox.Text = '1.0'
    $ui.CommentBox.Text = ''
    $ui.IsLeaveChk.IsChecked = $false
    $Script:EditingItem = $null
    $ui.FormHeader.Text = '新規エントリ'
    $ui.AddBtn.Visibility = 'Visible'
    $ui.UpdateBtn.Visibility = 'Collapsed'
    Select-InitialProject
}

# 個人設定の初期プロジェクトを選ぶ (起動時・クリア時)。通常の選択として扱うため、
# 📌 既定があれば工程〜コメントも入る。無効化・削除済みなら何もしない
function Select-InitialProject {
    if (-not $Script:CurrentMember) { return }
    try {
        $code = Get-InitialProject -MemberId ([string]$Script:CurrentMember.id)
        if (-not $code) { return }
        Clear-ProjectFilter
        $ui.ProjectCombo.SelectedValue = $code
    } catch { Write-FatalLog "Select-InitialProject: $_" }
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

# ---- 複製 (選択行の内容をフォームへ。Add すれば新規行として追加) ----
$ui.DuplicateBtn.Add_Click({
    $sel = $ui.EntriesGrid.SelectedItem
    if ($null -eq $sel) { return }
    Clear-Form
    Set-FormFromEntry -Entry $sel
    Set-Status "選択行をフォームに複製しました。値を編集して『追加』してください。" '#89b4fa'
})

# ---- お気に入り切替 (☆/★) ----
$ui.FavToggleBtn.Add_Click({
    try {
        $p = $ui.ProjectCombo.SelectedItem
        if (-not $p -or -not $Script:CurrentMember) { return }
        $toFav = -not [bool]$p.is_favorite
        Set-FavoriteProject -MemberId ([string]$Script:CurrentMember.id) -UnitCode ([string]$p.unit_code) -IsFavorite $toFav
        Set-ProjectComboItems -Preserve
        $msg = if ($toFav) { 'お気に入りに登録しました' } else { 'お気に入りを解除しました' }
        Set-Status ("⭐ [{0}] {1}" -f $p.unit_code, $msg) '#10b981'
    } catch {
        Show-ErrorDialog -Title 'お気に入りエラー' -Message $_.Exception.Message -Detail $_.ScriptStackTrace
    }
})

# ---- 既定 (ユニット別デフォルト) に登録 ----
$ui.SaveDefaultBtn.Add_Click({
    try {
        $p = $ui.ProjectCombo.SelectedItem
        if (-not $p -or -not $Script:CurrentMember) { return }
        $mid = [string]$Script:CurrentMember.id
        $uc  = [string]$p.unit_code
        $h = 0.0
        if (-not [double]::TryParse($ui.HoursBox.Text, [ref]$h) -or $h -lt 0) { $h = 0.0 }
        $def = @{
            process_code    = [string]$ui.ProcessCombo.SelectedValue
            task_group_code = [string]$ui.TaskGroupCombo.SelectedValue
            task_code       = [string]$ui.TaskCombo.SelectedValue
            category        = [string]$ui.CategoryCombo.SelectedValue
            hours           = $h
            comment         = [string]$ui.CommentBox.Text
        }
        $nm = { param($c) if ($c.SelectedItem) { [string]$c.SelectedItem.name } else { '(なし)' } }
        $hoursText = if ($h -gt 0) { '{0} h' -f $h.ToString('0.0#') } else { '(変更しない)' }
        $cmtText = if ($def.comment) { $def.comment } else { '(なし)' }
        $overwrite = if (Get-UnitDefault -MemberId $mid -UnitCode $uc) { "`n※ 登録済みの既定を上書きします。" } else { '' }
        $msg = ("[{0}] を選んだときに、次の値を自動で入力します。{1}`n`n" +
                "工程: {2}`nタスクグループ: {3}`nタスク: {4}`nカテゴリ: {5}`n工数: {6}`nコメント: {7}`n`n登録しますか?") -f `
               $uc, $overwrite, (& $nm $ui.ProcessCombo), (& $nm $ui.TaskGroupCombo), (& $nm $ui.TaskCombo),
               (& $nm $ui.CategoryCombo), $hoursText, $cmtText
        $r = [System.Windows.MessageBox]::Show($msg, '既定に登録', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        Set-UnitDefault -MemberId $mid -UnitCode $uc -Default $def
        Set-ProjectComboItems -Preserve
        Set-Status ("📌 [{0}] の既定を登録しました (解除は『お気に入り』画面から)" -f $uc) '#10b981'
    } catch {
        Show-ErrorDialog -Title '既定の登録エラー' -Message $_.Exception.Message -Detail $_.ScriptStackTrace
    }
})

# ---- 直前の入力日の実績をこの日にコピー ----
$ui.CopyPrevDayBtn.Add_Click({
    try {
        $d = $ui.EntryDate.SelectedDate
        if (-not $d) { throw '日付を選択してください' }
        $d = ([datetime]$d).Date
        $vy = [int]$ui.YearCombo.SelectedItem
        $vm = [int]$ui.MonthCombo.SelectedItem
        if ($d.Year -ne $vy -or $d.Month -ne $vm) {
            throw ("コピー先の日付 ({0}) は表示中の {1}/{2} の日付にしてください" -f $d.ToString('yyyy-MM-dd'), $vy, $vm)
        }
        $src = Find-PreviousWorkDayEntries -Entries $Script:Entries -Date $d
        if ($src.Count -eq 0) {
            # 月初は前月ファイルにしか直前の実績が無いので、前月分も探す
            $prev = (New-Object -TypeName datetime -ArgumentList $vy, $vm, 1).AddMonths(-1)
            $more = @(Load-MonthEntries -Source $Script:Source -MemberId ([string]$Script:CurrentMember.id) -Year $prev.Year -Month $prev.Month)
            $src = Find-PreviousWorkDayEntries -Entries $more -Date $d
        }
        if ($src.Count -eq 0) {
            Set-Status '直前の入力日の実績が見つかりませんでした' '#f9e2af'
            return
        }
        $srcDate = _EaStr $src[0].date
        $target = $d.ToString('yyyy-MM-dd')
        # 対象期間外のプロジェクトはコピーしない (追加時と同じ制約)。確認の前に除外して件数を正しく見せる
        $copyable = New-Object System.Collections.Generic.List[object]
        $skipped = New-Object System.Collections.Generic.List[string]
        foreach ($e in $src) {
            $pc = _EaStr $e.project_code
            $proj = Find-ProjectByCode -Code $pc
            $pf = [datetime]::MinValue; $pt = [datetime]::MinValue
            if ($proj -and (($proj.period_from -and [datetime]::TryParse([string]$proj.period_from, [ref]$pf) -and $d -lt $pf) -or
                            ($proj.period_to   -and [datetime]::TryParse([string]$proj.period_to,   [ref]$pt) -and $d -gt $pt))) {
                if (-not $skipped.Contains($pc)) { $skipped.Add($pc) }
                continue
            }
            $copyable.Add($e)
        }
        $skipNote = if ($skipped.Count -gt 0) { "`n※ 対象期間外のプロジェクト ({0}) の行はコピーしません。" -f ($skipped -join ', ') } else { '' }
        if ($copyable.Count -eq 0) {
            [System.Windows.MessageBox]::Show(("{0} の実績はすべて {1} が対象期間外のためコピーできません。{2}" -f $srcDate, $target, $skipNote),
                '直前の入力日の実績をコピー', 'OK', 'Information') | Out-Null
            return
        }
        $existing = @($Script:Entries | Where-Object { [string]$_.date -eq $target }).Count
        $note = if ($existing -gt 0) { "`n※ {0} には既に {1} 件あります (追加になります)。" -f $target, $existing } else { '' }
        $msg = ("{0} の実績 {1} 件 ({2:N1} h) を {3} にコピーします。{4}{5}`n`nコピー後に工数やコメントを確認してください。" -f `
                $srcDate, $copyable.Count, (Get-EntryHoursSum $copyable.ToArray()), $target, $note, $skipNote)
        $r = [System.Windows.MessageBox]::Show($msg, '直前の入力日の実績をコピー', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }

        foreach ($e in $copyable) {
            $pc  = _EaStr $e.project_code
            $prc = _EaStr $e.process_code; $tgc = _EaStr $e.task_group_code
            $tkc = _EaStr $e.task_code;    $ctc = _EaStr $e.category
            $n = Resolve-EntryNames -ProjCode $pc -ProcCode $prc -TgCode $tgc -TaskCode $tkc -CatCode $ctc
            $hours = 0.0
            [void][double]::TryParse((_EaStr $e.hours), [ref]$hours)
            $Script:Entries.Add([pscustomobject]@{
                date            = $target
                project_code    = $pc
                project_name    = $n.project_name
                process_code    = $prc
                process_name    = $n.process_name
                task_group_code = $tgc
                task_group_name = $n.task_group_name
                task_code       = $tkc
                task_name       = $n.task_name
                category        = $ctc
                category_name   = $n.category_name
                is_leave        = $false
                hours           = $hours
                comment         = _EaStr $e.comment
                dirty           = 'yes'
                dirty_mark      = '●'
            })
        }
        Update-HoursTotal
        Set-Status ("{0} の実績 {1} 件を {2} にコピーしました (未保存)" -f $srcDate, $copyable.Count, $target) '#89b4fa'
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'コピーできません', 'OK', 'Warning') | Out-Null
    }
})

# ---- 保存ロジック (共通) ----
# 戻り値: @{ Ok=bool; MemberId=string; MemberName=string; Year=int; Month=int; Count=int; ErrorDetail=string }
function _DoLocalSave {
    $m = Get-SelectedMember
    if (-not $m) { return @{ Ok = $false; ErrorDetail = '作業者が未選択です' } }
    $vy = [int]$ui.YearCombo.SelectedItem
    $vm = [int]$ui.MonthCombo.SelectedItem

    function _Sc { param($v) if ($v -is [array]) { if ($v.Count -gt 0) { $v[0] } else { $null } } else { $v } }
    $clean = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Script:Entries) {
        if (-not $e) { continue }
        $d = [string](_Sc $e.date)
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $h = 0.0
        [void][double]::TryParse([string](_Sc $e.hours), [ref]$h)
        $isLeaveE = $false
        if ($e.PSObject.Properties['is_leave']) { $isLeaveE = [bool](_Sc $e.is_leave) }
        $clean.Add([pscustomobject]@{
            date            = $d
            project_code    = [string](_Sc $e.project_code)
            process_code    = [string](_Sc $e.process_code)
            task_group_code = [string](_Sc $e.task_group_code)
            task_code       = [string](_Sc $e.task_code)
            category        = [string](_Sc $e.category)
            is_leave        = $isLeaveE
            hours           = $h
            comment         = [string](_Sc $e.comment)
        })
    }
    $entriesArr = $clean.ToArray()
    $midRaw = $m.id;   if ($midRaw   -is [array]) { $midRaw   = $midRaw[0] }
    $nameRaw = $m.name; if ($nameRaw -is [array]) { $nameRaw = $nameRaw[0] }
    $midStr  = [string]$midRaw
    $nameStr = [string]$nameRaw
    Write-FatalLog ("Save: member={0} view={1}/{2} count={3}" -f $midStr, $vy, $vm, $entriesArr.Count)

    try {
        Save-EntriesGrouped -Source $Script:Source -MemberId $midStr `
                            -AllEntries $entriesArr `
                            -ViewYear $vy -ViewMonth $vm `
                            -AuthorName $nameStr -AuthorEmail "$midStr@worktime-tracker.local"
        return @{ Ok = $true; MemberId = $midStr; MemberName = $nameStr; Year = $vy; Month = $vm; Count = $entriesArr.Count }
    } catch {
        $detail = "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)`n`n$($_.Exception.InnerException | Out-String)"
        Write-FatalLog "SAVE FAIL: $detail"
        return @{ Ok = $false; ErrorDetail = $detail }
    }
}

# ---- 保存ボタン (ローカルのみ) ----
$ui.SaveBtn.Add_Click({
    Set-Status "保存中..." '#f9e2af'
    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $r = _DoLocalSave
        if ($r.Ok) {
            # 保存成功 → 再読込 (全行クリーンに)
            Load-ViewMonth
            Set-Status "保存完了 ($($r.MemberId) $($r.Year)/$($r.Month))" '#a6e3a1'
            [System.Windows.MessageBox]::Show("ローカルに保存しました。`nGitlab にも反映するには『送信』を押してください。", '保存完了', 'OK', 'Information') | Out-Null
        } else {
            Set-Status "保存失敗 (詳細はダイアログ)" '#f38ba8'
            Show-ErrorDialog -Title '保存失敗' -Message '保存に失敗しました。' -Detail $r.ErrorDetail
        }
    } finally {
        $Script:Window.Cursor = $null
    }
})

# ---- 再読込 / 設定 / 管理者 ----
$ui.ReloadBtn.Add_Click({
    # 📋 読込 = ローカルから再読込のみ (pull なし)
    Reload-Masters
    Load-ViewMonth
})
$ui.PullBtn.Add_Click({
    # 📥 取得 = リモート pull → ローカル読込
    if (-not $Script:Source.RemoteCtx) {
        [System.Windows.MessageBox]::Show('スタンドアローンモードでは「取得」は使えません。「読込」を使ってください。', '取得', 'OK', 'Information') | Out-Null
        return
    }
    Set-Status 'リモートから取得中...' '#f9e2af'
    try {
        Reload-Masters -Pull
        # 当月の自分のデータも pull
        $mid = if ($Script:CurrentMember) { [string]$Script:CurrentMember.id } else { [string]$Script:Config.member_id }
        $vy = [int]$ui.YearCombo.SelectedItem
        $vm = [int]$ui.MonthCombo.SelectedItem
        if ($mid -and $vy -gt 0 -and $vm -gt 0) {
            $r = Sync-Pull-MyData -Source $Script:Source -MemberId $mid -Year $vy -Month $vm
            Write-FatalLog ("My data pull: pulled={0} missing={1} errors={2}" -f $r.Pulled, $r.Missing, $r.Errors.Count)
        }
        Clear-RemoteUpdateNotice -Source $Script:Source -Master -DataPath (Get-MonitorDataPath)
        $ui.RemoteNoticeText.Visibility = 'Collapsed'
        Load-ViewMonth
        Set-Status 'リモートから取得 → ローカル読込 完了' '#10b981'
    } catch {
        Set-Status ("取得失敗: $($_.Exception.Message)") '#ef4444'
        Show-ErrorDialog -Title '取得エラー' -Message 'リモートからの取得に失敗しました。' -Detail "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
    }
})

# ---- 個人設定 (お気に入り) ----
$ui.UserPrefsBtn.Add_Click({
    if (-not $Script:CurrentMember) { return }
    try {
        $changed = Show-UserPrefsDialog -MemberId ([string]$Script:CurrentMember.id) `
                                        -MemberName ([string]$Script:CurrentMember.name) `
                                        -Projects $Script:Projects
        if ($changed) {
            # Project Combo を再構築 (お気に入りが上に来る)。入力中の選択は維持する
            Set-ProjectComboItems -Preserve
            Load-RecentComboCount
            Update-RecentCombos
            Set-Status '個人設定を保存しました。プロジェクト一覧を更新。' '#10b981'
        }
    } catch {
        Show-ErrorDialog -Title '個人設定エラー' -Message $_.Exception.Message -Detail $_.ScriptStackTrace
    }
})

$ui.SettingsBtn.Add_Click({
    $newCtx = Initialize-AppContext -ForceDialog
    if ($newCtx) {
        $Script:Config       = $newCtx['Config']
        Update-LogPath -Config $Script:Config
        $Script:Source       = $newCtx['Source']
        $Script:Token        = $newCtx['Token']
        $Script:Members      = @($newCtx['Members'])
        $Script:Projects     = @($newCtx['Projects'])
        $Script:Categories   = @($newCtx['Categories'])
        $Script:TaskPatterns = @($newCtx['TaskPatterns'])
        $ui.ModeText.Text = switch ($Script:Config.mode) {
    'gitlab' { "Gitlab モード | {0} / {1} @ {2} | local: {3}" -f $Script:Config.gitlab_url, $Script:Config.project_id, $Script:Config.branch, $Script:Config.local_store }
    default  { "スタンドアローン | {0}" -f $Script:Config.local_store }
}

        $Script:CurrentMember = $Script:Members | Where-Object { $_.id -eq $Script:Config.member_id -and $_.active } | Select-Object -First 1
        if (-not $Script:CurrentMember) {
            $Script:CurrentMember = [pscustomobject]@{ id = $Script:Config.member_id; name = '(未登録)'; role = 'member' }
        }
        $ui.CurrentMemberText.Text = ("{0}  {1}" -f $Script:CurrentMember.id, $Script:CurrentMember.name)
        if (Has-Role -Member $Script:CurrentMember -Role 'admin') { $ui.AdminBtn.Visibility = 'Visible' } else { $ui.AdminBtn.Visibility = 'Collapsed' }

        $ui.CategoryCombo.ItemsSource = $Script:Categories
        Load-TrackerHolidays
        Set-ProjectComboItems
        Load-RecentComboCount
        Load-ViewMonth
    }
})

$ui.AdminBtn.Add_Click({
    $m = Get-SelectedMember
    # 旧 $m.role -ne 'admin' だと roles 配列スキーマで silent return していたため
    # Has-Role に統一
    if (-not $m -or -not (Has-Role -Member $m -Role 'admin')) {
        Write-FatalLog ("AdminBtn click ignored: member=[{0}] roles=[{1}]" -f `
            ($m | ConvertTo-Json -Compress -ErrorAction SilentlyContinue), `
            ((Get-MemberRoles -Member $m) -join ','))
        return
    }
    try {
        Show-AdminDialog -Source $Script:Source -MemberId $m.id -MemberName $m.name
        Reload-Masters
    } catch {
        $inner = $_
        while ($inner.Exception.InnerException) { $inner = $inner.Exception.InnerException }
        $detail = "{0}`n`n--- 内部例外 ---`n{1}`n`n--- ScriptStackTrace ---`n{2}" -f `
            $_.Exception.Message, ($inner | Out-String), $_.ScriptStackTrace
        Write-FatalLog "ADMIN: $detail"
        Show-ErrorDialog -Title 'マスタ編集エラー' -Message '管理者画面でエラーが発生しました。' -Detail $detail
    }
})

# ---- 保存先を開く ----
# スタンドアローン: ローカルフォルダのみ / Gitlab モード: ローカル or Gitlab リポジトリ
$ui.OpenFolderBtn.Add_Click({
    try {
        if ($Script:Config.mode -eq 'gitlab') {
            $r = [System.Windows.MessageBox]::Show(
                "どちらを開きますか?`n`n[はい] ローカル保管先 (Explorer)`n[いいえ] Gitlab リポジトリ (ブラウザ)",
                '保存先を開く', 'YesNoCancel', 'Question')
            if ($r -eq 'Cancel') { return }
            if ($r -eq 'Yes') {
                $path = $Script:Config.local_store
                if (-not $path -or -not (Test-Path -LiteralPath $path)) {
                    [System.Windows.MessageBox]::Show("ローカル保存先が見つかりません:`n$path", 'エラー', 'OK', 'Warning') | Out-Null
                    return
                }
                Start-Process explorer.exe -ArgumentList "`"$path`""
            } else {
                Set-Status '保存先 URL を取得中...' '#6b7280'
                $proj = Test-GitLabConnection -Ctx $Script:Source.RemoteCtx
                $url = if ($proj.web_url) { $proj.web_url } else { '{0}/{1}' -f $Script:Config.gitlab_url.TrimEnd('/'), $Script:Config.project_id }
                Set-Status "ブラウザで開く: $url" '#10b981'
                Start-Process $url
            }
        } else {
            # スタンドアローン: ローカルフォルダのみ
            $path = $Script:Config.local_store
            if (-not $path -or -not (Test-Path -LiteralPath $path)) {
                [System.Windows.MessageBox]::Show("ローカル保存先が見つかりません:`n$path", 'エラー', 'OK', 'Warning') | Out-Null
                return
            }
            Start-Process explorer.exe -ArgumentList "`"$path`""
        }
    } catch {
        [System.Windows.MessageBox]::Show("保存先を開けませんでした:`n$_", 'エラー', 'OK', 'Error') | Out-Null
    }
})

# ---- 📤 送信 (自分の全データを local → リモートへ) ----
# ---- 送信ボタン (= ローカル保存 → リモート push) ----
$ui.PushBtn.Add_Click({
    if (-not $Script:Source.RemoteCtx) {
        [System.Windows.MessageBox]::Show('現在はスタンドアローンモードです。送信するには設定で Gitlab モードに切替えてください。', '送信不可', 'OK', 'Information') | Out-Null
        return
    }
    $m = Get-SelectedMember
    if (-not $m) { return }

    $Script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    Set-SyncBusy $true '送信を準備しています…'
    try {
        # Step 1: ローカル保存
        Set-Status '送信: ローカル保存中...' '#f9e2af'
        $saveResult = _DoLocalSave
        if (-not $saveResult.Ok) {
            Set-Status '送信中断 (ローカル保存失敗)' '#f38ba8'
            Show-ErrorDialog -Title '送信失敗 (保存ステップ)' -Message 'ローカル保存に失敗したため送信を中断しました。' -Detail $saveResult.ErrorDetail
            return
        }
        # 保存成功 → ダーティ表示を消すため reload
        Load-ViewMonth

        # Step 2: リモート push
        Set-Status '送信: Gitlab へ push 中...' '#f9e2af'
        $midStr  = $saveResult.MemberId
        $nameStr = $saveResult.MemberName
        $onProgress = {
            param($Index, $Total, $Path)
            Set-SyncBusy $true ("GitLab へ送信中… ({0}/{1}) {2}" -f $Index, $Total, $Path)
        }
        $result = Sync-Push-MyData -Source $Script:Source -MemberId $midStr `
                                   -AuthorName $nameStr -AuthorEmail "$midStr@worktime-tracker.local" -OnProgress $onProgress
        $summary = "保存 → 送信 完了`n  保存: {0} 件 ({1}/{2})`n  push: {3}`n  リモートが新しいためスキップ: {4}`n  変更なし: {5}`n  エラー: {6}" -f `
            $saveResult.Count, $saveResult.Year, $saveResult.Month, `
            $result.Pushed, $result.SkippedNewer, $result.SkippedSame, $result.Errors.Count
        if ($result.Conflicts.Count -gt 0) {
            $confLines = $result.Conflicts | ForEach-Object { "  - {0}  (local: {1} / remote: {2})" -f $_.path, $_.local_updated, $_.remote_updated }
            $summary += "`n`n[競合 (リモート優先でスキップ)]`n" + ($confLines -join "`n")
        }
        if ($result.Errors.Count -gt 0) {
            $summary += "`n`n[エラー]`n" + (($result.Errors | Select-Object -First 5) -join "`n")
        }
        Write-FatalLog "PUSH: $summary"
        Suppress-RemoteUpdateNotice -Source $Script:Source -DataPath (Get-MonitorDataPath)
        $ui.RemoteNoticeText.Visibility = 'Collapsed'
        Set-Status ("送信完了 (保存={0} push={1})" -f $saveResult.Count, $result.Pushed) '#10b981'
        if ($result.Errors.Count -gt 0 -or $result.Conflicts.Count -gt 0) {
            Show-ErrorDialog -Title '送信結果' -Message '送信を実行しました (詳細)' -Detail $summary
        } else {
            [System.Windows.MessageBox]::Show($summary, '送信完了', 'OK', 'Information') | Out-Null
        }
    } catch {
        $detail = "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
        Write-FatalLog "PUSH FAIL: $detail"
        Set-Status "送信失敗 (詳細はダイアログ)" '#f38ba8'
        Show-ErrorDialog -Title '送信失敗' -Message '送信に失敗しました。' -Detail $detail
    } finally {
        Set-SyncBusy $false
        $Script:Window.Cursor = $null
    }
})

# ---- 初回ロード ----
# 画面を一度描画してから実績を読み込む。初期データ読込・名称解決で時間が掛かっても、
# 白画面のまま応答なしに見えることを防ぐ。
$Script:InitialViewLoadStarted = $false
$Script:InitialViewLoadTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:InitialViewLoadTimer.Interval = [timespan]::FromMilliseconds(100)
$Script:InitialViewLoadTimer.Add_Tick({
    $Script:InitialViewLoadTimer.Stop()
    try {
        Write-FatalLog 'UI rendered; initial month load started'
        Load-ViewMonth
        Write-FatalLog 'Initial month load completed'
    } catch {
        Write-FatalLog "Initial month load failed: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
        Set-Status '初期読込に失敗しました。詳細はログを確認してください。' '#f38ba8'
    }
})
$Script:Window.Add_ContentRendered({
    if ($Script:InitialViewLoadStarted) { return }
    $Script:InitialViewLoadStarted = $true
    $Script:InitialViewLoadTimer.Start()
})

# 5 分ごとに、画面を止めず GitLab の blob ID だけを照会する。取得・上書きはしない。
if ($Script:Source.RemoteCtx) {
    $Script:RemoteUpdateProbe = $null
    $Script:RemoteUpdatePollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:RemoteUpdatePollTimer.Interval = [timespan]::FromSeconds(1)
    $Script:RemoteUpdatePollTimer.Add_Tick({
        $result = Complete-RemoteUpdateProbe -Probe $Script:RemoteUpdateProbe
        if ($result) {
            $Script:RemoteUpdateProbe = $null
            Show-RemoteUpdateNotice $result
        }
    })
    $Script:RemoteUpdatePollTimer.Start()
    $Script:RemoteUpdateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:RemoteUpdateTimer.Interval = [timespan]::FromMinutes(5)
    $Script:RemoteUpdateTimer.Add_Tick({
        if (-not $Script:RemoteUpdateProbe) {
            $Script:RemoteUpdateProbe = Start-RemoteUpdateProbe -Source $Script:Source -Master -DataPath (Get-MonitorDataPath)
        }
    })
    $Script:RemoteUpdateTimer.Start()
    $Script:RemoteUpdateProbe = Start-RemoteUpdateProbe -Source $Script:Source -Master -DataPath (Get-MonitorDataPath)
    $Script:Window.Add_Closed({
        $Script:RemoteUpdateTimer.Stop()
        $Script:RemoteUpdatePollTimer.Stop()
        if ($Script:RemoteUpdateProbe) { $Script:RemoteUpdateProbe.Shell.Dispose() }
    })
}

$autoUpdateEnabled = if ($Script:Config.PSObject.Properties['auto_update_enabled']) { [bool]$Script:Config.auto_update_enabled } else { $true }
Register-AutoUpdate -Window $Script:Window -Source $Script:Source -AppRoot (Split-Path $PSScriptRoot -Parent) `
                    -CurrentVersion $Script:AppVersion -Enabled $autoUpdateEnabled

# ---- キーボードショートカット ----
# Ctrl+S = 保存 / Ctrl+R, F5 = 再読込 / Enter = 追加 (編集中は更新) / Esc = クリア
$Script:Window.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($ctrl -and $e.Key -eq 'S' -and $ui.SaveBtn) {
        $ui.SaveBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    } elseif ((($ctrl -and $e.Key -eq 'R') -or $e.Key -eq 'F5') -and $ui.ReloadBtn) {
        $ui.ReloadBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    } elseif ($e.Key -eq 'Escape' -and $ui.ClearBtn) {
        $ui.ClearBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    } elseif ($e.Key -eq 'Return' -and -not $ctrl) {
        # 複数行入力できるコメント欄では改行を優先する
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        if ($focused -eq $ui.CommentBox) { return }
        # プロジェクト欄で絞り込み中は、Enter で候補を確定する (追加はしない)
        $filtering = $Script:ProjectFilterText -and -not $ui.ProjectCombo.SelectedItem
        if ($ui.ProjectCombo.IsKeyboardFocusWithin -and ($ui.ProjectCombo.IsDropDownOpen -or $filtering)) {
            if ($filtering -and $ui.ProjectCombo.Items.Count -gt 0) {
                $ui.ProjectCombo.SelectedItem = $ui.ProjectCombo.Items[0]
            }
            $ui.ProjectCombo.IsDropDownOpen = $false
            $e.Handled = $true
            return
        }
        $target = if ($ui.UpdateBtn -and $ui.UpdateBtn.Visibility -eq 'Visible') { $ui.UpdateBtn } else { $ui.AddBtn }
        if ($target) {
            $target.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
            $e.Handled = $true
        }
    }
})

# 起動時の初期プロジェクト (個人設定)。ハンドラ登録後に選ぶことで 📌 既定も適用される
Select-InitialProject

[void]$Script:Window.ShowDialog()
