# DataStore.ps1 — マスタ/実績データの読み書き
# mode = 'gitlab' なら GitLab REST API 経由 (git CLI 不要)
# mode = 'local'  ならローカルファイルシステム (開発・テスト用)

. (Join-Path $PSScriptRoot 'GitLab.ps1')

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

function Get-MonthRelPath {
    param(
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month
    )
    return ('data/{0:D4}/{1:D2}/{2}.json' -f $Year, $Month, $MemberId)
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
    if ($Config.mode -eq 'gitlab') {
        $ctx = New-GitLabContext -BaseUrl $Config.gitlab_url -ProjectId $Config.project_id `
                                 -Branch  $Config.branch     -Token     $Token
        return [pscustomobject]@{ Mode = 'gitlab'; Ctx = $ctx; Root = $null }
    } else {
        $root = $Config.local_root
        if (-not $root) { $root = Get-RepoRoot -StartPath $PSScriptRoot }
        return [pscustomobject]@{ Mode = 'local'; Ctx = $null; Root = $root }
    }
}

function Get-DataFile {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$RelPath)
    if ($Source.Mode -eq 'gitlab') {
        return Get-GitLabFileRaw -Ctx $Source.Ctx -Path $RelPath
    } else {
        $p = Join-Path $Source.Root $RelPath
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return Get-Content -LiteralPath $p -Raw -Encoding UTF8
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
    if ($Source.Mode -eq 'gitlab') {
        $null = Set-GitLabFile -Ctx $Source.Ctx -Path $RelPath -Content $Content `
                               -CommitMessage $CommitMessage -AuthorName $AuthorName -AuthorEmail $AuthorEmail
    } else {
        $p = Join-Path $Source.Root $RelPath
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $p -Value $Content -Encoding UTF8
    }
}

# ---- マスタ ----

function Get-MasterMembers    { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/members.json') }
function Get-MasterProjects   { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/projects.json') }
function Get-MasterCategories { param($Source) _ReadJsonString (Get-DataFile -Source $Source -RelPath 'master/categories.json') }

function Save-MasterMembers {
    param($Source, $Data, [string]$AuthorName, [string]$AuthorEmail)
    $json = $Data | ConvertTo-Json -Depth 10
    Set-DataFile -Source $Source -RelPath 'master/members.json' -Content $json `
                 -CommitMessage 'update master: members' -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}
function Save-MasterProjects {
    param($Source, $Data, [string]$AuthorName, [string]$AuthorEmail)
    $json = $Data | ConvertTo-Json -Depth 10
    Set-DataFile -Source $Source -RelPath 'master/projects.json' -Content $json `
                 -CommitMessage 'update master: projects' -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}
function Save-MasterCategories {
    param($Source, $Data, [string]$AuthorName, [string]$AuthorEmail)
    $json = $Data | ConvertTo-Json -Depth 10
    Set-DataFile -Source $Source -RelPath 'master/categories.json' -Content $json `
                 -CommitMessage 'update master: categories' -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}

# ---- 実績データ ----

function Load-MonthEntries {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month
    )
    $rel = Get-MonthRelPath -MemberId $MemberId -Year $Year -Month $Month
    $raw = Get-DataFile -Source $Source -RelPath $rel
    if (-not $raw) { return ,@() }
    $doc = $raw | ConvertFrom-Json
    if ($null -eq $doc.entries) { return ,@() }
    return ,@($doc.entries)
}

function Save-MonthEntries {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        [Parameter(Mandatory)][object[]]$Entries,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    $rel = Get-MonthRelPath -MemberId $MemberId -Year $Year -Month $Month
    $doc = [ordered]@{
        member_id = $MemberId
        year      = $Year
        month     = $Month
        entries   = @($Entries)
    }
    $json = $doc | ConvertTo-Json -Depth 10
    $msg = 'update: {0} {1:D4}-{2:D2}' -f $MemberId, $Year, $Month
    Set-DataFile -Source $Source -RelPath $rel -Content $json -CommitMessage $msg `
                 -AuthorName $AuthorName -AuthorEmail $AuthorEmail
}

function Save-EntriesGrouped {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][object[]]$AllEntries,
        [Parameter(Mandatory)][int]$ViewYear,
        [Parameter(Mandatory)][int]$ViewMonth,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
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

    foreach ($key in $groups.Keys) {
        $parts = $key.Split('-')
        $y = [int]$parts[0]
        $m = [int]$parts[1]
        $newForMonth = @($groups[$key])

        if ($key -eq $viewKey) {
            Save-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m `
                              -Entries $newForMonth -AuthorName $AuthorName -AuthorEmail $AuthorEmail
        } else {
            $existing = @(Load-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m)
            $merged = $existing + $newForMonth
            Save-MonthEntries -Source $Source -MemberId $MemberId -Year $y -Month $m `
                              -Entries $merged -AuthorName $AuthorName -AuthorEmail $AuthorEmail
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
        $tree = Get-GitLabTree -Ctx $Source.Ctx -Path 'data'
        foreach ($item in $tree) {
            if ($item.type -ne 'blob') { continue }
            if (-not $item.path.EndsWith('.json')) { continue }
            try {
                $raw = Get-GitLabFileRaw -Ctx $Source.Ctx -Path $item.path
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
