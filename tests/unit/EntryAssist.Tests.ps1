# EntryAssist.Tests.ps1 — 日次入力の補助ロジック
#   - 直前の入力日の実績 (一括コピー元)
#   - 最近使った組み合わせ
#   - 当月の未入力平日
#   - プロジェクト候補の部分一致絞り込み
#
# 関数は `return ,$arr` で配列を返すため、呼出側で @() に包むと二重ラップになる (包まない)

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/EntryAssist.ps1')

    function New-E {
        param($Date, $Proj = 'ABC001', $Proc = 'DSN', $Tg = 'DB', $Task = 'ERD', $Cat = 'DESIGN', $Hours = 1.0, [switch]$Leave)
        [pscustomobject]@{
            date = $Date; project_code = $Proj; process_code = $Proc; task_group_code = $Tg
            task_code = $Task; category = $Cat; hours = $Hours; is_leave = [bool]$Leave; comment = ''
        }
    }
}

Describe 'Find-PreviousWorkDayEntries' -Tag 'unit' {
    It '指定日より前で最も新しい作業日の行をすべて返す' {
        $entries = @(
            (New-E '2026-10-01' -Proj 'A'),
            (New-E '2026-10-02' -Proj 'B'),
            (New-E '2026-10-02' -Proj 'C'),
            (New-E '2026-10-05' -Proj 'D')
        )
        $r = Find-PreviousWorkDayEntries -Entries $entries -Date ([datetime]'2026-10-05')
        @($r | ForEach-Object { $_.project_code }) | Should -Be @('B', 'C')
    }

    It '休暇だけの日は飛ばし、休暇行は含めない' {
        $entries = @(
            (New-E '2026-10-01' -Proj 'A'),
            (New-E '2026-10-02' -Proj '' -Leave)
        )
        $r = Find-PreviousWorkDayEntries -Entries $entries -Date ([datetime]'2026-10-05')
        @($r).Count | Should -Be 1
        $r[0].project_code | Should -Be 'A'
    }

    It '該当が 1 件でも配列で返る / 無ければ空配列' {
        $one = Find-PreviousWorkDayEntries -Entries @((New-E '2026-10-01')) -Date ([datetime]'2026-10-02')
        ,$one | Should -BeOfType [array]
        $none = Find-PreviousWorkDayEntries -Entries @((New-E '2026-10-03')) -Date ([datetime]'2026-10-02')
        @($none).Count | Should -Be 0
    }
}

Describe 'Get-RecentEntryCombos' -Tag 'unit' {
    It '新しい日付順・重複なし・上限件数まで' {
        $entries = @(
            (New-E '2026-10-01' -Proj 'A'),
            (New-E '2026-10-03' -Proj 'B'),
            (New-E '2026-10-02' -Proj 'A'),
            (New-E '2026-10-04' -Proj 'C'),
            (New-E '2026-10-04' -Proj '' -Leave)
        )
        $r = Get-RecentEntryCombos -Entries $entries -Max 2
        @($r | ForEach-Object { $_.project_code }) | Should -Be @('C', 'B')
    }

    It '工数は同じ組み合わせの中で最も新しい行の値' {
        $entries = @(
            (New-E '2026-10-01' -Proj 'A' -Hours 2.0),
            (New-E '2026-10-03' -Proj 'A' -Hours 3.5),
            (New-E '2026-10-02' -Proj 'A' -Hours 1.0)
        )
        $r = Get-RecentEntryCombos -Entries $entries -Max 5
        $r.Count | Should -Be 1
        $r[0].hours | Should -Be 3.5
    }

    It '工程やカテゴリが違えば別の組み合わせ' {
        $entries = @(
            (New-E '2026-10-01' -Cat 'DESIGN'),
            (New-E '2026-10-02' -Cat 'REVIEW')
        )
        (Get-RecentEntryCombos -Entries $entries -Max 5).Count | Should -Be 2
    }

    It '1 件でも配列で返る' {
        $r = Get-RecentEntryCombos -Entries @((New-E '2026-10-01')) -Max 5
        ,$r | Should -BeOfType [array]
    }
}

Describe 'Get-MissingWeekdays' -Tag 'unit' {
    It '土日・祝日・入力済み (休暇含む)・今日より後を除く' {
        # 2026-10: 1(木) 2(金) 3(土) 4(日) 5(月) 6(火)
        $entries = @(
            (New-E '2026-10-01'),
            (New-E '2026-10-05' -Proj '' -Leave)
        )
        $holidays = @([pscustomobject]@{ date = '2026-10-06'; name = 'テスト祝日' })
        $r = Get-MissingWeekdays -Entries $entries -Year 2026 -Month 10 -Holidays $holidays -Today ([datetime]'2026-10-07')
        @($r) | Should -Be @('2026-10-02', '2026-10-07')
    }

    It '未来の月は空' {
        (Get-MissingWeekdays -Entries @() -Year 2026 -Month 11 -Holidays @() -Today ([datetime]'2026-10-07')).Count | Should -Be 0
    }

    It '1 件でも配列で返る' {
        $r = Get-MissingWeekdays -Entries @() -Year 2026 -Month 10 -Holidays @() -Today ([datetime]'2026-10-01')
        ,$r | Should -BeOfType [array]
        $r.Count | Should -Be 1
    }
}

Describe 'Find-ProjectForCodes (同じユニットコードで別パターン)' -Tag 'unit' {
    BeforeAll {
        $script:Patterns = @(
            [pscustomobject]@{ id = 'P1'; name = 'パターン1'; processes = @(
                [pscustomobject]@{ code = 'DSN'; task_groups = @(
                    [pscustomobject]@{ code = 'DB'; tasks = @([pscustomobject]@{ code = 'ERD' }) }) }) },
            [pscustomobject]@{ id = 'P2'; name = 'パターン2'; processes = @(
                [pscustomobject]@{ code = 'DSN'; task_groups = @(
                    [pscustomobject]@{ code = 'API'; tasks = @([pscustomobject]@{ code = 'SPEC' }) }) },
                [pscustomobject]@{ code = 'OPS'; task_groups = @(
                    [pscustomobject]@{ code = 'MON'; tasks = @([pscustomobject]@{ code = 'DAILY' }) }) }) }
        )
        $script:Items = @(
            [pscustomobject]@{ unit_code = 'A'; task_pattern_id = 'P1'; key = 'A1' },
            [pscustomobject]@{ unit_code = 'A'; task_pattern_id = 'P2'; key = 'A2' },
            [pscustomobject]@{ unit_code = 'B'; task_pattern_id = 'P1'; key = 'B1' }
        )
    }

    It 'タスクまで一致するパターンの項目を選ぶ' {
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A' -ProcessCode 'DSN' -TaskGroupCode 'API' -TaskCode 'SPEC').key | Should -Be 'A2'
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A' -ProcessCode 'DSN' -TaskGroupCode 'DB' -TaskCode 'ERD').key | Should -Be 'A1'
    }

    It '工程だけ一致する場合もその項目を選ぶ' {
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A' -ProcessCode 'OPS').key | Should -Be 'A2'
    }

    It 'コード無し・どれにも一致しない場合は先頭' {
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A').key | Should -Be 'A1'
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A' -ProcessCode 'ZZZ').key | Should -Be 'A1'
    }

    It 'タスクグループ全体 (task_code = -) はグループ一致で判定' {
        (Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'A' -ProcessCode 'DSN' -TaskGroupCode 'API' -TaskCode '-').key | Should -Be 'A2'
    }

    It 'ユニットコードが無ければ $null' {
        Find-ProjectForCodes -Items $script:Items -Patterns $script:Patterns -UnitCode 'Z' | Should -BeNullOrEmpty
    }
}

Describe 'Test-ProjectFilterMatch' -Tag 'unit' {
    BeforeAll {
        $script:Item = [pscustomobject]@{ unit_code = 'ABC001'; display = '⭐ [ABC001] 顧客管理 (基幹刷新)' }
    }
    It '空文字は全件一致' { Test-ProjectFilterMatch -Item $script:Item -Text '' | Should -BeTrue }
    It 'コードの部分一致 (大小無視)' { Test-ProjectFilterMatch -Item $script:Item -Text 'abc0' | Should -BeTrue }
    It '名称の部分一致' { Test-ProjectFilterMatch -Item $script:Item -Text '顧客' | Should -BeTrue }
    It '空白区切りは AND' {
        Test-ProjectFilterMatch -Item $script:Item -Text '顧客 刷新' | Should -BeTrue
        Test-ProjectFilterMatch -Item $script:Item -Text '顧客 保守' | Should -BeFalse
    }
}
