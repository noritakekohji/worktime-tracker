# Date.Tests.ps1 — 日付正規化ロジックの単体テスト
#
# WbsInput / AdminDialog の CellEditEnding 内で行っている yyyy-MM-dd 正規化を
# 再現してエッジケースを網羅検証する。

BeforeAll {
    # 注: パラメータ名は $Input を避ける (PS 自動変数と衝突)
    function Convert-ToYyyyMmDd {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
        $t = $Value.Trim()
        if ($t -match '^(\d{4})(\d{2})(\d{2})$') {
            return "$($matches[1])-$($matches[2])-$($matches[3])"
        }
        $d = [DateTime]::MinValue
        if ([DateTime]::TryParse($t, [ref]$d)) {
            return $d.ToString('yyyy-MM-dd')
        }
        return $Value
    }
}

Describe 'Convert-ToYyyyMmDd' -Tag 'unit' {

    Context '8桁数字 yyyyMMdd' {
        It '<InputValue> → <Expected>' -TestCases @(
            @{ InputValue='20260101'; Expected='2026-01-01' }
            @{ InputValue='19270311'; Expected='1927-03-11' }
            @{ InputValue='20991231'; Expected='2099-12-31' }
        ) {
            Convert-ToYyyyMmDd $InputValue | Should -Be $Expected
        }
    }

    Context '区切り入り (ゼロ詰めなし)' {
        It '<InputValue> → <Expected>' -TestCases @(
            @{ InputValue='2026-5-1';   Expected='2026-05-01' }
            @{ InputValue='2026/5/1';   Expected='2026-05-01' }
            @{ InputValue='2026-12-30'; Expected='2026-12-30' }
            @{ InputValue='2026/12/30'; Expected='2026-12-30' }
        ) {
            Convert-ToYyyyMmDd $InputValue | Should -Be $Expected
        }
    }

    Context '空白・空文字' {
        It '空文字はそのまま空文字' {
            Convert-ToYyyyMmDd '' | Should -BeExactly ''
        }
        It '空白のみは空文字' {
            Convert-ToYyyyMmDd '   ' | Should -BeExactly ''
        }
        It '前後空白はトリム' {
            Convert-ToYyyyMmDd '  2026-5-1  ' | Should -Be '2026-05-01'
        }
    }

    Context '無効な入力は変換しない' {
        It '<InputValue> → <Expected>' -TestCases @(
            @{ InputValue='abc';            Expected='abc' }
            @{ InputValue='2026-99-99';     Expected='2026-99-99' }
            @{ InputValue='12345678901';    Expected='12345678901' }
            @{ InputValue='hello world';    Expected='hello world' }
        ) {
            Convert-ToYyyyMmDd $InputValue | Should -Be $Expected
        }
    }
}
