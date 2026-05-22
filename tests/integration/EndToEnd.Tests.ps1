# EndToEnd.Tests.ps1 — マスタ・エントリ・プランをまたぐ統合テスト

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Bootstrap.ps1')
}

Describe 'マスタ + エントリの統合シナリオ' -Tag 'integration' {

    BeforeEach {
        $script:tmpDir = Join-Path $env:TEMP ("worktime-e2e-" + (Get-Random))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $cfg = [pscustomobject]@{ mode='local'; member_id='alice'; local_store=$script:tmpDir }
        $script:src = New-DataSource -Config $cfg

        # 共通マスタ
        Save-MasterMembers -Source $script:src -Data @(
            [pscustomobject]@{ id='alice'; name='Alice Smith'; active=$true; role='admin' },
            [pscustomobject]@{ id='bob';   name='Bob Tanaka';  active=$true; role='member' }
        ) -AuthorName 'init' -AuthorEmail 'init@local'

        Save-MasterProjects -Source $script:src -Data @(
            [pscustomobject]@{ unit_code='P001'; project_name='プロジェクトA'; active=$true; task_pattern_id='PTN1' }
        ) -AuthorName 'init' -AuthorEmail 'init@local'

        Save-MasterCategories -Source $script:src -Data @(
            [pscustomobject]@{ code='DEV';  name='開発' },
            [pscustomobject]@{ code='TEST'; name='テスト' }
        ) -AuthorName 'init' -AuthorEmail 'init@local'

        Save-MasterHolidays -Source $script:src -Data @(
            [pscustomobject]@{ date='2026-05-04'; name='みどりの日' },
            [pscustomobject]@{ date='2026-05-05'; name='こどもの日' }
        ) -AuthorName 'init' -AuthorEmail 'init@local'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Bootstrap で全マスタが読み込める' {
        # Initialize-DataContext を Mock で再現 (Load-Config を上書き)
        Mock Load-Config { [pscustomobject]@{ mode='local'; member_id='alice'; local_store=$script:tmpDir } }
        Mock Test-ConfigComplete { $true }
        $ctx = Initialize-DataContext -AppName 'E2E'
        $ctx                | Should -Not -BeNullOrEmpty
        $ctx.Members.Count  | Should -Be 2
        $ctx.Projects.Count | Should -Be 1
        $ctx.Categories.Count | Should -Be 2
        $ctx.Holidays.Count | Should -Be 2
        $ctx.CurrentMember  | Should -Not -BeNullOrEmpty
        [string]$ctx.CurrentMember.id | Should -Be 'alice'
    }

    It '複数月のエントリを保存・読込' {
        $entries = @(
            [pscustomobject]@{ date='2026-05-01'; project_code='P001'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category='DEV';  hours=4.0; comment='' },
            [pscustomobject]@{ date='2026-05-02'; project_code='P001'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category='TEST'; hours=2.0; comment='' },
            [pscustomobject]@{ date='2026-06-01'; project_code='P001'; process_code='PR1'; task_group_code='TG1'; task_code='T2'; category='DEV';  hours=5.0; comment='' }
        )
        Save-EntriesGrouped -Source $script:src -MemberId 'alice' -AllEntries $entries `
            -ViewYear 2026 -ViewMonth 5 -AuthorName 'alice' -AuthorEmail 'a@local'

        $may = @(Load-MonthEntries -Source $script:src -MemberId 'alice' -Year 2026 -Month 5)
        $jun = @(Load-MonthEntries -Source $script:src -MemberId 'alice' -Year 2026 -Month 6)
        $may.Count | Should -Be 2
        $jun.Count | Should -Be 1
    }

    It '別メンバーの保存が他人のファイルに影響しない' {
        Save-MonthEntries -Source $script:src -MemberId 'alice' -Year 2026 -Month 5 `
            -Entries @([pscustomobject]@{ date='2026-05-01'; project_code='P001'; process_code=''; task_group_code=''; task_code=''; category=''; hours=8.0; comment='' }) `
            -AuthorName 'alice' -AuthorEmail 'a@local'
        Save-MonthEntries -Source $script:src -MemberId 'bob' -Year 2026 -Month 5 `
            -Entries @([pscustomobject]@{ date='2026-05-01'; project_code='P001'; process_code=''; task_group_code=''; task_code=''; category=''; hours=3.0; comment='' }) `
            -AuthorName 'bob' -AuthorEmail 'b@local'
        # ファイルが別パスに作られていることを確認
        (Test-Path (Join-Path $script:tmpDir 'data/2026/05/alice.json')) | Should -Be $true
        (Test-Path (Join-Path $script:tmpDir 'data/2026/05/bob.json'))   | Should -Be $true
    }
}
