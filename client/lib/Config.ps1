# Config.ps1 — クライアント設定 (%APPDATA%\worktime-tracker\config.json)

. (Join-Path $PSScriptRoot 'Credential.ps1')

function Get-ConfigPath {
    return Join-Path (Get-AppDataDir) 'config.json'
}

function New-DefaultConfig {
    return [pscustomobject]@{
        mode         = 'gitlab'   # 'gitlab' | 'local'
        gitlab_url   = 'https://gitlab.example.com'
        project_id   = ''         # GitLab プロジェクト ID または "group/project" の URL エンコード
        branch       = 'main'
        member_id    = ''
        local_root   = ''         # mode=local 時のリポジトリルート (開発用)
    }
}

function Load-Config {
    $p = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $p)) { return New-DefaultConfig }
    try {
        $cfg = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        # 不足プロパティを補完
        $def = New-DefaultConfig
        foreach ($prop in $def.PSObject.Properties.Name) {
            if (-not $cfg.PSObject.Properties.Name.Contains($prop)) {
                $cfg | Add-Member -NotePropertyName $prop -NotePropertyValue $def.$prop
            }
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
    if ($Config.mode -eq 'gitlab') {
        if (-not $Config.gitlab_url -or -not $Config.project_id) { return $false }
        if (-not (Test-GitLabTokenStored)) { return $false }
    } elseif ($Config.mode -eq 'local') {
        if (-not $Config.local_root -or -not (Test-Path -LiteralPath $Config.local_root)) { return $false }
    }
    return $true
}
