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

# ---- ガントチャート用セル背景コンバータ (C# 動的コンパイル) ----
# パラメータ = 列の日付 ('yyyy-MM-dd')
# Values[0] = 行の 開始,  Values[1] = 行の 終了,  Values[2] = セル値 (工数)
if (-not ([System.Management.Automation.PSTypeName]'WT.GanttCellBgConverter').Type) {
    Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
namespace WT {
    public class GanttCellBgConverter : IMultiValueConverter {
        static readonly SolidColorBrush BrushActual  = new SolidColorBrush(Color.FromRgb(0xa7,0xf3,0xd0)); // 緑 = 実績
        static readonly SolidColorBrush BrushPlan    = new SolidColorBrush(Color.FromRgb(0xdb,0xea,0xfe)); // 水色 = 計画期間
        static readonly SolidColorBrush BrushHoliday = new SolidColorBrush(Color.FromRgb(0xd1,0xd5,0xdb)); // 灰 = 休業日 (土日 + 社内休業)
        // 静的: 社内休業日マスタを yyyy-MM-dd 文字列のセットとして保持
        public static System.Collections.Generic.HashSet<string> CompanyHolidays =
            new System.Collections.Generic.HashSet<string>();
        static GanttCellBgConverter() {
            BrushActual.Freeze(); BrushPlan.Freeze(); BrushHoliday.Freeze();
        }
        public static void SetCompanyHolidays(System.Collections.Generic.IEnumerable<string> dates) {
            CompanyHolidays = new System.Collections.Generic.HashSet<string>();
            if (dates != null) {
                foreach (var d in dates) {
                    if (!string.IsNullOrEmpty(d)) CompanyHolidays.Add(d);
                }
            }
        }
        public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture) {
            try {
                string dateStr = parameter as string;
                if (string.IsNullOrEmpty(dateStr)) return Brushes.Transparent;
                DateTime cellDate;
                if (!DateTime.TryParse(dateStr, out cellDate)) return Brushes.Transparent;
                string startStr = (values != null && values.Length > 0) ? values[0] as string : null;
                string endStr   = (values != null && values.Length > 1) ? values[1] as string : null;
                string valueStr = (values != null && values.Length > 2) ? values[2] as string : null;
                if (!string.IsNullOrWhiteSpace(valueStr)) { return BrushActual; }
                DateTime st, en;
                bool hasSt = DateTime.TryParse(startStr, out st);
                bool hasEn = DateTime.TryParse(endStr, out en);
                if (hasSt && hasEn && cellDate >= st && cellDate <= en) { return BrushPlan; }
                // 休業日: 土日 OR 会社マスタ登録日
                if (cellDate.DayOfWeek == DayOfWeek.Saturday || cellDate.DayOfWeek == DayOfWeek.Sunday) { return BrushHoliday; }
                if (CompanyHolidays.Contains(dateStr)) { return BrushHoliday; }
                return Brushes.Transparent;
            } catch { return Brushes.Transparent; }
        }
        public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) {
            throw new NotImplementedException();
        }
    }
    // 進捗 % が 100 超なら赤背景 (過進捗ハイライト)
    public class OverdueBgConverter : IValueConverter {
        static readonly SolidColorBrush BrushOver = new SolidColorBrush(Color.FromRgb(0xfc,0xa5,0xa5)); // 赤
        static OverdueBgConverter() { BrushOver.Freeze(); }
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) {
            try {
                if (value == null) return Brushes.Transparent;
                string s = value.ToString().TrimEnd('%').Trim();
                if (string.IsNullOrEmpty(s)) return Brushes.Transparent;
                double d;
                if (double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out d) && d > 100.0) {
                    return BrushOver;
                }
                return Brushes.Transparent;
            } catch { return Brushes.Transparent; }
        }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) {
            throw new NotImplementedException();
        }
    }
}
"@
}

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')
. (Join-Path $libDir 'UserPrefs.ps1')
. (Join-Path $libDir 'AdminDialog.ps1')
. (Join-Path $libDir 'Bootstrap.ps1')

trap {
    $msg = "$($_.Exception.Message)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
    try { [System.Windows.MessageBox]::Show($msg, 'WBS 入力 - エラー', 'OK', 'Error') | Out-Null }
    catch { Write-Host $msg -ForegroundColor Red; Read-Host '終了するには Enter を押してください' }
    exit 1
}

# ---- 初期化 (設定 + マスタ読込) ----
$ctx = Initialize-DataContext -AppName 'WBS 入力'
if (-not $ctx) { exit 1 }
$Script:Config = $ctx.Config
$Script:Source = $ctx.Source
$cfg           = $ctx.Config
# active なプロジェクトのみ ComboBox 用に持つ (Bootstrap は全件返すため絞り込み)
$Script:Members      = @($ctx.Members)
$Script:Projects     = @($ctx.Projects | Where-Object { $_.active })
$Script:Categories   = @($ctx.Categories)
$Script:TaskPatterns = @($ctx.TaskPatterns)
$Script:Holidays     = @($ctx.Holidays)

# 休業日リストを Converter の静的フィールドに反映 (ガントセル背景判定に使用)
function _ApplyHolidaysToConverter {
    $dates = @($Script:Holidays | Where-Object { $_ -and $_.date } | ForEach-Object { [string]$_.date })
    # PS 5.1: Object[] から IEnumerable<string> への変換は失敗するため string[] へ明示キャスト
    [WT.GanttCellBgConverter]::SetCompanyHolidays([string[]]$dates)
}
_ApplyHolidaysToConverter

# マスタ再読込 (管理者画面後など)
function _LoadMasters {
    $r = Reload-MasterContext -Source $Script:Source
    $Script:Members      = @($r.Members)
    $Script:Projects     = @($r.Projects | Where-Object { $_.active })
    $Script:Categories   = @($r.Categories)
    $Script:TaskPatterns = @($r.TaskPatterns)
    $Script:Holidays     = @($r.Holidays)
    _ApplyHolidaysToConverter
}

# ---- XAML 読込 ----
$xamlPath = Join-Path $PSScriptRoot 'WbsInput.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in @('ProjectCombo','YearCombo','MonthCombo','MemberCombo','LoadBtn','AdminBtn',
                  'SaveBtn','PushBtn','WbsTree','WbsGrid','AddRowBtn','GridTitle','StatusText',
                  # タスクビュー (右下)
                  'TaskViewHeader','TaskEntryDate','TaskEntryCategory','TaskEntryAssignee',
                  'TaskEntryHours','TaskEntryComment','TaskEntryAddBtn','TaskEntryDelBtn',
                  'TaskEntriesGrid')) {
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

# 送信ボタンはモードに関わらず常時表示。standalone なら IsEnabled=False で誤操作防止
if (-not $Script:Source.RemoteCtx) {
    $ui.PushBtn.IsEnabled = $false
    $ui.PushBtn.ToolTip = 'standalone モードでは送信できません (Gitlabモード時のみ)'
}

# 管理者ロールなら管理者ボタン表示
if ($currentMember -and $currentMember.role -eq 'admin') {
    $ui.AdminBtn.Visibility = 'Visible'
    $ui.AdminBtn.Add_Click({
        try {
            $mid  = [string]$currentMember.id
            $mnm  = [string]$currentMember.name
            $changed = Show-AdminDialog -Source $Script:Source -MemberId $mid -MemberName $mnm
            if ($changed) {
                _LoadMasters
                # 現在ロード中のデータを再描画
                if ($null -ne $Script:DataTable) { Load-WbsData }
            }
        } catch {
            [System.Windows.MessageBox]::Show("管理者画面エラー:`n$_", 'エラー', 'OK', 'Error') | Out-Null
        }
    })
}

# ---- 状態変数 ----
$Script:DataTable   = $null
$Script:CurrentProj = $null
$Script:CurrentPtn  = $null
# タスクビュー用の全エントリ詳細リスト (カテゴリ・担当・コメント込み)
$Script:AllEntries = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
# 現在 TaskView に表示中のタスク (pc, tgc, tc, displayName)
$Script:CurrentTask = $null

function _ParseNum {
    param($v)
    if ($null -eq $v) { return 0.0 }
    $s = [string]$v
    $d = 0.0; [void][double]::TryParse($s, [ref]$d)
    return $d
}

# ---- ヘルパ関数 ----
function Get-TaskPatternFor {
    param($Project)
    if (-not $Project) { return $null }
    $ptnId = [string]$Project.task_pattern_id
    if (-not $ptnId) { return $null }
    return ($Script:TaskPatterns | Where-Object { $_.id -eq $ptnId } | Select-Object -First 1)
}

# メンバー ID から 2 文字短縮表記を生成
function Get-MemberAbbrev {
    param([string]$MemberId)
    if ([string]::IsNullOrWhiteSpace($MemberId)) { return '' }
    $m = $Script:Members | Where-Object { [string]$_.id -eq $MemberId } | Select-Object -First 1
    $src = if ($m -and $m.name) { [string]$m.name } else { $MemberId }
    if ([string]::IsNullOrWhiteSpace($src)) { return '' }
    if ($src.Length -le 2) { return $src }
    return $src.Substring(0, 2)
}

function Build-DataTable {
    param([int]$Year, [int]$Month)
    $tbl = New-Object 'System.Data.DataTable'
    if ($null -eq $tbl) { throw 'New-Object System.Data.DataTable returned null' }

    $stringType = [System.String]
    # 内部 + 表示列。タスクレベル 1 行集約。カテゴリ/担当の詳細はタスクビュー側で扱う
    $allCols = @(
        '_pc','_tgc','_tc','_proc_idx','_sort_key',           # 内部用
        'WBS','工程','タスクグループ','タスク',                # 階層
        '担当','計画','合計','進捗','開始','終了'              # タスク計画情報
    )
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
        # 進捗% = 実績合計 / 計画 * 100
        $planRaw = [string]$row["計画"]; $plan = 0.0
        if (-not [string]::IsNullOrWhiteSpace($planRaw) -and [double]::TryParse($planRaw, [ref]$plan) -and $plan -gt 0) {
            $pct = [Math]::Round(($total / $plan) * 100.0, 0)
            $row["進捗"] = "$pct%"
        } else {
            $row["進捗"] = ''
        }
    }
}

# ---- プランファイル I/O (プロジェクト共有: 担当/計画/期間は全員で共通) ----
function Get-WbsPlanRelPath {
    param([string]$ProjectCode, [int]$Year, [int]$Month)
    return ("wbs_plans/{0}/{1:D4}_{2:D2}.json" -f $ProjectCode, $Year, $Month)
}

function Load-WbsPlanItems {
    param($Source, [string]$ProjectCode, [int]$Year, [int]$Month)
    # Gitlab モードなら最新版を pull (失敗してもローカル版で続行)
    if ($Source -and $Source.RemoteCtx) {
        try {
            $rel = Get-WbsPlanRelPath -ProjectCode $ProjectCode -Year $Year -Month $Month
            $remoteText = Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $rel
            if ($remoteText) {
                $localPath = Join-Path $Source.LocalRoot $rel
                $parent = Split-Path -Parent $localPath
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [System.IO.File]::WriteAllText($localPath, [string]$remoteText, [System.Text.UTF8Encoding]::new($false))
            }
        } catch { }
    }
    $rel = Get-WbsPlanRelPath -ProjectCode $ProjectCode -Year $Year -Month $Month
    $raw = Get-DataFile -Source $Source -RelPath $rel
    if (-not $raw) { return @() }
    try {
        $doc = ConvertFrom-Json -InputObject ([string]$raw)
        if ($null -eq $doc -or $null -eq $doc.items) { return @() }
        return @($doc.items)
    } catch {
        return @()
    }
}

function Save-WbsPlanItems {
    param($Source, [string]$ProjectCode, [int]$Year, [int]$Month, $Items, [string]$AuthorName, [string]$AuthorEmail, [switch]$PushRemote)
    $rel = Get-WbsPlanRelPath -ProjectCode $ProjectCode -Year $Year -Month $Month
    $doc = [ordered]@{
        project_code = $ProjectCode
        year         = $Year
        month        = $Month
        items        = @($Items)
        updated_at   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 10
    Set-DataFile -Source $Source -RelPath $rel -Content ([string]$json) `
                 -AuthorName ([string]$AuthorName) -AuthorEmail ([string]$AuthorEmail)
    # Gitlab モードならリモートにも push (共有のため即時送信)
    if ($PushRemote -and $Source.RemoteCtx) {
        try {
            Set-GitLabFile -Ctx $Source.RemoteCtx -Path $rel -Content ([string]$json) `
                -CommitMessage ("WBS plan update: {0} {1:D4}/{2:D2}" -f $ProjectCode, $Year, $Month) `
                -AuthorName $AuthorName -AuthorEmail $AuthorEmail
        } catch {
            throw "WBS プランの送信失敗: $_"
        }
    }
}

function Build-GridColumns {
    param($Grid, [int]$Year, [int]$Month)
    $Grid.Columns.Clear()

    # B5: 列幅を user_prefs.json から復元
    $savedWidths = $null
    try {
        $prefs = Get-UserPrefs -MemberId $Script:Config.member_id
        if ($prefs -and $prefs.wbs_column_widths) { $savedWidths = $prefs.wbs_column_widths }
    } catch { }

    # ---- 固定列 (タスクレベル 1 行集約) ----
    $fixedDef = @(
        @{H="WBS";            B="[WBS]";            W=55;  RO=$true  },
        @{H="工程";           B="[工程]";           W=75;  RO=$true  },
        @{H="タスクグループ"; B="[タスクグループ]"; W=100; RO=$true  },
        @{H="タスク";         B="[タスク]";         W=120; RO=$true  },
        @{H="担当";           B="[担当]";           W=70;  RO=$false },
        @{H="計画";           B="[計画]";           W=50;  RO=$false },
        @{H="合計";           B="[合計]";           W=50;  RO=$true  },
        @{H="進捗";           B="[進捗]";           W=55;  RO=$true  },
        @{H="開始";           B="[開始]";           W=80;  RO=$false },
        @{H="終了";           B="[終了]";           W=80;  RO=$false }
    )
    $overdueConv = New-Object WT.OverdueBgConverter
    foreach ($fd in $fixedDef) {
        $col = New-Object System.Windows.Controls.DataGridTextColumn
        $col.Header      = $fd.H
        $col.Binding     = New-Object System.Windows.Data.Binding $fd.B
        $col.Width       = $fd.W
        $col.IsReadOnly  = $fd.RO
        $col.CanUserSort = $false
        # B5: 保存された列幅を適用 (ヘッダ名で照合)
        if ($savedWidths -and ($savedWidths.PSObject.Properties.Match($fd.H).Count -gt 0 -or ($savedWidths -is [hashtable] -and $savedWidths.ContainsKey($fd.H)))) {
            try {
                $w = if ($savedWidths -is [hashtable]) { $savedWidths[$fd.H] } else { $savedWidths.($fd.H) }
                $wN = 0.0
                if ([double]::TryParse([string]$w, [ref]$wN) -and $wN -gt 10) { $col.Width = $wN }
            } catch { }
        }
        # B4: 進捗 列で 100% 超なら背景を赤に
        if ($fd.H -eq '進捗') {
            $cellStyle = New-Object System.Windows.Style ([System.Windows.Controls.DataGridCell])
            $bn = New-Object System.Windows.Data.Binding '[進捗]'
            $bn.Converter = $overdueConv
            $bn.Mode = [System.Windows.Data.BindingMode]::OneWay
            $bgSetter = New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.Control]::BackgroundProperty), $bn
            [void]$cellStyle.Setters.Add($bgSetter)
            $col.CellStyle = $cellStyle
        }
        $Grid.Columns.Add($col)
    }
    $Grid.FrozenColumnCount = $fixedDef.Count

    # ---- 日付列 (ガントチャート風セル背景) ----
    $dayNames = @('日','月','火','水','木','金','土')
    $days = [DateTime]::DaysInMonth($Year, $Month)
    $todayStr = (Get-Date).ToString('yyyy-MM-dd')
    $converter = New-Object WT.GanttCellBgConverter
    for ($d = 1; $d -le $days; $d++) {
        $dtObj = [DateTime]::new($Year, $Month, $d)
        $key   = "{0:D4}-{1:D2}-{2:D2}" -f $Year, $Month, $d
        $dow   = [int]$dtObj.DayOfWeek
        $dn    = $dayNames[$dow]
        $isToday = ($key -eq $todayStr)

        $col = New-Object System.Windows.Controls.DataGridTextColumn
        $col.Header      = "$d`n$dn" + $(if ($isToday) { ' ▼' } else { '' })
        $col.Binding     = New-Object System.Windows.Data.Binding "[$key]"
        $col.Width       = 42
        $col.IsReadOnly  = $false
        $col.CanUserSort = $false

        # セル背景: MultiBinding で (開始,終了,セル値) → 色 を計算
        $cellStyle = New-Object System.Windows.Style ([System.Windows.Controls.DataGridCell])
        $mb = New-Object System.Windows.Data.MultiBinding
        $mb.Mode = [System.Windows.Data.BindingMode]::OneWay
        $mb.Converter = $converter
        $mb.ConverterParameter = $key
        [void]$mb.Bindings.Add((New-Object System.Windows.Data.Binding '[開始]'))
        [void]$mb.Bindings.Add((New-Object System.Windows.Data.Binding '[終了]'))
        [void]$mb.Bindings.Add((New-Object System.Windows.Data.Binding "[$key]"))
        $bgSetter = New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.Control]::BackgroundProperty), $mb
        [void]$cellStyle.Setters.Add($bgSetter)
        # 今日の列は左端に赤い太線
        if ($isToday) {
            $brd = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#ef4444'))
            $borderSetter = New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.Control]::BorderBrushProperty), $brd
            $thickness = New-Object System.Windows.Thickness 2, 0, 0, 0
            $thickSetter = New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.Control]::BorderThicknessProperty), $thickness
            [void]$cellStyle.Setters.Add($borderSetter)
            [void]$cellStyle.Setters.Add($thickSetter)
        }
        $col.CellStyle = $cellStyle

        $Grid.Columns.Add($col)
    }
}

function _MakeRow {
    # 旧 API 互換のため残置 (現在は Load-WbsData 内でインライン作成しているため未使用)
    param($Table, [string]$pc, [string]$pn, [string]$tgc, [string]$tgn, [string]$tc, [string]$tn, [string]$cat)
    if ($null -eq $Table) { throw "_MakeRow: Table パラメータが null" }
    $row = $Table.NewRow()
    $row["_pc"] = $pc; $row["_tgc"] = $tgc; $row["_tc"] = $tc
    $row["工程"] = $pn; $row["タスクグループ"] = $tgn; $row["タスク"] = $tn
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

        # 既存エントリ読込 → 詳細リスト Script:AllEntries に保存 (TaskView で個別表示するため)
        $loaded      = @(Load-MonthEntries -Source $Script:Source -MemberId $memberId -Year $year -Month $month)
        $projEntries = @($loaded | Where-Object { $null -ne $_ -and ([string]$_.project_code) -eq $projCode })
        $Script:AllEntries.Clear()
        foreach ($e in $projEntries) {
            if (-not $e) { continue }
            $catCode = [string]$e.category
            $catName = $catCode
            $catObj = $Script:Categories | Where-Object { [string]$_.code -eq $catCode } | Select-Object -First 1
            if ($catObj -and $catObj.name) { $catName = "$catCode  $($catObj.name)" }
            $Script:AllEntries.Add([pscustomobject]@{
                date             = [string]$e.date
                project_code     = [string]$e.project_code
                process_code     = [string]$e.process_code
                task_group_code  = [string]$e.task_group_code
                task_code        = [string]$e.task_code
                category         = $catCode
                category_display = $catName
                assignee         = if ($e.assignee) { [string]$e.assignee } else { '' }
                hours            = [double]([math]::Round([double](_ParseNum $e.hours), 2))
                comment          = [string]$e.comment
            })
        }

        # プランファイル読込 — タスクレベル集約 (key = "pc|tgc|tc")。category 入りの旧フォーマットも吸収
        $planItems = @(Load-WbsPlanItems -Source $Script:Source -ProjectCode $projCode -Year $year -Month $month)
        $planMap = @{}
        foreach ($p in $planItems) {
            if (-not $p) { continue }
            $k = "{0}|{1}|{2}" -f [string]$p.process_code, [string]$p.task_group_code, [string]$p.task_code
            if (-not $planMap.ContainsKey($k)) {
                $planMap[$k] = @{
                    planned_hours = $p.planned_hours
                    assignee      = if ($p.assignee) { [string]$p.assignee } else { '' }
                    planned_start = if ($p.planned_start) { [string]$p.planned_start } else { '' }
                    planned_end   = if ($p.planned_end)   { [string]$p.planned_end }   else { '' }
                }
            } else {
                # 既にあるなら空欄を埋める (最初の非空を優先)
                $cur = $planMap[$k]
                if (-not $cur.planned_hours -and $p.planned_hours) { $cur.planned_hours = $p.planned_hours }
                if (-not $cur.assignee      -and $p.assignee)      { $cur.assignee      = [string]$p.assignee }
                if (-not $cur.planned_start -and $p.planned_start) { $cur.planned_start = [string]$p.planned_start }
                if (-not $cur.planned_end   -and $p.planned_end)   { $cur.planned_end   = [string]$p.planned_end }
            }
        }

        # WBS 階層情報 + タスク列挙 (パターン順)
        $taskList = New-Object 'System.Collections.Generic.List[object]'   # 各要素: @{pc,pn,tgc,tgn,tc,tn,procIdx,wbsNo,sortKey}
        $wbsMap   = @{}
        if ($Script:CurrentPtn -and $Script:CurrentPtn.processes) {
            $procIdx = 0
            foreach ($proc in @($Script:CurrentPtn.processes)) {
                if (-not $proc) { continue }
                $procIdx++; $tgIdx = 0
                foreach ($tg in @($proc.task_groups)) {
                    if (-not $tg) { continue }
                    $tgIdx++; $tkIdx = 0
                    foreach ($tk in @($tg.tasks)) {
                        if (-not $tk) { continue }
                        $tkIdx++
                        $info = @{
                            pc       = [string]$proc.code
                            pn       = [string]$proc.name
                            tgc      = [string]$tg.code
                            tgn      = [string]$tg.name
                            tc       = [string]$tk.code
                            tn       = [string]$tk.name
                            procIdx  = $procIdx
                            wbsNo    = "$procIdx.$tgIdx.$tkIdx"
                            sortKey  = '{0:D4}.{1:D4}.{2:D4}' -f $procIdx, $tgIdx, $tkIdx
                        }
                        $taskList.Add($info)
                        $wbsMap["$($info.pc)|$($info.tgc)|$($info.tc)"] = $info
                    }
                }
            }
        }

        # パターン外のタスク (エントリやプランにあるが pattern にない) も追加
        $extraKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($e in $projEntries) {
            $k = "$([string]$e.process_code)|$([string]$e.task_group_code)|$([string]$e.task_code)"
            if (-not $wbsMap.ContainsKey($k)) { [void]$extraKeys.Add($k) }
        }
        foreach ($pk in $planMap.Keys) {
            if (-not $wbsMap.ContainsKey($pk)) { [void]$extraKeys.Add($pk) }
        }
        foreach ($k in $extraKeys) {
            $parts = $k.Split('|')
            if ($parts.Count -lt 3) { continue }
            $info = @{
                pc = $parts[0]; pn = ''; tgc = $parts[1]; tgn = ''; tc = $parts[2]; tn = ''
                procIdx = 0; wbsNo = ''; sortKey = '9999.9999.9999'
            }
            $taskList.Add($info)
            $wbsMap[$k] = $info
        }

        # タスク 1 行ずつ DataTable に追加
        foreach ($info in $taskList) {
            $row = $dt.NewRow()
            $row["_pc"]  = $info.pc;  $row["_tgc"] = $info.tgc; $row["_tc"] = $info.tc
            $row["_proc_idx"] = "$($info.procIdx)"
            $row["_sort_key"] = $info.sortKey
            $row["WBS"]  = $info.wbsNo
            $row["工程"] = $info.pn; $row["タスクグループ"] = $info.tgn; $row["タスク"] = $info.tn
            # プラン値
            $pkey = "$($info.pc)|$($info.tgc)|$($info.tc)"
            if ($planMap.ContainsKey($pkey)) {
                $p = $planMap[$pkey]
                if ($p.assignee)      { $row["担当"] = [string]$p.assignee }
                if ($p.planned_hours) { $row["計画"] = [string]$p.planned_hours }
                if ($p.planned_start) { $row["開始"] = [string]$p.planned_start }
                if ($p.planned_end)   { $row["終了"] = [string]$p.planned_end }
            }
            # 日付セル: そのタスクの全エントリ (全カテゴリ・全担当) を合算
            $taskEntries = @($Script:AllEntries | Where-Object {
                $_.process_code -eq $info.pc -and $_.task_group_code -eq $info.tgc -and $_.task_code -eq $info.tc
            })
            $byDate = @{}
            foreach ($e in $taskEntries) {
                $dk = [string]$e.date
                if (-not $byDate.ContainsKey($dk)) { $byDate[$dk] = 0.0 }
                $byDate[$dk] += [double]$e.hours
            }
            foreach ($dk in $byDate.Keys) {
                if ($dt.Columns.Contains($dk)) {
                    $h = [double]$byDate[$dk]
                    if ($h -gt 0) { $row[$dk] = $h.ToString("N1") }
                }
            }
            [void]$dt.Rows.Add($row)
        }

        $Script:DataTable = $dt
        Update-AllTotals

        # WBS 番号(_sort_key) → 開始予定日 の順でソート
        $dt.DefaultView.Sort = '_sort_key ASC, 開始 ASC'

        Build-GridColumns -Grid $ui.WbsGrid -Year $year -Month $month
        $ui.WbsGrid.ItemsSource = $dt.DefaultView

        Build-WbsTree

        # サマリ計算 (実績合計・計画合計・進捗%・タスク数)
        $dateColsForSum = @($dt.Columns | Where-Object { $_.ColumnName -match '^\d{4}-\d{2}-\d{2}$' })
        $totalHrs = 0.0
        $totalPlan = 0.0
        foreach ($r in $dt.Rows) {
            foreach ($c in $dateColsForSum) {
                $v = $r[$c.ColumnName]; $h = 0.0
                if (-not [string]::IsNullOrWhiteSpace($v) -and [double]::TryParse([string]$v, [ref]$h)) { $totalHrs += $h }
            }
            $pv = [string]$r["計画"]; $pn = 0.0
            if (-not [string]::IsNullOrWhiteSpace($pv) -and [double]::TryParse($pv, [ref]$pn)) { $totalPlan += $pn }
        }
        $progressPct = if ($totalPlan -gt 0) { [Math]::Round(($totalHrs / $totalPlan) * 100.0, 0) } else { 0 }
        $bar = ''
        if ($totalPlan -gt 0) {
            $filled = [Math]::Min(20, [Math]::Floor(($totalHrs / $totalPlan) * 20))
            $bar = ' [' + ('█' * $filled) + ('░' * (20 - $filled)) + "] $progressPct%"
        }
        $ui.GridTitle.Text = ("📊 {0}  /  {1:D4}年{2:D2}月  /  {3}行  /  実績 {4:N1}h / 計画 {5:N1}h{6}" -f `
            $projItem.project_name, $year, $month, $dt.Rows.Count, $totalHrs, $totalPlan, $bar)
        Set-Status ("読込完了: {0} 行 / 実績 {1:N1}h / 計画 {2:N1}h" -f $dt.Rows.Count, $totalHrs, $totalPlan) '#10b981'
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
    $procIdx = 0
    foreach ($proc in @($Script:CurrentPtn.processes)) {
        if (-not $proc) { continue }
        $procIdx++
        $pi = New-Object System.Windows.Controls.TreeViewItem
        $pi.Header = "⚙ $([string]$proc.name)"; $pi.IsExpanded = $true
        $tgIdx = 0
        foreach ($tg in @($proc.task_groups)) {
            if (-not $tg) { continue }
            $tgIdx++
            $ti = New-Object System.Windows.Controls.TreeViewItem
            $ti.Header = "🗂 $([string]$tg.name)"; $ti.IsExpanded = $true
            $tkIdx = 0
            foreach ($tk in @($tg.tasks)) {
                if (-not $tk) { continue }
                $tkIdx++
                $ki = New-Object System.Windows.Controls.TreeViewItem
                $ki.Header = "• $([string]$tk.name)"
                $ki.Tag = [pscustomobject]@{
                    pc=$proc.code; pn=$proc.name
                    tgc=$tg.code;  tgn=$tg.name
                    procIdx=$procIdx; tgIdx=$tgIdx; tkIdx=$tkIdx
                    wbsNo=("$procIdx.$tgIdx.$tkIdx")
                    sortKey=('{0:D4}.{1:D4}.{2:D4}' -f $procIdx, $tgIdx, $tkIdx)
                    tc=$tk.code;   tn=$tk.name
                }
                [void]$ti.Items.Add($ki)
            }
            [void]$pi.Items.Add($ti)
        }
        [void]$ui.WbsTree.Items.Add($pi)
    }
}

# ---- 行カラーリング: 工程インデックスごとに背景色を変える ----
# $global:WT_WbsRowBrushes は工程 idx (文字列) → Brush のマップ
$global:WT_WbsRowBrushes = @{
    '1' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#ffffff')))
    '2' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#ecfdf5')))
    '3' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#fef3c7')))
    '4' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#dbeafe')))
    '5' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#fce7f3')))
    '6' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#ede9fe')))
    '7' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#fed7aa')))
    '0' = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#f3f4f6')))
}
$ui.WbsGrid.Add_LoadingRow({
    param($s, $e)
    $drv = $e.Row.Item -as [System.Data.DataRowView]
    if (-not $drv) { return }
    try {
        $idx = [string]$drv.Row['_proc_idx']
        if ([string]::IsNullOrWhiteSpace($idx)) { return }
        # ループするように mod を取る
        $modKey = ([int]$idx % 7) + 1
        $key = [string]$modKey
        if ($idx -eq '0') { $key = '0' }
        if ($global:WT_WbsRowBrushes.ContainsKey($key)) {
            $e.Row.Background = $global:WT_WbsRowBrushes[$key]
        }
    } catch { }
})

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
    # インラインで行作成 (担当は未アサイン)。WBS番号/工程インデックス/ソートキーをツリーから取得
    $row = $Script:DataTable.NewRow()
    $row["_pc"]  = [string]$info.pc;  $row["_tgc"] = [string]$info.tgc; $row["_tc"] = [string]$info.tc
    $row["_proc_idx"] = if ($info.procIdx) { "$($info.procIdx)" } else { '0' }
    $row["_sort_key"] = if ($info.sortKey) { [string]$info.sortKey } else { '9999.9999.9999' }
    $row["WBS"] = if ($info.wbsNo) { [string]$info.wbsNo } else { '' }
    $row["工程"] = [string]$info.pn;  $row["タスクグループ"] = [string]$info.tgn
    $row["タスク"] = [string]$info.tn
    $row["担当"] = ''
    [void]$Script:DataTable.Rows.Add($row)
    # ソートが効いているため、追加行は自動で WBS 番号順に挿入される。スクロール位置は気にしない
    $ui.WbsGrid.ScrollIntoView($ui.WbsGrid.Items[$ui.WbsGrid.Items.Count - 1])
})

# セル編集後に合計を更新 (CurrentCellChanged は編集確定後に発火)
# また、日付列が選択されたらタスクビューの「日付」を該当日にセットする
$ui.WbsGrid.Add_CurrentCellChanged({
    if ($Script:DataTable) { Update-AllTotals }
    $cell = $ui.WbsGrid.CurrentCell
    if (-not $cell.IsValid) { return }
    $col = $cell.Column
    if (-not $col -or -not $col.Binding) { return }
    $path = [string]$col.Binding.Path.Path
    if ($path -match '^\[(\d{4}-\d{2}-\d{2})\]$') {
        $dStr = $matches[1]
        $d = [datetime]::MinValue
        if ([datetime]::TryParse($dStr, [ref]$d) -and $ui.TaskEntryDate) {
            $ui.TaskEntryDate.SelectedDate = $d
        }
    }
})

# A5: 数値セル (日付列 / 計画 列) で + キーで +0.5、- キーで -0.5
$ui.WbsGrid.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $Script:DataTable) { return }
    if ($e.Key -ne 'Add' -and $e.Key -ne 'Subtract' -and $e.Key -ne 'OemPlus' -and $e.Key -ne 'OemMinus') { return }
    $cell = $ui.WbsGrid.CurrentCell
    if (-not $cell.IsValid) { return }
    $col = $cell.Column
    if (-not $col -or -not $col.Binding) { return }
    $path = [string]$col.Binding.Path.Path
    $isDate = $path -match '^\[\d{4}-\d{2}-\d{2}\]$'
    $isPlan = ($path -eq '[計画]')
    if (-not ($isDate -or $isPlan)) { return }
    $drv = $cell.Item -as [System.Data.DataRowView]
    if (-not $drv) { return }
    $colKey = $path -replace '[\[\]]', ''
    $cur = [string]$drv.Row[$colKey]
    $d = 0.0; [void][double]::TryParse($cur, [ref]$d)
    $delta = 0.5
    if ($e.Key -eq 'Subtract' -or $e.Key -eq 'OemMinus') { $delta = -0.5 }
    $newVal = [Math]::Max(0.0, $d + $delta)
    $drv.Row[$colKey] = if ($newVal -le 0) { '' } else { $newVal.ToString('N1') }
    Update-AllTotals
    $e.Handled = $true
})

# 開始/終了 列の編集確定時に yyyy-MM-dd に正規化
# 例: "19270311" → "1927-03-11" / "2026-5-1" → "2026-05-01"
$ui.WbsGrid.Add_CellEditEnding({
    param($s, $e)
    if ($e.EditAction -ne [System.Windows.Controls.DataGridEditAction]::Commit) { return }
    $col = $e.Column
    if (-not $col -or -not $col.Binding) { return }
    $path = [string]$col.Binding.Path.Path
    if ($path -ne '[開始]' -and $path -ne '[終了]') { return }
    $tb = $e.EditingElement -as [System.Windows.Controls.TextBox]
    if (-not $tb) { return }
    $orig = [string]$tb.Text
    if ([string]::IsNullOrWhiteSpace($orig)) { return }
    $t = $orig.Trim()
    # 1) yyyyMMdd (8 桁数字)
    if ($t -match '^(\d{4})(\d{2})(\d{2})$') {
        $tb.Text = "$($matches[1])-$($matches[2])-$($matches[3])"
        return
    }
    # 2) その他は DateTime.TryParse → yyyy-MM-dd
    $d = [DateTime]::MinValue
    if ([DateTime]::TryParse($t, [ref]$d)) {
        $tb.Text = $d.ToString('yyyy-MM-dd')
    }
})

# ---- 保存共通処理 ----
function _BuildEntries {
    param([string]$ProjCode, [int]$Year, [int]$Month, [string]$MemberId)
    # タスクビューで管理している詳細リスト $Script:AllEntries から、当該プロジェクトのエントリを抽出
    $entries  = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Script:AllEntries) {
        if (-not $e) { continue }
        if ([string]$e.project_code -ne $ProjCode) { continue }
        if (-not $e.date -or [double]$e.hours -le 0) { continue }
        $entries.Add([pscustomobject]@{
            date            = [string]$e.date
            project_code    = $ProjCode
            process_code    = [string]$e.process_code
            task_group_code = [string]$e.task_group_code
            task_code       = [string]$e.task_code
            category        = [string]$e.category
            assignee        = [string]$e.assignee
            hours           = [double]$e.hours
            comment         = [string]$e.comment
        })
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

function _BuildPlanItems {
    param([string]$ProjCode)
    # タスクレベルのプラン情報 (1 行 = 1 タスク) を抽出
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($drv in $Script:DataTable.DefaultView) {
        $row = $drv.Row
        $pc  = [string]$row["_pc"];  $tgc = [string]$row["_tgc"]; $tc = [string]$row["_tc"]
        $plan = [string]$row["計画"]; $assn = [string]$row["担当"]
        $st = [string]$row["開始"];   $en = [string]$row["終了"]
        if ([string]::IsNullOrWhiteSpace($pc) -and [string]::IsNullOrWhiteSpace($tgc) `
            -and [string]::IsNullOrWhiteSpace($tc)) { continue }
        $planNum = 0.0; [void][double]::TryParse($plan, [ref]$planNum)
        $items.Add([pscustomobject]@{
            project_code    = $ProjCode
            process_code    = $pc
            task_group_code = $tgc
            task_code       = $tc
            category        = ''
            planned_hours   = if ($planNum -gt 0) { $planNum } else { $null }
            assignee        = $assn
            planned_start   = $st
            planned_end     = $en
        })
    }
    return $items.ToArray()
}

function _DoSave {
    if (-not $Script:DataTable) { throw 'データが読み込まれていません' }
    $projCode   = [string]$ui.ProjectCombo.SelectedItem.unit_code
    $year       = [int]$ui.YearCombo.SelectedItem
    $month      = [int]$ui.MonthCombo.SelectedItem
    $memberItem = $ui.MemberCombo.SelectedItem
    $memberId   = [string]$memberItem.id
    $memberName = [string]$memberItem.name

    # 1. 実績エントリ保存 (他プロジェクトとマージ)
    $r = _BuildEntries -ProjCode $projCode -Year $year -Month $month -MemberId $memberId
    Save-EntriesGrouped -Source $Script:Source -MemberId $memberId `
        -AllEntries $r.Merged -ViewYear $year -ViewMonth $month `
        -AuthorName $memberName -AuthorEmail "$memberId@worktime-tracker.local"

    # 2. プラン (計画/担当/期間) 保存 — プロジェクト全体で共有されるファイルに書く
    # Gitlab モードなら即時 push して他ユーザに見える状態にする
    $thisProjPlanItems = _BuildPlanItems -ProjCode $projCode
    Save-WbsPlanItems -Source $Script:Source -ProjectCode $projCode -Year $year -Month $month `
        -Items $thisProjPlanItems `
        -AuthorName $memberName -AuthorEmail "$memberId@worktime-tracker.local" `
        -PushRemote:($null -ne $Script:Source.RemoteCtx)
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

# ---- キーボードショートカット (A2) ----
# Ctrl+S = 保存 / Ctrl+R = 再読込 / F5 = 再読込
$Script:Window.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($ctrl -and $e.Key -eq 'S') {
        $ui.SaveBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    } elseif (($ctrl -and $e.Key -eq 'R') -or $e.Key -eq 'F5') {
        $ui.LoadBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        $e.Handled = $true
    }
})

# ---- タスクビュー (右下) ----
# カテゴリ ComboBox の初期化
$ui.TaskEntryCategory.ItemsSource = @($Script:Categories | ForEach-Object {
    [pscustomobject]@{ code = [string]$_.code; name = "$($_.code)  $($_.name)" }
})

# 担当者候補は メンバーマスタの 2文字短縮 + 空白
$asgList = New-Object 'System.Collections.Generic.List[string]'
[void]$asgList.Add('')
foreach ($m in $Script:Members) {
    if (-not $m -or -not $m.active) { continue }
    $abbr = Get-MemberAbbrev -MemberId ([string]$m.id)
    if ($abbr -and -not $asgList.Contains($abbr)) { [void]$asgList.Add($abbr) }
}
$ui.TaskEntryAssignee.ItemsSource = $asgList
$ui.TaskEntryDate.SelectedDate = [datetime]::Today

# タスクビューに表示中のエントリ (フィルタ済)
$Script:TaskViewEntries = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$ui.TaskEntriesGrid.ItemsSource = $Script:TaskViewEntries

function Refresh-TaskView {
    $Script:TaskViewEntries.Clear()
    $ui.TaskEntryAddBtn.IsEnabled = $false
    $ui.TaskEntryDelBtn.IsEnabled = $false
    if (-not $Script:CurrentTask) {
        $ui.TaskViewHeader.Text = '📝 上のグリッドでタスクを選択してください'
        return
    }
    $t = $Script:CurrentTask
    $ui.TaskViewHeader.Text = ("📝 {0}.{1}.{2}  {3}  /  {4}  /  {5}" -f $t.pc, $t.tgc, $t.tc, $t.pn, $t.tgn, $t.tn)
    $matches = @($Script:AllEntries | Where-Object {
        $_.process_code -eq $t.pc -and $_.task_group_code -eq $t.tgc -and $_.task_code -eq $t.tc
    })
    foreach ($e in $matches) { $Script:TaskViewEntries.Add($e) }
    $ui.TaskEntryAddBtn.IsEnabled = $true
    $ui.TaskEntryDelBtn.IsEnabled = ($matches.Count -gt 0)
    # 既定の担当: そのタスクの行の「担当」または現在ユーザ
    if (-not [string]::IsNullOrWhiteSpace($t.assignee)) {
        $ui.TaskEntryAssignee.Text = [string]$t.assignee
    } elseif ($Script:Config -and $Script:Config.member_id) {
        $ui.TaskEntryAssignee.Text = Get-MemberAbbrev -MemberId $Script:Config.member_id
    }
}

# WBS グリッドの行選択 → タスクビュー更新
$ui.WbsGrid.Add_SelectionChanged({
    $sel = $ui.WbsGrid.SelectedItem
    if ($null -eq $sel) { $Script:CurrentTask = $null; Refresh-TaskView; return }
    $drv = $sel -as [System.Data.DataRowView]
    if (-not $drv) { $Script:CurrentTask = $null; Refresh-TaskView; return }
    $r = $drv.Row
    $Script:CurrentTask = @{
        pc       = [string]$r["_pc"]
        tgc      = [string]$r["_tgc"]
        tc       = [string]$r["_tc"]
        pn       = [string]$r["工程"]
        tgn      = [string]$r["タスクグループ"]
        tn       = [string]$r["タスク"]
        assignee = [string]$r["担当"]
    }
    Refresh-TaskView
})

# WBS グリッドのセルから合計を再計算してタスク行を更新
function Recompute-TaskRow {
    param($pc, $tgc, $tc)
    if (-not $Script:DataTable) { return }
    foreach ($row in $Script:DataTable.Rows) {
        if (([string]$row["_pc"]) -ne $pc) { continue }
        if (([string]$row["_tgc"]) -ne $tgc) { continue }
        if (([string]$row["_tc"]) -ne $tc) { continue }
        # 日付列をクリアして合算しなおし
        $dateCols = @($Script:DataTable.Columns | Where-Object { $_.ColumnName -match '^\d{4}-\d{2}-\d{2}$' })
        foreach ($c in $dateCols) { $row[$c.ColumnName] = '' }
        $matches = @($Script:AllEntries | Where-Object {
            $_.process_code -eq $pc -and $_.task_group_code -eq $tgc -and $_.task_code -eq $tc
        })
        $byDate = @{}
        foreach ($e in $matches) {
            $dk = [string]$e.date
            if (-not $byDate.ContainsKey($dk)) { $byDate[$dk] = 0.0 }
            $byDate[$dk] += [double]$e.hours
        }
        foreach ($dk in $byDate.Keys) {
            if ($Script:DataTable.Columns.Contains($dk)) {
                $h = [double]$byDate[$dk]
                $row[$dk] = if ($h -gt 0) { $h.ToString('N1') } else { '' }
            }
        }
        break
    }
    Update-AllTotals
}

# タスクビュー: ＋ 追加
$ui.TaskEntryAddBtn.Add_Click({
    if (-not $Script:CurrentTask) { return }
    $d = $ui.TaskEntryDate.SelectedDate
    if (-not $d) {
        [System.Windows.MessageBox]::Show('日付を選択してください', '入力エラー', 'OK', 'Warning') | Out-Null; return
    }
    $hours = 0.0
    if (-not [double]::TryParse($ui.TaskEntryHours.Text, [ref]$hours) -or $hours -le 0) {
        [System.Windows.MessageBox]::Show('工数は正の数値を入力してください', '入力エラー', 'OK', 'Warning') | Out-Null; return
    }
    $catItem = $ui.TaskEntryCategory.SelectedItem
    $catCode = if ($catItem) { [string]$catItem.code } else { '' }
    $catDisp = if ($catItem) { [string]$catItem.name } else { '' }
    $assn = [string]$ui.TaskEntryAssignee.Text
    $t = $Script:CurrentTask
    $newEntry = [pscustomobject]@{
        date             = $d.ToString('yyyy-MM-dd')
        project_code     = [string]$ui.ProjectCombo.SelectedItem.unit_code
        process_code     = $t.pc
        task_group_code  = $t.tgc
        task_code        = $t.tc
        category         = $catCode
        category_display = $catDisp
        assignee         = $assn
        hours            = $hours
        comment          = [string]$ui.TaskEntryComment.Text
    }
    $Script:AllEntries.Add($newEntry)
    Refresh-TaskView
    Recompute-TaskRow $t.pc $t.tgc $t.tc
    # 入力欄をクリア (日付・担当は維持)
    $ui.TaskEntryHours.Text   = '1.0'
    $ui.TaskEntryComment.Text = ''
})

# タスクビュー: 🗑 削除
$ui.TaskEntryDelBtn.Add_Click({
    $sel = $ui.TaskEntriesGrid.SelectedItem
    if (-not $sel -or -not $Script:CurrentTask) { return }
    [void]$Script:AllEntries.Remove($sel)
    $t = $Script:CurrentTask
    Refresh-TaskView
    Recompute-TaskRow $t.pc $t.tgc $t.tc
})

# B5: 列幅永続化 — Closing で現在の列幅を user_prefs.json へ保存
$Script:Window.Add_Closing({
    try {
        if (-not $Script:Config -or -not $Script:Config.member_id) { return }
        $widths = @{}
        foreach ($col in $ui.WbsGrid.Columns) {
            $h = [string]$col.Header
            if (-not [string]::IsNullOrWhiteSpace($h)) {
                $widths[$h] = [double]$col.ActualWidth
            }
        }
        if ($widths.Count -gt 0) {
            $prefs = Get-UserPrefs -MemberId $Script:Config.member_id
            $prefs['wbs_column_widths'] = $widths
            Set-UserPrefs -MemberId $Script:Config.member_id -Prefs $prefs
        }
    } catch { }
})

[void]$Script:Window.ShowDialog()
