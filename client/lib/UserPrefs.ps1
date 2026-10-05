# UserPrefs.ps1 — 個人設定 (%APPDATA%\worktime-tracker\user_prefs.json)
#
# member_id ごとにキーを持つマップ構造:
#   {
#     "E1001": {
#       "favorite_projects": ["ABC001"],
#       "unit_defaults": {
#         "ABC001": { "process_code": "DSN", "task_group_code": "DB", "task_code": "ERD",
#                     "category": "DESIGN", "hours": 2.0, "comment": "" }
#       },
#       "recent_combo_count": 5
#     },
#     ...
#   }
#
# unit_defaults はユニットコードを選んだときに日次入力フォームへ自動で入れる値
# (ユニットごとに 1 つ)。読込時は Hashtable (code → Hashtable) に正規化する。

. (Join-Path $PSScriptRoot 'Credential.ps1')

function Get-UserPrefsPath {
    return Join-Path (Get-AppDataDir) 'user_prefs.json'
}

function Load-UserPrefsAll {
    $p = Get-UserPrefsPath
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        # PSCustomObject → Hashtable
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $entry = @{}
            foreach ($q in $p.Value.PSObject.Properties) {
                $entry[$q.Name] = $q.Value
            }
            $h[$p.Name] = $entry
        }
        return $h
    } catch {
        Write-Warning "user_prefs.json 読込失敗: $_"
        return @{}
    }
}

function Save-UserPrefsAll {
    param([Parameter(Mandatory)][hashtable]$All)
    $json = $All | ConvertTo-Json -Depth 10
    if ([string]::IsNullOrWhiteSpace($json)) { $json = '{}' }
    Set-Content -LiteralPath (Get-UserPrefsPath) -Value $json -Encoding UTF8
}

function Get-UserPrefs {
    # 指定 MemberId の個人設定を取得。なければ空デフォルト
    param([Parameter(Mandatory)][string]$MemberId)
    $all = Load-UserPrefsAll
    $p = if ($all.ContainsKey($MemberId)) { $all[$MemberId] } else { @{} }
    if (-not $p.ContainsKey('favorite_projects')) { $p['favorite_projects'] = @() }
    $p['favorite_projects'] = [string[]]@(@($p['favorite_projects']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $p['unit_defaults'] = _ToUnitDefaultsTable $p['unit_defaults']
    $p['recent_combo_count'] = _NormalizeRecentComboCount $p['recent_combo_count']
    return $p
}

# 日次入力「最近の組み合わせ」の表示件数。0 = 非表示
$Script:RecentComboCountDefault = 5
$Script:RecentComboCountMax     = 10

function _NormalizeRecentComboCount {
    param($Value)
    $n = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$n)) { return $Script:RecentComboCountDefault }
    return [Math]::Max(0, [Math]::Min($Script:RecentComboCountMax, $n))
}

function Get-RecentComboCount {
    param([Parameter(Mandatory)][string]$MemberId)
    return [int](Get-UserPrefs -MemberId $MemberId)['recent_combo_count']
}

function Set-RecentComboCount {
    param([Parameter(Mandatory)][string]$MemberId, [Parameter(Mandatory)][int]$Count)
    $prefs = Get-UserPrefs -MemberId $MemberId
    $prefs['recent_combo_count'] = _NormalizeRecentComboCount $Count
    Set-UserPrefs -MemberId $MemberId -Prefs $prefs
}

function _ToUnitDefaultsTable {
    # JSON 由来の PSCustomObject / 既に Hashtable のどちらでも code → Hashtable に揃える
    param($Value)
    $h = @{}
    if ($null -eq $Value) { return $h }
    $pairs = if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { [pscustomobject]@{ Name = [string]$k; Value = $Value[$k] } }
    } else {
        $Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }
    }
    foreach ($pr in @($pairs)) {
        if (-not $pr.Name -or $null -eq $pr.Value) { continue }
        $d = @{}
        if ($pr.Value -is [System.Collections.IDictionary]) {
            foreach ($k in $pr.Value.Keys) { $d[[string]$k] = $pr.Value[$k] }
        } else {
            foreach ($q in $pr.Value.PSObject.Properties) { $d[$q.Name] = $q.Value }
        }
        $h[[string]$pr.Name] = $d
    }
    return $h
}

function Get-UnitDefault {
    # 指定ユニットのデフォルト (Hashtable)。未登録なら $null
    param([Parameter(Mandatory)][string]$MemberId, [string]$UnitCode)
    if (-not $UnitCode) { return $null }
    $defs = (Get-UserPrefs -MemberId $MemberId)['unit_defaults']
    if ($defs.ContainsKey($UnitCode)) { return $defs[$UnitCode] }
    return $null
}

function Get-UnitDefaultCodes {
    param([Parameter(Mandatory)][string]$MemberId)
    $codes = [string[]]@((Get-UserPrefs -MemberId $MemberId)['unit_defaults'].Keys | Sort-Object)
    return ,$codes
}

function Set-UnitDefault {
    # 既存の他キー (favorite_projects 等) は温存してテンプレートだけ差し替える
    param(
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][string]$UnitCode,
        [Parameter(Mandatory)][hashtable]$Default
    )
    $prefs = Get-UserPrefs -MemberId $MemberId
    $hours = 0.0
    [void][double]::TryParse([string]$Default['hours'], [ref]$hours)
    $prefs['unit_defaults'][$UnitCode] = [ordered]@{
        process_code    = [string]$Default['process_code']
        task_group_code = [string]$Default['task_group_code']
        task_code       = [string]$Default['task_code']
        category        = [string]$Default['category']
        hours           = $hours
        comment         = [string]$Default['comment']
    }
    Set-UserPrefs -MemberId $MemberId -Prefs $prefs
}

function Remove-UnitDefault {
    param([Parameter(Mandatory)][string]$MemberId, [Parameter(Mandatory)][string]$UnitCode)
    $prefs = Get-UserPrefs -MemberId $MemberId
    if (-not $prefs['unit_defaults'].ContainsKey($UnitCode)) { return }
    $prefs['unit_defaults'].Remove($UnitCode)
    Set-UserPrefs -MemberId $MemberId -Prefs $prefs
}

function Set-FavoriteProject {
    param(
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][string]$UnitCode,
        [Parameter(Mandatory)][bool]$IsFavorite
    )
    $prefs = Get-UserPrefs -MemberId $MemberId
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in $prefs['favorite_projects']) { if ($c -ne $UnitCode) { $list.Add($c) } }
    if ($IsFavorite) { $list.Add($UnitCode) }
    $prefs['favorite_projects'] = $list.ToArray()
    Set-UserPrefs -MemberId $MemberId -Prefs $prefs
}

function Set-UserPrefs {
    param([Parameter(Mandatory)][string]$MemberId, [Parameter(Mandatory)][hashtable]$Prefs)
    $all = Load-UserPrefsAll
    $all[$MemberId] = $Prefs
    Save-UserPrefsAll -All $all
}
