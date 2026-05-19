# UserPrefs.ps1 — 個人設定 (%APPDATA%\worktime-tracker\user_prefs.json)
#
# member_id ごとにキーを持つマップ構造:
#   {
#     "E1001": { "favorite_projects": ["ABC001"] },
#     ...
#   }

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
    if (-not $all.ContainsKey($MemberId)) {
        return @{ favorite_projects = @() }
    }
    $p = $all[$MemberId]
    if (-not $p.ContainsKey('favorite_projects')) { $p['favorite_projects'] = @() }
    return $p
}

function Set-UserPrefs {
    param([Parameter(Mandatory)][string]$MemberId, [Parameter(Mandatory)][hashtable]$Prefs)
    $all = Load-UserPrefsAll
    $all[$MemberId] = $Prefs
    Save-UserPrefsAll -All $all
}
