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
                   'OtherMemberCombo','OtherYearCombo','OtherMonthCombo','OtherReloadBtn',
                   'OtherStatusText','OtherEntriesGrid','OtherAddBtn','OtherDelBtn',
                   'OtherSaveBtn','OtherPushBtn',
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
                # 旧スキーマ (id/name) からのフォールバック
                $uc  = if ($p.unit_code)    { [string]$p.unit_code }    else { [string]$p.id }
                $pn  = if ($p.project_name) { [string]$p.project_name } else { [string]$p.name }
                $projects.Add([pscustomobject]@{
                    unit_code       = $uc
                    project_name    = $pn
                    unit_name       = [string]$p.unit_name
                    target_system   = [string]$p.target_system
                    work_type       = if ($p.work_type) { [string]$p.work_type } else { '案件対応' }
                    period_from     = [string]$p.period_from
                    period_to       = [string]$p.period_to
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
            # 他者データ編集タブのメンバーリストも更新
            if ($script:OtherRefreshMembers) { & $script:OtherRefreshMembers }
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
            unit_code      = ''
            project_name   = ''
            unit_name      = ''
            target_system  = ''
            work_type      = '案件対応'
            period_from    = ''
            period_to      = ''
            task_pattern_id= ''
            active         = $true
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

    # ---- 他者データ編集 ----
    $script:OtherEntries = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $u.OtherEntriesGrid.ItemsSource = $script:OtherEntries

    # メンバーコンボの ItemsSource は members コレクションに連動 (id + name 表示)
    $script:OtherRefreshMembers = {
        $items = @($members | Where-Object { $_.active } | ForEach-Object {
            [pscustomobject]@{ id = [string]$_.id; display = "$($_.id) — $($_.name)" }
        })
        $u.OtherMemberCombo.ItemsSource = $items
        if ($items.Count -gt 0) { $u.OtherMemberCombo.SelectedIndex = 0 }
    }.GetNewClosure()

    # 年月コンボ
    $now = Get-Date
    $u.OtherYearCombo.ItemsSource  = ($now.Year - 2)..($now.Year + 1)
    $u.OtherYearCombo.SelectedItem = $now.Year
    $u.OtherMonthCombo.ItemsSource = 1..12
    $u.OtherMonthCombo.SelectedItem = $now.Month

    function _OStatus { param([string]$Text,[string]$Color='#6b7280')
        $u.OtherStatusText.Text = $Text
        $u.OtherStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
    }

    $script:OtherReload = {
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { _OStatus 'メンバーを選択してください' '#f59e0b'; return }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        try {
            $script:OtherEntries.Clear()
            $loaded = @(Load-MonthEntries -Source $Source -MemberId $mid -Year $y -Month $m)
            foreach ($e in $loaded) {
                $script:OtherEntries.Add([pscustomobject]@{
                    date            = [string]$e.date
                    project_code    = [string]$e.project_code
                    process_code    = [string]$e.process_code
                    task_group_code = [string]$e.task_group_code
                    task_code       = [string]$e.task_code
                    category        = [string]$e.category
                    hours           = [double]([string]$e.hours -replace '^\s*$','0')
                    comment         = [string]$e.comment
                })
            }
            _OStatus ("{0} の {1}/{2} を読込 ({3} 件)" -f $mid, $y, $m, $loaded.Count) '#059669'
        } catch {
            _OStatus "読込失敗: $_" '#dc2626'
        }
    }.GetNewClosure()

    $u.OtherReloadBtn.Add_Click({ & $script:OtherReload })
    $u.OtherMemberCombo.Add_SelectionChanged({ if ($u.OtherMemberCombo.SelectedValue) { & $script:OtherReload } })
    $u.OtherYearCombo.Add_SelectionChanged({  if ($u.OtherMemberCombo.SelectedValue) { & $script:OtherReload } })
    $u.OtherMonthCombo.Add_SelectionChanged({ if ($u.OtherMemberCombo.SelectedValue) { & $script:OtherReload } })

    $u.OtherAddBtn.Add_Click({
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { return }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        $defaultDate = ('{0:D4}-{1:D2}-01' -f $y, $m)
        $script:OtherEntries.Add([pscustomobject]@{
            date='' + $defaultDate; project_code=''; process_code=''; task_group_code=''; task_code=''
            category=''; hours=0.0; comment=''
        })
    })

    $u.OtherDelBtn.Add_Click({
        $sel = $u.OtherEntriesGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$script:OtherEntries.Remove($sel)
    })

    $u.OtherSaveBtn.Add_Click({
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { _OStatus 'メンバー未選択' '#f59e0b'; return }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        try {
            # 配列化して date 月別グルーピングは ViewYear/ViewMonth で全置換 → 単純化
            $entriesArr = @($script:OtherEntries | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.date)) { return }
                [pscustomobject]@{
                    date            = [string]$_.date
                    project_code    = [string]$_.project_code
                    process_code    = [string]$_.process_code
                    task_group_code = [string]$_.task_group_code
                    task_code       = [string]$_.task_code
                    category        = [string]$_.category
                    hours           = [double]$_.hours
                    comment         = [string]$_.comment
                }
            })
            Save-EntriesGrouped -Source $Source -MemberId $mid `
                                -AllEntries $entriesArr -ViewYear $y -ViewMonth $m `
                                -AuthorName "$MemberName (管理者編集)" `
                                -AuthorEmail "$MemberId@worktime-tracker.local"
            _OStatus ("ローカル保存完了 ({0} 件)" -f $entriesArr.Count) '#059669'
        } catch {
            _OStatus "保存失敗: $_" '#dc2626'
        }
    })

    $u.OtherPushBtn.Add_Click({
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { _OStatus 'メンバー未選択' '#f59e0b'; return }
        if (-not $Source.RemoteCtx) { _OStatus 'リモート未設定 (local モード)' '#f59e0b'; return }
        try {
            _OStatus '送信中...' '#db2777'
            $r = Sync-Push-MyData -Source $Source -MemberId $mid `
                                  -AuthorName "$MemberName (管理者)" `
                                  -AuthorEmail "$MemberId@worktime-tracker.local"
            $summary = "送信: push={0} / 競合={1} / 同一={2} / エラー={3}" -f $r.Pushed, $r.SkippedNewer, $r.SkippedSame, $r.Errors.Count
            _OStatus $summary '#059669'
            if ($r.Conflicts.Count -gt 0 -or $r.Errors.Count -gt 0) {
                $detail = $summary + "`n`n"
                if ($r.Conflicts.Count -gt 0) {
                    $detail += "[競合 (リモート優先でスキップ)]`n" + (($r.Conflicts | ForEach-Object { "  - {0}  (local:{1} / remote:{2})" -f $_.path,$_.local_updated,$_.remote_updated }) -join "`n") + "`n`n"
                }
                if ($r.Errors.Count -gt 0) {
                    $detail += "[エラー]`n" + (($r.Errors | Select-Object -First 10) -join "`n")
                }
                [System.Windows.MessageBox]::Show($detail, '送信結果', 'OK', 'Information') | Out-Null
            } else {
                [System.Windows.MessageBox]::Show($summary, '送信完了', 'OK', 'Information') | Out-Null
            }
        } catch {
            _OStatus "送信失敗: $_" '#dc2626'
        }
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
    # WPF イベントハンドラから内部 function が見えないことがあるので script: 変数として保持
    $script:DoJsonLoad = {
        $t = $u.JsonTargetCombo.SelectedItem.Content
        $data = switch ($t) {
            'members'       { @($members)    }
            'projects'      { @($projects)   }
            'task_patterns' { @($patterns)   }
            'categories'    { @($categories) }
        }
        $u.JsonBox.Text = ($data | ConvertTo-Json -Depth 10)
    }.GetNewClosure()
    $u.JsonTargetCombo.Add_SelectionChanged({ & $script:DoJsonLoad })
    $u.JsonReloadBtn.Add_Click({ & $script:DoJsonLoad })
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
                        $uc = if ($p.unit_code) { [string]$p.unit_code } else { [string]$p.id }
                        $pn = if ($p.project_name) { [string]$p.project_name } else { [string]$p.name }
                        $projects.Add([pscustomobject]@{
                            unit_code       = $uc
                            project_name    = $pn
                            unit_name       = [string]$p.unit_name
                            target_system   = [string]$p.target_system
                            work_type       = if ($p.work_type) { [string]$p.work_type } else { '案件対応' }
                            period_from     = [string]$p.period_from
                            period_to       = [string]$p.period_to
                            task_pattern_id = [string]$p.task_pattern_id
                            active          = if ($null -ne $p.active) { [bool]$p.active } else { $true }
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

            $authorName  = [string]$MemberName
            $authorEmail = "$([string]$MemberId)@worktime-tracker.local"
            $where = 'init'

            $where = 'members serialize'
            $membersOut = @($members | ForEach-Object {
                [ordered]@{
                    id         = [string]$_.id
                    name       = [string]$_.name
                    company    = [string]$_.company
                    department = [string]$_.department
                    rank       = [string]$_.rank
                    role       = if ($_.role) { [string]$_.role } else { 'member' }
                    active     = [bool]$_.active
                }
            })
            $where = 'Save-MasterMembers'
            Save-MasterMembers -Source $Source -Data $membersOut -AuthorName $authorName -AuthorEmail $authorEmail

            $where = 'projects serialize'
            $projectsOut = @($projects | ForEach-Object {
                [ordered]@{
                    unit_code       = [string]$_.unit_code
                    project_name    = [string]$_.project_name
                    unit_name       = [string]$_.unit_name
                    target_system   = [string]$_.target_system
                    work_type       = [string]$_.work_type
                    period_from     = [string]$_.period_from
                    period_to       = [string]$_.period_to
                    task_pattern_id = [string]$_.task_pattern_id
                    active          = [bool]$_.active
                }
            })
            $where = 'Save-MasterProjects'
            Save-MasterProjects -Source $Source -Data $projectsOut -AuthorName $authorName -AuthorEmail $authorEmail

            $where = 'Save-MasterTaskPatterns'
            # @() を使うと PS 5.1 で List[object] of Hashtable が ArgumentException を出すため未ラップで渡す
            Save-MasterTaskPatterns -Source $Source -Data $patterns -AuthorName $authorName -AuthorEmail $authorEmail

            $where = 'categories serialize'
            $catsOut = @($categories | ForEach-Object {
                [ordered]@{ code = [string]$_.code; name = [string]$_.name }
            })
            $where = 'Save-MasterCategories'
            Save-MasterCategories -Source $Source -Data $catsOut -AuthorName $authorName -AuthorEmail $authorEmail

            _Status '保存完了。クライアントの再読込で反映されます。' '#059669'
            [System.Windows.MessageBox]::Show('保存しました。', '完了', 'OK', 'Information') | Out-Null
        } catch {
            $detail = "場所: $where`n`n$($_.Exception.Message)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
            _Status "保存失敗 (詳細はダイアログ)" '#dc2626'
            [System.Windows.MessageBox]::Show($detail, 'マスタ保存失敗', 'OK', 'Error') | Out-Null
        } finally {
            $win.Cursor = $null
        }
    })

    $u.ReloadBtn.Add_Click({ Load-All; & $script:DoJsonLoad })
    $u.CloseBtn.Add_Click({ $win.Close() })

    Load-All
    & $script:DoJsonLoad
    [void]$win.ShowDialog()
}
