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
    foreach ($n in 'MemberLabel','ProjectsList','SaveBtn','CancelBtn','RecentCountCombo','InitialProjectCombo') {
        $u[$n] = $win.FindName($n)
    }
    $u.MemberLabel.Text = ("対象: {0} ({1})" -f $MemberId, $MemberName)

    # 既存設定読込
    $prefs = Get-UserPrefs -MemberId $MemberId
    $favSet = New-Object System.Collections.Generic.HashSet[string]

    # 最近の組み合わせの表示件数 (保存値が選択肢に無ければ選択肢に足して保持する)
    $countItems = New-Object System.Collections.Generic.List[object]
    foreach ($c in @(0, 3, 5, 8, 10)) {
        $label = if ($c -eq 0) { '0 (表示しない)' } else { '{0} 件' -f $c }
        $countItems.Add([pscustomobject]@{ value = $c; label = $label })
    }
    $curCount = [int]$prefs['recent_combo_count']
    if (-not ($countItems | Where-Object { $_.value -eq $curCount })) {
        $countItems.Add([pscustomobject]@{ value = $curCount; label = ('{0} 件' -f $curCount) })
    }
    $u.RecentCountCombo.DisplayMemberPath = 'label'
    $u.RecentCountCombo.SelectedValuePath = 'value'
    $u.RecentCountCombo.ItemsSource = $countItems
    $u.RecentCountCombo.SelectedValue = $curCount

    # 初期プロジェクト: (なし) + 有効なプロジェクト。無効化済みのプロジェクトが設定されていれば、それも残して見せる
    $initItems = New-Object System.Collections.Generic.List[object]
    $initItems.Add([pscustomobject]@{ value = ''; label = '(なし)' })
    $curInit = [string]$prefs['initial_project']
    foreach ($p in @($Projects)) {
        if (-not $p.unit_code) { continue }
        $uc = [string]$p.unit_code
        if (-not $p.active -and $uc -ne $curInit) { continue }
        $nm = if ($p.unit_name) { [string]$p.unit_name } else { [string]$p.project_name }
        $suffix = if ($p.active) { '' } else { ' (無効)' }
        $initItems.Add([pscustomobject]@{ value = $uc; label = ('[{0}] {1}{2}' -f $uc, $nm, $suffix) })
    }
    $u.InitialProjectCombo.DisplayMemberPath = 'label'
    $u.InitialProjectCombo.SelectedValuePath = 'value'
    $u.InitialProjectCombo.ItemsSource = $initItems
    $u.InitialProjectCombo.SelectedValue = $curInit
    if ($null -eq $u.InitialProjectCombo.SelectedItem) { $u.InitialProjectCombo.SelectedIndex = 0 }
    foreach ($p in @($prefs.favorite_projects)) {
        if ($p) { [void]$favSet.Add([string]$p) }
    }

    # 既定 (ユニット別デフォルト) の登録状況。解除は保存時にまとめて反映する
    $unitDefaults = $prefs['unit_defaults']
    $removeSet = New-Object System.Collections.Generic.HashSet[string]

    # 行 = お気に入り CheckBox + (既定があれば) 解除ボタン
    $cbList = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Projects)) {
        if (-not $p.unit_code) { continue }
        $uc = [string]$p.unit_code
        $row = New-Object System.Windows.Controls.DockPanel
        $row.LastChildFill = $true
        $cb = New-Object System.Windows.Controls.CheckBox
        $projectDisplay = if ($p.unit_name) { [string]$p.unit_name } else { [string]$p.project_name }
        $unitDisplay = if ($p.unit_name) { "($($p.project_name))" } else { '' }
        $mark = if ($unitDefaults.ContainsKey($uc)) { '  📌' } else { '' }
        $cb.Content = ('[{0}] {1}  {2}{3}' -f $uc, $projectDisplay, $unitDisplay, $mark)
        $cb.Tag = $uc
        $cb.IsChecked = $favSet.Contains($uc)
        if ($unitDefaults.ContainsKey($uc)) {
            $d = $unitDefaults[$uc]
            $cb.ToolTip = ("既定: 工程={0} / タスクグループ={1} / タスク={2} / カテゴリ={3} / 工数={4} / コメント={5}" -f `
                $d['process_code'], $d['task_group_code'], $d['task_code'], $d['category'], $d['hours'], $d['comment'])
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = '既定を解除'
            $btn.Tag = $uc
            $btn.MinHeight = 24
            $btn.Padding = '8,0'
            $btn.FontSize = 11
            $btn.Add_Click({
                param($s, $e)
                $code = [string]$s.Tag
                if ($removeSet.Contains($code)) {
                    [void]$removeSet.Remove($code); $s.Content = '既定を解除'
                } else {
                    [void]$removeSet.Add($code); $s.Content = '解除を取消 (保存で確定)'
                }
            })
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
            [void]$row.Children.Add($btn)
        }
        [void]$row.Children.Add($cb)
        $u.ProjectsList.Items.Add($row) | Out-Null
        $cbList.Add($cb)
    }

    $script:Result = $false

    $u.SaveBtn.Add_Click({
        $favs = New-Object System.Collections.Generic.List[string]
        foreach ($cb in $cbList) {
            if ($cb.IsChecked) { $favs.Add([string]$cb.Tag) }
        }
        # 読み直してから差分だけ反映する (unit_defaults 等ほかのキーを消さない)
        $newPrefs = Get-UserPrefs -MemberId $MemberId
        $newPrefs['favorite_projects'] = $favs.ToArray()
        $newPrefs['initial_project'] = [string]$u.InitialProjectCombo.SelectedValue
        if ($null -ne $u.RecentCountCombo.SelectedValue) {
            $newPrefs['recent_combo_count'] = _NormalizeRecentComboCount $u.RecentCountCombo.SelectedValue
        }
        foreach ($code in $removeSet) { [void]$newPrefs['unit_defaults'].Remove($code) }
        Set-UserPrefs -MemberId $MemberId -Prefs $newPrefs
        $script:Result = $true
        $win.Close()
    })
    $u.CancelBtn.Add_Click({ $script:Result = $false; $win.Close() })

    [void]$win.ShowDialog()
    return $script:Result
}
