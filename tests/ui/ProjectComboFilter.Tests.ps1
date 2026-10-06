# ProjectComboFilter.Tests.ps1 — 日次入力のプロジェクト候補 絞り込み / 選択ヘルパ
#
# 回帰防止の狙い:
#   - Get-ProjectComboView が ICollectionView を「要素に展開せず」返すこと。
#     ICollectionView は IEnumerable なので `return $view` だと PS が展開し、
#     起動時に「プロパティ 'Filter' が見つかりません」で落ちた (開発中に発生)
#   - 絞り込み中でも Select-ProjectCode なら候補外のプロジェクトを選べること
#     (WPF は Filter で隠れた項目を SelectedValue で選べない)
#
#   WorkTimeTracker.ps1 は読み込むとウインドウを起動するため、AST から関数だけ取り出して評価する。

BeforeAll {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/EntryAssist.ps1')

    $trackerPath = Join-Path $script:RepoRoot 'client/WorkTimeTracker.ps1'
    $wanted = @('Get-ProjectComboView', 'Clear-ProjectFilter', 'Select-ProjectCode')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($trackerPath, [ref]$null, [ref]$null)
    $defs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    $found = @($defs | ForEach-Object { $_.Name })
    foreach ($w in $wanted) {
        if ($found -notcontains $w) { throw "WorkTimeTracker.ps1 に関数 $w が見つからない (リネームされた?)" }
    }
    . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))
}

Describe '起動時の候補構築で未定義関数を呼ばない' -Tag 'ui' {
    # 起動時にトップレベルで Set-ProjectComboItems を呼ぶ時点で、そこから (推移的に) 呼ばれる
    # Tracker 内の関数がすべて定義済みであること。
    # 同じユニットコードが複数あるときだけ通る分岐で、後方定義の Get-TaskPatternFor を呼んで
    # 起動時に落ちた (開発中に発生)。分岐の条件に関係なく静的に検出する
    It 'Set-ProjectComboItems の初回呼出しより前に、呼ばれる関数が定義されている' {
        $path = Join-Path $script:RepoRoot 'client/WorkTimeTracker.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $defs = @{}
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            if (-not $defs.ContainsKey($f.Name)) { $defs[$f.Name] = $f }
        }
        # トップレベル (関数・スクリプトブロック引数の外) の最初の呼出し行
        $firstCall = $ast.EndBlock.Statements | Where-Object {
            $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Extent.Text -match '^\s*Set-ProjectComboItems\b'
        } | Select-Object -First 1
        $firstCall | Should -Not -BeNullOrEmpty
        $callLine = $firstCall.Extent.StartLineNumber

        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue('Set-ProjectComboItems')
        $late = New-Object System.Collections.Generic.List[string]
        while ($queue.Count -gt 0) {
            $name = $queue.Dequeue()
            if (-not $seen.Add($name)) { continue }
            $fn = $defs[$name]
            if ($fn.Extent.StartLineNumber -gt $callLine) { $late.Add("$name (line $($fn.Extent.StartLineNumber))") }
            foreach ($cmd in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $cn = $cmd.GetCommandName()
                if ($cn -and $defs.ContainsKey($cn)) { $queue.Enqueue($cn) }
            }
        }
        $late | Should -BeNullOrEmpty -Because "起動時の呼出し (line $callLine) より後で定義された関数を呼んでいる"
    }
}

Describe 'プロジェクト候補の絞り込み' -Tag 'ui' {
    BeforeEach {
        $script:SuppressTemplate = 0
        $script:ProjectFilterText = ''
        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.DisplayMemberPath = 'display'
        $combo.SelectedValuePath = 'unit_code'
        $combo.ItemsSource = @(
            [pscustomobject]@{ unit_code = 'ABC001'; display = '[ABC001] 顧客管理' },
            [pscustomobject]@{ unit_code = 'XYZ002'; display = '[XYZ002] 保守' }
        )
        $script:ui = @{ ProjectCombo = $combo }
        $v = Get-ProjectComboView
        $v.Filter = [Predicate[object]]{ param($o) Test-ProjectFilterMatch -Item $o -Text $script:ProjectFilterText }
    }

    It 'Get-ProjectComboView は ICollectionView を展開せずに返す' {
        $v = Get-ProjectComboView
        # パイプに流すとここでも展開されるため -is で判定する
        ($v -is [System.ComponentModel.ICollectionView]) | Should -BeTrue
    }

    It '入力文字で候補が絞り込まれる' {
        $script:ProjectFilterText = '保守'
        (Get-ProjectComboView).Refresh()
        $script:ui.ProjectCombo.Items.Count | Should -Be 1
    }

    It '絞り込み中でも Select-ProjectCode で候補外を選べ、絞り込みは解除される' {
        $script:ProjectFilterText = '保守'
        (Get-ProjectComboView).Refresh()
        Select-ProjectCode 'ABC001'
        $script:ui.ProjectCombo.SelectedValue | Should -Be 'ABC001'
        $script:ProjectFilterText | Should -Be ''
        $script:ui.ProjectCombo.Items.Count | Should -Be 2
    }

    It '同じユニットコードの別パターンは、工程〜タスクのコードかキーで選び分ける' {
        $script:TaskPatterns = @(
            [pscustomobject]@{ id = 'P1'; processes = @([pscustomobject]@{ code = 'DSN'; task_groups = @() }) },
            [pscustomobject]@{ id = 'P2'; processes = @([pscustomobject]@{ code = 'OPS'; task_groups = @() }) }
        )
        $script:ui.ProjectCombo.ItemsSource = @(
            [pscustomobject]@{ unit_code = 'A'; task_pattern_id = 'P1'; item_key = 'A|P1|1'; display = '[A] x ‹P1›' },
            [pscustomobject]@{ unit_code = 'A'; task_pattern_id = 'P2'; item_key = 'A|P2|2'; display = '[A] x ‹P2›' }
        )
        Select-ProjectCode 'A' -ProcessCode 'OPS'
        $script:ui.ProjectCombo.SelectedItem.item_key | Should -Be 'A|P2|2'
        Select-ProjectCode 'A' -ProcessCode 'DSN'
        $script:ui.ProjectCombo.SelectedItem.item_key | Should -Be 'A|P1|1'
        Select-ProjectCode 'A' -ItemKey 'A|P2|2'
        $script:ui.ProjectCombo.SelectedItem.item_key | Should -Be 'A|P2|2'
    }

    It 'Select-ProjectCode の間は既定の適用を抑止し、終わったら戻す' {
        $script:ui.ProjectCombo.Add_SelectionChanged({ $script:SeenSuppress = $script:SuppressTemplate })
        Select-ProjectCode 'XYZ002'
        $script:SeenSuppress | Should -BeGreaterThan 0
        $script:SuppressTemplate | Should -Be 0
    }
}
