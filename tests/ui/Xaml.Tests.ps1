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

# 画面ごとにパレットが分岐すると「同じツールに見えない」状態に戻る。
# 背景・枠線・文字色の共通トークンは全画面で同値であることを固定する
# (アクセント色は画面を見分けるためのものなので対象外)。
Describe '共通カラートークンが全画面で一致' -Tag 'ui' {

    $tokenCases = @(
        @{ Label='Tracker';         Xaml='client/MainWindow.xaml' }
        @{ Label='WbsInput';        Xaml='client/WbsInput.xaml' }
        @{ Label='ReportViewer';    Xaml='reports/ReportViewer.xaml' }
        @{ Label='AdminDialog';     Xaml='client/AdminDialog.xaml' }
        @{ Label='UserPrefsDialog'; Xaml='client/UserPrefsDialog.xaml' }
    )

    It '<label>: Bg / Surface / Surface2 / Border / Text が共通値' -TestCases $tokenCases {
        param($Label, $Xaml)
        # Pester v5 の -TestCases It は Run フェーズで実行され、Describe 直下の
        # プレーン変数 (Discovery フェーズのみ) を参照できない。It 内で定義する。
        $expected = @{
            'Bg'       = '#f8fafc'
            'Surface'  = '#ffffff'
            'Surface2' = '#f1f5f9'
            'Border'   = '#cbd5e1'
            'Text'     = '#0f172a'
        }
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Xaml) -Raw
        $mismatch = @()
        foreach ($key in $expected.Keys) {
            $m = [regex]::Match($text, ('x:Key="{0}"\s*Color="(#[0-9a-fA-F]{{6}})"' -f [regex]::Escape($key)))
            if (-not $m.Success) { continue }   # そのトークンを持たない画面は対象外
            if ($m.Groups[1].Value.ToLower() -ne $expected[$key]) {
                $mismatch += ("{0}={1} (期待 {2})" -f $key, $m.Groups[1].Value, $expected[$key])
            }
        }
        $mismatch | Should -Be @() -Because ("$Label : 共通トークンの値が他画面と違います: " + ($mismatch -join ', '))
    }

    It '白文字ボタンの背景はコントラスト比 4.5:1 以上' {
        # WCAG AA / design-tokens.md の基準。ボタン文字は 12px 前後なので大文字例外は使えない
        function Get-Luminance {
            param([string]$Hex)
            $h = $Hex.TrimStart('#')
            # 各要素は括弧で囲む (囲まないと "x / 255.0, y" がカンマ優先で配列除算になる)
            $ch = @(
                ([Convert]::ToInt32($h.Substring(0, 2), 16) / 255.0),
                ([Convert]::ToInt32($h.Substring(2, 2), 16) / 255.0),
                ([Convert]::ToInt32($h.Substring(4, 2), 16) / 255.0)
            )
            $lin = foreach ($c in $ch) {
                if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow((($c + 0.055) / 1.055), 2.4) }
            }
            (0.2126 * $lin[0]) + (0.7152 * $lin[1]) + (0.0722 * $lin[2])
        }
        # 各画面の主ボタン (白文字) に使う色
        $primaryColors = @{
            'Tracker/WbsInput の主ボタン' = '#047857'
            'Report の主ボタン'           = '#0369a1'
            'Admin の主ボタン'            = '#be185d'
            'Tracker の警告ボタン'        = '#b45309'
            'Tracker の危険ボタン'        = '#e11d48'
        }
        $ng = @()
        foreach ($name in $primaryColors.Keys) {
            $l = Get-Luminance $primaryColors[$name]
            $ratio = (1.0 + 0.05) / ($l + 0.05)
            if ($ratio -lt 4.5) { $ng += ("{0} {1} = {2:N2}:1" -f $name, $primaryColors[$name], $ratio) }
        }
        $ng | Should -Be @() -Because ('白文字のコントラストが不足: ' + ($ng -join ', '))
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

# ボタンアイコンは Segoe MDL2 Assets (IconGlyph スタイル) に統一している。
# 絵文字は環境によって色付き/モノクロが混在するため、Content に絵文字を直書きする
# ボタンが復活していないかを回帰的に検出する (◀▶▲▼ など色のない幾何学記号は対象外)。
Describe 'ボタンアイコンは絵文字直書きに戻っていない' -Tag 'ui' {

    $iconXamlFiles = @(
        'client/MainWindow.xaml',
        'client/WbsInput.xaml',
        'reports/ReportViewer.xaml',
        'client/AdminDialog.xaml',
        'client/ConfigDialog.xaml',
        'client/UserPrefsDialog.xaml'
    )

    It '<_>: Button の Content に絵文字 (色付きピクトグラム) が直書きされていない' -TestCases ($iconXamlFiles | ForEach-Object { @{ Rel = $_ } }) {
        param($Rel)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Rel) -Raw
        $offenders = New-Object 'System.Collections.Generic.List[string]'
        foreach ($m in ([regex]::Matches($text, '<Button\b[\s\S]*?/>|<Button\b[\s\S]*?</Button>'))) {
            $cm = [regex]::Match($m.Value, 'Content="([^"]*)"')
            if (-not $cm.Success -or $cm.Groups[1].Value.Length -eq 0) { continue }
            $cp = [int][char]$cm.Groups[1].Value[0]
            # U+1F000 以上、または装飾用記号 (Dingbats/Misc Symbols 0x2190-0x2BFF) は
            # 色付きピクトグラムとして絵文字フォント任せになりやすいため対象。
            # 幾何学図形 (▲▼◀▶ = U+25xx) は元々モノクロなので対象外。
            if ($cp -ge 0x1F000 -or ($cp -ge 0x2190 -and $cp -le 0x2BFF -and $cp -notin 0x25A0..0x25FF)) {
                $offenders.Add($cm.Groups[1].Value)
            }
        }
        $offenders | Should -Be @() -Because ("$Rel : Content に絵文字が直書きされたボタンがあります (IconGlyph 化してください): " + ($offenders -join ', '))
    }

    It '<_>: IconGlyph スタイルが定義されている' -TestCases ($iconXamlFiles | ForEach-Object { @{ Rel = $_ } }) {
        param($Rel)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Rel) -Raw
        $text | Should -Match 'x:Key="IconGlyph"' -Because "$Rel : ボタンアイコン用の共通スタイルが見つかりません"
        $text | Should -Match 'FontFamily.*Segoe MDL2 Assets' -Because "$Rel : IconGlyph は Segoe MDL2 Assets を使う想定です"
    }
}

# フォントサイズは 11 (補助) / 13 (本文) / 16 (見出し) の 3 段階 + アイコングリフ専用の 14px
# だけに絞っている。新しいサイズが無秩序に増えるのを防ぐ回帰テスト。
Describe 'フォントサイズが規定の段階に収まっている' -Tag 'ui' {

    $sizeXamlFiles = @(
        'client/MainWindow.xaml',
        'client/WbsInput.xaml',
        'reports/ReportViewer.xaml',
        'client/AdminDialog.xaml',
        'client/ConfigDialog.xaml',
        'client/UserPrefsDialog.xaml'
    )
    It '<_>: FontSize が 11/13/14(アイコン)/16/22 以外を使っていない' -TestCases ($sizeXamlFiles | ForEach-Object { @{ Rel = $_ } }) {
        param($Rel)
        # Pester v5 の -TestCases It は Run フェーズで実行され、Describe 直下の
        # プレーン変数 (Discovery フェーズのみ) を参照できない。It 内で定義する。
        # 22 はダッシュボード KPI 数値など、コード側 (ReportViewer.ps1) で動的生成する
        # 強調表示専用の最上位ティア。XAML には現れない想定だが許容はしておく。
        $allowed = @(11, 13, 14, 16, 22)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Rel) -Raw
        $sizes = @([regex]::Matches($text, 'FontSize="(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
        $unexpected = @($sizes | Where-Object { $allowed -notcontains $_ })
        $unexpected | Should -Be @() -Because ("$Rel : 想定外の FontSize があります (11/13/16 いずれかに寄せてください): " + ($unexpected -join ', '))
    }
}

# Start-AppScreen (Bootstrap.ps1) を使う画面遷移ボタンが実際に動くための前提条件。
# WorkTimeTracker.ps1 だけ Bootstrap.ps1 の dot-source が漏れていたため、
# WBS入力/レポートへの画面遷移ボタンが「用語 'Start-AppScreen' は認識されません」で
# 実行時エラーになっていた (2026-08-22)。$ui.XXX テストと違い、これは「呼び出す関数が
# そもそもロードされているか」を静的に確認する。
Describe 'Start-AppScreen を呼ぶ画面は Bootstrap.ps1 を dot-source している' -Tag 'ui' {

    $screenCases = @(
        @{ Label='Tracker';      Ps='client/WorkTimeTracker.ps1' }
        @{ Label='WbsInput';     Ps='client/WbsInput.ps1' }
        @{ Label='ReportViewer'; Ps='reports/ReportViewer.ps1' }
    )

    It '<label>: Start-AppScreen を呼んでいれば Bootstrap.ps1 も dot-source している' -TestCases $screenCases {
        param($Label, $Ps)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Ps) -Raw
        if ($text -notmatch 'Start-AppScreen') { return }   # このスクリーン移動を実装していないなら対象外
        $text | Should -Match "\. \(Join-Path \`$libDir 'Bootstrap\.ps1'\)" `
            -Because "$Label : Start-AppScreen を呼んでいるのに Bootstrap.ps1 を dot-source していません (実行時に「用語が認識されません」で落ちます)"
    }
}

# WPF の Opacity は子要素 (テキスト含む) に多重にカスケードするため、
# ControlTemplate の disabled トリガーで Border.Opacity を下げると、背景色によっては
# ボタンが背景に溶けて見えなくなる (WbsInput の「送信」ボタンでコントラスト比 1.5:1 まで
# 低下していた実例あり)。無効時は明示的な色 (#f1f5f9/#94a3b8 など) を指定する方式に統一する。
Describe '無効ボタンの見た目は Opacity ではなく明示色で表現している' -Tag 'ui' {

    $paletteXamlFiles = @(
        'client/MainWindow.xaml',
        'client/WbsInput.xaml',
        'reports/ReportViewer.xaml',
        'client/AdminDialog.xaml',
        'client/ConfigDialog.xaml',
        'client/UserPrefsDialog.xaml'
    )

    It '<_>: IsEnabled=False トリガーが Opacity を使っていない' -TestCases ($paletteXamlFiles | ForEach-Object { @{ Rel = $_ } }) {
        param($Rel)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Rel) -Raw
        $offenders = New-Object 'System.Collections.Generic.List[string]'
        foreach ($m in ([regex]::Matches($text, '<Trigger Property="IsEnabled" Value="False">[\s\S]{0,150}?</Trigger>'))) {
            if ($m.Value -match 'Property="Opacity"') { $offenders.Add($m.Value) }
        }
        $offenders.Count | Should -Be 0 -Because "$Rel : IsEnabled=False で Opacity を使っている箇所があります (背景に溶けて見えなくなる)"
    }
}

# E950 は Segoe MDL2 Assets では「チップ/回路基板」のような見た目で、
# 「Tools (レンチ)」を意図した用途 (管理者ボタン等) には向かない。
# 正しいレンチのグリフは E90F (Repair)。誤ったグリフの再導入を防ぐ。
Describe 'アイコングリフの既知の誤用が復活していない' -Tag 'ui' {

    $iconXamlFiles = @(
        'client/MainWindow.xaml',
        'client/WbsInput.xaml',
        'reports/ReportViewer.xaml',
        'client/AdminDialog.xaml',
        'client/ConfigDialog.xaml',
        'client/UserPrefsDialog.xaml'
    )

    It '<_>: E950 (チップに見える誤字) が使われていない' -TestCases ($iconXamlFiles | ForEach-Object { @{ Rel = $_ } }) {
        param($Rel)
        $text = Get-Content -LiteralPath (Resolve-Path-Local $Rel) -Raw
        $text | Should -Not -Match '&#xE950;' -Because "$Rel : E950 は Segoe MDL2 Assets で「チップ」に見えるグリフです。管理者/ツール用途には E90F (Repair=レンチ) を使ってください"
    }
}
