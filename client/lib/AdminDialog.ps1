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
                   'PatCodeBox','PatNameBox','PatHint','PatNodeAddBtn','PatNodeAddSibBtn','PatNodeDelBtn',
                   'PatNodeUpBtn','PatNodeDownBtn','PatCopyBtn',
                   'CategoriesGrid','CatAddBtn','CatDelBtn',
                   'HolidaysGrid','HolAddBtn','HolDelBtn',
                   'OtherMemberCombo','OtherYearCombo','OtherMonthCombo','OtherReloadBtn',
                   'OtherStatusText','OtherEntriesGrid','OtherAddBtn','OtherDelBtn',
                   'OtherSaveBtn','OtherPushBtn',
                   'JsonTargetCombo','JsonReloadBtn','JsonValidateBtn','JsonApplyBtn','JsonBox') {
        $u[$n] = $win.FindName($n)
    }

    $members      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $projects     = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $categories   = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $holidays     = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
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
            $holidays.Clear()
            foreach ($h in (Get-MasterHolidays -Source $Source)) {
                if (-not $h) { continue }
                $holidays.Add([pscustomobject]@{ date=[string]$h.date; name=[string]$h.name })
            }
            _Status ("メンバー={0} / プロジェクト={1} / パターン={2} / カテゴリ={3} / 休業日={4}" -f $members.Count, $projects.Count, $patterns.Count, $categories.Count, $holidays.Count) '#059669'
            # 他者データ編集タブのメンバーリストも更新
            if ($global:WT_OtherRefreshMembers) { & $global:WT_OtherRefreshMembers }
        } catch {
            _Status "読込失敗: $_" '#dc2626'
        }
    }

    $u.MembersGrid.ItemsSource    = $members
    $u.ProjectsGrid.ItemsSource   = $projects
    $u.CategoriesGrid.ItemsSource = $categories
    $u.HolidaysGrid.ItemsSource   = $holidays

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

    # ---- 休業日 ----
    $u.HolAddBtn.Add_Click({
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $holidays.Add([pscustomobject]@{ date = $today; name = '' })
    })
    $u.HolDelBtn.Add_Click({
        $sel = $u.HolidaysGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$holidays.Remove($sel)
    })

    # ---- 他者データ編集 ----
    $global:WT_OtherEntries = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $u.OtherEntriesGrid.ItemsSource = $global:WT_OtherEntries

    # メンバーコンボの ItemsSource は members コレクションに連動 (id + name 表示)
    $global:WT_OtherRefreshMembers = {
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

    # WPF イベントハンドラから内部 function が見えないため script: スコープの scriptblock に
    $global:WT_DoOStatus = {
        param([string]$Text,[string]$Color='#6b7280')
        $u.OtherStatusText.Text = $Text
        $u.OtherStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($Color)
    }.GetNewClosure()

    $global:WT_OtherReload = {
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { & $global:WT_DoOStatus 'メンバーを選択してください' '#f59e0b'; return }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        try {
            $global:WT_OtherEntries.Clear()
            $loaded = @(Load-MonthEntries -Source $Source -MemberId $mid -Year $y -Month $m)
            foreach ($e in $loaded) {
                $global:WT_OtherEntries.Add([pscustomobject]@{
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
            & $global:WT_DoOStatus ("{0} の {1}/{2} を読込 ({3} 件)" -f $mid, $y, $m, $loaded.Count) '#059669'
        } catch {
            & $global:WT_DoOStatus "読込失敗: $_" '#dc2626'
        }
    }.GetNewClosure()

    $u.OtherReloadBtn.Add_Click({ & $global:WT_OtherReload })
    $u.OtherMemberCombo.Add_SelectionChanged({ if ($u.OtherMemberCombo.SelectedValue) { & $global:WT_OtherReload } })
    $u.OtherYearCombo.Add_SelectionChanged({  if ($u.OtherMemberCombo.SelectedValue) { & $global:WT_OtherReload } })
    $u.OtherMonthCombo.Add_SelectionChanged({ if ($u.OtherMemberCombo.SelectedValue) { & $global:WT_OtherReload } })

    $u.OtherAddBtn.Add_Click({
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { return }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        $defaultDate = ('{0:D4}-{1:D2}-01' -f $y, $m)
        $global:WT_OtherEntries.Add([pscustomobject]@{
            date='' + $defaultDate; project_code=''; process_code=''; task_group_code=''; task_code=''
            category=''; hours=0.0; comment=''
        })
    })

    $u.OtherDelBtn.Add_Click({
        $sel = $u.OtherEntriesGrid.SelectedItem
        if ($null -eq $sel) { return }
        [void]$global:WT_OtherEntries.Remove($sel)
    })

    # ローカル保存 (共通ロジック)。成功で true、失敗で false
    $global:WT_OtherLocalSave = {
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { & $global:WT_DoOStatus 'メンバー未選択' '#f59e0b'; return $false }
        $y = [int]$u.OtherYearCombo.SelectedItem
        $m = [int]$u.OtherMonthCombo.SelectedItem
        try {
            $entriesArr = @($global:WT_OtherEntries | ForEach-Object {
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
            & $global:WT_DoOStatus ("ローカル保存完了 ({0} 件)" -f $entriesArr.Count) '#059669'
            return $true
        } catch {
            & $global:WT_DoOStatus "保存失敗: $_" '#dc2626'
            return $false
        }
    }.GetNewClosure()

    $u.OtherSaveBtn.Add_Click({ [void](& $global:WT_OtherLocalSave) })

    $u.OtherPushBtn.Add_Click({
        $mid = $u.OtherMemberCombo.SelectedValue
        if (-not $mid) { & $global:WT_DoOStatus 'メンバー未選択' '#f59e0b'; return }
        if (-not $Source.RemoteCtx) { & $global:WT_DoOStatus 'リモート未設定 (local モード)' '#f59e0b'; return }
        # Step 1: ローカル保存
        $ok = & $global:WT_OtherLocalSave
        if (-not $ok) { return }
        # Step 2: リモート push
        try {
            & $global:WT_DoOStatus '送信: リモートへ push 中...' '#db2777'
            $r = Sync-Push-MyData -Source $Source -MemberId $mid `
                                  -AuthorName "$MemberName (管理者)" `
                                  -AuthorEmail "$MemberId@worktime-tracker.local"
            $summary = "保存 → 送信 完了`n  push: {0}`n  競合: {1}`n  同一: {2}`n  エラー: {3}" -f $r.Pushed, $r.SkippedNewer, $r.SkippedSame, $r.Errors.Count
            & $global:WT_DoOStatus ("送信完了 push={0}" -f $r.Pushed) '#059669'
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
            & $global:WT_DoOStatus "送信失敗: $_" '#dc2626'
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
        $u.PatNodeAddSibBtn.IsEnabled = $false
        $u.PatNodeDelBtn.IsEnabled = $false
        $u.PatNodeUpBtn.IsEnabled = $false
        $u.PatNodeDownBtn.IsEnabled = $false
        $u.PatHint.Text = ''
    }

    $global:WT_CurrentPattern   = $null
    $global:WT_CurrentPatNode   = $null
    $global:WT_SuppressPatEdit  = $false

    # パターン編集モードへ右ペインを切替する共通処理 (Render-PatternTree の呼び出しは含まない)
    # GetNewClosure() クロージャからは Show-AdminDialog 内部関数が見えないため、
    # Render-PatternTree は呼び出し元の通常ハンドラ側で実行する。
    $global:WT_ShowPatternEdit = {
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { return }
        $global:WT_CurrentPattern = $sel.data
        $global:WT_SuppressPatEdit = $true
        $global:WT_CurrentPatNode = $null
        $u.PatDetailTitle.Text = '編集中: パターン'
        $u.PatKindText.Text = 'パターン'
        $u.PatCodeBox.Text = [string]$global:WT_CurrentPattern.id
        $u.PatNameBox.Text = [string]$global:WT_CurrentPattern.name
        $u.PatCodeBox.IsEnabled = $true
        $u.PatNameBox.IsEnabled = $true
        $u.PatNodeAddBtn.IsEnabled = $true
        $u.PatNodeAddSibBtn.IsEnabled = $false
        $u.PatNodeDelBtn.IsEnabled = $false
        $u.PatHint.Text = '直下に「工程」を追加できます。'
        $global:WT_SuppressPatEdit = $false
    }.GetNewClosure()

    $u.PatternsList.Add_SelectionChanged({
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { $global:WT_CurrentPattern = $null; $u.PatternTree.Items.Clear(); _ClearPatNode; return }
        & $global:WT_ShowPatternEdit
        Render-PatternTree -Pattern $global:WT_CurrentPattern
    })

    # WPF の ListBox は同じ項目を再クリックしても SelectionChanged が発火しない。
    # ツリーノード選択後にパターン一覧の同じ行を再クリックしたときを PreviewMouseDown で検出する。
    $u.PatternsList.Add_PreviewMouseDown({
        param($s, $e)
        $el = $e.OriginalSource -as [System.Windows.DependencyObject]
        while ($el -and ($el -isnot [System.Windows.Controls.ListBoxItem])) {
            $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
        }
        if (-not $el) { return }
        if ($el.DataContext -eq $u.PatternsList.SelectedItem -and $global:WT_CurrentPatNode) {
            & $global:WT_ShowPatternEdit
            Render-PatternTree -Pattern $global:WT_CurrentPattern
        }
    })

    $u.PatternTree.Add_SelectedItemChanged({
        $sel = $u.PatternTree.SelectedItem
        if (-not $sel -or -not $sel.Tag) { return }
        $global:WT_SuppressPatEdit = $true
        $global:WT_CurrentPatNode = $sel
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
        $u.PatNodeAddSibBtn.IsEnabled = $true
        $u.PatNodeUpBtn.IsEnabled   = $true
        $u.PatNodeDownBtn.IsEnabled = $true
        $u.PatHint.Text = switch ($info.kind) {
            'process'    { '直下に「タスク分類1」を追加 / 兄弟として別の「工程」を追加できます。' }
            'task_group' { '直下に「タスク分類2」を追加 / 兄弟として別の「タスク分類1」を追加できます。' }
            'task'       { '最下層。兄弟として別の「タスク分類2」を追加できます。' }
        }
        $global:WT_SuppressPatEdit = $false
    })

    # TextChanged 用ハンドラ (リスト/ツリーは再描画しない — 入力中フォーカスを保つ)
    $global:WT_ApplyPatEdit = {
        if ($global:WT_SuppressPatEdit) { return }
        $code = $u.PatCodeBox.Text.Trim()
        $name = $u.PatNameBox.Text.Trim()
        if ($global:WT_CurrentPatNode -and $global:WT_CurrentPatNode.Tag) {
            $info = $global:WT_CurrentPatNode.Tag
            $info.data.code = $code
            $info.data.name = $name
            $icon = switch ($info.kind) { 'process'{'⚙'}; 'task_group'{'🗂'}; 'task'{'•'} }
            $global:WT_CurrentPatNode.Header = ('{0} [{1}] {2}' -f $icon, $code, $name)
        } elseif ($global:WT_CurrentPattern) {
            $global:WT_CurrentPattern.id   = $code
            $global:WT_CurrentPattern.name = $name
            # 注意: 入力中は PatternsList を再描画しない (フォーカスが外れて 1 文字確定になる)
            # 表示更新はパターン切替時の Render-PatternsList で行う
            $u.PatHeader.Text = ("階層: {0}  ({1})" -f $code, $name)
        }
    }.GetNewClosure()
    $u.PatCodeBox.Add_TextChanged({ & $global:WT_ApplyPatEdit })
    $u.PatNameBox.Add_TextChanged({ & $global:WT_ApplyPatEdit })

    $u.PatAddBtn.Add_Click({
        $new = @{ id = 'NEW_PAT'; name = '新規パターン'; processes = @() }
        $patterns.Add($new)
        Render-PatternsList
        # 追加したパターンを選択
        foreach ($it in $u.PatternsList.Items) { if ($it.data -eq $new) { $u.PatternsList.SelectedItem = $it; break } }
    })
    $u.PatDelBtn.Add_Click({
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { return }
        $r = [System.Windows.MessageBox]::Show(("パターン『{0}』を削除しますか?" -f $sel.data.id), '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        [void]$patterns.Remove($sel.data)
        $global:WT_CurrentPattern = $null
        Render-PatternsList
    })

    # E3: テンプレートコピー — 選択パターンを丸ごと複製
    $u.PatCopyBtn.Add_Click({
        $sel = $u.PatternsList.SelectedItem
        if (-not $sel) { return }
        $src = $sel.data
        # 再帰でディープコピー (hashtable 化)
        $cloneNode = {
            param($Node)
            $h = @{}
            foreach ($key in @('code','name','id')) {
                if ($Node.PSObject.Properties.Match($key).Count -gt 0 -or ($Node -is [hashtable] -and $Node.ContainsKey($key))) {
                    $h[$key] = [string]$Node.$key
                }
            }
            foreach ($childKey in @('processes','task_groups','tasks')) {
                if ($Node.PSObject.Properties.Match($childKey).Count -gt 0 -or ($Node -is [hashtable] -and $Node.ContainsKey($childKey))) {
                    $children = @($Node.$childKey)
                    $newChildren = @()
                    foreach ($c in $children) {
                        if ($c) { $newChildren += & $cloneNode $c }
                    }
                    $h[$childKey] = $newChildren
                }
            }
            return $h
        }
        $copy = & $cloneNode $src
        # 新 ID/名称
        $copy.id   = ([string]$src.id) + '_COPY'
        $copy.name = ([string]$src.name) + ' (コピー)'
        $patterns.Add($copy)
        Render-PatternsList
        # 追加したパターンを選択
        foreach ($it in $u.PatternsList.Items) {
            if ($it.data -eq $copy) { $u.PatternsList.SelectedItem = $it; break }
        }
    })

    # ＋ 子を追加
    $u.PatNodeAddBtn.Add_Click({
        if (-not $global:WT_CurrentPattern) { return }
        if (-not $global:WT_CurrentPatNode) {
            # パターン直下に工程追加
            if (-not $global:WT_CurrentPattern.processes) { $global:WT_CurrentPattern.processes = @() }
            $global:WT_CurrentPattern.processes = @($global:WT_CurrentPattern.processes) + @(@{ code='NEW'; name='新規工程'; task_groups=@() })
        } else {
            $info = $global:WT_CurrentPatNode.Tag
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
        Render-PatternTree -Pattern $global:WT_CurrentPattern
    })

    # ＋ 兄弟を追加 (並行階層)
    $u.PatNodeAddSibBtn.Add_Click({
        if (-not $global:WT_CurrentPattern -or -not $global:WT_CurrentPatNode) { return }
        $info = $global:WT_CurrentPatNode.Tag
        switch ($info.kind) {
            'process' {
                # 兄弟工程 = パターン.processes に新規追加
                if (-not $global:WT_CurrentPattern.processes) { $global:WT_CurrentPattern.processes = @() }
                $global:WT_CurrentPattern.processes = @($global:WT_CurrentPattern.processes) + @(@{ code='NEW'; name='新規工程'; task_groups=@() })
            }
            'task_group' {
                # 兄弟タスクグループ = 親プロセスの task_groups に追加
                if (-not $info.parent.task_groups) { $info.parent.task_groups = @() }
                $info.parent.task_groups = @($info.parent.task_groups) + @(@{ code='NEW'; name='新規グループ'; tasks=@() })
            }
            'task' {
                # 兄弟タスク = 親グループの tasks に追加
                if (-not $info.parent.tasks) { $info.parent.tasks = @() }
                $info.parent.tasks = @($info.parent.tasks) + @(@{ code='NEW'; name='新規タスク' })
            }
        }
        Render-PatternTree -Pattern $global:WT_CurrentPattern
    })

    $u.PatNodeDelBtn.Add_Click({
        if (-not $global:WT_CurrentPatNode) { return }
        $info = $global:WT_CurrentPatNode.Tag
        $r = [System.Windows.MessageBox]::Show(("[{0}] {1} を削除しますか?" -f $info.data.code, $info.data.name), '確認', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        switch ($info.kind) {
            'process'    { $global:WT_CurrentPattern.processes = @($global:WT_CurrentPattern.processes | Where-Object { $_ -ne $info.data }) }
            'task_group' { $info.parent.task_groups = @($info.parent.task_groups | Where-Object { $_ -ne $info.data }) }
            'task'       { $info.parent.tasks      = @($info.parent.tasks      | Where-Object { $_ -ne $info.data }) }
        }
        Render-PatternTree -Pattern $global:WT_CurrentPattern
        $global:WT_CurrentPatNode = $null
        _ClearPatNode
        # パターンレベルへ戻す
        $u.PatDetailTitle.Text = '編集中: パターン'
        $u.PatKindText.Text = 'パターン'
        $u.PatCodeBox.Text = [string]$global:WT_CurrentPattern.id
        $u.PatNameBox.Text = [string]$global:WT_CurrentPattern.name
        $u.PatCodeBox.IsEnabled = $true
        $u.PatNameBox.IsEnabled = $true
        $u.PatNodeAddBtn.IsEnabled = $true
    })

    # ---- 順序入れ替え (▲ 上へ / ▼ 下へ) ----
    # GetNewClosure() のクロージャからは Show-AdminDialog 内部関数 (Render-PatternTree) が見えないため
    # データの swap だけクロージャで行い、Render は Click ハンドラから呼ぶ。
    # 戻り値: swap 成功した場合の「移動後の要素」/ 失敗時 $null
    $global:WT_SwapPatNode = {
        param([int]$Delta)   # -1=上へ, +1=下へ
        if (-not $global:WT_CurrentPatNode) { return $null }
        $info = $global:WT_CurrentPatNode.Tag
        # 親コレクションを取得
        $parentList = $null
        switch ($info.kind) {
            'process'    { $parentList = @($global:WT_CurrentPattern.processes) }
            'task_group' { $parentList = @($info.parent.task_groups) }
            'task'       { $parentList = @($info.parent.tasks) }
        }
        if (-not $parentList -or $parentList.Count -le 1) { return $null }
        # 現在 index を探す
        $idx = -1
        for ($i = 0; $i -lt $parentList.Count; $i++) {
            if ($parentList[$i] -eq $info.data) { $idx = $i; break }
        }
        if ($idx -lt 0) { return $null }
        $newIdx = $idx + $Delta
        if ($newIdx -lt 0 -or $newIdx -ge $parentList.Count) { return $null }   # 端は移動不可
        # swap
        $tmp = $parentList[$idx]
        $parentList[$idx] = $parentList[$newIdx]
        $parentList[$newIdx] = $tmp
        # 親コレクションに書き戻し
        switch ($info.kind) {
            'process'    { $global:WT_CurrentPattern.processes = @($parentList) }
            'task_group' { $info.parent.task_groups = @($parentList) }
            'task'       { $info.parent.tasks      = @($parentList) }
        }
        return $parentList[$newIdx]
    }.GetNewClosure()

    # 再描画後にツリーから対応ノードを探して選択するヘルパ (再帰)
    function _SelectPatNodeByData {
        param($Items, $TargetData)
        foreach ($it in $Items) {
            if ($it.Tag -and $it.Tag.data -eq $TargetData) {
                $it.IsSelected = $true
                $it.BringIntoView() | Out-Null
                return $true
            }
            if ($it.Items.Count -gt 0) {
                if (_SelectPatNodeByData -Items $it.Items -TargetData $TargetData) { return $true }
            }
        }
        return $false
    }

    $u.PatNodeUpBtn.Add_Click({
        $moved = & $global:WT_SwapPatNode -1
        if ($null -eq $moved) { return }
        Render-PatternTree -Pattern $global:WT_CurrentPattern
        [void](_SelectPatNodeByData -Items $u.PatternTree.Items -TargetData $moved)
    })
    $u.PatNodeDownBtn.Add_Click({
        $moved = & $global:WT_SwapPatNode 1
        if ($null -eq $moved) { return }
        Render-PatternTree -Pattern $global:WT_CurrentPattern
        [void](_SelectPatNodeByData -Items $u.PatternTree.Items -TargetData $moved)
    })

    # ---- JSON 直接編集 ----
    # WPF イベントハンドラから内部 function が見えないことがあるので script: 変数として保持
    $global:WT_DoJsonLoad = {
        $t = $u.JsonTargetCombo.SelectedItem.Content
        $data = switch ($t) {
            'members'       { @($members)    }
            'projects'      { @($projects)   }
            'task_patterns' { @($patterns)   }
            'categories'    { @($categories) }
        }
        $u.JsonBox.Text = ($data | ConvertTo-Json -Depth 10)
    }.GetNewClosure()
    $u.JsonTargetCombo.Add_SelectionChanged({ & $global:WT_DoJsonLoad })
    $u.JsonReloadBtn.Add_Click({ & $global:WT_DoJsonLoad })
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

            $where = 'holidays serialize'
            $holsOut = @($holidays | Where-Object { $_.date } | ForEach-Object {
                [ordered]@{ date = [string]$_.date; name = [string]$_.name }
            })
            $where = 'Save-MasterHolidays'
            Save-MasterHolidays -Source $Source -Data $holsOut -AuthorName $authorName -AuthorEmail $authorEmail

            # Step 2: リモート モードならリモートへも push
            if ($Source.RemoteCtx) {
                $where = 'Sync-Push-Masters'
                _Status 'リモートへ送信中...' '#db2777'
                $pushResult = Sync-Push-Masters -Source $Source -AuthorName $authorName -AuthorEmail $authorEmail
                $msg = "保存 → 送信 完了`n  ローカル保存: 4 ファイル`n  リモート push: $($pushResult.Pushed)`n  エラー: $($pushResult.Errors.Count)"
                if ($pushResult.Errors.Count -gt 0) {
                    $msg += "`n`n[リモート push エラー]`n" + (($pushResult.Errors | Select-Object -First 5) -join "`n")
                    _Status "ローカル保存完了 / リモート push 失敗" '#dc2626'
                    [System.Windows.MessageBox]::Show($msg, '送信エラー', 'OK', 'Warning') | Out-Null
                } else {
                    _Status 'ローカル保存 + リモート送信 完了。各クライアントの再読込で反映。' '#059669'
                    [System.Windows.MessageBox]::Show($msg, '完了', 'OK', 'Information') | Out-Null
                }
            } else {
                _Status 'ローカル保存完了 (local モードのためリモート送信なし)' '#059669'
                [System.Windows.MessageBox]::Show('ローカルに保存しました。`n(リモート設定がないため送信なし)', '完了', 'OK', 'Information') | Out-Null
            }
        } catch {
            $detail = "場所: $where`n`n$($_.Exception.Message)`n`n--- ScriptStackTrace ---`n$($_.ScriptStackTrace)"
            _Status "保存失敗 (詳細はダイアログ)" '#dc2626'
            [System.Windows.MessageBox]::Show($detail, 'マスタ保存失敗', 'OK', 'Error') | Out-Null
        } finally {
            $win.Cursor = $null
        }
    })

    $u.ReloadBtn.Add_Click({ Load-All; & $global:WT_DoJsonLoad })
    $u.CloseBtn.Add_Click({ $win.Close() })

    Load-All
    & $global:WT_DoJsonLoad
    [void]$win.ShowDialog()
}
