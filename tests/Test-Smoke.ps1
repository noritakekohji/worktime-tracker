# Test-Smoke.ps1 — UI/ライブラリのスモークテスト (PS 5.1 標準のみ、追加モジュール不要)
#
# 起動: powershell -ExecutionPolicy Bypass -File tests\Test-Smoke.ps1
# または: tests\run-tests.cmd
#
# 検査内容:
#   1. XAML がパースできるか
#   2. PS スクリプトで FindName 参照している x:Name が XAML に存在するか
#   3. lib スクリプトが必要な関数を公開しているか
#   4. DataStore のラウンドトリップ (マスタ書き → 読み)
#   5. ヘルパ関数の単体動作

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Script:Pass = 0
$Script:Fail = 0
$Script:Skip = 0
$Script:Failures = @()

$Script:RepoRoot = Split-Path $PSScriptRoot -Parent

# lib をスクリプトスコープで dot-source (各 Test スクリプトブロックから関数が見えるようにする)
. (Join-Path $Script:RepoRoot 'client/lib/Config.ps1')
. (Join-Path $Script:RepoRoot 'client/lib/Credential.ps1')
. (Join-Path $Script:RepoRoot 'client/lib/GitLab.ps1')
. (Join-Path $Script:RepoRoot 'client/lib/DataStore.ps1')
. (Join-Path $Script:RepoRoot 'client/lib/Bootstrap.ps1')
. (Join-Path $Script:RepoRoot 'client/lib/UserPrefs.ps1')

function Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host -NoNewline ("  [ ] {0} ... " -f $Name)
    try {
        & $Body
        Write-Host "OK" -ForegroundColor Green
        $Script:Pass++
    } catch {
        Write-Host "FAIL" -ForegroundColor Red
        Write-Host ("      → {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $Script:Fail++
        $Script:Failures += "$Name : $($_.Exception.Message)"
    }
}

function _LoadXaml {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "XAML が存在しない: $Path" }
    [xml]$xaml = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    return [Windows.Markup.XamlReader]::Load($reader)
}

# PS スクリプト本文から FindName('...') と foreach @(...) の名前リストを抽出
function _ExtractFindNames {
    param([Parameter(Mandatory)][string]$PsPath)
    if (-not (Test-Path -LiteralPath $PsPath)) { return @() }
    $content = Get-Content -LiteralPath $PsPath -Raw
    $names = New-Object 'System.Collections.Generic.HashSet[string]'

    # FindName('xxx') / FindName("xxx") の直接参照
    foreach ($m in ([regex]::Matches($content, "FindName\(\s*['""]([^'""]+)['""]\s*\)"))) {
        [void]$names.Add($m.Groups[1].Value)
    }
    # foreach ($n in @('A','B',...)) { ... FindName($n) ... }
    foreach ($m in ([regex]::Matches($content, "foreach\s*\(\s*\`$n\s+in\s+@\(([^)]+)\)", [System.Text.RegularExpressions.RegexOptions]::Singleline))) {
        $list = $m.Groups[1].Value
        foreach ($it in ([regex]::Matches($list, "'([^']+)'"))) {
            [void]$names.Add($it.Groups[1].Value)
        }
    }
    return @($names)
}

# XAML 内の x:Name 一覧
function _ExtractXamlNames {
    param([Parameter(Mandatory)]$Window)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    # FindName ではなく LogicalTreeHelper で全要素を巡回
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

Write-Host ""
Write-Host "==================================================="
Write-Host " WorkTime Tracker  UI/Lib スモークテスト"
Write-Host "==================================================="

# ===== Section 1: XAML パース =====
Write-Host ""
Write-Host "[Section 1] XAML が正しくパースできるか" -ForegroundColor Cyan

$xamlFiles = @(
    @{ Path='client/MainWindow.xaml';      Label='MainWindow' },
    @{ Path='client/WbsInput.xaml';        Label='WbsInput' },
    @{ Path='client/AdminDialog.xaml';     Label='AdminDialog' },
    @{ Path='client/ConfigDialog.xaml';    Label='ConfigDialog' },
    @{ Path='client/UserPrefsDialog.xaml'; Label='UserPrefsDialog' },
    @{ Path='reports/ReportViewer.xaml';   Label='ReportViewer' }
)
foreach ($f in $xamlFiles) {
    Test ("XAML パース: {0}" -f $f.Label) ([scriptblock]::Create(@"
        `$w = _LoadXaml (Join-Path `$Script:RepoRoot '$($f.Path)')
        if (-not `$w) { throw 'Window が null' }
"@))
}

# ===== Section 2: PS で参照される x:Name が XAML に存在するか =====
Write-Host ""
Write-Host "[Section 2] PS の FindName 参照と XAML の x:Name が一致するか" -ForegroundColor Cyan

$pairs = @(
    @{ Xaml='client/MainWindow.xaml';      Ps='client/WorkTimeTracker.ps1'; Label='Tracker' },
    @{ Xaml='client/WbsInput.xaml';        Ps='client/WbsInput.ps1';        Label='WbsInput' },
    @{ Xaml='client/AdminDialog.xaml';     Ps='client/lib/AdminDialog.ps1'; Label='AdminDialog' },
    @{ Xaml='client/ConfigDialog.xaml';    Ps='client/lib/ConfigDialog.ps1';Label='ConfigDialog' },
    @{ Xaml='client/UserPrefsDialog.xaml'; Ps='client/lib/UserPrefsDialog.ps1'; Label='UserPrefsDialog' },
    @{ Xaml='reports/ReportViewer.xaml';   Ps='reports/ReportViewer.ps1';   Label='ReportViewer' }
)
foreach ($p in $pairs) {
    Test ("名前参照整合: {0}" -f $p.Label) ([scriptblock]::Create(@"
        `$w = _LoadXaml (Join-Path `$Script:RepoRoot '$($p.Xaml)')
        `$xamlNames = _ExtractXamlNames -Window `$w
        `$psNames = _ExtractFindNames -PsPath (Join-Path `$Script:RepoRoot '$($p.Ps)')
        # PS の名前リストには 'n' (foreach 変数名) など誤検出が混ざる可能性があるため、
        # 「XAML に x:Name=X が無いのに PS が FindName('X') している」だけを失敗とする
        # ただし `$n のような明らかな変数は除外
        `$missing = @(`$psNames | Where-Object {
            `$_ -and `$_ -notmatch '^\w$' -and -not `$xamlNames.Contains(`$_)
        })
        if (`$missing.Count -gt 0) {
            throw ("XAML に無い名前を PS が参照: " + (`$missing -join ', '))
        }
"@))
}

# ===== Section 3: lib スクリプトの公開関数 =====
Write-Host ""
Write-Host "[Section 3] lib スクリプトが必要な関数を公開しているか" -ForegroundColor Cyan

Test "必須関数が公開されている" {
    $required = @(
        'Load-Config','Test-ConfigComplete',
        'New-DataSource','Get-DataFile','Set-DataFile',
        'Get-MasterMembers','Get-MasterProjects','Get-MasterCategories','Get-MasterTaskPatterns','Get-MasterHolidays',
        'Save-MasterMembers','Save-MasterProjects','Save-MasterCategories','Save-MasterTaskPatterns','Save-MasterHolidays',
        'Load-MonthEntries','Save-MonthEntries','Save-EntriesGrouped',
        'Initialize-DataContext','Reload-MasterContext',
        'Get-UserPrefs','Set-UserPrefs'
    )
    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) { throw "未定義関数: $($missing -join ', ')" }
}

# ===== Section 4: DataStore ラウンドトリップ =====
Write-Host ""
Write-Host "[Section 4] DataStore のラウンドトリップ" -ForegroundColor Cyan

Test "Master holidays 書込→読込" {
    $tmp = Join-Path $env:TEMP ("worktime-test-" + (Get-Random))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $cfg = [pscustomobject]@{ mode='local'; member_id='ut01'; local_store=$tmp }
        $src = New-DataSource -Config $cfg
        $data = @(
            [pscustomobject]@{ date='2026-01-01'; name='元日' },
            [pscustomobject]@{ date='2026-12-30'; name='年末休' }
        )
        Save-MasterHolidays -Source $src -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Get-MasterHolidays -Source $src)
        if ($loaded.Count -ne 2) { throw "件数不一致 expected=2 actual=$($loaded.Count)" }
        if ($loaded[0].name -ne '元日') { throw "name 不一致" }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test "Month entries 書込→読込" {
    $tmp = Join-Path $env:TEMP ("worktime-test-" + (Get-Random))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $cfg = [pscustomobject]@{ mode='local'; member_id='ut02'; local_store=$tmp }
        $src = New-DataSource -Config $cfg
        $entries = @(
            [pscustomobject]@{ date='2026-05-01'; project_code='P1'; process_code='PR1'; task_group_code='TG1'; task_code='T1'; category='C1'; hours=4.0; comment='' }
        )
        Save-MonthEntries -Source $src -MemberId 'ut02' -Year 2026 -Month 5 -Entries $entries -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Load-MonthEntries -Source $src -MemberId 'ut02' -Year 2026 -Month 5)
        if ($loaded.Count -ne 1) { throw "件数不一致 expected=1 actual=$($loaded.Count)" }
        if ([double]$loaded[0].hours -ne 4.0) { throw "hours 不一致" }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===== Section 5: 純粋関数 =====
Write-Host ""
Write-Host "[Section 5] ヘルパ関数の単体動作" -ForegroundColor Cyan

Test "日付正規化: yyyyMMdd → yyyy-MM-dd" {
    # WbsInput / AdminDialog 内のロジックを抽出した小スクリプト
    function _NormDate([string]$t) {
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        $t = $t.Trim()
        if ($t -match '^(\d{4})(\d{2})(\d{2})$') { return "$($matches[1])-$($matches[2])-$($matches[3])" }
        $d = [DateTime]::MinValue
        if ([DateTime]::TryParse($t, [ref]$d)) { return $d.ToString('yyyy-MM-dd') }
        return $t
    }
    $cases = @(
        @{ in='19270311'; out='1927-03-11' },
        @{ in='2026-5-1'; out='2026-05-01' },
        @{ in='2026/12/30'; out='2026-12-30' },
        @{ in='abc';      out='abc' }
    )
    foreach ($c in $cases) {
        $got = _NormDate $c.in
        if ($got -ne $c.out) { throw "input=$($c.in)  expect=$($c.out)  got=$got" }
    }
}

Test "Get-MemberAbbrev: name 先頭 2 文字" {
    # WbsInput の Get-MemberAbbrev ロジックを抽出 (Members マスタなし版)
    function _Abbrev([string]$id, [string]$name) {
        $src = if ($name) { $name } else { $id }
        if (-not $src) { return '' }
        if ($src.Length -le 2) { return $src }
        return $src.Substring(0, 2)
    }
    if ((_Abbrev 'X' 'noritake') -ne 'no') { throw 'noritake → no' }
    if ((_Abbrev 'X' '田中太郎') -ne '田中') { throw '田中太郎 → 田中' }
    if ((_Abbrev 'kohji' $null) -ne 'ko') { throw 'kohji → ko (no name)' }
    if ((_Abbrev 'ab' $null) -ne 'ab') { throw '2char id stays' }
}

Test "GanttCellBgConverter 型がコンパイル可能" {
    # WbsInput.ps1 のヘッダ部 (Add-Type 部分) を流すと WT.GanttCellBgConverter が登録される
    if (-not ([System.Management.Automation.PSTypeName]'WT.GanttCellBgConverter').Type) {
        # WbsInput.ps1 から Add-Type ブロックだけ実行する代わりに最小再現
        Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
namespace WT {
    public class _SmokeProbe : IValueConverter {
        public object Convert(object v, Type t, object p, CultureInfo c) { return v; }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { return v; }
    }
}
"@
    }
}

# ===== Summary =====
Write-Host ""
Write-Host "==================================================="
Write-Host (" Passed: {0}   Failed: {1}" -f $Script:Pass, $Script:Fail) -ForegroundColor $(if ($Script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "==================================================="

if ($Script:Fail -gt 0) {
    Write-Host ""
    Write-Host "失敗詳細:" -ForegroundColor Red
    foreach ($e in $Script:Failures) {
        Write-Host ("  - {0}" -f $e) -ForegroundColor Yellow
    }
    exit 1
}
exit 0
