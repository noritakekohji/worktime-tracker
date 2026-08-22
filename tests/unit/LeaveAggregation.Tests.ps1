# LeaveAggregation.Tests.ps1 — 休暇 (is_leave) を工数集計に混ぜない
#
# 回帰防止の狙い:
#   休暇エントリは「その日は入力済み」を表すだけで作業工数ではない。
#   Report の Apply-Filters が休暇込みの行をそのまま _SumBy / ChartRows に流していたため、
#   休暇時間が合計・メンバー別・グラフ・週次負荷にすべて加算されていた (2026-08 の不具合)。
#   一方で未入力検知では休暇日を「入力あり」として扱う必要があるため、
#   「集計は除外・存在判定は含める」の両方を押さえる。
#
#   ReportViewer.ps1 は読み込むと WPF ウインドウを起動してしまうため dot-source できない。
#   集計ヘルパは AST から関数定義だけ取り出して評価し、配線はソース文字列で検証する。

BeforeAll {
    $script:RepoRoot   = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:ViewerPath  = Join-Path $script:RepoRoot 'reports/ReportViewer.ps1'
    $script:TrackerPath = Join-Path $script:RepoRoot 'client/WorkTimeTracker.ps1'

    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')

    # ReportViewer から集計ヘルパだけ取り出す
    $wanted = @('_SumBy')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ViewerPath, [ref]$null, [ref]$null)
    $defs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    $found = @($defs | ForEach-Object { $_.Name })
    foreach ($w in $wanted) {
        if ($found -notcontains $w) { throw "ReportViewer.ps1 に関数 $w が見つからない (リネームされた?)" }
    }
    . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))

    $script:ViewerSrc  = Get-Content -LiteralPath $script:ViewerPath  -Raw
    $script:TrackerSrc = Get-Content -LiteralPath $script:TrackerPath -Raw

    # Apply-Filters が組み立てる行と同じ形 (休暇は project/category が空)
    $script:SampleRows = @(
        [pscustomobject]@{ date='2026-08-20'; member_id='E001'; project_code='ABC001'; category='IMPL'; hours=1.0; is_leave=$false },
        [pscustomobject]@{ date='2026-08-20'; member_id='E001'; project_code='';       category='';     hours=8.0; is_leave=$true  },
        [pscustomobject]@{ date='2026-08-21'; member_id='E002'; project_code='ABC001'; category='IMPL'; hours=3.0; is_leave=$false }
    )
}

Describe '休暇は工数集計に入らない' -Tag 'unit' {

    It '合計工数は休暇を除いた分だけ' {
        Get-EntryHoursSum $script:SampleRows | Should -Be 4.0
    }

    It 'メンバー別集計から休暇分が落ちる' {
        $work = Get-WorkEntries $script:SampleRows
        $byMember = _SumBy $work 'member_id' 'メンバー'
        $e001 = $byMember | Where-Object { $_.'メンバー' -eq 'E001' }
        $e001.'工数' | Should -Be 1.0
    }

    It 'プロジェクト別集計に休暇の空プロジェクト行が現れない' {
        $work = Get-WorkEntries $script:SampleRows
        $byProj = _SumBy $work 'project_code' 'プロジェクト'
        @($byProj | Where-Object { [string]$_.'プロジェクト' -eq '' }).Count | Should -Be 0
    }

    It '休暇日は「入力あり」として残る (未入力検知が誤検知しない)' {
        # 未入力検知は休暇込みの行で日付の有無だけを見る
        $dates = @($script:SampleRows | Where-Object { $_.member_id -eq 'E001' } | ForEach-Object { $_.date } | Sort-Object -Unique)
        $dates | Should -Contain '2026-08-20'
    }
}

Describe 'Report / Tracker の集計配線' -Tag 'unit' {

    It 'Apply-Filters は休暇を除いた行を集計に渡す' {
        # _SumBy に休暇込みの $rows を直接渡していないこと
        ([regex]::Matches($script:ViewerSrc, '_SumBy\s+\$rows\b')).Count | Should -Be 0
        # @() で囲むと PS 5.1 では二重ラップになるため、囲まずに受けていることも併せて確認する
        $script:ViewerSrc | Should -Match '\$workRows\s*=\s*Get-WorkEntries\s+\$rows'
        ([regex]::Matches($script:ViewerSrc, '@\(Get-WorkEntries')).Count | Should -Be 0
    }

    It '遅延ビルド用の ChartRows も休暇を除いた行' {
        $script:ViewerSrc | Should -Match '\$Script:ChartRows\s*=\s*\$workRows'
    }

    It '未入力検知用に休暇込みの行を保持している' {
        $script:ViewerSrc | Should -Match '\$Script:AllFilteredRows\s*=\s*\$rows'
        ([regex]::Matches($script:ViewerSrc, '\$presenceRows\s*=')).Count | Should -BeGreaterOrEqual 2
    }

    It '休暇の工数は 0 として扱う (Report の明細行 / Tracker の読込)' {
        $script:ViewerSrc  | Should -Match 'hours\s+=\s*if \(\$isLeave\)\s*\{\s*0\.0\s*\}'
        $script:TrackerSrc | Should -Match 'hours\s+=\s*if \(\$isLeaveLoaded\)\s*\{\s*0\.0\s*\}'
    }

    It '休暇のときは工数入力を求めず 0 で登録する' {
        # 「工数は正の数値で入力してください」の検証を休暇時に通さないこと
        $script:TrackerSrc | Should -Match 'if \(-not \$isLeave\) \{[\s\S]{0,200}工数は正の数値で入力してください'
        # 休暇チェック中は工数欄とクイック工数ボタンを無効化する
        $script:TrackerSrc | Should -Match 'function Set-LeaveFormState'
        $script:TrackerSrc | Should -Match '\$ui\.IsLeaveChk\.Add_Checked'
        $script:TrackerSrc | Should -Match '\$ui\.IsLeaveChk\.Add_Unchecked'
    }

    # 休暇にプロジェクトが紛れ込んでいた実例 (2026-08-22)。
    # プロジェクトを選んでから休暇にチェックすると、コンボの選択が残ったまま
    # Get-EntryFromForm がエントリを組み立てるため、休暇なのに project_code が入っていた。
    It '休暇エントリにプロジェクト/工程/タスクが紛れ込まない' {
        # データ生成側: 休暇なら UI の状態によらず必ず空にする
        $script:TrackerSrc | Should -Match 'if \(\$isLeave\) \{[\s\S]{0,400}\$proj = \$null; \$proc = \$null; \$tg = \$null; \$task = \$null' `
            -Because '休暇のとき Get-EntryFromForm がプロジェクト系を強制的に空にしていません'
    }

    It '休暇チェック中はプロジェクト系コンボを選べない' {
        # UI 側: 選択を外し、操作も塞ぐ
        $script:TrackerSrc | Should -Match 'function Set-LeaveFormState[\s\S]{0,1500}\$ui\.ProjectCombo\.SelectedIndex = -1' `
            -Because '休暇チェック時にプロジェクトの選択を外していません'
        $script:TrackerSrc | Should -Match 'function Set-LeaveFormState[\s\S]{0,2000}ProjectCombo, \$ui\.ProcessCombo, \$ui\.TaskGroupCombo, \$ui\.TaskCombo[\s\S]{0,200}IsEnabled = \(-not \$IsLeave\)' `
            -Because '休暇チェック時にプロジェクト系コンボを無効化していません'
    }

    It '休暇時間の併記は残っていない (合算しない)' {
        ([regex]::Matches($script:ViewerSrc,  '休暇 \{0:N1\} h')).Count | Should -Be 0
        ([regex]::Matches($script:TrackerSrc, '休暇 \{1:N1\} h')).Count | Should -Be 0
    }

    It 'Tracker の当日/当月合計は共通ヘルパで休暇を除外する' {
        $script:TrackerSrc | Should -Match 'function Update-HoursTotal[\s\S]{0,400}Get-EntryHoursSum'
        $script:TrackerSrc | Should -Match 'function Update-HoursDay[\s\S]{0,600}Get-EntryHoursSum'
        # 休暇判定を通さない素の合計が復活していないこと
        ([regex]::Matches($script:TrackerSrc, '\$sum\s*\+=\s*\[double\]\$e\.hours')).Count | Should -Be 0
    }
}
