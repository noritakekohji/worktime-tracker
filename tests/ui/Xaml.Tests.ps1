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
        foreach ($m in ([regex]::Matches($content, "foreach\s*\(\s*\`$n\s+in\s+@\(([^)]+)\)", [System.Text.RegularExpressions.RegexOptions]::Singleline))) {
            $list = $m.Groups[1].Value
            foreach ($it in ([regex]::Matches($list, "'([^']+)'"))) {
                [void]$names.Add($it.Groups[1].Value)
            }
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
}
