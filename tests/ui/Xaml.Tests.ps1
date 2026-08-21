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

# local_store のパスが長いと、フッタ左のテキストが幅を食ってボタンが画面外へ押し出されていた。
# 「テキストは省略・ボタンは常に見える」を最小幅で検証する。
Describe 'フッタは長いパスでもボタンが切れない' -Tag 'ui' {

    $footerCases = @(
        @{ Label='Tracker';    Xaml='client/MainWindow.xaml';      Status='ModeText';   Buttons=@('SaveBtn','PushBtn','OpenFolderBtn') }
        @{ Label='WbsInput';   Xaml='client/WbsInput.xaml';        Status='StatusText'; Buttons=@('SaveBtn','PushBtn') }
        @{ Label='ReportViewer'; Xaml='reports/ReportViewer.xaml'; Status='StatusText'; Buttons=@('ApplyBtn','ExportBtn') }
    )

    It '<label>: 最小幅 + 長いパスでもフッタのボタンが枠内に収まる' -TestCases $footerCases {
        param($Label, $Xaml, $Status, $Buttons)
        $w = Get-Window $Xaml
        $w.WindowStyle   = 'None'
        $w.ShowInTaskbar = $false
        $w.Left = -32000
        $w.Top  = -32000
        $w.Width = if ($w.MinWidth -gt 0) { $w.MinWidth } else { 960 }
        $w.Show()
        try {
            $tb = $w.FindName($Status)
            $tb | Should -Not -BeNullOrEmpty -Because "$Label : $Status が XAML にない"
            $tb.Text = 'スタンドアローン | C:\Users\user\OneDrive - とても長い会社名 株式会社\部門共有\業務システム部\worktime-tracker\local_store\2026年度\バックアップ\store'
            $w.UpdateLayout()

            # ボタンの座標だけ見ても検出できない: レイアウト上の枠をはみ出しても
            # 座標自体は「正しい位置」を返し、実際には親 Border が描画を切り落とすため。
            # そこで「テキスト幅 + ボタン列の幅」がウインドウ幅に収まるかで判定する。
            foreach ($n in $Buttons) {
                $w.FindName($n) | Should -Not -BeNullOrEmpty -Because "$Label : $n が XAML にない"
            }
            $firstBtn = $w.FindName($Buttons[0])
            $panel = [System.Windows.Media.VisualTreeHelper]::GetParent($firstBtn)
            $used = $tb.ActualWidth + $panel.ActualWidth
            $used | Should -BeLessOrEqual $w.ActualWidth -Because (
                "$Label : フッタ左のテキスト ({0:N0}px) とボタン列 ({1:N0}px) の合計がウインドウ幅 ({2:N0}px) を超えています。" -f `
                    $tb.ActualWidth, $panel.ActualWidth, $w.ActualWidth)
        } finally {
            $w.Close()
        }
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

    # 逆方向: XAML にボタンがあるのに PS 側がその名前に一切触れていないと、
    # 押しても無反応の「飾りボタン」になる (Report のナビゲーションボタンで発生)。
    It '<label>: XAML の名前付きボタンは PS 側から参照されている' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $xamlPath = Resolve-Path-Local $Xaml
        $psPath   = Resolve-Path-Local $Ps
        if (-not (Test-Path -LiteralPath $psPath)) { Set-ItResult -Skipped -Because "$Ps がない"; return }
        $xamlText = Get-Content -LiteralPath $xamlPath -Raw
        $psText   = Get-Content -LiteralPath $psPath -Raw
        $btnNames = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($m in ([regex]::Matches($xamlText, '<Button[^>]*x:Name="([A-Za-z_][A-Za-z0-9_]*)"'))) {
            [void]$btnNames.Add($m.Groups[1].Value)
        }
        $orphans = @($btnNames | Where-Object { $psText -notmatch [regex]::Escape($_) })
        $orphans | Should -Be @() -Because ("$Label : PS 側から一度も参照されないボタン (押しても無反応): " + ($orphans -join ', '))
    }

    # FindName していない名前を $ui.XXX で触ると常に $null になる
    It '<label>: $ui.XXX で触る要素は全て FindName 済み' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $registered = Get-PsFindNameReferences $Ps
        $uiNames = Get-PsUiMemberReferences $Ps
        $missing = @($uiNames | Where-Object { $registered -notcontains $_ })
        $missing | Should -Be @() -Because ("$Label : FindName していない要素を `$ui 経由で参照しています: " + ($missing -join ', '))
    }
}
