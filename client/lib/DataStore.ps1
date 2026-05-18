# DataStore.ps1 — マスタ/実績データのファイル I/O

. (Join-Path $PSScriptRoot 'Yaml.ps1')

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
    throw "リポジトリルートが見つかりません (master/ と data/ が存在するディレクトリ)。"
}

function Get-MasterMembers {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Import-Yaml -Path (Join-Path $RepoRoot 'master/members.yaml')
}

function Get-MasterProjects {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Import-Yaml -Path (Join-Path $RepoRoot 'master/projects.yaml')
}

function Get-MasterCategories {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Import-Yaml -Path (Join-Path $RepoRoot 'master/categories.yaml')
}

function Get-MonthFilePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month
    )
    $mm = '{0:D2}' -f $Month
    return Join-Path $RepoRoot ("data/{0}/{1}/{2}.json" -f $Year, $mm, $MemberId)
}

function Load-MonthEntries {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month
    )
    $path = Get-MonthFilePath -RepoRoot $RepoRoot -MemberId $MemberId -Year $Year -Month $Month
    if (-not (Test-Path -LiteralPath $path)) {
        return ,@()
    }
    $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $doc.entries) { return ,@() }
    return ,@($doc.entries)
}

function Save-MonthEntries {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        [Parameter(Mandatory)][object[]]$Entries
    )
    $path = Get-MonthFilePath -RepoRoot $RepoRoot -MemberId $MemberId -Year $Year -Month $Month
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $doc = [ordered]@{
        member_id = $MemberId
        year      = $Year
        month     = $Month
        entries   = @($Entries)
    }
    $json = $doc | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

# 日付別エントリ配列を年月でグルーピングして月次ファイルにマージ保存
function Save-EntriesGrouped {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][object[]]$AllEntries  # 入力月用に表示中の全エントリ (置き換える)
        ,
        [Parameter(Mandatory)][int]$ViewYear,
        [Parameter(Mandatory)][int]$ViewMonth
    )
    # 表示中の月だけ「全置換」する。他月にバックデートで入ったエントリは別ファイルにマージ。
    $groups = @{}
    foreach ($e in $AllEntries) {
        $d = [datetime]::Parse($e.date)
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
            # 表示中月: 完全置換
            Save-MonthEntries -RepoRoot $RepoRoot -MemberId $MemberId -Year $y -Month $m -Entries $newForMonth
        } else {
            # 他月: 既存とマージ (同一エントリ重複は防がず、純追加)
            $existing = @(Load-MonthEntries -RepoRoot $RepoRoot -MemberId $MemberId -Year $y -Month $m)
            $merged = $existing + $newForMonth
            Save-MonthEntries -RepoRoot $RepoRoot -MemberId $MemberId -Year $y -Month $m -Entries $merged
        }
    }

    # 表示月にエントリ 0 件 (全削除) の場合も空で保存
    if (-not $groups.ContainsKey($viewKey)) {
        Save-MonthEntries -RepoRoot $RepoRoot -MemberId $MemberId -Year $ViewYear -Month $ViewMonth -Entries @()
    }
}
