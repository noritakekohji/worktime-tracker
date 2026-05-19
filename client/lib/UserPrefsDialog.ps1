# UserPrefsDialog.ps1 — 個人設定ダイアログ
#
# 引数: MemberId, MemberName, Projects (master projects array)
# 戻り値: 保存されれば $true / キャンセル $false

. (Join-Path $PSScriptRoot 'UserPrefs.ps1')

function Show-UserPrefsDialog {
    param(
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][string]$MemberName,
        [Parameter(Mandatory)]$Projects
    )

    Add-Type -AssemblyName PresentationFramework

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'UserPrefsDialog.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $u = @{}
    foreach ($n in 'MemberLabel','ProjectsList','SaveBtn','CancelBtn') {
        $u[$n] = $win.FindName($n)
    }
    $u.MemberLabel.Text = ("対象: {0} ({1})" -f $MemberId, $MemberName)

    # 既存設定読込
    $prefs = Get-UserPrefs -MemberId $MemberId
    $favSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in @($prefs.favorite_projects)) {
        if ($p) { [void]$favSet.Add([string]$p) }
    }

    # CheckBox 一覧構築
    $cbList = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Projects)) {
        if (-not $p.unit_code) { continue }
        $uc = [string]$p.unit_code
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = ('[{0}] {1}  {2}' -f $uc, $p.project_name, $(if ($p.unit_name) { "($($p.unit_name))" } else { '' }))
        $cb.Tag = $uc
        $cb.IsChecked = $favSet.Contains($uc)
        $u.ProjectsList.Items.Add($cb) | Out-Null
        $cbList.Add($cb)
    }

    $script:Result = $false

    $u.SaveBtn.Add_Click({
        $favs = New-Object System.Collections.Generic.List[string]
        foreach ($cb in $cbList) {
            if ($cb.IsChecked) { $favs.Add([string]$cb.Tag) }
        }
        $newPrefs = @{ favorite_projects = $favs.ToArray() }
        Set-UserPrefs -MemberId $MemberId -Prefs $newPrefs
        $script:Result = $true
        $win.Close()
    })
    $u.CancelBtn.Add_Click({ $script:Result = $false; $win.Close() })

    [void]$win.ShowDialog()
    return $script:Result
}
