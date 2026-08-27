# MemberMonthSummary.Tests.ps1 — メンバー別タブの「メンバー × 月」クロス集計
#
# 回帰防止の狙い:
#   1. メンバー別集計は月を列に展開する。列が増減しても 合計 / 件数 が末尾に残ること。
#   2. Set-PivotGrid は先頭 `_` のキーを列にせず値だけ残す。
#      ここを落とすと `_key` が画面に列として出る、あるいは消えてドリルダウンが
#      無反応になる (どちらも silent fail で気づきにくい)。
#
#   ReportViewer.ps1 は読み込むと WPF ウインドウを起動してしまうため dot-source できない。
#   AST から必要な関数定義だけ取り出して評価する (LeaveAggregation.Tests.ps1 と同じ手法)。

BeforeAll {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase           -ErrorAction SilentlyContinue

    $script:RepoRoot   = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:ViewerPath = Join-Path $script:RepoRoot 'reports/ReportViewer.ps1'

    $wanted = @('_MonthKey', 'Build-MemberMonthSummary', 'Set-PivotGrid')
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ViewerPath, [ref]$null, [ref]$null)
    $defs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    $found = @($defs | ForEach-Object { $_.Name })
    foreach ($w in $wanted) {
        if ($found -notcontains $w) { throw "ReportViewer.ps1 に関数 $w が見つからない (リネームされた?)" }
    }
    . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))

    # ReportViewer 本体の依存はスタブで置き換える。
    # 抽出した関数からは未修飾 $u / ヘルパが見えている必要があるため global に置く。
    function global:_TraceMgr { param($A, $B) }
    function global:Resolve-MemberDisplay { param([string]$Id) "$Id さん" }
    $global:u = @{ MemberSummaryGrid = (New-Object System.Windows.Controls.DataGrid) }

    $script:ViewerSrc = Get-Content -LiteralPath $script:ViewerPath -Raw

    # Apply-Filters が組み立てる行と同じ形 (工数集計対象のみ = 休暇は除外済み)
    $script:SampleRows = @(
        [pscustomobject]@{ date='2026-07-01'; member_id='E001'; hours=3.0 },
        [pscustomobject]@{ date='2026-07-02'; member_id='E001'; hours=2.0 },
        [pscustomobject]@{ date='2026-08-03'; member_id='E001'; hours=1.5 },
        [pscustomobject]@{ date='2026-08-04'; member_id='E002'; hours=4.0 }
    )

    function Get-PivotHeaders {
        param($Grid)
        return @($Grid.Columns | ForEach-Object { [string]$_.Header })
    }

    function Get-PivotCell {
        param($Grid, $Item, [string]$Header)
        $col = @($Grid.Columns | Where-Object { [string]$_.Header -eq $Header })[0]
        if (-not $col) { throw "列 '$Header' が無い" }
        $path = [string]$col.Binding.Path.Path
        return [string]$Item.$path
    }
}

AfterAll {
    Remove-Item -Path 'function:global:_TraceMgr' -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:global:Resolve-MemberDisplay' -ErrorAction SilentlyContinue
    Remove-Variable -Name 'u' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'メンバー別は月を列に展開する' -Tag 'unit' {

    BeforeAll {
        Build-MemberMonthSummary -Rows $script:SampleRows
        $script:Grid  = $global:u.MemberSummaryGrid
        $script:Items = @($script:Grid.ItemsSource)
    }

    It '列は メンバー + 実績のある月 + 合計 + 件数 の順' {
        Get-PivotHeaders $script:Grid | Should -Be @('メンバー', '2026-07', '2026-08', '合計', '件数')
    }

    It '行はメンバー + 月合計フッタ' {
        $script:Items.Count | Should -Be 3
        (Get-PivotCell $script:Grid $script:Items[2] 'メンバー') | Should -Be '◆ 月合計'
    }

    It '月ごとの工数が該当列に入る' {
        $e001 = $script:Items[0]
        (Get-PivotCell $script:Grid $e001 'メンバー') | Should -Be 'E001 さん'
        (Get-PivotCell $script:Grid $e001 '2026-07') | Should -Be '5.0'
        (Get-PivotCell $script:Grid $e001 '2026-08') | Should -Be '1.5'
        (Get-PivotCell $script:Grid $e001 '合計')    | Should -Be '6.5'
        (Get-PivotCell $script:Grid $e001 '件数')    | Should -Be '3'
    }

    It '実績が無い月のセルは空' {
        $e002 = $script:Items[1]
        (Get-PivotCell $script:Grid $e002 '2026-07') | Should -Be ''
        (Get-PivotCell $script:Grid $e002 '2026-08') | Should -Be '4.0'
    }

    It '月合計行は列ごとの縦計' {
        $footer = $script:Items[2]
        (Get-PivotCell $script:Grid $footer '2026-07') | Should -Be '5.0'
        (Get-PivotCell $script:Grid $footer '2026-08') | Should -Be '5.5'
        (Get-PivotCell $script:Grid $footer '合計')    | Should -Be '10.5'
        (Get-PivotCell $script:Grid $footer '件数')    | Should -Be '4'
    }

    It 'ドリルダウン用の _key は列にせず値だけ残す' {
        Get-PivotHeaders $script:Grid | Should -Not -Contain '_key'
        [string]$script:Items[0]._key | Should -Be 'E001'
        # フッタ行はドリルダウン対象外 (_EnableDrillDown が空キーで早期 return)
        [string]$script:Items[2]._key | Should -BeNullOrEmpty
    }

    It '該当行が無いときはグリッドを空にする' {
        Build-MemberMonthSummary -Rows @()
        $global:u.MemberSummaryGrid.ItemsSource | Should -BeNullOrEmpty
        $global:u.MemberSummaryGrid.Columns.Count | Should -Be 0
    }
}

Describe '_MonthKey' -Tag 'unit' {
    It 'yyyy-MM-dd を yyyy-MM にする' {
        _MonthKey '2026-08-03' | Should -Be '2026-08'
    }
    It '解析できない値は先頭 7 文字にフォールバック' {
        _MonthKey '2026-13-99' | Should -Be '2026-13'
    }
    It '空文字は空文字' {
        _MonthKey '' | Should -Be ''
    }
}

Describe 'Apply-Filters の配線' -Tag 'unit' {
    It 'メンバー別グリッドは Build-MemberMonthSummary が組み立てる' {
        $script:ViewerSrc | Should -Match 'Build-MemberMonthSummary\s+-Rows\s+\$workRows'
    }
    It '旧 _SumBy によるメンバー別集計は残っていない' {
        $script:ViewerSrc | Should -Not -Match "MemberSummaryGrid\.ItemsSource\s*=\s*_SumBy"
    }
    It 'ドリルダウンは従来どおり有効' {
        $script:ViewerSrc | Should -Match '_EnableDrillDown\s+\$u\.MemberSummaryGrid'
    }
}
