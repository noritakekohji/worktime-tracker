# ExcelImport.Tests.ps1 - Excel import conversion tests

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'scripts/import-excel-workentries.ps1')
}

Describe 'Excel取込 JSON 変換' -Tag 'unit','import' {
    It '日本語ヘッダーを標準フィールドに解決する' {
        $headers = @('日付','案件コード','工程コード','タスクグループコード','タスクコード','カテゴリ','工数','コメント')
        $map = Resolve-ImportColumnMap -Headers $headers
        $map['date'] | Should -Be 0
        $map['project_code'] | Should -Be 1
        $map['hours'] | Should -Be 6
    }

    It '1人分の行を月次JSONエントリに変換する' {
        $headers = @('日付','案件コード','工程コード','タスクグループコード','タスクコード','カテゴリ','工数','コメント')
        $map = Resolve-ImportColumnMap -Headers $headers
        $rows = @(
            [pscustomobject]@{ RowNumber = 2; Values = @('2026/06/01','ABC001','DSN','DB','ERD','DESIGN','3.5','ER図') },
            [pscustomobject]@{ RowNumber = 3; Values = @('2026/06/02','ABC001','IMP','BE','API','DEV','4','API実装') }
        )
        $result = ConvertTo-WorkEntryImportResult -Rows $rows -ColumnMap $map -Year 2026 -Month 6 -DefaultMemberId 'E001' -SourceName 'E001.xlsx'

        $result.Errors.Count | Should -Be 0
        $result.Members[0] | Should -Be 'E001'
        $result.Entries.Count | Should -Be 2
        $result.Entries[0].date | Should -Be '2026-06-01'
        [double]$result.Entries[0].hours | Should -Be 3.5
    }

    It '対象年月外の日付をエラーにする' {
        $headers = @('日付','工数')
        $map = Resolve-ImportColumnMap -Headers $headers
        $rows = @([pscustomobject]@{ RowNumber = 2; Values = @('2026/07/01','1') })
        $result = ConvertTo-WorkEntryImportResult -Rows $rows -ColumnMap $map -Year 2026 -Month 6 -DefaultMemberId 'E001' -SourceName 'E001.xlsx'

        $result.Errors.Count | Should -Be 1
        $result.Errors[0] | Should -Match '対象年月外'
    }

    It '既存JSONは Force なしでは上書きしない' {
        $tmp = Join-Path $env:TEMP ("worktime-import-test-" + (Get-Random))
        try {
            $entries = @([pscustomobject]@{ date='2026-06-01'; project_code='P1'; process_code=''; task_group_code=''; task_code=''; alias=''; category=''; is_leave=$false; hours=1.0; comment='' })
            $path = Write-WorkEntryMonthJson -OutputRoot $tmp -MemberId 'E001' -Year 2026 -Month 6 -Entries $entries
            Test-Path -LiteralPath $path | Should -Be $true
            { Write-WorkEntryMonthJson -OutputRoot $tmp -MemberId 'E001' -Year 2026 -Month 6 -Entries $entries } |
                Should -Throw '*既に存在*'
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        }
    }
}
