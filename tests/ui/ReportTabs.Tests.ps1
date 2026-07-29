# ReportTabs.Tests.ps1 — Report のタブ構成と遅延構築の対応
#
# 回帰防止の狙い:
#   Report は 14 タブのフラット構成から 5 グループ + サブタブに再編し、
#   重い Build-* は「表示中のタブだけ」実行する遅延構築にした。
#   各ビューは "<外側タブ名>/<内側タブ index>" で置き場所を宣言する。
#
#   タブを 1 つ足し引きすると index がずれるが、ずれても例外は出ず
#   「開いてもタブが白いまま」になるだけで気づきにくい。
#   XAML の実構造と $Script:Views の宣言を突き合わせて検出する。

BeforeAll {
    $script:RepoRoot   = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:XamlPath   = Join-Path $script:RepoRoot 'reports/ReportViewer.xaml'
    $script:ViewerPath = Join-Path $script:RepoRoot 'reports/ReportViewer.ps1'

    Add-Type -AssemblyName PresentationFramework
    [xml]$x = Get-Content -LiteralPath $script:XamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $x
    $script:Win = [Windows.Markup.XamlReader]::Load($reader)

    # XAML から実在する位置キー "<Grp>/<idx>" の集合を作る
    $script:GroupNames = @('GrpOverview','GrpMember','GrpProject','GrpCheck','GrpDetail')
    $script:ValidKeys  = New-Object 'System.Collections.Generic.List[string]'
    $script:InnerCount = @{}
    foreach ($g in $script:GroupNames) {
        $inner = $script:Win.FindName("${g}Inner")
        $n = if ($inner) { $inner.Items.Count } else { 0 }
        $script:InnerCount[$g] = $n
        for ($i = 0; $i -lt $n; $i++) { [void]$script:ValidKeys.Add("$g/$i") }
    }

    # ReportViewer.ps1 から $Script:Views の宣言だけを取り出して評価する。
    # 中の ScriptBlock は「作るだけ」で実行しないので Build-* は不要。
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ViewerPath, [ref]$null, [ref]$null)
    $assign = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$Script:Views'
    }, $true) | Select-Object -First 1
    if (-not $assign) { throw 'ReportViewer.ps1 に $Script:Views の宣言が見つからない' }
    $script:Views = & ([scriptblock]::Create($assign.Right.Extent.Text))
}

Describe 'タブのグループ構成' -Tag 'ui' {

    It '外側タブ MainTabs が存在し 5 グループを持つ' {
        $main = $script:Win.FindName('MainTabs')
        $main | Should -Not -BeNullOrEmpty
        $main.Items.Count | Should -Be 5
    }

    It '5 つのグループタブと内側 TabControl が全て存在する' {
        foreach ($g in $script:GroupNames) {
            $script:Win.FindName($g)          | Should -Not -BeNullOrEmpty -Because "グループタブ $g"
            $script:Win.FindName("${g}Inner") | Should -Not -BeNullOrEmpty -Because "内側 TabControl ${g}Inner"
        }
    }

    It '各グループが 1 つ以上のサブタブを持つ' {
        foreach ($g in $script:GroupNames) {
            $script:InnerCount[$g] | Should -BeGreaterThan 0 -Because "グループ $g が空"
        }
    }

    It '再編前の画面要素が 1 つも失われていない' {
        # 旧 14 タブの中身を代表する x:Name。移動はしても消してはいけない。
        $mustExist = @(
            'DashboardPanel','DetailGrid','MemberSummaryGrid','ProjectSummaryGrid',
            'CategorySummaryGrid','SystemSummaryGrid','CompanySummaryGrid','AnalysisPanel',
            'HeatmapCanvas','HeatmapAxisCombo','LoadWeeklyGrid','MissingEntriesGrid',
            'MemberProjectGrid','WorkTypeKpiPanel','WorkTypeByMemberGrid','WorkTypePieCanvas',
            'CaseAnalysisGrid','OpsAnalysisGrid','AnomalyGrid','ChartCanvas','ChartAxisCombo',
            'LoadOverThresholdTxt','LoadTargetTxt','LoadRefreshBtn',
            'WorkTypeSystemFilter','WorkTypeProjectFilter'
        )
        foreach ($n in $mustExist) {
            $script:Win.FindName($n) | Should -Not -BeNullOrEmpty -Because "再編で $n が失われた"
        }
    }

    It '未入力検知はチェックグループへ移されている' {
        $script:Win.FindName('MissingTab') | Should -Not -BeNullOrEmpty
    }
}

Describe '遅延構築ビューの置き場所宣言' -Tag 'ui' {

    It 'ビューが 1 つ以上宣言されている' {
        @($script:Views).Count | Should -BeGreaterThan 0
    }

    It '各ビューが N (名前) / At (位置) / S (処理) を持つ' {
        foreach ($v in $script:Views) {
            $v.N | Should -Not -BeNullOrEmpty
            @($v.At).Count | Should -BeGreaterThan 0 -Because "$($v.N) に位置指定がない"
            $v.S | Should -BeOfType [scriptblock] -Because "$($v.N) の処理"
        }
    }

    It '全ビューの位置キーが XAML に実在するタブを指している' {
        # ここが落ちるときはタブを足し引きして index がずれている。
        # 放置すると「そのタブを開いても白いまま」になる。
        foreach ($v in $script:Views) {
            foreach ($k in @($v.At)) {
                $script:ValidKeys -contains $k | Should -BeTrue `
                    -Because "$($v.N) の位置 '$k' に対応するタブが XAML に無い (有効: $($script:ValidKeys -join ', '))"
            }
        }
    }

    It 'ビュー名が重複していない (dirty フラグが衝突する)' {
        $names = @($script:Views | ForEach-Object { $_.N })
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }
}
