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
. (Join-Path $libDir 'Version.ps1')
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')
. (Join-Path $libDir 'ConfigDialog.ps1')
. (Join-Path $libDir 'AdminDialog.ps1')
. (Join-Path $libDir 'UserPrefs.ps1')
. (Join-Path $libDir 'UserPrefsDialog.ps1')

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
                "Gitlab からマスタを取得しますか?`n`n  [はい] リモートから取得 → ローカルから読込 (最新)`n  [いいえ] ローカルから読込 (オフラインキャッシュ)",
                'WorkTime Tracker  起動', 'YesNo', 'Question')
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
$Script:Source     = $ctx['Source']
$Script:Token      = $ctx['Token']
$Script:Members      = @($ctx['Members'])
$Script:Projects     = @($ctx['Projects'])
$Script:Categories   = @($ctx['Categories'])
$Script:TaskPatterns = @($ctx['TaskPatterns'])
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
        # UI 反映: プロジェクト / カテゴリ / 現在の作業者
        if ($ui -and $ui.ProjectCombo) {
            $ui.ProjectCombo.ItemsSource = Build-ProjectComboItems
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
    'CurrentMemberText','YearCombo','MonthCombo','ReloadBtn','PullBtn','StatusText',
    'EntryDate','TodayBtn','YesterdayBtn','IsLeaveChk',
    'ProjectCombo','ProcessCombo','TaskGroupCombo','TaskCombo',
    'CategoryCombo','HoursBox','CommentBox','ClearBtn','AddBtn','UpdateBtn','TaskDescBorder','TaskDescText',
    'EntriesGrid','EditRowBtn','DeleteRowBtn','DuplicateBtn','SaveBtn','HoursTotalText','HoursDayText',
    'AdminBtn','SettingsBtn','UserPrefsBtn','OpenFolderBtn','PushBtn','FormHeader','ListTitle','ModeText','VersionText'
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

function Update-HoursTotal {
    $sum = 0.0
    foreach ($e in $Script:Entries) { $sum += [double]$e.hours }
    $ui.HoursTotalText.Text = '{0:N1} h' -f $sum
    Update-HoursDay
}

function Update-HoursDay {
    if (-not $ui.HoursDayText) { return }
    $d = $ui.EntryDate.SelectedDate
    if (-not $d) { $ui.HoursDayText.Text = '0.0 h'; return }
    $dStr = $d.ToString('yyyy-MM-dd')
    $sum = 0.0
    foreach ($e in $Script:Entries) {
        if ([string]$e.date -eq $dStr) { $sum += [double]$e.hours }
    }
    $ui.HoursDayText.Text = '{0:N1} h' -f $sum
}

function Set-Status {
    param([string]$Text, [string]$Color = '#f9e2af')
    $ui.StatusText.Text = $Text
    $ui.StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
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
    $allActive = @($Script:Projects | Where-Object { $_.active })
    $items = foreach ($p in $allActive) {
        $isFav = $favs.Contains([string]$p.unit_code)
        $star  = if ($isFav) { '⭐ ' } else { '' }
        $disp = if ($p.unit_name) {
            "{0}[{1}] {2} ({3})" -f $star, $p.unit_code, $p.project_name, $p.unit_name
        } else {
            "{0}[{1}] {2}" -f $star, $p.unit_code, $p.project_name
        }
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
        }
    }
    # お気に入り優先でソート (お気に入り内は unit_code 順、その他は unit_code 順)
    # PS 5.1: 単一要素は return で自動 unwrap されるため Write-Output -NoEnumerate
    # で配列を保持する (アクティブプロジェクトが 1 件のとき WPF が IEnumerable に
    # キャストできず起動エラーになる事故を防ぐ)
    $sorted = @($items | Sort-Object @{Expression='is_favorite'; Descending=$true}, @{Expression='unit_code'; Descending=$false})
    Write-Output -NoEnumerate -InputObject $sorted
}
$ui.ProjectCombo.ItemsSource = Build-ProjectComboItems

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
    $proj = $Script:Projects | Where-Object { $_.unit_code -eq $ProjCode } | Select-Object -First 1
    if ($proj) {
        if ($proj.project_name) { $projName = [string]$proj.project_name }
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
                hours           = _Num $e.hours
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
$ui.TodayBtn.Add_Click({ $ui.EntryDate.SelectedDate = [datetime]::Today })
$ui.YesterdayBtn.Add_Click({ $ui.EntryDate.SelectedDate = ([datetime]::Today).AddDays(-1) })
$ui.EntryDate.Add_SelectedDateChanged({ Update-HoursDay })

# クイック工数ボタン
foreach ($n in 'H025','H05','H1','H2','H4','H8') {
    $b = $Script:Window.FindName($n)
    if ($b) {
        $b.Add_Click({ param($s,$e) $ui.HoursBox.Text = [string]$s.Tag; $ui.HoursBox.Focus() | Out-Null }.GetNewClosure())
    }
}

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

    if (-not $isLeave) {
        if (-not $proj) { throw 'プロジェクトを選択してください (休暇は ☑ 休暇 をチェック)' }
        if (-not $proc -and $ui.ProcessCombo.Items.Count -gt 0) { throw '工程を選択してください' }
        if (-not $tg   -and $ui.TaskGroupCombo.Items.Count -gt 0) { throw 'タスクグループを選択してください' }
        if (-not $task -and $ui.TaskCombo.Items.Count -gt 0) { throw 'タスクを選択してください' }
    }
    # 休暇のときは proj/proc/tg/task すべて任意。カテゴリは無くても OK。
    $hours = 0.0
    if (-not [double]::TryParse($ui.HoursBox.Text, [ref]$hours) -or $hours -le 0) {
        throw '工数は正の数値で入力してください'
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
        project_name    = if ($proj) { [string]$proj.project_name } else { if ($isLeave) { '(休暇)' } else { '' } }
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
    $ui.ProjectCombo.SelectedValue   = $Entry.project_code
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
    $ui.ProjectCombo.SelectedIndex = -1
    Reset-Cascade -From @('process','task_group','task')
    $ui.CategoryCombo.SelectedIndex = -1
    $ui.HoursBox.Text = '1.0'
    $ui.CommentBox.Text = ''
    $ui.IsLeaveChk.IsChecked = $false
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

# ---- 複製 (選択行の内容をフォームへ。Add すれば新規行として追加) ----
$ui.DuplicateBtn.Add_Click({
    $sel = $ui.EntriesGrid.SelectedItem
    if ($null -eq $sel) { return }
    Clear-Form
    Set-FormFromEntry -Entry $sel
    Set-Status "選択行をフォームに複製しました。値を編集して『追加』してください。" '#89b4fa'
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
            # Project Combo を再構築 (お気に入りが上に来る)
            $ui.ProjectCombo.ItemsSource = Build-ProjectComboItems
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
        $ui.ProjectCombo.ItemsSource  = Build-ProjectComboItems
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
        $result = Sync-Push-MyData -Source $Script:Source -MemberId $midStr `
                                   -AuthorName $nameStr -AuthorEmail "$midStr@worktime-tracker.local"
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
        $Script:Window.Cursor = $null
    }
})

# ---- 初回ロード ----
Load-ViewMonth

# ---- キーボードショートカット (A2) ----
# Ctrl+S = 保存 / Ctrl+R = 再読込 / F5 = 再読込
$Script:Window.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($ctrl -and $e.Key -eq 'S' -and $ui.SaveBtn) {
        $ui.SaveBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    } elseif ((($ctrl -and $e.Key -eq 'R') -or $e.Key -eq 'F5') -and $ui.ReloadBtn) {
        $ui.ReloadBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    }
})

[void]$Script:Window.ShowDialog()
