# DataStore.Tests.ps1 — マスタ・月次エントリのラウンドトリップ

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')

    function New-TempDataSource {
        $tmp = Join-Path $env:TEMP ("worktime-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $cfg = [pscustomobject]@{ mode='local'; member_id='ut'; local_store=$tmp }
        $src = New-DataSource -Config $cfg
        return [pscustomobject]@{ Source=$src; Dir=$tmp }
    }

    function Remove-TempDataSource {
        param($Ctx)
        if ($Ctx -and $Ctx.Dir) { Remove-Item -LiteralPath $Ctx.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'DataStore マスタ I/O' -Tag 'lib','integration' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It 'Members: 書込→読込で同一データ' {
        $data = @(
            [pscustomobject]@{ id='E001'; name='山田太郎'; active=$true; role='admin' },
            [pscustomobject]@{ id='E002'; name='佐藤花子'; active=$true; role='member' }
        )
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        $loaded.Count | Should -Be 2
        $loaded[0].name | Should -Be '山田太郎'
        [string]$loaded[1].role | Should -Be 'member'
    }

    It 'Holidays: 書込→読込で同一データ' {
        $data = @(
            [pscustomobject]@{ date='2026-01-01'; name='元日' },
            [pscustomobject]@{ date='2026-12-30'; name='年末休' }
        )
        Save-MasterHolidays -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Get-MasterHolidays -Source $script:ctx.Source)
        $loaded.Count | Should -Be 2
        [string]$loaded[0].date | Should -Be '2026-01-01'
        [string]$loaded[1].name | Should -Be '年末休'
    }

    It '空配列を保存しても読込時にエラーにならない' {
        Save-MasterCategories -Source $script:ctx.Source -Data @() -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Get-MasterCategories -Source $script:ctx.Source)
        $loaded.Count | Should -Be 0
    }

    It 'マスタが未保存の場合は空配列を返す' {
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        $loaded.Count | Should -Be 0
    }
}

Describe 'DataStore 月次エントリ I/O' -Tag 'lib','integration' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It '1 件のエントリのラウンドトリップ' {
        $entries = @(
            [pscustomobject]@{
                date='2026-05-01'; project_code='P1'; process_code='PR1'
                task_group_code='TG1'; task_code='T1'; category='C1'
                hours=4.0; comment='テスト'
            }
        )
        Save-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 5 `
            -Entries $entries -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Load-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 5)
        $loaded.Count | Should -Be 1
        [double]$loaded[0].hours | Should -Be 4.0
        [string]$loaded[0].comment | Should -Be 'テスト'
    }

    It '複数件 + 別月の独立性' {
        $may = @(
            [pscustomobject]@{ date='2026-05-01'; project_code='P1'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category=''; hours=2.0; comment='' },
            [pscustomobject]@{ date='2026-05-15'; project_code='P2'; process_code='PR2'; task_group_code='TG2'; task_code='T2'; category=''; hours=3.5; comment='' }
        )
        $jun = @(
            [pscustomobject]@{ date='2026-06-01'; project_code='P1'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category=''; hours=1.0; comment='' }
        )
        Save-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 5 -Entries $may -AuthorName 'ut' -AuthorEmail 'ut@local'
        Save-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 6 -Entries $jun -AuthorName 'ut' -AuthorEmail 'ut@local'

        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 5)).Count | Should -Be 2
        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 6)).Count | Should -Be 1
    }

    It '別メンバーのファイルは混ざらない' {
        $aliceE = @([pscustomobject]@{ date='2026-05-01'; project_code='P1'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category=''; hours=2.0; comment='' })
        $bobE   = @([pscustomobject]@{ date='2026-05-01'; project_code='P1'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category=''; hours=5.0; comment='' })
        Save-MonthEntries -Source $script:ctx.Source -MemberId 'alice' -Year 2026 -Month 5 -Entries $aliceE -AuthorName 'ut' -AuthorEmail 'ut@local'
        Save-MonthEntries -Source $script:ctx.Source -MemberId 'bob'   -Year 2026 -Month 5 -Entries $bobE   -AuthorName 'ut' -AuthorEmail 'ut@local'
        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'alice' -Year 2026 -Month 5))[0].hours | Should -Be 2.0
        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'bob'   -Year 2026 -Month 5))[0].hours | Should -Be 5.0
    }

    It 'Save-EntriesGrouped: 月毎に分割保存' {
        $mixed = @(
            [pscustomobject]@{ date='2026-04-30'; project_code='P1'; process_code=''; task_group_code=''; task_code=''; category=''; hours=1.0; comment='' },
            [pscustomobject]@{ date='2026-05-01'; project_code='P1'; process_code=''; task_group_code=''; task_code=''; category=''; hours=2.0; comment='' },
            [pscustomobject]@{ date='2026-05-15'; project_code='P1'; process_code=''; task_group_code=''; task_code=''; category=''; hours=3.0; comment='' }
        )
        # ViewYear/ViewMonth は表示中の月。指定月以外のエントリは date から判定して書き分け
        Save-EntriesGrouped -Source $script:ctx.Source -MemberId 'ut' -AllEntries $mixed `
            -ViewYear 2026 -ViewMonth 5 -AuthorName 'ut' -AuthorEmail 'ut@local'
        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 4)).Count | Should -Be 1
        (@(Load-MonthEntries -Source $script:ctx.Source -MemberId 'ut' -Year 2026 -Month 5)).Count | Should -Be 2
    }
}

Describe 'Get/Set-DataFile (生 I/O)' -Tag 'lib' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It '存在しないパスは null を返す' {
        Get-DataFile -Source $script:ctx.Source -RelPath 'nonexistent/foo.json' | Should -BeNullOrEmpty
    }

    It '書込→読込で UTF-8 BOM なしのまま保持' {
        Set-DataFile -Source $script:ctx.Source -RelPath 'test/foo.txt' -Content 'こんにちは世界'
        Get-DataFile -Source $script:ctx.Source -RelPath 'test/foo.txt' | Should -Be 'こんにちは世界'
        # BOM が付いていないことを生バイトで検証
        $p = Join-Path $script:ctx.Source.LocalRoot 'test/foo.txt'
        $b = [System.IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -Be $false
    }
}
