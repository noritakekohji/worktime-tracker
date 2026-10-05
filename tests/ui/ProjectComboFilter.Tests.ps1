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

    It 'Select-ProjectCode の間は既定の適用を抑止し、終わったら戻す' {
        $script:ui.ProjectCombo.Add_SelectionChanged({ $script:SeenSuppress = $script:SuppressTemplate })
        Select-ProjectCode 'XYZ002'
        $script:SeenSuppress | Should -BeGreaterThan 0
        $script:SuppressTemplate | Should -Be 0
    }
}
