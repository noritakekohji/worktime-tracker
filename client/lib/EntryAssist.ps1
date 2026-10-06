# EntryAssist.ps1 — 日次入力 (Tracker) の入力補助ロジック
#
# UI に依存しない純粋関数だけを置く (tests/unit/EntryAssist.Tests.ps1 で検証)。
# 休暇判定は DataStore.ps1 の Test-IsLeaveEntry を使うため、DataStore.ps1 の後に dot-source すること。
# 配列を返す関数はすべて `return ,$arr` (PS 5.1 の 1 要素 unwrap 対策)。

function _EaStr {
    param($v)
    if ($v -is [array]) { $v = if ($v.Count -gt 0) { $v[0] } else { $null } }
    return [string]$v
}

function Find-PreviousWorkDayEntries {
    # Date より前で、作業 (休暇以外) の実績がある最も新しい日の行を返す。休暇行は含めない
    param($Entries, [Parameter(Mandatory)][datetime]$Date)
    $limit = $Date.ToString('yyyy-MM-dd')
    $latest = ''
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Entries)) {
        if ($null -eq $e -or (Test-IsLeaveEntry $e)) { continue }
        $d = _EaStr $e.date
        if (-not $d -or $d -ge $limit) { continue }
        $work.Add($e)
        if ($d -gt $latest) { $latest = $d }
    }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($e in $work) { if ((_EaStr $e.date) -eq $latest) { $hits.Add($e) } }
    return ,$hits.ToArray()
}

function Get-RecentEntryCombos {
    # 新しい日付順に「プロジェクト〜カテゴリ」の組み合わせを重複なしで最大 Max 件返す。
    # 同じ日付の中では後から追加した行を新しいとみなす。hours はその組み合わせの最新行の工数
    param($Entries, [int]$Max = 5)
    $indexed = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($e in @($Entries)) {
        $i++
        if ($null -eq $e -or (Test-IsLeaveEntry $e)) { continue }
        if (-not (_EaStr $e.project_code)) { continue }
        $indexed.Add([pscustomobject]@{ date = (_EaStr $e.date); idx = $i; entry = $e })
    }
    $sorted = @($indexed | Sort-Object @{Expression='date'; Descending=$true}, @{Expression='idx'; Descending=$true})
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($x in $sorted) {
        if ($out.Count -ge $Max) { break }
        $e = $x.entry
        $hours = 0.0
        [void][double]::TryParse((_EaStr $e.hours), [ref]$hours)
        $combo = [pscustomobject]@{
            project_code    = _EaStr $e.project_code
            process_code    = _EaStr $e.process_code
            task_group_code = _EaStr $e.task_group_code
            task_code       = _EaStr $e.task_code
            category        = _EaStr $e.category
            hours           = $hours
        }
        $key = ($combo.project_code, $combo.process_code, $combo.task_group_code, $combo.task_code, $combo.category) -join '|'
        if ($seen.Add($key)) { $out.Add($combo) }
    }
    return ,$out.ToArray()
}

function Get-MissingWeekdays {
    # 指定月の平日 (土日・祝日を除く) のうち、今日までで 1 件も入力が無い日 ('yyyy-MM-dd')。
    # 休暇行も「入力あり」として扱う
    param($Entries, [int]$Year, [int]$Month, $Holidays, [datetime]$Today = [datetime]::Today)
    $filled = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in @($Entries)) { if ($null -ne $e) { [void]$filled.Add((_EaStr $e.date)) } }
    $off = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($h in @($Holidays)) { if ($null -ne $h) { [void]$off.Add((_EaStr $h.date)) } }
    $out = New-Object System.Collections.Generic.List[string]
    $days = [datetime]::DaysInMonth($Year, $Month)
    for ($d = 1; $d -le $days; $d++) {
        $dt = New-Object -TypeName datetime -ArgumentList $Year, $Month, $d
        if ($dt -gt $Today.Date) { break }
        if ($dt.DayOfWeek -eq 'Saturday' -or $dt.DayOfWeek -eq 'Sunday') { continue }
        $s = $dt.ToString('yyyy-MM-dd')
        if ($off.Contains($s) -or $filled.Contains($s)) { continue }
        $out.Add($s)
    }
    return ,$out.ToArray()
}

function Find-ProjectForCodes {
    # 同じユニットコードで別パターンのプロジェクトがあるとき、実績に記録された工程〜タスクのコードを
    # 含むパターンの項目を選ぶ (実績にはユニットコードしか残らないため)。
    # 一致の深さ (工程 1 / タスクグループ 2 / タスク 3) が最も大きい項目。同点・不一致なら先頭。
    # Items: unit_code / task_pattern_id を持つ項目 (マスタのプロジェクトやコンボ項目)
    param($Items, $Patterns, [string]$UnitCode, [string]$ProcessCode, [string]$TaskGroupCode, [string]$TaskCode)
    $best = $null; $bestScore = -1
    foreach ($it in @($Items)) {
        if ($null -eq $it -or (_EaStr $it.unit_code) -ne $UnitCode) { continue }
        $score = 0
        $ptn = @($Patterns) | Where-Object { $_ -and (_EaStr $_.id) -eq (_EaStr $it.task_pattern_id) } | Select-Object -First 1
        $proc = if ($ptn -and $ProcessCode) { @($ptn.processes) | Where-Object { $_ -and (_EaStr $_.code) -eq $ProcessCode } | Select-Object -First 1 }
        if ($proc) {
            $score = 1
            $tg = if ($TaskGroupCode) { @($proc.task_groups) | Where-Object { $_ -and (_EaStr $_.code) -eq $TaskGroupCode } | Select-Object -First 1 }
            if ($tg) {
                $score = 2
                # タスクグループ全体 ('-' / 空) はグループ一致で十分
                if (-not $TaskCode -or $TaskCode -eq '-' -or
                    (@($tg.tasks) | Where-Object { $_ -and (_EaStr $_.code) -eq $TaskCode })) { $score = 3 }
            }
        }
        if ($score -gt $bestScore) { $best = $it; $bestScore = $score }
    }
    return $best
}

function Test-ProjectFilterMatch {
    # プロジェクト候補の絞り込み。空白区切りの語をすべて含めば一致 (大小無視)
    param($Item, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $hay = ('{0} {1}' -f (_EaStr $Item.unit_code), (_EaStr $Item.display)).ToLowerInvariant()
    foreach ($w in ($Text.Trim().ToLowerInvariant() -split '\s+')) {
        if (-not $hay.Contains($w)) { return $false }
    }
    return $true
}
