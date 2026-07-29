# ReportResolvers.Tests.ps1 — Report の名称解決と集計ヘルパ
#
# 回帰防止の狙い:
#   Resolve-* は線形検索 (Where-Object) からハッシュテーブル索引 + メモ化に
#   置き換えた。索引の作り方を間違えても例外は出ず、画面には「コードだけ」や
#   「別プロジェクトの名称」が静かに出るだけなので、値を直接検証する。
#   _SumBy も Group-Object 置き換えのため、件数と工数の一致を押さえる。
#
#   ReportViewer.ps1 は読み込むと WPF ウインドウを起動してしまうため
#   dot-source できない。AST から対象関数の定義だけを取り出して評価する。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:ViewerPath = Join-Path $script:RepoRoot 'reports/ReportViewer.ps1'

    $wanted = @(
        '_BuildMasterIndexes','_MergeCodeName','_SumBy',
        'Resolve-MemberName','Resolve-MemberDisplay','Resolve-MemberCompany',
        'Resolve-ProjectName','Resolve-ProjectDisplay','Resolve-ProjectTargetSystem',
        'Resolve-CategoryName','Resolve-CategoryDisplay',
        'Resolve-ProjectTaskPattern','Resolve-ProcessName','Resolve-TaskGroupName','Resolve-TaskName'
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ViewerPath, [ref]$null, [ref]$null)
    $defs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }

    # 抽出漏れ (リネーム等) をここで検出する
    $found = @($defs | ForEach-Object { $_.Name })
    foreach ($w in $wanted) {
        if ($found -notcontains $w) { throw "ReportViewer.ps1 に関数 $w が見つからない (リネームされた?)" }
    }
    . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))

    function Reset-Masters {
        $script:_Idx = $null    # 索引 + メモを破棄
        $script:Members = @(
            [pscustomobject]@{ id='E001'; name='山田太郎'; company='アルファ社'; active=$true },
            [pscustomobject]@{ id='E002'; name='佐藤花子'; company='ベータ社';   active=$true },
            [pscustomobject]@{ id='E003'; name='鈴木一郎';                        active=$true }
        )
        $script:Projects = @(
            [pscustomobject]@{ unit_code='ABC001'; project_name='顧客管理刷新'; target_system='CRM'; work_type='案件対応'; task_pattern_id='PT1' },
            [pscustomobject]@{ unit_code='XYZ999'; project_name='運用保守';     target_system='ERP'; work_type='維持運用'; task_pattern_id='PT2' },
            [pscustomobject]@{ unit_code='NOPAT'; project_name='パターン無し' }
        )
        $script:Categories = @(
            [pscustomobject]@{ code='DESIGN'; name='設計' },
            [pscustomobject]@{ code='TEST';   name='テスト' }
        )
        $script:TaskPatterns = @(
            [pscustomobject]@{ id='PT1'; processes=@(
                [pscustomobject]@{ code='DSN'; name='設計'; task_groups=@(
                    [pscustomobject]@{ code='DB'; name='DB設計'; tasks=@(
                        [pscustomobject]@{ code='ERD'; name='ER図作成' }
                    )}
                )}
            )},
            [pscustomobject]@{ id='PT2'; processes=@(
                [pscustomobject]@{ code='DSN'; name='運用設計'; task_groups=@(
                    [pscustomobject]@{ code='DB'; name='DB運用'; tasks=@(
                        [pscustomobject]@{ code='ERD'; name='ER図保守' }
                    )}
                )}
            )}
        )
    }
}

Describe 'メンバー / プロジェクト / カテゴリの名称解決' -Tag 'unit' {

    BeforeEach { Reset-Masters }

    It 'メンバー ID から氏名を引ける' {
        Resolve-MemberName 'E001' | Should -Be '山田太郎'
        Resolve-MemberName 'E002' | Should -Be '佐藤花子'
    }

    It '未登録のメンバー ID は空文字' {
        Resolve-MemberName 'NOPE' | Should -Be ''
    }

    It '表示文字列は "ID  氏名"、氏名が無ければ ID のみ' {
        Resolve-MemberDisplay 'E001' | Should -Be 'E001  山田太郎'
        Resolve-MemberDisplay 'NOPE' | Should -Be 'NOPE'
        Resolve-MemberDisplay ''     | Should -Be ''
    }

    It '会社を引ける。未設定は空文字' {
        Resolve-MemberCompany 'E001' | Should -Be 'アルファ社'
        Resolve-MemberCompany 'E003' | Should -Be ''
        Resolve-MemberCompany 'NOPE' | Should -Be ''
    }

    It 'プロジェクト名と対象システムを引ける' {
        Resolve-ProjectName 'ABC001'         | Should -Be '顧客管理刷新'
        Resolve-ProjectDisplay 'ABC001'      | Should -Be 'ABC001  顧客管理刷新'
        Resolve-ProjectTargetSystem 'ABC001' | Should -Be 'CRM'
        Resolve-ProjectTargetSystem 'XYZ999' | Should -Be 'ERP'
        Resolve-ProjectTargetSystem 'NOPAT'  | Should -Be ''
    }

    It 'カテゴリ名を引ける' {
        Resolve-CategoryName 'DESIGN'    | Should -Be '設計'
        Resolve-CategoryDisplay 'DESIGN' | Should -Be 'DESIGN  設計'
        Resolve-CategoryDisplay 'NOPE'   | Should -Be 'NOPE'
    }

    It 'マスタ差し替え後に索引を破棄すれば新しい値を返す' {
        Resolve-MemberName 'E001' | Should -Be '山田太郎'
        $script:Members = @([pscustomobject]@{ id='E001'; name='改名後'; active=$true })
        $script:_Idx = $null      # Reload-Masters 相当
        Resolve-MemberName 'E001' | Should -Be '改名後'
    }
}

Describe 'タスクパターン経由の名称解決 (プロジェクトごとに異なる名称)' -Tag 'unit' {

    BeforeEach { Reset-Masters }

    It 'プロジェクトに紐づくパターンを引ける' {
        (Resolve-ProjectTaskPattern 'ABC001').id | Should -Be 'PT1'
        (Resolve-ProjectTaskPattern 'XYZ999').id | Should -Be 'PT2'
        Resolve-ProjectTaskPattern 'NOPAT'       | Should -BeNullOrEmpty
        Resolve-ProjectTaskPattern ''            | Should -BeNullOrEmpty
    }

    It '同じコードでもプロジェクトが違えば別名称を返す (索引の取り違え検出)' {
        Resolve-ProcessName   'DSN' 'ABC001'             | Should -Be '設計'
        Resolve-ProcessName   'DSN' 'XYZ999'             | Should -Be '運用設計'
        Resolve-TaskGroupName 'DB'  'ABC001' 'DSN'       | Should -Be 'DB設計'
        Resolve-TaskGroupName 'DB'  'XYZ999' 'DSN'       | Should -Be 'DB運用'
        Resolve-TaskName      'ERD' 'ABC001' 'DSN' 'DB'  | Should -Be 'ER図作成'
        Resolve-TaskName      'ERD' 'XYZ999' 'DSN' 'DB'  | Should -Be 'ER図保守'
    }

    It 'パターン未紐付けのプロジェクトはフォールバック表から引く' {
        # PT1/PT2 のどちらかの名称が返れば良い (どのパターンでもよい探索)
        Resolve-ProcessName 'DSN' 'NOPAT' | Should -Not -BeNullOrEmpty
    }

    It 'task_code "-" はタスクグループ全体' {
        Resolve-TaskName '-' 'ABC001' 'DSN' 'DB' | Should -Be 'タスクグループ全体'
    }

    It '未知のコードは空文字' {
        Resolve-ProcessName   'NOPE' 'ABC001'              | Should -Be ''
        Resolve-TaskGroupName 'NOPE' 'ABC001' 'DSN'        | Should -Be ''
        Resolve-TaskName      'NOPE' 'ABC001' 'DSN' 'DB'   | Should -Be ''
    }

    It 'メモ化しても引数違いで別の値を返す (キー衝突検出)' {
        # 1 度目で ABC001 をメモ化 → 2 度目に XYZ999 が汚染されないこと
        Resolve-TaskName 'ERD' 'ABC001' 'DSN' 'DB' | Should -Be 'ER図作成'
        Resolve-TaskName 'ERD' 'XYZ999' 'DSN' 'DB' | Should -Be 'ER図保守'
        Resolve-TaskName 'ERD' 'ABC001' 'DSN' 'DB' | Should -Be 'ER図作成'
    }
}

Describe '_MergeCodeName' -Tag 'unit' {

    It 'コードと名称を連結する' {
        _MergeCodeName 'DSN' '設計' | Should -Be 'DSN  設計'
    }

    It '名称が空ならコードのみ、コードが空なら空文字' {
        _MergeCodeName 'DSN' ''  | Should -Be 'DSN'
        _MergeCodeName ''    '設計' | Should -Be ''
    }
}

Describe '_SumBy (Group-Object 置き換えの集計)' -Tag 'unit' {

    BeforeAll {
        $script:SumRows = @(
            [pscustomobject]@{ member_id='E001'; project_code='ABC001'; hours=3.5 },
            [pscustomobject]@{ member_id='E001'; project_code='ABC001'; hours=2.0 },
            [pscustomobject]@{ member_id='E002'; project_code='XYZ999'; hours=8.0 },
            [pscustomobject]@{ member_id='E002'; project_code='ABC001'; hours=1.25 }
        )
    }

    It 'プロパティ名をキーに件数と工数を集計する' {
        $r = _SumBy $script:SumRows 'member_id' 'メンバー'
        $r.Count | Should -Be 2
        $e2 = $r | Where-Object { $_.メンバー -eq 'E002' }
        $e2.件数 | Should -Be 2
        $e2.工数 | Should -Be 9.25
        $e1 = $r | Where-Object { $_.メンバー -eq 'E001' }
        $e1.件数 | Should -Be 2
        $e1.工数 | Should -Be 5.5
    }

    It '工数の降順に並ぶ' {
        $r = _SumBy $script:SumRows 'member_id' 'メンバー'
        $r[0].工数 | Should -BeGreaterOrEqual $r[1].工数
    }

    It '見出し (KeyLabel) が 1 列目のプロパティ名になる' {
        $r = _SumBy $script:SumRows 'project_code' 'プロジェクト'
        $r[0].PSObject.Properties.Name[0] | Should -Be 'プロジェクト'
    }

    It 'ScriptBlock をキーに使える' {
        $r = _SumBy $script:SumRows { param($row) if ($row.hours -ge 3) { '長時間' } else { '短時間' } } '区分'
        ($r | Where-Object { $_.区分 -eq '長時間' }).件数 | Should -Be 2
        ($r | Where-Object { $_.区分 -eq '短時間' }).件数 | Should -Be 2
    }

    It 'Display で表示文字列を差し替えられる' {
        Reset-Masters
        $r = _SumBy $script:SumRows 'member_id' 'メンバー' { param($k) Resolve-MemberDisplay $k }
        @($r | ForEach-Object { $_.メンバー }) | Should -Contain 'E001  山田太郎'
    }

    It '空配列でも落ちない' {
        @(_SumBy @() 'member_id' 'メンバー').Count | Should -Be 0
    }

    It '合計工数は元データの総和と一致する' {
        $r = _SumBy $script:SumRows 'project_code' 'プロジェクト'
        $sum = 0.0; foreach ($x in $r) { $sum += [double]$x.工数 }
        $sum | Should -Be 14.75
    }
}
