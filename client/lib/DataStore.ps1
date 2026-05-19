# DataStore.ps1 — マスタ/実績データの読み書き
# mode = 'gitlab' なら GitLab REST API 経由 (git CLI 不要)
# mode = 'local'  ならローカルファイルシステム (開発・テスト用)

. (Join-Path $PSScriptRoot 'GitLab.ps1')
. (Join-Path $PSScriptRoot 'GitHub.ps1')

function Get-RepoRoot {
    param([string]$StartPath = $PSScriptRoot)
    $d = Get-Item -LiteralPath $StartPath
    while ($d) {
        if ((Test-Path (Join-Path $d.FullName 'master')) -and
            (Test-Path (Join-Path $d.FullName 'data'))) {
            return $d.FullName
        }
        $d = $d.Parent
    }
    return $null
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
    return $Json | ConvertFrom-Json
}

function New-DataSource {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Token
    )
    switch ($Config.mode) {
        'gitlab' {
            $ctx = New-GitLabContext -BaseUrl $Config.gitlab_url -ProjectId $Config.project_id `
                                     -Branch  $Config.branch     -Token     $Token
            return [pscustomobject]@{ Mode = 'gitlab'; Ctx = $ctx; Root = $null }
        }
        'github' {
            $ctx = New-GitHubContext -Repo $Config.github_repo -Branch $Config.branch -Token $Token
            return [pscustomobject]@{ Mode = 'github'; Ctx = $ctx; Root = $null }
        }
        default {
            $root = $Config.local_root
            if (-not $root) { $root = Get-RepoRoot -StartPath $PSScriptRoot }
            return [pscustomobject]@{ Mode = 'local'; Ctx = $null; Root = $root }
        }
    }
}

function Get-DataFile {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$RelPath)
    switch ($Source.Mode) {
        'gitlab' { return Get-GitLabFileRaw -Ctx $Source.Ctx -Path $RelPath }
        'github' { return Get-GitHubFileRaw -Ctx $Source.Ctx -Path $RelPath }
        default  {
            $p = Join-Path $Source.Root $RelPath
            if (-not (Test-Path -LiteralPath $p)) { return $null }
            return Get-Content -LiteralPath $p -Raw -Encoding UTF8
        }
    }
}

function Set-DataFile {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    try {
        switch ($Source.Mode) {
            'gitlab' {
                $null = Set-GitLabFile -Ctx $Source.Ctx -Path $RelPath -Content $Content `
                                       -CommitMessage $CommitMessage -AuthorName $AuthorName -AuthorEmail $AuthorEmail
            }
            'github' {
                $null = Set-GitHubFile -Ctx $Source.Ctx -Path $RelPath -Content $Content `
                                       -CommitMessage $CommitMessage -AuthorName $AuthorName -AuthorEmail $AuthorEmail
            }
            default {
                $p = Join-Path $Source.Root $RelPath
                $dir = Split-Path -Parent $p
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Set-Content -LiteralPath $p -Value $Content -Encoding UTF8
            }
        }
    } catch {
        throw ("Set-DataFile failed: mode={0} path={1} :: {2}" -f $Source.Mode, $RelPath, $_.Exception.Message)
    }
}

# ---- マスタ ----

function Get-MasterMembers      { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/members.json') }
function Get-MasterProjects     { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/projects.json') }
function Get-MasterCategories   { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/categories.json') }
function Get-MasterTaskPatterns { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/task_patterns.json') }

function _SaveMasterJson {
    param($Source, $Data, [string]$RelPath, [string]$CommitMessage, $AuthorName, $AuthorEmail)
    # 配列の単一要素化を防ぐため Write-Output で配列のまま渡す
    $arr = @($Data)
    # ConvertTo-Json はパイプライン経由で配列を渡すと PS 5.1 で 1 要素時に
    # オブジェクトとして出力するため -InputObject を使い、配列でラップする
    $json = ConvertTo-Json -InputObject $arr -Depth 10
    Set-DataFile -Source $Source -RelPath $RelPath -Content ([string]$json) `
                 -CommitMessage $CommitMessage `
                 -AuthorName ([string]$AuthorName) -AuthorEmail ([string]$AuthorEmail)
}

function Save-MasterMembers      { param($Source, $Data, $AuthorName, $AuthorEmail)
    _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/members.json'       -CommitMessage 'update master: members'       -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}
function Save-MasterProjects     { param($Source, $Data, $AuthorName, $AuthorEmail)
    _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/projects.json'      -CommitMessage 'update master: projects'      -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}
function Save-MasterCategories   { param($Source, $Data, $AuthorName, $AuthorEmail)
    _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/categories.json'    -CommitMessage 'update master: categories'    -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}
function Save-MasterTaskPatterns { param($Source, $Data, $AuthorName, $AuthorEmail)
    _SaveMasterJson -Source $Source -Data $Data -RelPath 'master/task_patterns.json' -CommitMessage 'update master: task_patterns' -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}

# ---- 実績データ ----

function Load-MonthEntries {
    param($Source, $MemberId, $Year, $Month)
    if (-not $Source) { throw 'Load-MonthEntries: Source 未指定' }
    $mid = _AsScalarStr $MemberId
    if ([string]::IsNullOrWhiteSpace($mid)) { throw 'Load-MonthEntries: MemberId 未指定' }
    $rel = Get-MonthRelPath -MemberId $mid -Year $Year -Month $Month
    $raw = Get-DataFile -Source $Source -RelPath $rel
    if (-not $raw) { return ,@() }
    $doc = $raw | ConvertFrom-Json
    if ($null -eq $doc.entries) { return ,@() }
    return ,@($doc.entries)
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
        member_id = $mid
        year      = $y
        month     = $m
        entries   = @($Entries)
    }
    $json = $doc | ConvertTo-Json -Depth 10
    $msg = 'update: {0} {1:D4}-{2:D2}' -f $mid, $y, $m
    Set-DataFile -Source $Source -RelPath $rel -Content $json -CommitMessage $msg `
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

function Load-AllEntries {
    param([Parameter(Mandatory)]$Source)
    $results = New-Object System.Collections.Generic.List[object]
    if ($Source.Mode -eq 'local') {
        $dataRoot = Join-Path $Source.Root 'data'
        if (-not (Test-Path $dataRoot)) { return ,@() }
        Get-ChildItem -Path $dataRoot -Recurse -Filter '*.json' | ForEach-Object {
            try {
                $doc = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($e in @($doc.entries)) {
                    $row = [ordered]@{ member_id = $doc.member_id }
                    foreach ($p in $e.PSObject.Properties) { $row[$p.Name] = $p.Value }
                    $results.Add([pscustomobject]$row)
                }
            } catch { Write-Warning "skip $($_.FullName): $_" }
        }
    } else {
        if ($Source.Mode -eq 'gitlab') {
            $tree    = Get-GitLabTree    -Ctx $Source.Ctx -Path 'data'
            $getter  = { param($p) Get-GitLabFileRaw -Ctx $Source.Ctx -Path $p }
        } else {
            $tree    = Get-GitHubTree    -Ctx $Source.Ctx -Path 'data'
            $getter  = { param($p) Get-GitHubFileRaw -Ctx $Source.Ctx -Path $p }
        }
        foreach ($item in $tree) {
            if ($item.type -ne 'blob') { continue }
            if (-not $item.path.EndsWith('.json')) { continue }
            try {
                $raw = & $getter $item.path
                $doc = $raw | ConvertFrom-Json
                foreach ($e in @($doc.entries)) {
                    $row = [ordered]@{ member_id = $doc.member_id }
                    foreach ($p in $e.PSObject.Properties) { $row[$p.Name] = $p.Value }
                    $results.Add([pscustomobject]$row)
                }
            } catch { Write-Warning "skip $($item.path): $_" }
        }
    }
    return ,$results.ToArray()
}
