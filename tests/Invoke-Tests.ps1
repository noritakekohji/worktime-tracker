# Invoke-Tests.ps1 — Pester 5 によるテスト実行ランナー
#
# - Pester 5 が無ければ CurrentUser スコープに自動インストール (-SkipPublisherCheck)
# - tests/ 配下の *.Tests.ps1 を全実行
# - 結果を tests/results/TestResults.xml (NUnit) と Coverage に出力
#
# 起動: powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
#       または tests\run-tests.cmd

[CmdletBinding()]
param(
    [string[]]$Tag,                    # -Tag unit,integration 等で絞り込み
    [switch]$NoInstall,                # Pester の自動インストールを抑止
    [switch]$Coverage                  # コードカバレッジを取得
)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$repo    = Split-Path $here -Parent
$results = Join-Path $here 'results'
if (-not (Test-Path -LiteralPath $results)) { New-Item -ItemType Directory -Path $results -Force | Out-Null }

# ---- Pester 5 が無ければインストール ----
$existing = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if (-not $existing) {
    if ($NoInstall) {
        Write-Host "Pester 5 が見つかりません。-NoInstall 指定のため終了します。" -ForegroundColor Red
        Write-Host "Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck で導入してください。" -ForegroundColor Yellow
        exit 2
    }
    Write-Host "Pester 5 をインストール中... (CurrentUser スコープ)" -ForegroundColor Yellow
    try {
        # PSGallery を Trust 化 (社内 proxy 経由でも動くようにオプション複数)
        $null = Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction SilentlyContinue
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
    } catch {
        Write-Host "Pester インストール失敗: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "インターネット接続/プロキシ設定を確認してください。" -ForegroundColor Yellow
        exit 2
    }
}

# ---- Import Pester ----
Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 5.0.0 -Force
$pesterVer = (Get-Module Pester).Version
Write-Host ("Pester {0} を使用" -f $pesterVer) -ForegroundColor Cyan

# ---- Pester 設定 ----
$config = New-PesterConfiguration
$config.Run.Path        = $here
$config.Run.PassThru    = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled      = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath   = Join-Path $results 'TestResults.xml'

if ($Tag) { $config.Filter.Tag = $Tag }

if ($Coverage) {
    $config.CodeCoverage.Enabled       = $true
    $config.CodeCoverage.Path          = @(
        (Join-Path $repo 'client/lib/*.ps1'),
        (Join-Path $repo 'client/WbsInput.ps1'),
        (Join-Path $repo 'client/WorkTimeTracker.ps1'),
        (Join-Path $repo 'reports/ReportViewer.ps1')
    )
    $config.CodeCoverage.OutputPath    = Join-Path $results 'Coverage.xml'
    $config.CodeCoverage.OutputFormat  = 'JaCoCo'
}

# ---- 実行 ----
$result = Invoke-Pester -Configuration $config

# ---- サマリ ----
Write-Host ""
Write-Host ("結果 XML: {0}" -f $config.TestResult.OutputPath.Value) -ForegroundColor DarkGray
if ($Coverage) {
    Write-Host ("カバレッジ XML: {0}" -f $config.CodeCoverage.OutputPath.Value) -ForegroundColor DarkGray
}

if ($result.FailedCount -gt 0) { exit 1 } else { exit 0 }
