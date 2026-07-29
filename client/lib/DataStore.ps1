# DataStore.ps1 — マスタ/実績データの読み書き (ハイブリッド: ローカル常用 + 任意で Gitlab 同期)
#
# Source 構造:
#   @{
#     Mode       = 'local' | 'gitlab'
#     LocalRoot  = <常用ローカルストア。全モード共通>
#     RemoteCtx  = $null (local) or GitLab Context (Gitlab モード)
#   }
#
# 読み書きは常に LocalRoot に対して行う。
# Gitlab との同期は Sync-Pull-Masters / Sync-Push-MyData を明示的に呼ぶ。

. (Join-Path $PSScriptRoot 'GitLab.ps1')

# ---- ロール判定 (member / leader / admin の複数選択対応) ----
# 全画面 (WorkTimeTracker / WbsInput / ReportViewer / AdminDialog) が DataStore を
# dot-source するため、共通ヘルパとしてここに定義する。
# 新スキーマ: members.json の各要素に "roles": ["admin","leader","member"] 配列
# 旧スキーマ: "role": "admin" / "member" の単一文字列 (後方互換で受理)
function Get-MemberRoles {
    param($Member)
    if (-not $Member) { return @() }
    if ($Member.PSObject.Properties['roles'] -and $Member.roles) {
        return @($Member.roles | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    if ($Member.PSObject.Properties['role'] -and $Member.role) {
        return @([string]$Member.role)
    }
    return @('member')
}

function Has-Role {
    param($Member, [string]$Role)
    $roles = Get-MemberRoles -Member $Member
    return ($roles -contains $Role)
}

function _AsScalarStr { param($v)
    if ($null -eq $v) { return '' }
    if ($v -is [array]) { if ($v.Count -gt 0) { return [string]$v[0] } else { return '' } }
    return [string]$v
}

function Get-MonthRelPath {
    param($MemberId, $Year, $Month)
    $mid = _AsScalarStr $MemberId
    $y   = [int](_AsScalarStr $Year)
    $m   = [int](_AsScalarStr $Month)
    return ('data/{0:D4}/{1:D2}/{2}.json' -f $y, $m, $mid)
}

function _ReadJsonString {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    return ConvertFrom-Json -InputObject $Json
}

# JSON 配列ファイルを読み、配列を Object[] として一意に返すヘルパ。
# PowerShell 関数の出力ストリームは配列を auto-unroll するため、
# 配列をひと塊として渡すには Write-Output -NoEnumerate を使う。
# 呼び出し側は @() で囲んで N 要素配列に戻す。
function _ReadJsonArray {
    # JSON 配列を読み、関数の出力ストリームに 1 要素ずつ emit する。
    # 呼び出し側は @(funcCall) で N 要素配列に集約する。
    param($Source, [string]$RelPath)
    $raw = Get-DataFile -Source $Source -RelPath $RelPath
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $parsed = ConvertFrom-Json -InputObject ([string]$raw)
    if ($null -eq $parsed) { return }
    # 配列 → 各要素を Write-Output (auto-unroll)
    # 単一オブジェクト → そのまま 1 要素
    if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        foreach ($e in $parsed) { Write-Output $e }
    } else {
        Write-Output $parsed
    }
}

function _EnsureDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ---- DataSource 生成 ----

function New-DataSource {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Token
    )
    $local = if ($Config.local_store) { [string]$Config.local_store } else { (Join-Path $env:LOCALAPPDATA 'worktime-tracker\store') }
    _EnsureDir $local
    _EnsureDir (Join-Path $local 'master')
    _EnsureDir (Join-Path $local 'data')

    $remote = $null
    if ($Config.mode -eq 'gitlab' -and $Token) {
        $remote = New-GitLabContext -BaseUrl $Config.gitlab_url -ProjectId $Config.project_id `
                                    -Branch  $Config.branch     -Token     $Token
    }

    return [pscustomobject]@{
        Mode       = [string]$Config.mode
        LocalRoot  = $local
        RemoteCtx  = $remote
    }
}

# ---- ローカル I/O (Source.Mode に関係なく LocalRoot を対象) ----

function Get-DataFile {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$RelPath)
    $p = Join-Path $Source.LocalRoot $RelPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
}

function Set-DataFile {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Content,
        [string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    $p = Join-Path $Source.LocalRoot $RelPath
    _EnsureDir (Split-Path -Parent $p)
    [System.IO.File]::WriteAllText($p, $Content, [System.Text.UTF8Encoding]::new($false))
}

# ---- マスタ ----

function Get-MasterMembers      { param($Source) _ReadJsonArray -Source $Source -RelPath 'master/members.json' }
function Get-MasterProjects     { param($Source) _ReadJsonArray -Source $Source -RelPath 'master/projects.json' }
function Get-MasterCategories   { param($Source) _ReadJsonArray -Source $Source -RelPath 'master/categories.json' }
function Get-MasterTaskPatterns { param($Source) _ReadJsonArray -Source $Source -RelPath 'master/task_patterns.json' }
function Get-MasterHolidays     { param($Source) _ReadJsonArray -Source $Source -RelPath 'master/holidays.json' }

function _ToPSObjectDeep {
    # 再帰的に Hashtable / OrderedDictionary / PSCustomObject / 配列 を
    # PSCustomObject + Object[] に正規化する。
    # PS 5.1 の ConvertTo-Json は Hashtable 入れ子で 'Cannot find an overload...' を起こすため必須。
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [string]) { return $v }
    if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return $v }
    if ($v -is [datetime]) { return $v }
    if ($v -is [System.Collections.IDictionary]) {
        $o = New-Object psobject
        foreach ($k in @($v.Keys)) {
            $o | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue (_ToPSObjectDeep $v[$k])
        }
        return $o
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($e in $v) { $list.Add( (_ToPSObjectDeep $e) ) }
        return $list.ToArray()
    }
    if ($v -is [System.Management.Automation.PSObject]) {
        $o = New-Object psobject
        foreach ($p in $v.PSObject.Properties) {
            $o | Add-Member -NotePropertyName ([string]$p.Name) -NotePropertyValue (_ToPSObjectDeep $p.Value)
        }
        return $o
    }
    return $v
}

function _ToObjectArray {
    # PS 5.1: @() が List[object] of Hashtable で ArgumentException を出すケースがあるため
    # 安全に Object[] に変換するヘルパ。
    param($v)
    if ($null -eq $v) { return @() }
    if ($v -is [object[]]) { return $v }
    if ($v -is [System.Collections.Generic.IList[object]]) {
        try { return $v.ToArray() } catch {}
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in $v) { $list.Add($e) }
    return $list.ToArray()
}

function _SaveMasterJson {
    # マスタ JSON 配列を保存。入力は Hashtable / Ordered / PSCustomObject 混在 OK。
    param($Source, $Data, [string]$RelPath, [string]$CommitMessage, $AuthorName, $AuthorEmail)

    $items = _ToObjectArray $Data
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $items) {
        $rows.Add( (_ToPSObjectDeep $e) )
    }
    $json = ConvertTo-Json -InputObject $rows.ToArray() -Depth 32
    if ([string]::IsNullOrEmpty($json)) { $json = '[]' }
    Set-DataFile -Source $Source -RelPath ([string]$RelPath) -Content ([string]$json) `
                 -AuthorName ([string]$AuthorName) -AuthorEmail ([string]$AuthorEmail)
}

function Save-MasterMembers      { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/members.json'       -CommitMessage 'update master: members'       -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterProjects     { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/projects.json'      -CommitMessage 'update master: projects'      -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterCategories   { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/categories.json'    -CommitMessage 'update master: categories'    -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterTaskPatterns { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/task_patterns.json' -CommitMessage 'update master: task_patterns' -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterHolidays     { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/holidays.json'      -CommitMessage 'update master: holidays'      -AuthorName $AuthorName -AuthorEmail $AuthorEmail }

# プロジェクトの wbs_items だけを更新する (WbsInput からの保存用)
# 他プロジェクトはそのまま温存し、対象プロジェクトの wbs_items のみ差し替える。
# 戻り値: 保存後の projects 配列
function Save-ProjectWbsItems {
    param(
        $Source,
        [string]$ProjectCode,
        $WbsItems,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    # 最新の projects.json を取得 → 配列で差し替え → 保存
    $current = @(Get-MasterProjects -Source $Source)
    $updated = New-Object System.Collections.Generic.List[object]
    foreach ($p in $current) {
        if ($null -eq $p) { continue }
        $h = [ordered]@{
            unit_code       = [string]$p.unit_code
            project_name    = [string]$p.project_name
            unit_name       = [string]$p.unit_name
            target_system   = [string]$p.target_system
            work_type       = if ($p.work_type) { [string]$p.work_type } else { '案件対応' }
            period_from     = [string]$p.period_from
            period_to       = [string]$p.period_to
            task_pattern_id = [string]$p.task_pattern_id
            active          = if ($null -ne $p.active) { [bool]$p.active } else { $true }
            wbs_items       = @()
        }
        if (([string]$p.unit_code) -eq $ProjectCode) {
            $h.wbs_items = @($WbsItems)
        } elseif ($p.wbs_items) {
            $h.wbs_items = @($p.wbs_items)
        }
        $updated.Add($h)
    }
    Save-MasterProjects -Source $Source -Data $updated.ToArray() `
                        -AuthorName $AuthorName -AuthorEmail $AuthorEmail
    return $updated.ToArray()
}

# ---- 実績データ (ローカル) ----

function Load-MonthEntries {
    # ホスティング/エンコード問わずローカルから N 個の entry を出力 (auto-unroll)。
    # 呼び出し側は @(Load-MonthEntries ...) で N 要素配列に集約する。
    param($Source, $MemberId, $Year, $Month)
    if (-not $Source) { throw 'Load-MonthEntries: Source 未指定' }
    $mid = _AsScalarStr $MemberId
    if ([string]::IsNullOrWhiteSpace($mid)) { throw 'Load-MonthEntries: MemberId 未指定' }
    $rel = Get-MonthRelPath -MemberId $mid -Year $Year -Month $Month
    $raw = Get-DataFile -Source $Source -RelPath $rel
    if (-not $raw) { return }
    $doc = ConvertFrom-Json -InputObject ([string]$raw)
    if ($null -eq $doc -or $null -eq $doc.entries) { return }
    foreach ($e in @($doc.entries)) { Write-Output $e }
}

function Save-MonthEntries {
    param($Source, $MemberId, $Year, $Month, $Entries, $AuthorName, $AuthorEmail)
    if (-not $Source) { throw 'Save-MonthEntries: Source 未指定' }
    $mid = _AsScalarStr $MemberId
    if ([string]::IsNullOrWhiteSpace($mid)) { throw 'Save-MonthEntries: MemberId 未指定' }
    $y   = [int](_AsScalarStr $Year)
    $m   = [int](_AsScalarStr $Month)
    $Entries = @($Entries)
    $rel = Get-MonthRelPath -MemberId $mid -Year $y -Month $m
    $doc = [ordered]@{
        member_id  = $mid
        year       = $y
        month      = $m
        entries    = @($Entries)
        updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 10
    Set-DataFile -Source $Source -RelPath $rel -Content ([string]$json) `
                 -AuthorName ([string]$AuthorName) -AuthorEmail ([string]$AuthorEmail)
}

function Save-EntriesGrouped {
    param($Source, $MemberId, $AllEntries, $ViewYear, $ViewMonth, $AuthorName, $AuthorEmail)
    if (-not $Source) { throw 'Save-EntriesGrouped: Source 未指定' }
    $MemberId  = _AsScalarStr $MemberId
    if ([string]::IsNullOrWhiteSpace($MemberId)) { throw 'Save-EntriesGrouped: MemberId 未指定' }
    $ViewYear  = [int](_AsScalarStr $ViewYear)
    $ViewMonth = [int](_AsScalarStr $ViewMonth)
    $AuthorName  = [string]$AuthorName
    $AuthorEmail = [string]$AuthorEmail
    $AllEntries = @($AllEntries)
    $groups = @{}
    foreach ($e in $AllEntries) {
        if (-not $e -or [string]::IsNullOrWhiteSpace([string]$e.date)) { continue }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$e.date, [ref]$d)) {
            throw "保存中: 日付の形式が不正です (date='$($e.date)')"
        }
        $key = '{0}-{1:D2}' -f $d.Year, $d.Month
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($e)
    }
    $viewKey = '{0}-{1:D2}' -f $ViewYear, $ViewMonth

    $keysSnap = @($groups.Keys | ForEach-Object { [string]$_ })
    foreach ($key in $keysSnap) {
        $parts = ([string]$key).Split('-')
        $y = [int]([string]$parts[0])
        $m = [int]([string]$parts[1])
        $newForMonth = New-Object 'System.Collections.Generic.List[object]'
        foreach ($e in $groups[[string]$key]) { $newForMonth.Add($e) }

        if ($key -eq $viewKey) {
            Save-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m `
                              -Entries $newForMonth.ToArray() -AuthorName $AuthorName -AuthorEmail $AuthorEmail
        } else {
            $merged = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in @(Load-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m)) {
                $merged.Add($e)
            }
            foreach ($e in $newForMonth) { $merged.Add($e) }
            Save-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m `
                              -Entries $merged.ToArray() -AuthorName $AuthorName -AuthorEmail $AuthorEmail
        }
    }

    if (-not $groups.ContainsKey($viewKey)) {
        Save-MonthEntries -Source $Source -MemberId $MemberId -Year $ViewYear -Month $ViewMonth `
                          -Entries @() -AuthorName $AuthorName -AuthorEmail $AuthorEmail
    }
}

# ---- 全件取得 (Report 用) ----

function Load-AllEntries-Local {
    param([Parameter(Mandatory)]$Source)
    $dataRoot = Join-Path $Source.LocalRoot 'data'
    if (-not (Test-Path $dataRoot)) { return }
    Get-ChildItem -Path $dataRoot -Recurse -Filter '*.json' | ForEach-Object {
        try {
            $raw = [System.IO.File]::ReadAllText($_.FullName, [System.Text.UTF8Encoding]::new($false))
            $doc = ConvertFrom-Json -InputObject $raw
            foreach ($e in @($doc.entries)) {
                $row = [ordered]@{ member_id = $doc.member_id }
                foreach ($p in $e.PSObject.Properties) { $row[$p.Name] = $p.Value }
                Write-Output ([pscustomobject]$row)
            }
        } catch { Write-Warning "skip $($_.FullName): $_" }
    }
}

function Load-AllEntries-Remote {
    # リモートから全件取得 (他人のデータも含めて Report 用)
    param([Parameter(Mandatory)]$Source)
    if (-not $Source.RemoteCtx) { throw 'Load-AllEntries-Remote: リモート未設定' }
    $tree   = Get-GitLabTree -Ctx $Source.RemoteCtx -Path 'data'
    $getter = { param($p) Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $p }
    foreach ($item in $tree) {
        if ($item.type -ne 'blob') { continue }
        if (-not $item.path.EndsWith('.json')) { continue }
        try {
            $raw = & $getter $item.path
            $doc = ConvertFrom-Json -InputObject ([string]$raw)
            foreach ($e in @($doc.entries)) {
                $row = [ordered]@{ member_id = $doc.member_id }
                foreach ($p in $e.PSObject.Properties) { $row[$p.Name] = $p.Value }
                Write-Output ([pscustomobject]$row)
            }
        } catch { Write-Warning "skip $($item.path): $_" }
    }
}

function Load-AllEntries {
    # 互換: local モードならローカル、リモートモードならリモート優先 (Report で使用)
    param([Parameter(Mandatory)]$Source)
    if ($Source.Mode -eq 'local') { Load-AllEntries-Local -Source $Source; return }
    if ($Source.RemoteCtx)        { Load-AllEntries-Remote -Source $Source; return }
    Load-AllEntries-Local -Source $Source
}

# ---- 同期状態 (差分同期用) ----
# リモートの blob SHA を覚えておき、次回 pull で変化のないファイルの
# ダウンロードを丸ごと省く。tree API は 1 リクエストで全ファイルの blob SHA を
# 返すため、「変更なし」なら 1 リクエストで同期が完了する。
#
# 形式:
#   { "pull": { "<rel path>": "<blob sha>" },
#     "push": { "<rel path>": "<pushed content hash>" } }
#
# local_store 直下に置く。master/ data/ の外なので push 対象にはならない。

function _SyncStatePath {
    param($Source)
    return (Join-Path $Source.LocalRoot '.sync_state.json')
}

function _LoadSyncState {
    param($Source)
    $empty = @{ pull = @{}; push = @{} }
    $p = _SyncStatePath -Source $Source
    if (-not (Test-Path -LiteralPath $p)) { return $empty }
    try {
        $doc = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false)))
        foreach ($sec in @('pull','push')) {
            if ($doc.PSObject.Properties[$sec] -and $doc.$sec) {
                foreach ($prop in $doc.$sec.PSObject.Properties) { $empty[$sec][$prop.Name] = [string]$prop.Value }
            }
        }
    } catch {
        # 壊れていても同期は続行できる (全件ダウンロードに退化するだけ)
    }
    return $empty
}

function _SaveSyncState {
    param($Source, $State)
    try {
        $json = ([pscustomobject]@{ pull = $State.pull; push = $State.push } | ConvertTo-Json -Depth 4)
        [System.IO.File]::WriteAllText((_SyncStatePath -Source $Source), $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # 保存に失敗しても次回は全件ダウンロードになるだけなので握りつぶす
    }
}

function _ContentHash {
    # [string] 型指定により $null は空文字に強制変換される ($null 判定は不要)。
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return [System.BitConverter]::ToString($bytes).Replace('-','')
    } finally { $sha.Dispose() }
}

# tree API の結果から blob だけを {path -> id} で返す
function _RemoteBlobMap {
    param($Source, [string]$Path)
    $map = @{}
    foreach ($item in @(Get-GitLabTree -Ctx $Source.RemoteCtx -Path $Path)) {
        if ($item.type -ne 'blob') { continue }
        if (-not ([string]$item.path).EndsWith('.json')) { continue }
        $map[[string]$item.path] = [string]$item.id
    }
    return $map
}

# blob SHA が前回と同じ かつ ローカル実体が在るならダウンロードを省く共通ロジック。
# 戻り値: @{ Pulled; Skipped; Errors }
function _PullBlobs {
    param($Source, $BlobMap, $State, $OnProgress)
    $pulled = 0; $skipped = 0; $errors = @()
    $paths = @($BlobMap.Keys | Sort-Object)
    $total = $paths.Count
    $i = 0
    foreach ($rel in $paths) {
        $i++
        $sha = [string]$BlobMap[$rel]
        $dst = Join-Path $Source.LocalRoot $rel
        if ($State.pull[$rel] -eq $sha -and (Test-Path -LiteralPath $dst)) {
            $skipped++
            continue
        }
        if ($OnProgress) { & $OnProgress $i $total $rel }
        try {
            $raw = Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $rel
            if ($null -eq $raw) { continue }
            _EnsureDir (Split-Path -Parent $dst)
            [System.IO.File]::WriteAllText($dst, $raw, [System.Text.UTF8Encoding]::new($false))
            $State.pull[$rel] = $sha
            $pulled++
        } catch {
            $errors += "$rel : $($_.Exception.Message)"
        }
    }
    return @{ Pulled = $pulled; Skipped = $skipped; Errors = $errors }
}

# ---- 同期: マスタ pull (リモート → local_store) ----

function Sync-Pull-Masters {
    param(
        [Parameter(Mandatory)]$Source,
        [switch]$Force,
        $OnProgress
    )
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pulled = 0; Skipped = 0; Missing = 0; Errors = @() }
    }
    $known = @('members.json','projects.json','categories.json','task_patterns.json','holidays.json')
    $state = _LoadSyncState -Source $Source
    if ($Force) { foreach ($n in $known) { $state.pull.Remove("master/$n") } }

    try {
        $blobs = _RemoteBlobMap -Source $Source -Path 'master'
    } catch {
        return [pscustomobject]@{ Pulled = 0; Skipped = 0; Missing = 0; Errors = @("tree(master): $($_.Exception.Message)") }
    }
    # マスタは 5 ファイル固定。リモートに無いものは Missing として数える。
    $missing = 0
    foreach ($n in $known) { if (-not $blobs.ContainsKey("master/$n")) { $missing++ } }

    $r = _PullBlobs -Source $Source -BlobMap $blobs -State $state -OnProgress $OnProgress
    _SaveSyncState -Source $Source -State $state
    return [pscustomobject]@{ Pulled = $r.Pulled; Skipped = $r.Skipped; Missing = $missing; Errors = $r.Errors }
}

# ---- 同期: 自分の月次データ pull (リモート → local_store) ----
# WbsInput / Tracker の「取得」ボタンから呼ばれ、対象月のファイル 1 つを更新。
function Sync-Pull-MyData {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month
    )
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pulled = 0; Missing = 0; Errors = @() }
    }
    $rel = Get-MonthRelPath -MemberId $MemberId -Year $Year -Month $Month
    try {
        $raw = Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $rel
        if (-not $raw) {
            return [pscustomobject]@{ Pulled = 0; Missing = 1; Errors = @() }
        }
        $dst = Join-Path $Source.LocalRoot $rel
        _EnsureDir (Split-Path -Parent $dst)
        [System.IO.File]::WriteAllText($dst, $raw, [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Pulled = 1; Missing = 0; Errors = @() }
    } catch {
        return [pscustomobject]@{ Pulled = 0; Missing = 0; Errors = @("$rel : $($_.Exception.Message)") }
    }
}

# ---- 同期: 全データ pull (Report の「取得」用) ----
# data/ 配下の *.json をリモートから取って local_store に書き戻す。
# tree API が返す blob SHA を前回値と突き合わせ、変更のないファイルは
# ダウンロードしない。全員が更新していない限り、実 GET は数件で済む。
function Sync-Pull-AllData {
    param(
        [Parameter(Mandatory)]$Source,
        [switch]$Force,
        $OnProgress
    )
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pulled = 0; Skipped = 0; Total = 0; Errors = @() }
    }
    $state = _LoadSyncState -Source $Source
    if ($Force) {
        foreach ($k in @($state.pull.Keys)) { if ($k -like 'data/*') { $state.pull.Remove($k) } }
    }
    try {
        $blobs = _RemoteBlobMap -Source $Source -Path 'data'
    } catch {
        return [pscustomobject]@{ Pulled = 0; Skipped = 0; Total = 0; Errors = @("tree(data): $($_.Exception.Message)") }
    }
    $r = _PullBlobs -Source $Source -BlobMap $blobs -State $state -OnProgress $OnProgress
    _SaveSyncState -Source $Source -State $state
    return [pscustomobject]@{ Pulled = $r.Pulled; Skipped = $r.Skipped; Total = $blobs.Count; Errors = $r.Errors }
}

# ---- 同期: マスタ push (local_store → リモート) ----

function Sync-Push-Masters {
    param([Parameter(Mandatory)]$Source, $AuthorName, $AuthorEmail, [switch]$Force)
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pushed = 0; SkippedNoDiff = 0; Errors = @() }
    }
    $pushed = 0; $noDiff = 0; $errors = @()
    $state = _LoadSyncState -Source $Source
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json','holidays.json')) {
        $rel   = "master/$name"
        $local = Join-Path $Source.LocalRoot $rel
        if (-not (Test-Path -LiteralPath $local)) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($local, [System.Text.UTF8Encoding]::new($false))
            # 前回 push 時と同一内容なら空コミットを作らずに飛ばす
            $hash = _ContentHash $content
            if (-not $Force -and $state.push[$rel] -eq $hash) { $noDiff++; continue }
            $null = Set-GitLabFile -Ctx $Source.RemoteCtx -Path $rel -Content $content `
                                   -CommitMessage "sync master: $name" -AuthorName $AuthorName -AuthorEmail $AuthorEmail
            $state.push[$rel] = $hash
            $pushed++
        } catch {
            $errors += "master/$name : $($_.Exception.Message)"
        }
    }
    _SaveSyncState -Source $Source -State $state
    return [pscustomobject]@{ Pushed = $pushed; SkippedNoDiff = $noDiff; Errors = $errors }
}

# ---- 同期: 自分のデータ push (local_store → リモート, 全期間) ----
# 動作:
#   1. local_store/data/**/*.json で member_id == 自分 のもの全件
#   2. 各ファイルについてリモートを fetch → updated_at 比較
#       - local 新しい → PUT
#       - remote 新しい → スキップ (要警告)
#       - 同じ → スキップ
#       - リモート無し → POST
#   3. 結果サマリを返す

function Sync-Push-MyData {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        $AuthorName,
        $AuthorEmail,
        [switch]$Force,
        $OnProgress
    )
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        throw 'Sync-Push-MyData: リモート未設定のため送信できません'
    }
    $result = [pscustomobject]@{
        Pushed        = 0
        SkippedNewer  = 0    # リモートが新しいためスキップ
        SkippedSame   = 0
        SkippedNoDiff = 0    # 前回 push 以降ローカルが変わっていない (通信なし)
        Errors        = @()
        Conflicts     = @()  # @{ path; local_updated; remote_updated }
    }
    $dataRoot = Join-Path $Source.LocalRoot 'data'
    if (-not (Test-Path -LiteralPath $dataRoot)) { return $result }

    $state = _LoadSyncState -Source $Source
    $myFiles = @(Get-ChildItem -Path $dataRoot -Recurse -Filter "$MemberId.json")
    $total = $myFiles.Count
    $i = 0
    foreach ($f in $myFiles) {
        $i++
        $rel = $f.FullName.Substring($Source.LocalRoot.Length).TrimStart('\','/') -replace '\\','/'
        try {
            $localText = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))

            # 前回 push した内容と同一なら通信そのものを省く
            $localHash = _ContentHash $localText
            if (-not $Force -and $state.push[$rel] -eq $localHash) {
                $result.SkippedNoDiff++
                continue
            }
            if ($OnProgress) { & $OnProgress $i $total $rel }

            $localDoc  = $localText | ConvertFrom-Json
            $localTs   = [string]$localDoc.updated_at

            # files/:path は content と last_commit_id を同時に返すので、
            # 「リモート内容の取得」と「楽観排他用メタ」を 1 往復でまかなう。
            $remoteMeta = $null
            try { $remoteMeta = Get-GitLabFileMeta -Ctx $Source.RemoteCtx -Path $rel } catch { }
            $remoteText = Get-GitLabFileMetaContent -Meta $remoteMeta

            $shouldPush = $true
            if ($remoteText) {
                try {
                    $remoteDoc = $remoteText | ConvertFrom-Json
                    $remoteTs  = [string]$remoteDoc.updated_at
                    if ($remoteTs -and $localTs) {
                        $rL = [datetime]::MinValue; $rR = [datetime]::MinValue
                        $okL = [datetime]::TryParse($localTs,  [ref]$rL)
                        $okR = [datetime]::TryParse($remoteTs, [ref]$rR)
                        if ($okL -and $okR) {
                            if ($rR -gt $rL) {
                                $shouldPush = $false
                                $result.SkippedNewer++
                                $result.Conflicts += [pscustomobject]@{
                                    path = $rel
                                    local_updated  = $localTs
                                    remote_updated = $remoteTs
                                }
                                continue
                            } elseif ($rR -eq $rL) {
                                $shouldPush = $false
                                $result.SkippedSame++
                                # 同一と確認できたので次回は通信なしで飛ばせる
                                $state.push[$rel] = $localHash
                                continue
                            }
                        }
                    }
                } catch {
                    # remote doc 不正なら上書きする
                }
            }
            if ($shouldPush) {
                $commitMsg = ('upload: {0}' -f $rel)
                # 直前に取得済みの meta を渡し、Set-GitLabFile 内でのメタ再取得を省く
                $null = Set-GitLabFile -Ctx $Source.RemoteCtx -Path $rel -Content $localText `
                                       -CommitMessage $commitMsg -AuthorName $AuthorName -AuthorEmail $AuthorEmail `
                                       -KnownMeta $remoteMeta -MetaResolved
                $state.push[$rel] = $localHash
                $result.Pushed++
            }
        } catch {
            $result.Errors += "$rel : $($_.Exception.Message)"
        }
    }
    _SaveSyncState -Source $Source -State $state
    return $result
}

# ---- マスタ存在チェック (bootstrap 用) ----

function Test-LocalMastersComplete {
    param([Parameter(Mandatory)]$Source)
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json','holidays.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source.LocalRoot "master/$name"))) { return $false }
    }
    return $true
}
