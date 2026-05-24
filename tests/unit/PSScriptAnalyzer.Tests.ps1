# PSScriptAnalyzer.Tests.ps1 — 静的解析で真のバグを検出
#
# tests/PSScriptAnalyzerSettings.psd1 で許可した高シグナルルールに違反していないか
# 全 .ps1 (client/reports/scripts) を検査する。
# CI でも Pester 経由で走るので、push 毎に自動チェックが効く。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:Settings = Join-Path $script:RepoRoot 'tests/PSScriptAnalyzerSettings.psd1'

    # PSScriptAnalyzer をユーザスコープに自動インストール (Pester と同じ流儀)
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        try {
            Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
        } catch {
            Write-Warning "PSScriptAnalyzer の自動インストールに失敗: $_"
        }
    }
    Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
}

Describe 'PSScriptAnalyzer (静的解析)' -Tag 'unit','lint' {

    BeforeAll {
        $script:HasAnalyzer = $null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)
    }

    It 'PSScriptAnalyzer がロード済み' {
        $script:HasAnalyzer | Should -Be $true -Because 'Install-Module PSScriptAnalyzer -Scope CurrentUser を実行してください'
    }

    It '<file> に高シグナル違反がない' -TestCases @(
        $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
        $files = @()
        $files += Get-ChildItem (Join-Path $repoRoot 'client')  -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem (Join-Path $repoRoot 'reports') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files | ForEach-Object { @{ file = $_; rel = ($_ -replace [regex]::Escape($repoRoot + '\'), '') } }
    ) {
        param($file, $rel)
        if (-not $script:HasAnalyzer) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer 未導入'
            return
        }
        $findings = @(Invoke-ScriptAnalyzer -Path $file -Settings $script:Settings)
        if ($findings.Count -gt 0) {
            $msg = ($findings | ForEach-Object { "  [{0}] line {1}: {2}" -f $_.RuleName, $_.Line, $_.Message }) -join "`n"
            $findings.Count | Should -Be 0 -Because ("`n${rel}:`n$msg")
        }
    }
}
