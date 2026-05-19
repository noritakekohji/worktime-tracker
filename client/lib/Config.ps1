# Config.ps1 — クライアント設定 (%APPDATA%\worktime-tracker\config.json)
#
# モード:
#   local            : ローカル保管のみ。リモート無し。
#   local+gitlab     : ローカル保管 + 送信ボタンで GitLab に push。
#   local+github     : ローカル保管 + 送信ボタンで GitHub に push。
#
# local_store: マスタ・実績の常用ストア (デフォルト %LOCALAPPDATA%\worktime-tracker\store)

. (Join-Path $PSScriptRoot 'Credential.ps1')

function Get-ConfigPath {
    return Join-Path (Get-AppDataDir) 'config.json'
}

function Get-DefaultLocalStore {
    return Join-Path $env:LOCALAPPDATA 'worktime-tracker\store'
}

function New-DefaultConfig {
    return [pscustomobject]@{
        mode         = 'local'                    # 'local' | 'gitlab' | 'github'
        gitlab_url   = 'https://gitlab.example.com'
        project_id   = ''                         # GitLab: 数値 ID または "group/project"
        github_repo  = ''                         # GitHub: "owner/repo"
        branch       = 'main'
        member_id    = ''
        local_store  = (Get-DefaultLocalStore)   # 常用ローカルストア (どのモードでも使用)
        local_root   = ''                         # (旧設定; 互換のため残置)
    }
}

function Load-Config {
    $p = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $p)) { return New-DefaultConfig }
    try {
        $cfg = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $def = New-DefaultConfig
        foreach ($prop in $def.PSObject.Properties.Name) {
            if (-not $cfg.PSObject.Properties.Name.Contains($prop)) {
                $cfg | Add-Member -NotePropertyName $prop -NotePropertyValue $def.$prop
            }
        }
        # local_store 空ならデフォルト埋め込み
        if ([string]::IsNullOrWhiteSpace($cfg.local_store)) {
            $cfg.local_store = Get-DefaultLocalStore
        }
        return $cfg
    } catch {
        Write-Warning "config.json 読込失敗、デフォルトを使用: $_"
        return New-DefaultConfig
    }
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $json = $Config | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Get-ConfigPath) -Value $json -Encoding UTF8
}

function Test-ConfigComplete {
    param([Parameter(Mandatory)]$Config)
    if (-not $Config.member_id) { return $false }
    if (-not $Config.local_store) { return $false }
    switch ($Config.mode) {
        'gitlab' {
            if (-not $Config.gitlab_url -or -not $Config.project_id) { return $false }
            if (-not (Test-GitLabTokenStored)) { return $false }
        }
        'github' {
            if (-not $Config.github_repo) { return $false }
            if (-not (Test-GitLabTokenStored)) { return $false }
        }
        'local' { }   # local_store チェックは上で済
    }
    return $true
}
