# Config.Tests.ps1 — log_dir フィールドの補完・保存・読込テスト

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
}

Describe 'New-DefaultConfig' -Tag 'unit','config' {
    It 'log_dir フィールドが空文字で存在する' {
        $cfg = New-DefaultConfig
        $cfg.PSObject.Properties.Name | Should -Contain 'log_dir'
        $cfg.log_dir | Should -Be ''
    }
}

Describe 'Load-Config: log_dir 補完' -Tag 'unit','config' {
    It '既存 config.json に log_dir がない場合 空文字で補完される' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            # log_dir を含まない旧形式の config を書く
            '{"mode":"local","member_id":"E001","local_store":"C:\\tmp\\store","branch":"main","gitlab_url":"","project_id":""}' |
                Set-Content -LiteralPath $cfgPath -Encoding UTF8

            # Get-ConfigPath を一時パスに差し替えるためスコープを操作する
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = Load-Config
                $cfg.log_dir | Should -Be ''
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Save-Config / Load-Config: log_dir ラウンドトリップ' -Tag 'unit','config' {
    It 'log_dir を保存して読み戻せる' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = New-DefaultConfig
                $cfg.log_dir = 'C:\logs\worktime'
                Save-Config -Config $cfg
                $loaded = Load-Config
                $loaded.log_dir | Should -Be 'C:\logs\worktime'
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'log_dir が空文字のとき保存・読込後も空文字' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = New-DefaultConfig
                $cfg.log_dir = ''
                Save-Config -Config $cfg
                $loaded = Load-Config
                $loaded.log_dir | Should -Be ''
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
