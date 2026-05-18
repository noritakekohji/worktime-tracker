# AdminDialog.ps1 — マスタ編集 (新スキーマ対応)

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
                   'MembersGrid','MemAddBtn','MemDelBtn',
                   'ProjectsGrid','PrjAddBtn','PrjDelBtn',
                   'PatternsList','PatAddBtn','PatDelBtn',
                   'PatternTree','PatHeader','PatDetailTitle','PatKindText',
                   'PatCodeBox','PatNameBox','PatHint','PatNodeAddBtn','PatNodeDelBtn',
                   'CategoriesGrid','CatAddBtn','CatDelBtn',
                   'JsonTargetCombo','JsonReloadBtn','JsonValidateBtn','JsonApplyBtn','JsonBox') {
        $u[$n] = $win.FindName($n)
    }

    $members      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $projects     = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $categories   = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $patterns     = New-Object 'System.Collections.Generic.List[object]'   # hashtable list

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
                    company    = [string]$m.company
                    department = [string]$m.department
                    rank       = [string]$m.rank
                    role       = if ($m.role) { [string]$m.role } else { 'member' }
                    active     = if ($null -ne $m.active) { [bool]$m.active } else { $true }
                })
            }
            $projects.Clear()
            foreach ($p in (Get-MasterProjects -Source $Source)) {
                $projects.Add([pscustomobject]@{
                    id              = [string]$p.id
                    name            = [string]$p.name
                    target_system   = [string]$p.target_system
                    work_type       = if ($p.work_type) { [string]$p.work_type } else { '開発' }
                    task_pattern_id = [string]$p.task_pattern_id
                    active          = if ($null -ne $p.active) { [bool]$p.active } else { $true }
                })
            }
            $patterns.Clear()
            foreach ($pt in (Get-MasterTaskPatterns -Source $Source)) {
                $patterns.Add( (_ToHash $pt) )
            }
            Render-PatternsList
            $categories.Clear()
            foreach ($c in (Get-MasterCategories -Source $Source)) {
                $categories.Add([pscustomobject]@{ code=[string]$c.code; name=[string]$c.name })
            }
            _Status ("メンバー={0} / プロジェクト={1} / パターン={2} / カテゴリ={3}" -f $members.Count, $projects.Count, $patterns.Count, $categories.Count) '#059669'
        } catch {
            _Status "読込失敗: $_" '#dc2626'
        }
    }

    $u.MembersGrid.ItemsSource    = $members
    $u.ProjectsGrid.ItemsSource   = $projects
    $u.CategoriesGrid.ItemsSource = $categories

    # ---- メンバー ----
    $u.MemAddBtn.Add_Click({
        $members.Add([pscustomobject]@{ id=''; name=''; company=''; department=''; rank=''; role='member'; active=$true })
    })
    $u.MemDelBtn.Add_Click({
        $sel = $u.MembersGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$members.Remove($sel)
    })

    # ---- プロジェクト ----
    $u.PrjAddBtn.Add_Click({
        $projects.Add([pscustomobject]@{
            id=''; name=''; target_system=''; work_type='開発'; task_pattern_id=''; active=$true
        })
    })
    $u.PrjDelBtn.Add_Click({
        $sel = $u.ProjectsGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$projects.Remove($sel)
    })

    # ---- カテゴリ ----
    $u.CatAddBtn.Add_Click({
        $categories.Add([pscustomobject]@{ code=''; name='' })
    })
    $u.CatDelBtn.Add_Click({
        $sel = $u.CategoriesGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$categories.Remove($sel)
    })

    # ---- タスクパターン ----
    function Render-PatternsList {
        $items = foreach ($p in $patterns) {
            [pscustomobject]@{ data = $p; display = ("{0}  ({1})" -f $p.id, $p.name) }
        }
        $u.PatternsList.ItemsSource = @($items)
        $u.PatternTree.Items.Clear()
        $u.PatHeader.Text = '階層 (工程 > タスク分類1 > タスク分類2)'
        _ClearPatNode
    }

    function _NewItem { param($Header, $Kind, $Data, $Parent)
        $ti = New-Object System.Windows.Controls.TreeViewItem
        $ti.Header = $Header
        $ti.IsExpanded = $true
        $ti.Tag = [pscustomobject]@{ kind = $Kind; data = $Data; parent = $Parent }
        return $ti
    }

    function Render-PatternTree {
        param($Pattern)
        $u.PatternTree.Items.Clear()
        if (-not $Pattern) { return }
        $u.PatHeader.Text = ("階層: {0}  ({1})" -f $Pattern.id, $Pattern.name)
        foreach ($pr in @($Pattern.processes)) {
            if (-not $pr) { continue }
            $prItem = _NewItem ("⚙ [{0}] {1}" -f $pr.code, $pr.name) 'process' $pr $Pattern
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
            [void]$u.PatternTree.Items.Add($prItem)
        }
    }

    function _ClearPatNode {
        $u.PatDetailTitle.Text = '左で選択してください'
        $u.PatKindText.Text = ''
        $u.PatCodeBox.Text = ''
        $u.PatNameBox.Text = ''
        $u.PatCodeBox.IsEnabled = $false
        $u.PatNameBox.IsEnabled = $false
        $u.PatNodeAddBtn.IsEnabled = $false
        $u.PatNodeDelBtn.IsEnabled = $false
        $u.PatHint.Text = ''
    }

    $Script:CurrentPattern = $null
    $Script:CurrentPatNode = $null
    $Script:SuppressPatEdit = $false

    $u.PatternsList.Add_SelectionChanged({
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { $Script:CurrentPattern = $null; $u.PatternTree.Items.Clear(); return }
        $Script:CurrentPattern = $sel.data
        # パターン自体を編集できるように右ペインに反映
        $Script:SuppressPatEdit = $true
        $Script:CurrentPatNode = $null
        $u.PatDetailTitle.Text = '編集中: パターン'
        $u.PatKindText.Text = 'パターン'
        $u.PatCodeBox.Text = [string]$Script:CurrentPattern.id
        $u.PatNameBox.Text = [string]$Script:CurrentPattern.name
        $u.PatCodeBox.IsEnabled = $true
        $u.PatNameBox.IsEnabled = $true
        $u.PatNodeAddBtn.IsEnabled = $true   # 工程を追加できる
        $u.PatNodeDelBtn.IsEnabled = $false  # パターン自体は左で削除
        $u.PatHint.Text = '直下に「工程」を追加できます。'
        $Script:SuppressPatEdit = $false
        Render-PatternTree -Pattern $Script:CurrentPattern
    })

    $u.PatternTree.Add_SelectedItemChanged({
        $sel = $u.PatternTree.SelectedItem
        if (-not $sel -or -not $sel.Tag) { return }
        $Script:SuppressPatEdit = $true
        $Script:CurrentPatNode = $sel
        $info = $sel.Tag
        $kindLabel = switch ($info.kind) {
            'process'    { '工程' }
            'task_group' { 'タスク分類1 (グループ)' }
            'task'       { 'タスク分類2 (タスク)' }
        }
        $u.PatDetailTitle.Text = "編集中: $kindLabel"
        $u.PatKindText.Text = $kindLabel
        $u.PatCodeBox.Text = [string]$info.data.code
        $u.PatNameBox.Text = [string]$info.data.name
        $u.PatCodeBox.IsEnabled = $true
        $u.PatNameBox.IsEnabled = $true
        $u.PatNodeDelBtn.IsEnabled = $true
        $u.PatNodeAddBtn.IsEnabled = ($info.kind -ne 'task')
        $u.PatHint.Text = switch ($info.kind) {
            'process'    { '直下に「タスク分類1」を追加できます。' }
            'task_group' { '直下に「タスク分類2」を追加できます。' }
            'task'       { 'これは最下層です。子を追加できません。' }
        }
        $Script:SuppressPatEdit = $false
    })

    function _ApplyPatEdit {
        if ($Script:SuppressPatEdit) { return }
        $code = $u.PatCodeBox.Text.Trim()
        $name = $u.PatNameBox.Text.Trim()
        if ($Script:CurrentPatNode -and $Script:CurrentPatNode.Tag) {
            $info = $Script:CurrentPatNode.Tag
            $info.data.code = $code
            $info.data.name = $name
            $icon = switch ($info.kind) { 'process'{'⚙'}; 'task_group'{'🗂'}; 'task'{'•'} }
            $Script:CurrentPatNode.Header = ('{0} [{1}] {2}' -f $icon, $code, $name)
        } elseif ($Script:CurrentPattern) {
            $Script:CurrentPattern.id   = $code
            $Script:CurrentPattern.name = $name
            $u.PatHeader.Text = ("階層: {0}  ({1})" -f $code, $name)
            # 左ペインの表示も更新
            Render-PatternsList
            # 再選択して詳細パネルを維持
            foreach ($it in $u.PatternsList.Items) { if ($it.data -eq $Script:CurrentPattern) { $u.PatternsList.SelectedItem = $it; break } }
        }
    }
    $u.PatCodeBox.Add_TextChanged({ _ApplyPatEdit })
    $u.PatNameBox.Add_TextChanged({ _ApplyPatEdit })

    $u.PatAddBtn.Add_Click({
        $new = @{ id = 'NEW_PAT'; name = '新規パターン'; processes = @() }
        $patterns.Add($new)
        Render-PatternsList
    })
    $u.PatDelBtn.Add_Click({
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { return }
        $r = [System.Windows.MessageBox]::Show(("パターン『{0}』を削除しますか?" -f $sel.data.id), '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        [void]$patterns.Remove($sel.data)
        $Script:CurrentPattern = $null
        Render-PatternsList
    })

    $u.PatNodeAddBtn.Add_Click({
        if (-not $Script:CurrentPattern) { return }
        if (-not $Script:CurrentPatNode) {
            # パターン直下に工程追加
            if (-not $Script:CurrentPattern.processes) { $Script:CurrentPattern.processes = @() }
            $Script:CurrentPattern.processes = @($Script:CurrentPattern.processes) + @(@{ code='NEW'; name='新規工程'; task_groups=@() })
        } else {
            $info = $Script:CurrentPatNode.Tag
            switch ($info.kind) {
                'process' {
                    if (-not $info.data.task_groups) { $info.data.task_groups = @() }
                    $info.data.task_groups = @($info.data.task_groups) + @(@{ code='NEW'; name='新規グループ'; tasks=@() })
                }
                'task_group' {
                    if (-not $info.data.tasks) { $info.data.tasks = @() }
                    $info.data.tasks = @($info.data.tasks) + @(@{ code='NEW'; name='新規タスク' })
                }
            }
        }
        Render-PatternTree -Pattern $Script:CurrentPattern
    })

    $u.PatNodeDelBtn.Add_Click({
        if (-not $Script:CurrentPatNode) { return }
        $info = $Script:CurrentPatNode.Tag
        $r = [System.Windows.MessageBox]::Show(("[{0}] {1} を削除しますか?" -f $info.data.code, $info.data.name), '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        switch ($info.kind) {
            'process'    { $Script:CurrentPattern.processes = @($Script:CurrentPattern.processes | Where-Object { $_ -ne $info.data }) }
            'task_group' { $info.parent.task_groups = @($info.parent.task_groups | Where-Object { $_ -ne $info.data }) }
            'task'       { $info.parent.tasks      = @($info.parent.tasks      | Where-Object { $_ -ne $info.data }) }
        }
        Render-PatternTree -Pattern $Script:CurrentPattern
        $Script:CurrentPatNode = $null
        _ClearPatNode
        # パターンレベルへ戻す
        $u.PatDetailTitle.Text = '編集中: パターン'
        $u.PatKindText.Text = 'パターン'
        $u.PatCodeBox.Text = [string]$Script:CurrentPattern.id
        $u.PatNameBox.Text = [string]$Script:CurrentPattern.name
        $u.PatCodeBox.IsEnabled = $true
        $u.PatNameBox.IsEnabled = $true
        $u.PatNodeAddBtn.IsEnabled = $true
    })

    # ---- JSON 直接編集 ----
    function _JsonLoad {
        $t = $u.JsonTargetCombo.SelectedItem.Content
        $data = switch ($t) {
            'members'       { @($members)    }
            'projects'      { @($projects)   }
            'task_patterns' { @($patterns)   }
            'categories'    { @($categories) }
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
                            id=[string]$m.id; name=[string]$m.name; company=[string]$m.company
                            department=[string]$m.department; rank=[string]$m.rank
                            role=if($m.role){[string]$m.role}else{'member'}
                            active=if($null -ne $m.active){[bool]$m.active}else{$true}
                        })
                    }
                }
                'projects' {
                    $projects.Clear()
                    foreach ($p in @($parsed)) {
                        $projects.Add([pscustomobject]@{
                            id=[string]$p.id; name=[string]$p.name; target_system=[string]$p.target_system
                            work_type=if($p.work_type){[string]$p.work_type}else{'開発'}
                            task_pattern_id=[string]$p.task_pattern_id
                            active=if($null -ne $p.active){[bool]$p.active}else{$true}
                        })
                    }
                }
                'task_patterns' {
                    $patterns.Clear()
                    foreach ($pt in @($parsed)) { $patterns.Add( (_ToHash $pt) ) }
                    Render-PatternsList
                }
                'categories' {
                    $categories.Clear()
                    foreach ($c in @($parsed)) {
                        $categories.Add([pscustomobject]@{ code=[string]$c.code; name=[string]$c.name })
                    }
                }
            }
            _Status "$t を JSON から適用 (保存は別途)" '#059669'
        } catch { _Status "JSON 適用失敗: $_" '#dc2626' }
    })

    # ---- 保存 ----
    $u.SaveBtn.Add_Click({
        try {
            _Status '保存中...' '#db2777'
            $win.Cursor = [System.Windows.Input.Cursors]::Wait

            $author = @{ AuthorName = $MemberName; AuthorEmail = "$MemberId@worktime-tracker.local" }

            $membersOut = @($members | ForEach-Object {
                [ordered]@{ id=$_.id; name=$_.name; company=$_.company; department=$_.department; rank=$_.rank; role=$_.role; active=[bool]$_.active }
            })
            Save-MasterMembers -Source $Source -Data $membersOut @author

            $projectsOut = @($projects | ForEach-Object {
                [ordered]@{
                    id              = $_.id
                    name            = $_.name
                    target_system   = $_.target_system
                    work_type       = $_.work_type
                    task_pattern_id = $_.task_pattern_id
                    active          = [bool]$_.active
                }
            })
            Save-MasterProjects -Source $Source -Data $projectsOut @author

            Save-MasterTaskPatterns -Source $Source -Data @($patterns) @author

            $catsOut = @($categories | ForEach-Object { [ordered]@{ code=$_.code; name=$_.name } })
            Save-MasterCategories -Source $Source -Data $catsOut @author

            _Status '保存完了。クライアントの再読込で反映されます。' '#059669'
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
