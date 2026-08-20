# Xaml.Tests.ps1 — XAML パース + PS の FindName 参照整合テスト

BeforeAll {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    Add-Type -AssemblyName PresentationCore     -ErrorAction SilentlyContinue
    Add-Type -AssemblyName WindowsBase          -ErrorAction SilentlyContinue

    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent

    function Resolve-Path-Local { param([string]$Rel) Join-Path $script:RepoRoot $Rel }

    function Get-Window {
        param([string]$Rel)
        $p = Resolve-Path-Local $Rel
        if (-not (Test-Path -LiteralPath $p)) { throw "XAML not found: $p" }
        [xml]$xaml = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        return [Windows.Markup.XamlReader]::Load($reader)
    }

    function Get-XamlNamedElements {
        param($Window)
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $stack.Push($Window)
        while ($stack.Count -gt 0) {
            $el = $stack.Pop()
            if ($null -eq $el) { continue }
            $fe = $el -as [System.Windows.FrameworkElement]
            if ($fe -and $fe.Name) { [void]$set.Add($fe.Name) }
            try {
                foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) {
                    if ($null -ne $child) { $stack.Push($child) }
                }
            } catch { }
        }
        return $set
    }

    function Get-PsFindNameReferences {
        param([string]$PsRel)
        $p = Resolve-Path-Local $PsRel
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        $content = Get-Content -LiteralPath $p -Raw
        $names = New-Object 'System.Collections.Generic.HashSet[string]'
        # 直接呼び出し FindName('x') / FindName("x")
        foreach ($m in ([regex]::Matches($content, "FindName\(\s*['""]([^'""]+)['""]\s*\)"))) {
            [void]$names.Add($m.Groups[1].Value)
        }
        # foreach ($n in @('A','B',...)) パターン
        # リスト内にコメント (括弧を含むことがある) が挟まっても最後まで拾えるよう、
        # 閉じ括弧 2 個 + ブロック開始 "{" までを非貪欲に取る
        foreach ($m in ([regex]::Matches($content, "foreach\s*\(\s*\`$n\s+in\s+@\(([\s\S]*?)\)\)\s*\{", [System.Text.RegularExpressions.RegexOptions]::Singleline))) {
            $list = $m.Groups[1].Value
            foreach ($it in ([regex]::Matches($list, "'([^']+)'"))) {
                [void]$names.Add($it.Groups[1].Value)
            }
        }
        # $names = @('A','B',...) を別行で定義し foreach で FindName するパターン (Tracker)
        foreach ($m in ([regex]::Matches($content, "\`$(?<var>\w+)\s*=\s*@\((?<list>[\s\S]*?)\r?\n\s*\)"))) {
            $var  = $m.Groups['var'].Value
            $tail = $content.Substring($m.Index + $m.Length)
            if ($tail.Length -gt 400) { $tail = $tail.Substring(0, 400) }
            # 直後に「その変数を回して FindName する」コードがある場合のみ UI 名リストとみなす
            if ($tail -notmatch 'FindName' -or $tail -notmatch [regex]::Escape('$' + $var)) { continue }
            foreach ($it in ([regex]::Matches($m.Groups['list'].Value, "'([^']+)'"))) {
                [void]$names.Add($it.Groups[1].Value)
            }
        }
        return @($names)
    }

    # $ui.XXX 形式で実際にコードが触っている UI 要素名を抜き出す。
    # FindName のリストだけ更新して本体ロジックが旧名のまま残る事故 (WbsInput 2026-08) を検出する。
    function Get-PsUiMemberReferences {
        param([string]$PsRel)
        $p = Resolve-Path-Local $PsRel
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        $content = Get-Content -LiteralPath $p -Raw
        # ハッシュテーブル自体のメンバは UI 要素ではないので除外する
        $skip = @('Keys','Values','Count','Item','Add','Remove','Clear','ContainsKey','GetEnumerator','PSObject','GetType')
        $names = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($m in ([regex]::Matches($content, '\$ui\.([A-Za-z_][A-Za-z0-9_]*)'))) {
            $n = $m.Groups[1].Value
            if ($skip -contains $n) { continue }
            [void]$names.Add($n)
        }
        return @($names)
    }
}

Describe 'XAML パース' -Tag 'ui' {

    It 'MainWindow.xaml がパース可能' {
        Get-Window 'client/MainWindow.xaml' | Should -Not -BeNullOrEmpty
    }
    It 'WbsInput.xaml がパース可能' {
        Get-Window 'client/WbsInput.xaml' | Should -Not -BeNullOrEmpty
    }
    It 'AdminDialog.xaml がパース可能' {
        Get-Window 'client/AdminDialog.xaml' | Should -Not -BeNullOrEmpty
    }
    It 'ConfigDialog.xaml がパース可能' {
        Get-Window 'client/ConfigDialog.xaml' | Should -Not -BeNullOrEmpty
    }
    It 'UserPrefsDialog.xaml がパース可能' {
        Get-Window 'client/UserPrefsDialog.xaml' | Should -Not -BeNullOrEmpty
    }
    It 'ReportViewer.xaml がパース可能' {
        Get-Window 'reports/ReportViewer.xaml' | Should -Not -BeNullOrEmpty
    }
}

Describe 'PS の FindName 参照と XAML の x:Name が整合' -Tag 'ui' {

    $cases = @(
        @{ Label='Tracker';         Xaml='client/MainWindow.xaml';      Ps='client/WorkTimeTracker.ps1' }
        @{ Label='WbsInput';        Xaml='client/WbsInput.xaml';        Ps='client/WbsInput.ps1' }
        @{ Label='AdminDialog';     Xaml='client/AdminDialog.xaml';     Ps='client/lib/AdminDialog.ps1' }
        @{ Label='ConfigDialog';    Xaml='client/ConfigDialog.xaml';    Ps='client/lib/ConfigDialog.ps1' }
        @{ Label='UserPrefsDialog'; Xaml='client/UserPrefsDialog.xaml'; Ps='client/lib/UserPrefsDialog.ps1' }
        @{ Label='ReportViewer';    Xaml='reports/ReportViewer.xaml';   Ps='reports/ReportViewer.ps1' }
    )

    It '<label>: PS が参照する名前は全て XAML に存在' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $w = Get-Window $Xaml
        $xamlNames = Get-XamlNamedElements $w
        $psNames = Get-PsFindNameReferences $Ps
        # 1 文字の名前 (foreach 変数 $n 等) は誤検出可能性が高いので除外
        $missing = @($psNames | Where-Object { $_ -and $_ -notmatch '^\w$' -and -not $xamlNames.Contains($_) })
        $missing | Should -Be @() -Because ("$Label : XAML に存在しない名前を PS が参照しています: " + ($missing -join ', '))
    }

    # FindName リストだけ直して本体ロジックが旧名のままだと $ui.XXX が $null になり、
    # 起動直後に「null 値の式ではメソッドを呼び出せません」で落ちる。
    It '<label>: $ui.XXX で触る要素は全て XAML に存在' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $w = Get-Window $Xaml
        $xamlNames = Get-XamlNamedElements $w
        $uiNames = Get-PsUiMemberReferences $Ps
        $missing = @($uiNames | Where-Object { -not $xamlNames.Contains($_) })
        $missing | Should -Be @() -Because ("$Label : XAML に存在しない要素を `$ui 経由で参照しています: " + ($missing -join ', '))
    }

    # 逆方向: FindName していない名前を $ui.XXX で触ると常に $null になる
    It '<label>: $ui.XXX で触る要素は全て FindName 済み' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $registered = Get-PsFindNameReferences $Ps
        $uiNames = Get-PsUiMemberReferences $Ps
        $missing = @($uiNames | Where-Object { $registered -notcontains $_ })
        $missing | Should -Be @() -Because ("$Label : FindName していない要素を `$ui 経由で参照しています: " + ($missing -join ', '))
    }
}
