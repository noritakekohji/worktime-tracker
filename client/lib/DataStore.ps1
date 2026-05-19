# DataStore.ps1 — マスタ/実績データの読み書き (ハイブリッド: ローカル常用 + 任意でリモート同期)
#
# Source 構造:
#   @{
#     Mode       = 'local' | 'gitlab' | 'github'
#     LocalRoot  = <常用ローカルストア。全モード共通>
#     RemoteCtx  = $null (local) or GitLab/GitHub Context (リモート同期可)
#   }
#
# 読み書きは常に LocalRoot に対して行う。
# リモートとの同期は Sync-Pull-Masters / Sync-Push-MyData を明示的に呼ぶ。

. (Join-Path $PSScriptRoot 'GitLab.ps1')
. (Join-Path $PSScriptRoot 'GitHub.ps1')

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
    switch ($Config.mode) {
        'gitlab' {
            if ($Token) {
                $remote = New-GitLabContext -BaseUrl $Config.gitlab_url -ProjectId $Config.project_id `
                                            -Branch  $Config.branch     -Token     $Token
            }
        }
        'github' {
            if ($Token) {
                $remote = New-GitHubContext -Repo $Config.github_repo -Branch $Config.branch -Token $Token
            }
        }
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

function _SaveMasterJson {
    param($Source, $Data, [string]$RelPath, [string]$CommitMessage, $AuthorName, $AuthorEmail)
    $arr = @($Data)
    $json = ConvertTo-Json -InputObject $arr -Depth 10
    Set-DataFile -Source $Source -RelPath $RelPath -Content ([string]$json) `
                 -CommitMessage $CommitMessage `
                 -AuthorName ([string]$AuthorName) -AuthorEmail ([string]$AuthorEmail)
}

function Save-MasterMembers      { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/members.json'       -CommitMessage 'update master: members'       -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterProjects     { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/projects.json'      -CommitMessage 'update master: projects'      -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterCategories   { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/categories.json'    -CommitMessage 'update master: categories'    -AuthorName $AuthorName -AuthorEmail $AuthorEmail }
function Save-MasterTaskPatterns { param($Source, $Data, $AuthorName, $AuthorEmail) _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/task_patterns.json' -CommitMessage 'update master: task_patterns' -AuthorName $AuthorName -AuthorEmail $AuthorEmail }

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
    if ($Source.Mode -eq 'gitlab') {
        $tree   = Get-GitLabTree -Ctx $Source.RemoteCtx -Path 'data'
        $getter = { param($p) Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $p }
    } else {
        $tree   = Get-GitHubTree -Ctx $Source.RemoteCtx -Path 'data'
        $getter = { param($p) Get-GitHubFileRaw -Ctx $Source.RemoteCtx -Path $p }
    }
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

# ---- 同期: マスタ pull (リモート → local_store) ----

function Sync-Pull-Masters {
    param([Parameter(Mandatory)]$Source)
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pulled = 0; Missing = 0; Errors = @() }
    }
    $pulled = 0; $missing = 0; $errors = @()
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json')) {
        try {
            $raw = if ($Source.Mode -eq 'gitlab') {
                Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path "master/$name"
            } else {
                Get-GitHubFileRaw -Ctx $Source.RemoteCtx -Path "master/$name"
            }
            if (-not $raw) { $missing++; continue }
            $dst = Join-Path $Source.LocalRoot "master/$name"
            _EnsureDir (Split-Path -Parent $dst)
            [System.IO.File]::WriteAllText($dst, $raw, [System.Text.UTF8Encoding]::new($false))
            $pulled++
        } catch {
            $errors += "master/$name : $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Pulled = $pulled; Missing = $missing; Errors = $errors }
}

# ---- 同期: マスタ push (local_store → リモート) ----

function Sync-Push-Masters {
    param([Parameter(Mandatory)]$Source, $AuthorName, $AuthorEmail)
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        return [pscustomobject]@{ Pushed = 0; Errors = @() }
    }
    $pushed = 0; $errors = @()
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json')) {
        $local = Join-Path $Source.LocalRoot "master/$name"
        if (-not (Test-Path -LiteralPath $local)) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($local, [System.Text.UTF8Encoding]::new($false))
            if ($Source.Mode -eq 'gitlab') {
                $null = Set-GitLabFile -Ctx $Source.RemoteCtx -Path "master/$name" -Content $content `
                                       -CommitMessage "sync master: $name" -AuthorName $AuthorName -AuthorEmail $AuthorEmail
            } else {
                $null = Set-GitHubFile -Ctx $Source.RemoteCtx -Path "master/$name" -Content $content `
                                       -CommitMessage "sync master: $name" -AuthorName $AuthorName -AuthorEmail $AuthorEmail
            }
            $pushed++
        } catch {
            $errors += "master/$name : $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Pushed = $pushed; Errors = $errors }
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

function _GetRemoteEntryDoc {
    param($Source, [string]$RelPath)
    try {
        if ($Source.Mode -eq 'gitlab') { return Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path $RelPath }
        else                            { return Get-GitHubFileRaw -Ctx $Source.RemoteCtx -Path $RelPath }
    } catch { return $null }
}

function Sync-Push-MyData {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        $AuthorName,
        $AuthorEmail
    )
    if ($Source.Mode -eq 'local' -or -not $Source.RemoteCtx) {
        throw 'Sync-Push-MyData: リモート未設定のため送信できません'
    }
    $result = [pscustomobject]@{
        Pushed       = 0
        SkippedNewer = 0    # リモートが新しいためスキップ
        SkippedSame  = 0
        Errors       = @()
        Conflicts    = @()  # @{ path; local_updated; remote_updated }
    }
    $dataRoot = Join-Path $Source.LocalRoot 'data'
    if (-not (Test-Path -LiteralPath $dataRoot)) { return $result }

    $myFiles = Get-ChildItem -Path $dataRoot -Recurse -Filter "$MemberId.json"
    foreach ($f in $myFiles) {
        $rel = $f.FullName.Substring($Source.LocalRoot.Length).TrimStart('\','/') -replace '\\','/'
        try {
            $localText = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))
            $localDoc  = $localText | ConvertFrom-Json
            $localTs   = [string]$localDoc.updated_at

            $remoteText = _GetRemoteEntryDoc -Source $Source -RelPath $rel
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
                if ($Source.Mode -eq 'gitlab') {
                    $null = Set-GitLabFile -Ctx $Source.RemoteCtx -Path $rel -Content $localText `
                                           -CommitMessage $commitMsg -AuthorName $AuthorName -AuthorEmail $AuthorEmail
                } else {
                    $null = Set-GitHubFile -Ctx $Source.RemoteCtx -Path $rel -Content $localText `
                                           -CommitMessage $commitMsg -AuthorName $AuthorName -AuthorEmail $AuthorEmail
                }
                $result.Pushed++
            }
        } catch {
            $result.Errors += "$rel : $($_.Exception.Message)"
        }
    }
    return $result
}

# ---- マスタ存在チェック (bootstrap 用) ----

function Test-LocalMastersComplete {
    param([Parameter(Mandatory)]$Source)
    foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source.LocalRoot "master/$name"))) { return $false }
    }
    return $true
}
