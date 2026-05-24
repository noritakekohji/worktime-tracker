# ProjectWbsItems.Tests.ps1 — Save-ProjectWbsItems が対象プロジェクトの wbs_items
# だけ差し替え、他プロジェクト + 他フィールドを温存することを確認

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
}

Describe 'Save-ProjectWbsItems' -Tag 'lib','integration' {

    BeforeEach {
        $script:tmpDir = Join-Path $env:TEMP ("worktime-projwbs-" + (Get-Random))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:src = [pscustomobject]@{ Mode='local'; LocalRoot=$script:tmpDir; RemoteCtx=$null }

        # 初期データ: 3 プロジェクト
        $initial = @(
            [ordered]@{
                unit_code='P1'; project_name='プロジェクトA'; unit_name='UA';
                target_system='SYS1'; work_type='案件対応';
                period_from='2026-01-01'; period_to='2026-12-31';
                task_pattern_id='PAT1'; active=$true
                wbs_items=@(
                    [ordered]@{ process_code='DSN'; task_group_code='DB'; task_code='ERD'; alias='初期'; planned_hours=8.0 }
                )
            }
            [ordered]@{
                unit_code='P2'; project_name='プロジェクトB';
                task_pattern_id='PAT2'; active=$true
                wbs_items=@(
                    [ordered]@{ process_code='IMP'; task_group_code='FE'; task_code='-'; alias='UI'; planned_hours=16.0 }
                )
            }
            [ordered]@{
                unit_code='P3'; project_name='プロジェクトC'; active=$false
                wbs_items=@()
            }
        )
        Save-MasterProjects -Source $script:src -Data $initial -AuthorName 'ut' -AuthorEmail 'ut@x'
    }
    AfterEach { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'P1 の wbs_items を差し替えても P2/P3 は影響なし' {
        $newItems = @(
            [ordered]@{ process_code='DSN'; task_group_code='DB'; task_code='ERD'; alias='更新後';  planned_hours=12.0 }
            [ordered]@{ process_code='IMP'; task_group_code='BE'; task_code='-';   alias='追加';    planned_hours=20.0 }
        )
        $r = Save-ProjectWbsItems -Source $script:src -ProjectCode 'P1' -WbsItems $newItems `
                                  -AuthorName 'ut' -AuthorEmail 'ut@x'

        # 戻り値が 3 件
        $r.Count | Should -Be 3

        # 再読込して検証
        $loaded = @(Get-MasterProjects -Source $script:src)
        $loaded.Count | Should -Be 3

        $p1 = $loaded | Where-Object { $_.unit_code -eq 'P1' } | Select-Object -First 1
        $p1 | Should -Not -BeNullOrEmpty
        @($p1.wbs_items).Count | Should -Be 2
        ([string]$p1.wbs_items[0].alias) | Should -Be '更新後'
        ([string]$p1.project_name) | Should -Be 'プロジェクトA'   # 他フィールド温存
        ([string]$p1.target_system) | Should -Be 'SYS1'           # 他フィールド温存

        $p2 = $loaded | Where-Object { $_.unit_code -eq 'P2' } | Select-Object -First 1
        $p2 | Should -Not -BeNullOrEmpty
        @($p2.wbs_items).Count | Should -Be 1
        ([string]$p2.wbs_items[0].alias) | Should -Be 'UI'        # 他プロジェクト温存

        $p3 = $loaded | Where-Object { $_.unit_code -eq 'P3' } | Select-Object -First 1
        [bool]$p3.active | Should -Be $false                       # active=false 温存
    }

    It '空配列で wbs_items を完全に消せる' {
        $r = Save-ProjectWbsItems -Source $script:src -ProjectCode 'P2' -WbsItems @() `
                                  -AuthorName 'ut' -AuthorEmail 'ut@x'
        $loaded = @(Get-MasterProjects -Source $script:src)
        $p2 = $loaded | Where-Object { $_.unit_code -eq 'P2' } | Select-Object -First 1
        # PS 5.1 の ConvertFrom-Json は空配列 [] を $null として返すため
        # null 要素を除いてカウント (WbsInput の Get-ProjectWbsItems と同じ扱い)
        $items = @($p2.wbs_items | Where-Object { $_ })
        $items.Count | Should -Be 0
    }

    It '存在しないプロジェクトコードを指定しても他プロジェクトは無傷' {
        Save-ProjectWbsItems -Source $script:src -ProjectCode 'P_NONEXISTENT' -WbsItems @(@{a=1}) `
                             -AuthorName 'ut' -AuthorEmail 'ut@x'
        $loaded = @(Get-MasterProjects -Source $script:src)
        $loaded.Count | Should -Be 3
        $p1 = $loaded | Where-Object { $_.unit_code -eq 'P1' } | Select-Object -First 1
        @($p1.wbs_items).Count | Should -Be 1   # 元のまま
    }
}
