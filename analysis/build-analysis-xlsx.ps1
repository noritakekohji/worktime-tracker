# build-analysis-xlsx.ps1 — Excel 分析ブック生成 (Excel COM 利用)
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File analysis/build-analysis-xlsx.ps1
#
# 生成物: analysis/worktime-analysis.xlsx
# 動作要件: 実行マシンに Excel (2016+)。完成 .xlsx は他マシンでも開ける。

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$outXlsx = Join-Path $here 'worktime-analysis.xlsx'

# ----- Power Query M コード -----
# Settings テーブル (tbl_Settings) の Name=LocalStorePath 行を参照
$mEntries = @'
let
    SetTbl = Excel.CurrentWorkbook(){[Name="tbl_Settings"]}[Content],
    LocalRoot = Table.SelectRows(SetTbl, each [Name] = "LocalStorePath"){0}[Value],
    DataFolder = LocalRoot & "\data",
    SourceFolder = Folder.Files(DataFolder),
    OnlyJson = Table.SelectRows(SourceFolder, each [Extension] = ".json"),
    AddDoc = Table.AddColumn(OnlyJson, "Doc", each Json.Document([Content])),
    Pick = Table.SelectColumns(AddDoc, {"Doc"}),
    Expanded = Table.ExpandRecordColumn(Pick, "Doc", {"member_id","entries","updated_at"}),
    HasEntries = Table.SelectRows(Expanded, each [entries] <> null),
    Flatten = Table.ExpandListColumn(HasEntries, "entries"),
    Cols = Table.ExpandRecordColumn(Flatten, "entries",
        {"date","project_code","process_code","task_group_code","task_code","category","hours","comment"}),
    TypedDate = Table.TransformColumnTypes(Cols, {{"date", type date}, {"hours", type number}}),
    AddYM = Table.AddColumn(TypedDate, "year_month", each Date.ToText([date], "yyyy-MM"))
in
    AddYM
'@

$mMembers = @'
let
    SetTbl = Excel.CurrentWorkbook(){[Name="tbl_Settings"]}[Content],
    LocalRoot = Table.SelectRows(SetTbl, each [Name] = "LocalStorePath"){0}[Value],
    Path = LocalRoot & "\master\members.json",
    Raw = File.Contents(Path),
    Json = Json.Document(Raw),
    Tbl = Table.FromList(Json, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    Expanded = Table.ExpandRecordColumn(Tbl, "Column1",
        {"id","name","company","department","rank","role","active"})
in
    Expanded
'@

$mProjects = @'
let
    SetTbl = Excel.CurrentWorkbook(){[Name="tbl_Settings"]}[Content],
    LocalRoot = Table.SelectRows(SetTbl, each [Name] = "LocalStorePath"){0}[Value],
    Path = LocalRoot & "\master\projects.json",
    Raw = File.Contents(Path),
    Json = Json.Document(Raw),
    Tbl = Table.FromList(Json, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    Expanded = Table.ExpandRecordColumn(Tbl, "Column1",
        {"unit_code","project_name","unit_name","target_system","work_type","period_from","period_to","task_pattern_id","active"})
in
    Expanded
'@

$mCategories = @'
let
    SetTbl = Excel.CurrentWorkbook(){[Name="tbl_Settings"]}[Content],
    LocalRoot = Table.SelectRows(SetTbl, each [Name] = "LocalStorePath"){0}[Value],
    Path = LocalRoot & "\master\categories.json",
    Raw = File.Contents(Path),
    Json = Json.Document(Raw),
    Tbl = Table.FromList(Json, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    Expanded = Table.ExpandRecordColumn(Tbl, "Column1", {"code","name"})
in
    Expanded
'@

$mEntriesEnriched = @'
let
    Src = #"Entries",
    JoinMember = Table.NestedJoin(Src, {"member_id"}, #"Members", {"id"}, "M", JoinKind.LeftOuter),
    ExpandMember = Table.ExpandTableColumn(JoinMember, "M", {"name","company","department","rank"},
        {"member_name","company","department","rank"}),
    JoinProject = Table.NestedJoin(ExpandMember, {"project_code"}, #"Projects", {"unit_code"}, "P", JoinKind.LeftOuter),
    ExpandProject = Table.ExpandTableColumn(JoinProject, "P", {"project_name","unit_name","work_type","target_system"},
        {"project_name","unit_name","work_type","target_system"}),
    JoinCategory = Table.NestedJoin(ExpandProject, {"category"}, #"Categories", {"code"}, "C", JoinKind.LeftOuter),
    ExpandCategory = Table.ExpandTableColumn(JoinCategory, "C", {"name"}, {"category_name"})
in
    ExpandCategory
'@

Write-Host "Excel COM 起動..." -ForegroundColor Cyan
$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false
$xl.DisplayAlerts = $false
$miss = [System.Reflection.Missing]::Value

try {
    $wb = $xl.Workbooks.Add()
    while ($wb.Sheets.Count -gt 1) { $wb.Sheets.Item($wb.Sheets.Count).Delete() }

    # ===== Settings =====
    $shSettings = $wb.Sheets.Item(1)
    $shSettings.Name = 'Settings'
    $shSettings.Range('A1').Value2 = 'Name'
    $shSettings.Range('B1').Value2 = 'Value'
    $shSettings.Range('A2').Value2 = 'LocalStorePath'
    $shSettings.Range('B2').Value2 = (Join-Path $env:LOCALAPPDATA 'worktime-tracker\store')
    # Excel Table 化 (Power Query から tbl_Settings として参照)
    $loSet = $shSettings.ListObjects.Add(
        1,  # xlSrcRange
        $shSettings.Range('A1:B2'),
        $miss,
        1   # xlYes (has headers)
    )
    $loSet.Name = 'tbl_Settings'
    $loSet.TableStyle = 'TableStyleMedium11'
    $shSettings.Columns('A:A').ColumnWidth = 22
    $shSettings.Columns('B:B').ColumnWidth = 80

    $shSettings.Range('A4').Value2 = '使い方:'
    $shSettings.Range('A4').Font.Bold = $true
    $shSettings.Range('A5').Value2 = '1. B2 を WorkTime Tracker のローカル保管先に書き換え'
    $shSettings.Range('A6').Value2 = '2. データ → すべて更新 (Ctrl+Alt+F5) を実行'
    $shSettings.Range('A7').Value2 = '3. Dashboard シートでピボット/スライサー/グラフを確認'
    $shSettings.Range('A8').Value2 = ''
    $shSettings.Range('A9').Value2 = '※ 既定パス: %LOCALAPPDATA%\worktime-tracker\store'
    $shSettings.Range('A9').Font.Color = 0x808080

    # ===== Queries 追加 =====
    Write-Host "Power Query クエリ追加..." -ForegroundColor Cyan
    $wb.Queries.Add('Members',         $mMembers)         | Out-Null
    $wb.Queries.Add('Projects',        $mProjects)        | Out-Null
    $wb.Queries.Add('Categories',      $mCategories)      | Out-Null
    $wb.Queries.Add('Entries',         $mEntries)         | Out-Null
    $wb.Queries.Add('EntriesEnriched', $mEntriesEnriched) | Out-Null

    # ===== クエリをテーブルとして配置 =====
    function _AddQueryTable {
        param($Workbook, [string]$QueryName, [string]$SheetName)
        $sh = $Workbook.Sheets.Add($miss, $Workbook.Sheets.Item($Workbook.Sheets.Count))
        $sh.Name = $SheetName
        $connStr = "OLEDB;Provider=Microsoft.Mashup.OleDb.1;Data Source=`$Workbook`$;Location=$QueryName;Extended Properties=`"`""
        $qt = $sh.QueryTables.Add($connStr, $sh.Range('A1'), "SELECT * FROM [$QueryName]")
        $qt.CommandType = 2        # xlCmdSql
        $qt.Name = "Query - $QueryName"
        $qt.RefreshOnFileOpen = $false
        $qt.BackgroundQuery = $false
        $qt.RefreshStyle = 1
        $qt.SaveData = $true
        $qt.AdjustColumnWidth = $true
        $refreshed = $false
        try {
            $qt.Refresh($false) | Out-Null
            $refreshed = $true
        } catch {
            Write-Warning "$QueryName Refresh failed: $($_.Exception.Message)"
        }
        # ListObject 化
        try {
            if ($sh.ListObjects.Count -gt 0) {
                $lo = $sh.ListObjects.Item(1)
                $lo.Name = $QueryName + 'Table'
            }
        } catch {}
        return [pscustomobject]@{ Sheet = $sh; Refreshed = $refreshed }
    }

    Write-Host "テーブル化..." -ForegroundColor Cyan
    $r1 = _AddQueryTable -Workbook $wb -QueryName 'Members'         -SheetName 'Members'
    $r2 = _AddQueryTable -Workbook $wb -QueryName 'Projects'        -SheetName 'Projects'
    $r3 = _AddQueryTable -Workbook $wb -QueryName 'Categories'      -SheetName 'Categories'
    $r4 = _AddQueryTable -Workbook $wb -QueryName 'Entries'         -SheetName 'Entries'
    $r5 = _AddQueryTable -Workbook $wb -QueryName 'EntriesEnriched' -SheetName 'EntriesEnriched'

    # 全クエリの依存関係解決のため Workbook 全体を Refresh
    Write-Host "全クエリ更新..." -ForegroundColor Cyan
    try { $wb.RefreshAll(); Start-Sleep -Seconds 3 } catch { Write-Warning "RefreshAll: $_" }

    # ListObject の存在を再確認
    $enrichedOk = $false
    try {
        $sh = $wb.Worksheets('EntriesEnriched')
        if ($sh.ListObjects.Count -gt 0) { $enrichedOk = $true }
        elseif ($sh.UsedRange.Rows.Count -gt 1) {
            # ListObject 未作成だが範囲はある → 手動で作成
            $rng = $sh.UsedRange
            $lo = $sh.ListObjects.Add(1, $rng, $miss, 1)
            $lo.Name = 'EntriesEnrichedTable'
            $enrichedOk = $true
        }
    } catch { Write-Warning "EntriesEnriched verify: $_" }

    # ===== Dashboard =====
    if ($enrichedOk) {
        Write-Host "Dashboard 作成..." -ForegroundColor Cyan
        $shDash = $wb.Sheets.Add($miss, $wb.Sheets.Item($wb.Sheets.Count))
        $shDash.Name = 'Dashboard'

        $shDash.Range('A1').Value2 = 'メンバー別 月次工数'
        $shDash.Range('A1').Font.Bold = $true; $shDash.Range('A1').Font.Size = 14

        $shEnriched = $wb.Worksheets('EntriesEnriched')
        $sourceTbl = $shEnriched.ListObjects.Item(1)

        $pcCache = $wb.PivotCaches().Create(1, $sourceTbl)
        $pivot = $pcCache.CreatePivotTable($shDash.Range('A3'), 'PT_Member')
        $pivot.PivotFields('member_name').Orientation = 1   # xlRowField
        $pivot.PivotFields('year_month').Orientation = 2    # xlColumnField
        $pivot.AddDataField($pivot.PivotFields('hours'), '合計工数', -4157) | Out-Null

        # スライサー
        Write-Host "スライサー追加..." -ForegroundColor Cyan
        try {
            $sc = $wb.SlicerCaches.Add2($pivot, 'project_name')
            $sc.Slicers.Add($shDash, $miss, 'SL_Project', 'プロジェクト', 100, 350, 200, 200) | Out-Null
        } catch { Write-Warning "Slicer project_name: $_" }
        try {
            $sc = $wb.SlicerCaches.Add2($pivot, 'category_name')
            $sc.Slicers.Add($shDash, $miss, 'SL_Category', 'カテゴリ', 100, 560, 200, 200) | Out-Null
        } catch { Write-Warning "Slicer category_name: $_" }
        try {
            $sc = $wb.SlicerCaches.Add2($pivot, 'work_type')
            $sc.Slicers.Add($shDash, $miss, 'SL_WorkType', '業務種別', 320, 350, 200, 200) | Out-Null
        } catch { Write-Warning "Slicer work_type: $_" }
        try {
            $sc = $wb.SlicerCaches.Add2($pivot, 'department')
            $sc.Slicers.Add($shDash, $miss, 'SL_Department', '部署', 320, 560, 200, 200) | Out-Null
        } catch { Write-Warning "Slicer department: $_" }

        # ピボットグラフ 1
        Write-Host "グラフ追加..." -ForegroundColor Cyan
        try {
            $co = $shDash.ChartObjects().Add(540, 50, 480, 280)
            $co.Chart.SetSourceData($pivot.TableRange1)
            $co.Chart.ChartType = 51   # xlColumnClustered
            $co.Chart.HasTitle = $true
            $co.Chart.ChartTitle.Text = 'メンバー × 年月 工数'
        } catch { Write-Warning "Chart 1: $_" }

        # 2 つ目のピボット: プロジェクト別
        $shDash.Range('A22').Value2 = 'プロジェクト別 合計工数'
        $shDash.Range('A22').Font.Bold = $true; $shDash.Range('A22').Font.Size = 14
        try {
            $pc2 = $wb.PivotCaches().Create(1, $sourceTbl)
            $pv2 = $pc2.CreatePivotTable($shDash.Range('A24'), 'PT_Project')
            $pv2.PivotFields('project_name').Orientation = 1
            $pv2.PivotFields('work_type').Orientation = 1
            $pv2.AddDataField($pv2.PivotFields('hours'), '合計工数', -4157) | Out-Null

            $co2 = $shDash.ChartObjects().Add(540, 360, 480, 280)
            $co2.Chart.SetSourceData($pv2.TableRange1)
            $co2.Chart.ChartType = 5   # xlPie
            $co2.Chart.HasTitle = $true
            $co2.Chart.ChartTitle.Text = 'プロジェクト別 工数構成'
        } catch { Write-Warning "Pivot 2 / Chart 2: $_" }

        # Dashboard を Settings の直後に
        $shDash.Move($shSettings)
    } else {
        Write-Warning "EntriesEnriched の Refresh が失敗したため Dashboard は未生成 (利用者が更新後に作成可)"
    }

    $shSettings.Activate()

    Write-Host "保存: $outXlsx" -ForegroundColor Green
    if (Test-Path -LiteralPath $outXlsx) { Remove-Item -LiteralPath $outXlsx -Force }
    $wb.SaveAs($outXlsx, 51)   # xlOpenXMLWorkbook
    $wb.Close($false)
} finally {
    $xl.Quit()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($xl) | Out-Null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

Write-Host "完了: $outXlsx" -ForegroundColor Green
