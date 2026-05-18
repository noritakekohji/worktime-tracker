# YAML 読込ヘルパ (powershell-yaml モジュール利用)

function Initialize-YamlModule {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "powershell-yaml モジュールをインストールします..." -ForegroundColor Yellow
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module powershell-yaml -ErrorAction Stop
}

function Import-Yaml {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "YAML ファイルが見つかりません: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ConvertFrom-Yaml -Yaml $text
}
