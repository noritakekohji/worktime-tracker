# AdminDialog.ps1 — マスタ編集 (メンバー / プロジェクト 4段 / カテゴリ / JSON 直接)

. (Join-Path $PSScriptRoot 'DataStore.ps1')

function Show-AdminDialog {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$MemberId,
        [Parameter(Mandatory)][string]$MemberName
    )

    Add-Type -AssemblyName PresentationFramework

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'AdminDialog.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $u = @{}
    foreach ($n in 'StatusText','ReloadBtn','CloseBtn','SaveBtn',
                   'MembersGrid','MemAddBtn','MemDelBtn','MemRoleCol',
                   'ProjectsTree','PrjDetailTitle','PrjKindText','PrjCodeBox','PrjNameBox','PrjActiveBox','PrjHint',
                   'PrjAddRootBtn','PrjAddChildBtn','PrjDelBtn',
                   'CategoriesGrid','CatAddBtn','CatDelBtn',
                   'JsonTargetCombo','JsonReloadBtn','JsonValidateBtn','JsonApplyBtn','JsonBox') {
        $u[$n] = $win.FindName($n)
    }

    $u.MemRoleCol.ItemsSource = @('member','admin')

    $members    = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $projects   = New-Object 'System.Collections.Generic.List[object]'
    $categories = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'

    function _Status { param([string]$Text,[string]$Color='#6b7280')
        $u.StatusText.Text = $Text
        $u.StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
    }

    function _ToHash {
        param($Obj)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $Obj.Keys) { $h[$k] = _ToHash $Obj[$k] }
            return $h
        }
        if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
            return @($Obj | ForEach-Object { _ToHash $_ })
        }
        if ($Obj -is [psobject]) {
            $h = @{}
            foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = _ToHash $p.Value }
            return $h
        }
        return $Obj
    }

    function Load-All {
        try {
            _Status '読込中...' '#db2777'
            $members.Clear()
            foreach ($m in (Get-MasterMembers -Source $Source)) {
                $members.Add([pscustomobject]@{
                    id         = [string]$m.id
                    name       = [string]$m.name
                    department = [string]$m.department
                    role       = if ($m.role) { [string]$m.role } else { 'member' }
                    active     = if ($null -ne $m.active) { [bool]$m.active } else { $true }
                })
            }
            $projects.Clear()
            foreach ($p in (Get-MasterProjects -Source $Source)) {
                $projects.Add( (_ToHash $p) )
            }
            Render-Projects
            $categories.Clear()
            foreach ($c in (Get-MasterCategories -Source $Source)) {
                $categories.Add([pscustomobject]@{ code=[string]$c.code; name=[string]$c.name })
            }
            _Status ("読込: メンバー={0} / プロジェクト={1} / カテゴリ={2}" -f $members.Count, $projects.Count, $categories.Count) '#059669'
        } catch {
            _Status "読込失敗: $_" '#dc2626'
        }
    }

    $u.MembersGrid.ItemsSource    = $members
    $u.CategoriesGrid.ItemsSource = $categories

    function _NewItem { param($Header, $Kind, $Data, $Parent)
        $ti = New-Object System.Windows.Controls.TreeViewItem
        $ti.Header = $Header
        $ti.IsExpanded = $true
        $ti.Tag = [pscustomobject]@{ kind = $Kind; data = $Data; parent = $Parent }
        return $ti
    }

    function Render-Projects {
        $u.ProjectsTree.Items.Clear()
        foreach ($p in $projects) {
            $pItem = _NewItem ("📁 [{0}] {1}" -f $p.code, $p.name) 'project' $p $null
            foreach ($pr in @($p.processes)) {
                if (-not $pr) { continue }
                $prItem = _NewItem ("⚙ [{0}] {1}" -f $pr.code, $pr.name) 'process' $pr $p
                foreach ($tg in @($pr.task_groups)) {
                    if (-not $tg) { continue }
                    $tgItem = _NewItem ("🗂 [{0}] {1}" -f $tg.code, $tg.name) 'task_group' $tg $pr
                    foreach ($tk in @($tg.tasks)) {
                        if (-not $tk) { continue }
                        $tkItem = _NewItem ("• [{0}] {1}" -f $tk.code, $tk.name) 'task' $tk $tg
                        [void]$tgItem.Items.Add($tkItem)
                    }
                    [void]$prItem.Items.Add($tgItem)
                }
                [void]$pItem.Items.Add($prItem)
            }
            [void]$u.ProjectsTree.Items.Add($pItem)
        }
        _ClearPrjDetail
    }

    function _ClearPrjDetail {
        $u.PrjDetailTitle.Text = 'ノードを選択してください'
        $u.PrjKindText.Text = ''
        $u.PrjCodeBox.Text = ''
        $u.PrjNameBox.Text = ''
        $u.PrjActiveBox.IsChecked = $false
        $u.PrjActiveBox.Visibility = 'Collapsed'
        $u.PrjCodeBox.IsEnabled = $false
        $u.PrjNameBox.IsEnabled = $false
        $u.PrjActiveBox.IsEnabled = $false
        $u.PrjAddChildBtn.IsEnabled = $false
        $u.PrjDelBtn.IsEnabled = $false
        $u.PrjHint.Text = ''
    }

    $Script:CurrentNode = $null
    $u.ProjectsTree.Add_SelectedItemChanged({
        $sel = $u.ProjectsTree.SelectedItem
        if (-not $sel -or -not $sel.Tag) { _ClearPrjDetail; return }
        $Script:CurrentNode = $sel
        $info = $sel.Tag
        $kindLabel = switch ($info.kind) {
            'project'    { 'プロジェクト' }
            'process'    { '工程' }
            'task_group' { 'タスクグループ' }
            'task'       { 'タスク' }
        }
        $u.PrjDetailTitle.Text = "編集中: $kindLabel"
        $u.PrjKindText.Text = $kindLabel
        $u.PrjCodeBox.Text = [string]$info.data.code
        $u.PrjNameBox.Text = [string]$info.data.name
        $u.PrjCodeBox.IsEnabled = $true
        $u.PrjNameBox.IsEnabled = $true
        if ($info.kind -eq 'project') {
            $u.PrjActiveBox.Visibility = 'Visible'
            $u.PrjActiveBox.IsEnabled = $true
            $u.PrjActiveBox.IsChecked = [bool]$info.data.active
        } else {
            $u.PrjActiveBox.Visibility = 'Collapsed'
        }
        $u.PrjDelBtn.IsEnabled = $true
        $u.PrjAddChildBtn.IsEnabled = ($info.kind -ne 'task')
        $u.PrjHint.Text = switch ($info.kind) {
            'project'    { '直下に「工程」を追加できます。' }
            'process'    { '直下に「タスクグループ」を追加できます。' }
            'task_group' { '直下に「タスク」を追加できます。' }
            'task'       { 'これは最下層です。子を追加できません。' }
        }
    })

    function _ApplyEditToCurrent {
        if (-not $Script:CurrentNode) { return }
        $info = $Script:CurrentNode.Tag
        $info.data.code = $u.PrjCodeBox.Text.Trim()
        $info.data.name = $u.PrjNameBox.Text.Trim()
        if ($info.kind -eq 'project') {
            $info.data.active = [bool]$u.PrjActiveBox.IsChecked
        }
        $icon = switch ($info.kind) { 'project'{'📁'}; 'process'{'⚙'}; 'task_group'{'🗂'}; 'task'{'•'} }
        $Script:CurrentNode.Header = ('{0} [{1}] {2}' -f $icon, $info.data.code, $info.data.name)
    }
    $u.PrjCodeBox.Add_TextChanged({ _ApplyEditToCurrent })
    $u.PrjNameBox.Add_TextChanged({ _ApplyEditToCurrent })
    $u.PrjActiveBox.Add_Click({ _ApplyEditToCurrent })

    $u.PrjAddRootBtn.Add_Click({
        $new = @{ code = 'NEW'; name = '新規プロジェクト'; active = $true; processes = @() }
        $projects.Add($new)
        Render-Projects
        _Status 'プロジェクトを追加しました。' '#db2777'
    })

    $u.PrjAddChildBtn.Add_Click({
        if (-not $Script:CurrentNode) { return }
        $info = $Script:CurrentNode.Tag
        switch ($info.kind) {
            'project' {
                if (-not $info.data.processes) { $info.data.processes = @() }
                $info.data.processes = @($info.data.processes) + @(@{ code='NEW'; name='新規工程'; task_groups=@() })
            }
            'process' {
                if (-not $info.data.task_groups) { $info.data.task_groups = @() }
                $info.data.task_groups = @($info.data.task_groups) + @(@{ code='NEW'; name='新規TG'; tasks=@() })
            }
            'task_group' {
                if (-not $info.data.tasks) { $info.data.tasks = @() }
                $info.data.tasks = @($info.data.tasks) + @(@{ code='NEW'; name='新規タスク' })
            }
        }
        Render-Projects
        _Status '子要素を追加しました。' '#db2777'
    })

    $u.PrjDelBtn.Add_Click({
        if (-not $Script:CurrentNode) { return }
        $info = $Script:CurrentNode.Tag
        $r = [System.Windows.MessageBox]::Show(("削除しますか?`n[{0}] {1}" -f $info.data.code, $info.data.name), '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        switch ($info.kind) {
            'project'    { [void]$projects.Remove($info.data) }
            'process'    { $info.parent.processes  = @($info.parent.processes  | Where-Object { $_ -ne $info.data }) }
            'task_group' { $info.parent.task_groups = @($info.parent.task_groups | Where-Object { $_ -ne $info.data }) }
            'task'       { $info.parent.tasks      = @($info.parent.tasks      | Where-Object { $_ -ne $info.data }) }
        }
        Render-Projects
        _Status '削除しました。' '#dc2626'
    })

    $u.MemAddBtn.Add_Click({
        $members.Add([pscustomobject]@{ id=''; name=''; department=''; role='member'; active=$true })
    })
    $u.MemDelBtn.Add_Click({
        $sel = $u.MembersGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$members.Remove($sel)
    })

    $u.CatAddBtn.Add_Click({
        $categories.Add([pscustomobject]@{ code=''; name='' })
    })
    $u.CatDelBtn.Add_Click({
        $sel = $u.CategoriesGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$categories.Remove($sel)
    })

    function _JsonLoad {
        $t = $u.JsonTargetCombo.SelectedItem.Content
        $data = switch ($t) {
            'members'    { @($members)    }
            'projects'   { @($projects)   }
            'categories' { @($categories) }
        }
        $u.JsonBox.Text = ($data | ConvertTo-Json -Depth 10)
    }
    $u.JsonTargetCombo.Add_SelectionChanged({ _JsonLoad })
    $u.JsonReloadBtn.Add_Click({ _JsonLoad })
    $u.JsonValidateBtn.Add_Click({
        try { [void]($u.JsonBox.Text | ConvertFrom-Json); _Status 'JSON OK' '#059669' }
        catch { _Status "JSON 構文エラー: $_" '#dc2626' }
    })
    $u.JsonApplyBtn.Add_Click({
        $t = $u.JsonTargetCombo.SelectedItem.Content
        try {
            $parsed = $u.JsonBox.Text | ConvertFrom-Json
            switch ($t) {
                'members' {
                    $members.Clear()
                    foreach ($m in @($parsed)) {
                        $members.Add([pscustomobject]@{
                            id=[string]$m.id; name=[string]$m.name; department=[string]$m.department
                            role=if($m.role){[string]$m.role}else{'member'}
                            active=if($null -ne $m.active){[bool]$m.active}else{$true}
                        })
                    }
                }
                'projects' {
                    $projects.Clear()
                    foreach ($p in @($parsed)) { $projects.Add( (_ToHash $p) ) }
                    Render-Projects
                }
                'categories' {
                    $categories.Clear()
                    foreach ($c in @($parsed)) {
                        $categories.Add([pscustomobject]@{ code=[string]$c.code; name=[string]$c.name })
                    }
                }
            }
            _Status "$t を JSON から適用しました (保存はまだ)" '#059669'
        } catch { _Status "JSON 適用失敗: $_" '#dc2626' }
    })

    $u.SaveBtn.Add_Click({
        try {
            _Status '保存中...' '#db2777'
            $win.Cursor = [System.Windows.Input.Cursors]::Wait

            $membersOut = @($members | ForEach-Object {
                [ordered]@{ id=$_.id; name=$_.name; department=$_.department; role=$_.role; active=[bool]$_.active }
            })
            Save-MasterMembers -Source $Source -Data $membersOut -AuthorName $MemberName -AuthorEmail "$MemberId@worktime-tracker.local"

            $projectsOut = @($projects)
            Save-MasterProjects -Source $Source -Data $projectsOut -AuthorName $MemberName -AuthorEmail "$MemberId@worktime-tracker.local"

            $catsOut = @($categories | ForEach-Object { [ordered]@{ code=$_.code; name=$_.name } })
            Save-MasterCategories -Source $Source -Data $catsOut -AuthorName $MemberName -AuthorEmail "$MemberId@worktime-tracker.local"

            _Status '保存完了。クライアントの『再読込』で反映されます。' '#059669'
            [System.Windows.MessageBox]::Show('保存しました。', '完了', 'OK', 'Information') | Out-Null
        } catch {
            _Status "保存失敗: $_" '#dc2626'
            [System.Windows.MessageBox]::Show("保存失敗:`n$_", 'エラー', 'OK', 'Error') | Out-Null
        } finally {
            $win.Cursor = $null
        }
    })

    $u.ReloadBtn.Add_Click({ Load-All; _JsonLoad })
    $u.CloseBtn.Add_Click({ $win.Close() })

    Load-All
    _JsonLoad
    [void]$win.ShowDialog()
}
