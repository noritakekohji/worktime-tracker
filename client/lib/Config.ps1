# Config.ps1 — クライアント設定 (%APPDATA%\worktime-tracker\config.json)
#
# モード:
#   local  : スタンドアローン (ローカル保管のみ)
#   gitlab : Gitlab モード (ローカル保管 + 送信ボタンで Gitlab に同期)

. (Join-Path $PSScriptRoot 'Credential.ps1')

function Get-ConfigPath {
    return Join-Path (Get-AppDataDir) 'config.json'
}

function Get-DefaultLocalStore {
    return Join-Path $env:LOCALAPPDATA 'worktime-tracker\store'
}

function New-DefaultConfig {
    return [pscustomobject]@{
        mode         = 'local'                    # 'local' | 'gitlab'
        gitlab_url   = 'https://gitlab.example.com'
        project_id   = ''
        branch       = 'main'
        member_id    = ''
        local_store  = (Get-DefaultLocalStore)
        local_root   = ''                         # (旧設定; 互換)
        log_dir      = ''                         # ログ出力先フォルダ (空文字 = 出力なし)
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
        if ([string]::IsNullOrWhiteSpace($cfg.local_store)) {
            $cfg.local_store = Get-DefaultLocalStore
        }
        # GitHub モードを使用していた場合は local に降格 (互換)
        if ($cfg.mode -ne 'local' -and $cfg.mode -ne 'gitlab') {
            $cfg.mode = 'local'
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
    if ($Config.mode -eq 'gitlab') {
        if (-not $Config.gitlab_url -or -not $Config.project_id) { return $false }
        if (-not (Test-GitLabTokenStored)) { return $false }
    }
    return $true
}
