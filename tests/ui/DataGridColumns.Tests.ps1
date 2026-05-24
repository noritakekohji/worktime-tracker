# DataGridColumns.Tests.ps1 — AutoGenerateColumns=False のグリッドは
# XAML に <DataGrid.Columns> を持つか、PS 側で .Columns.Add しているかをチェック。
# 「列定義なし + AutoGenerate=False」だと表が空になる事故を防ぐ。

BeforeAll {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent

    function _LoadXaml {
        param([string]$Rel)
        $p = Join-Path $script:RepoRoot $Rel
        [xml]$xml = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        return $xml
    }

    function _FindDataGrids {
        param($Node, [string[]]$Hits = @())
        if (-not $Node) { return ,$Hits }
        if ($Node.LocalName -eq 'DataGrid') {
            $name = $Node.Attributes['x:Name'].Value
            $auto = $Node.Attributes['AutoGenerateColumns']
            $autoVal = if ($auto) { $auto.Value } else { 'True' }   # WPF 既定 True
            $hasCols = $false
            foreach ($c in $Node.ChildNodes) {
                if ($c.LocalName -eq 'DataGrid.Columns') { $hasCols = $true; break }
            }
            $Hits += "{0}|{1}|{2}" -f $name, $autoVal, $hasCols
        }
        foreach ($child in $Node.ChildNodes) {
            if ($child.NodeType -eq 'Element') {
                $Hits = _FindDataGrids -Node $child -Hits $Hits
            }
        }
        return ,$Hits
    }

    function _PsAddsColumns {
        param([string]$GridName, [string]$PsRel)
        $p = Join-Path $script:RepoRoot $PsRel
        if (-not (Test-Path $p)) { return $false }
        $content = Get-Content -LiteralPath $p -Raw
        $gn = [regex]::Escape($GridName)
        # 1) $ui.GridName.Columns.Add / .Columns.Clear → 直接列生成
        if ($content -match ("\.{0}\.Columns\.(Add|Clear)" -f $gn)) { return $true }
        # 2) -Grid $u.GridName / $ui.GridName というパラメータ渡し
        #    (Set-PivotGrid / Build-GridColumns / _BuildWorkTypeDrillDown 等のヘルパ用。
        #     多行コマンドで間に `` バッククォート改行を挟むケースもあるため広めに許容)
        if ($content -match ("-Grid\s+\`$u[i]?\.{0}\b" -f $gn)) { return $true }
        return $false
    }
}

Describe 'DataGrid 列定義の整合性' -Tag 'ui','schema' {

    $cases = @(
        @{ Label='ReportViewer'; Xaml='reports/ReportViewer.xaml';   Ps='reports/ReportViewer.ps1' }
        @{ Label='MainWindow';   Xaml='client/MainWindow.xaml';      Ps='client/WorkTimeTracker.ps1' }
        @{ Label='WbsInput';     Xaml='client/WbsInput.xaml';        Ps='client/WbsInput.ps1' }
        @{ Label='AdminDialog';  Xaml='client/AdminDialog.xaml';     Ps='client/lib/AdminDialog.ps1' }
    )

    It '<label>: AutoGenerateColumns=False のグリッドは列定義 (XAML or PS) を持つ' -TestCases $cases {
        param($Label, $Xaml, $Ps)
        $xml = _LoadXaml $Xaml
        $hits = _FindDataGrids -Node $xml.DocumentElement
        $orphans = New-Object System.Collections.Generic.List[string]
        foreach ($h in $hits) {
            $parts = $h.Split('|')
            $name = $parts[0]; $auto = $parts[1]; $hasCols = ($parts[2] -eq 'True')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($auto -eq 'False' -and -not $hasCols) {
                if (-not (_PsAddsColumns -GridName $name -PsRel $Ps)) {
                    $orphans.Add($name)
                }
            }
        }
        if ($orphans.Count -gt 0) {
            $msg = "AutoGenerateColumns=False かつ列定義なし: " + ($orphans -join ', ')
            $orphans.Count | Should -Be 0 -Because $msg
        }
    }
}
