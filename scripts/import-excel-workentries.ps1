# import-excel-workentries.ps1 - Excel work entries to worktime-tracker JSON
#
# This script only writes JSON files under the specified OutputRoot.
# It never writes to the configured local_store and never talks to GitLab.

param(
    [string]$InputFolder = '',
    [string]$OutputRoot = '',
    [int]$Year = 0,
    [int]$Month = 0,
    [string]$WorksheetName = '',
    [int]$HeaderRow = 1,
    [string]$MemberId = '',
    [string]$MemberIdPattern = '^(?<member_id>[A-Za-z0-9_-]+)',
    [string]$ColumnMapPath = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Normalize-ImportHeader {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    $s = $s -replace '[\s　_\-／/\\\(\)（）\[\]【】\.]', ''
    return $s
}

function Get-DefaultImportColumnAliases {
    return @{
        date            = @('date','日付','作業日','実績日','対象日','年月日')
        member_id       = @('member_id','memberid','メンバーid','社員id','社員番号','担当者id','ユーザーid')
        project_code    = @('project_code','projectcode','プロジェクトコード','案件コード','PJコード','案件','プロジェクト')
        process_code    = @('process_code','processcode','工程コード','工程')
        task_group_code = @('task_group_code','taskgroupcode','タスクグループコード','作業グループコード','タスクグループ','作業グループ')
        task_code       = @('task_code','taskcode','タスクコード','作業コード','タスク','作業')
        alias           = @('alias','別名','wbs別名','WBS別名')
        category        = @('category','カテゴリ','分類','作業カテゴリ','区分')
        hours           = @('hours','hour','工数','時間','実績工数','作業時間','h')
        comment         = @('comment','コメント','備考','メモ','内容')
        is_leave        = @('is_leave','isleave','休暇','休み','有休','有給','休暇フラグ')
    }
}

function Read-ImportColumnMapFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @{} }
    if (-not (Test-Path -LiteralPath $Path)) { throw "列マップファイルが見つかりません: $Path" }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($true))
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $parsed = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($p in $parsed.PSObject.Properties) {
        $map[[string]$p.Name] = $p.Value
    }
    return $map
}

function Resolve-ImportColumnMap {
    param(
        [Parameter(Mandatory)]$Headers,
        $UserMap = @{}
    )
    $headerList = @($Headers)
    $byExact = @{}
    $byNorm = @{}
    for ($i = 0; $i -lt $headerList.Count; $i++) {
        $name = [string]$headerList[$i]
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $byExact.ContainsKey($name)) { $byExact[$name] = $i }
        $norm = Normalize-ImportHeader $name
        if ($norm -and -not $byNorm.ContainsKey($norm)) { $byNorm[$norm] = $i }
    }

    $resolved = @{}
    $aliases = Get-DefaultImportColumnAliases
    foreach ($field in @($aliases.Keys)) {
        $found = $null
        if ($UserMap -and $UserMap.ContainsKey($field)) {
            $spec = $UserMap[$field]
            if ($spec -is [int]) {
                $idx = [int]$spec - 1
                if ($idx -ge 0 -and $idx -lt $headerList.Count) { $found = $idx }
            } else {
                $specText = [string]$spec
                if ($byExact.ContainsKey($specText)) {
                    $found = $byExact[$specText]
                } else {
                    $specNorm = Normalize-ImportHeader $specText
                    if ($byNorm.ContainsKey($specNorm)) { $found = $byNorm[$specNorm] }
                }
            }
        }

        if ($null -eq $found) {
            foreach ($candidate in @($aliases[$field])) {
                $key = Normalize-ImportHeader $candidate
                if ($byNorm.ContainsKey($key)) {
                    $found = $byNorm[$key]
                    break
                }
            }
        }

        if ($null -ne $found) { $resolved[$field] = [int]$found }
    }
    return $resolved
}

function Get-ImportRowValue {
    param($Row, $ColumnMap, [string]$Field)
    if ($null -eq $ColumnMap -or -not $ColumnMap.ContainsKey($Field)) { return '' }
    $idx = [int]$ColumnMap[$Field]
    if ($idx -lt 0 -or $idx -ge $Row.Count) { return '' }
    if ($null -eq $Row[$idx]) { return '' }
    return [string]$Row[$idx]
}

function ConvertTo-ImportDateString {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }

    $num = 0.0
    if ([double]::TryParse($s, [ref]$num) -and $num -gt 20000 -and $num -lt 80000) {
        return ([datetime]::FromOADate($num)).ToString('yyyy-MM-dd')
    }

    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($s, [ref]$dt)) {
        return $dt.ToString('yyyy-MM-dd')
    }
    return ''
}

function ConvertTo-ImportBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -match '^(1|true|yes|y|on|○|〇|有|有休|有給|休暇|休み)$')
}

function ConvertTo-ImportHours {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return 0.0 }
    $num = 0.0
    if (-not [double]::TryParse($s, [ref]$num)) {
        throw "工数が数値ではありません: '$s'"
    }
    return [double]([math]::Round($num, 2))
}

function ConvertTo-WorkEntryImportResult {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$ColumnMap,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        [string]$DefaultMemberId = '',
        [string]$SourceName = ''
    )
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $members = @{}

    foreach ($rowObj in @($Rows)) {
        $rowNo = [int]$rowObj.RowNumber
        $row = @($rowObj.Values)
        $dateText = ConvertTo-ImportDateString (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'date')
        $isLeave = ConvertTo-ImportBool (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'is_leave')

        if (-not $dateText) {
            $errors.Add(("{0}: 行 {1}: 日付が空または不正です" -f $SourceName, $rowNo))
            continue
        }

        $dt = [datetime]::Parse($dateText)
        if ($dt.Year -ne $Year -or $dt.Month -ne $Month) {
            $errors.Add(("{0}: 行 {1}: 対象年月外の日付です ({2})" -f $SourceName, $rowNo, $dateText))
            continue
        }

        $member = Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'member_id'
        if ([string]::IsNullOrWhiteSpace($member)) { $member = $DefaultMemberId }
        $member = ([string]$member).Trim()
        if ([string]::IsNullOrWhiteSpace($member)) {
            $errors.Add(("{0}: 行 {1}: member_id を特定できません" -f $SourceName, $rowNo))
            continue
        }
        $members[$member] = $true

        $hours = 0.0
        try {
            $hours = ConvertTo-ImportHours (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'hours')
        } catch {
            $errors.Add(("{0}: 行 {1}: {2}" -f $SourceName, $rowNo, $_.Exception.Message))
            continue
        }
        if (-not $isLeave -and $hours -le 0) {
            $errors.Add(("{0}: 行 {1}: 通常行の工数は 0 より大きくしてください" -f $SourceName, $rowNo))
            continue
        }

        $entry = [ordered]@{
            date            = $dateText
            project_code    = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'project_code').Trim()
            process_code    = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'process_code').Trim()
            task_group_code = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'task_group_code').Trim()
            task_code       = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'task_code').Trim()
            alias           = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'alias').Trim()
            category        = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'category').Trim()
            is_leave        = [bool]$isLeave
            hours           = $hours
            comment         = (Get-ImportRowValue -Row $row -ColumnMap $ColumnMap -Field 'comment').Trim()
        }

        if (-not $isLeave -and [string]::IsNullOrWhiteSpace($entry.project_code)) {
            $warnings.Add(("{0}: 行 {1}: project_code が空です" -f $SourceName, $rowNo))
        }
        $entries.Add([pscustomobject]$entry)
    }

    return [pscustomobject]@{
        Entries  = $entries.ToArray()
        Members  = @($members.Keys | Sort-Object)
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function New-WorkEntryMonthDocument {
    param(
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        $Entries
    )
    return [ordered]@{
        member_id  = $MemberId
        year       = $Year
        month      = $Month
        entries    = @($Entries)
        updated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Write-WorkEntryMonthJson {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        $Entries,
        [switch]$Force
    )
    $dir = Join-Path $OutputRoot ('data\{0:D4}\{1:D2}' -f $Year, $Month)
    $path = Join-Path $dir ("$MemberId.json")
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "出力先が既に存在します。上書きする場合は -Force を指定してください: $path"
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $doc = New-WorkEntryMonthDocument -MemberId $MemberId -Year $Year -Month $Month -Entries $Entries
    $json = ConvertTo-Json -InputObject $doc -Depth 10
    [System.IO.File]::WriteAllText($path, [string]$json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-MemberIdFromFileName {
    param([string]$Path, [string]$Pattern)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match $Pattern) {
        if ($Matches.ContainsKey('member_id')) { return [string]$Matches['member_id'] }
        if ($Matches.Count -gt 1) { return [string]$Matches[1] }
    }
    return ''
}

function Read-ExcelTableRows {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$WorksheetName = '',
        [int]$HeaderRow = 1
    )
    $excel = $null
    $book = $null
    $sheet = $null
    $used = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $book = $excel.Workbooks.Open($Path)
        if ([string]::IsNullOrWhiteSpace($WorksheetName)) {
            $sheet = $book.Worksheets.Item(1)
        } else {
            $sheet = $book.Worksheets.Item($WorksheetName)
        }
        $used = $sheet.UsedRange
        $rowCount = [int]$used.Rows.Count
        $colCount = [int]$used.Columns.Count
        if ($rowCount -lt $HeaderRow) { throw "ヘッダー行が範囲外です: $Path" }

        $headers = New-Object 'System.Collections.Generic.List[string]'
        for ($c = 1; $c -le $colCount; $c++) {
            $headers.Add([string]$sheet.Cells.Item($HeaderRow, $c).Text)
        }

        $rows = New-Object 'System.Collections.Generic.List[object]'
        for ($r = ($HeaderRow + 1); $r -le $rowCount; $r++) {
            $vals = New-Object 'System.Collections.Generic.List[string]'
            $hasValue = $false
            for ($c = 1; $c -le $colCount; $c++) {
                $cellText = [string]$sheet.Cells.Item($r, $c).Text
                if (-not [string]::IsNullOrWhiteSpace($cellText)) { $hasValue = $true }
                $vals.Add($cellText)
            }
            if ($hasValue) {
                $rows.Add([pscustomobject]@{ RowNumber = $r; Values = $vals.ToArray() })
            }
        }
        return [pscustomobject]@{ Headers = $headers.ToArray(); Rows = $rows.ToArray() }
    } finally {
        if ($book) { $book.Close($false) | Out-Null }
        if ($excel) { $excel.Quit() | Out-Null }
        foreach ($obj in @($used, $sheet, $book, $excel)) {
            if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj)
            }
        }
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
    }
}

function Invoke-ExcelWorkEntryImport {
    param(
        [Parameter(Mandatory)][string]$InputFolder,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        [string]$WorksheetName = '',
        [int]$HeaderRow = 1,
        [string]$MemberId = '',
        [string]$MemberIdPattern = '^(?<member_id>[A-Za-z0-9_-]+)',
        [string]$ColumnMapPath = '',
        [switch]$DryRun,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $InputFolder)) { throw "入力フォルダが見つかりません: $InputFolder" }
    if ($Year -lt 2000 -or $Year -gt 2100) { throw 'Year は 2000-2100 の範囲で指定してください' }
    if ($Month -lt 1 -or $Month -gt 12) { throw 'Month は 1-12 の範囲で指定してください' }

    $userMap = Read-ImportColumnMapFile -Path $ColumnMapPath
    $files = @(Get-ChildItem -LiteralPath $InputFolder -File |
        Where-Object {
            $_.Name -notlike '~$*' -and
            @('.xlsx','.xlsm','.xls') -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object FullName)
    if ($files.Count -eq 0) { throw "Excelファイルが見つかりません: $InputFolder" }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $seenTargets = @{}
    foreach ($file in $files) {
        $table = Read-ExcelTableRows -Path $file.FullName -WorksheetName $WorksheetName -HeaderRow $HeaderRow
        $columnMap = Resolve-ImportColumnMap -Headers $table.Headers -UserMap $userMap
        foreach ($required in @('date','hours')) {
            if (-not $columnMap.ContainsKey($required)) {
                throw ("{0}: 必須列を特定できません: {1}" -f $file.Name, $required)
            }
        }

        $defaultMember = $MemberId
        if ([string]::IsNullOrWhiteSpace($defaultMember)) {
            $defaultMember = Get-MemberIdFromFileName -Path $file.FullName -Pattern $MemberIdPattern
        }
        $converted = ConvertTo-WorkEntryImportResult -Rows $table.Rows -ColumnMap $columnMap `
            -Year $Year -Month $Month -DefaultMemberId $defaultMember -SourceName $file.Name
        if ($converted.Errors.Count -gt 0) {
            $msg = ($converted.Errors | ForEach-Object { "  $_" }) -join "`n"
            throw ("{0}: 取込エラーがあります`n{1}" -f $file.Name, $msg)
        }
        if ($converted.Members.Count -ne 1) {
            throw ("{0}: 1ファイル内の member_id は1人にしてください。検出: {1}" -f $file.Name, ($converted.Members -join ', '))
        }
        $resolvedMember = [string]$converted.Members[0]
        $target = Join-Path (Join-Path $OutputRoot ('data\{0:D4}\{1:D2}' -f $Year, $Month)) ("$resolvedMember.json")
        if ($seenTargets.ContainsKey($target)) {
            throw "同じ出力先になるExcelが複数あります: $target"
        }
        $seenTargets[$target] = $true

        $writtenPath = ''
        if (-not $DryRun) {
            $writtenPath = Write-WorkEntryMonthJson -OutputRoot $OutputRoot -MemberId $resolvedMember `
                -Year $Year -Month $Month -Entries $converted.Entries -Force:$Force
        }
        $results.Add([pscustomobject]@{
            File     = $file.FullName
            MemberId = $resolvedMember
            Entries  = $converted.Entries.Count
            Warnings = $converted.Warnings
            Output   = if ($DryRun) { $target } else { $writtenPath }
            DryRun   = [bool]$DryRun
        })
    }
    return $results.ToArray()
}

function Invoke-ImportScriptMain {
    if ([string]::IsNullOrWhiteSpace($InputFolder)) { throw '-InputFolder を指定してください' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw '-OutputRoot を指定してください' }
    $result = Invoke-ExcelWorkEntryImport -InputFolder $InputFolder -OutputRoot $OutputRoot `
        -Year $Year -Month $Month -WorksheetName $WorksheetName -HeaderRow $HeaderRow `
        -MemberId $MemberId -MemberIdPattern $MemberIdPattern -ColumnMapPath $ColumnMapPath `
        -DryRun:$DryRun -Force:$Force
    foreach ($r in @($result)) {
        $mode = if ($r.DryRun) { 'DRYRUN' } else { 'WRITE' }
        Write-Output ("[{0}] {1} -> {2} ({3} entries)" -f $mode, $r.File, $r.Output, $r.Entries)
        foreach ($w in @($r.Warnings)) { Write-Warning $w }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ImportScriptMain
}
