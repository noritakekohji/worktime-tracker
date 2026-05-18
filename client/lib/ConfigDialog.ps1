# ConfigDialog.ps1 — 初回設定/設定変更ダイアログ
#   - mode=gitlab: URL/ProjectId/Branch/Token を表示
#   - mode=local : データフォルダ (共有ドライブ等) を選択

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Credential.ps1')
. (Join-Path $PSScriptRoot 'GitLab.ps1')

Add-Type -AssemblyName System.Windows.Forms

function Show-ConfigDialog {
    param([Parameter(Mandatory)]$Config)

    Add-Type -AssemblyName PresentationFramework

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConfigDialog.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $u = @{}
    foreach ($n in 'ModeCombo','UrlBox','ProjectIdBox','BranchBox','TokenBox','MemberIdBox','StatusText','TestBtn','SaveBtn','CancelBtn',
                   'UrlLabel','ProjectIdLabel','ProjectIdHint','BranchLabel','TokenLabel','TokenHint',
                   'LocalRootLabel','LocalRootBox','BrowseBtn','LocalRootHint') {
        $u[$n] = $win.FindName($n)
    }

    # 現在値で初期化
    $u.UrlBox.Text       = $Config.gitlab_url
    $u.ProjectIdBox.Text = $Config.project_id
    $u.BranchBox.Text    = $Config.branch
    $u.MemberIdBox.Text  = if ($Config.member_id) { $Config.member_id } else { $env:USERNAME }
    $u.LocalRootBox.Text = $Config.local_root
    foreach ($i in $u.ModeCombo.Items) {
        if ($i.Content -eq $Config.mode) { $u.ModeCombo.SelectedItem = $i }
    }
    if (Test-GitLabTokenStored) {
        $u.TokenBox.Password = ''
        $u.StatusText.Text = '(既存トークンを保管中。変更する場合のみ入力)'
        $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Gray
    }

    function _SetVis {
        $mode = $u.ModeCombo.SelectedItem.Content
        $gl = ($mode -eq 'gitlab')
        $lo = ($mode -eq 'local')
        $vGl = if ($gl) { 'Visible' } else { 'Collapsed' }
        $vLo = if ($lo) { 'Visible' } else { 'Collapsed' }
        foreach ($n in 'UrlLabel','UrlBox','ProjectIdLabel','ProjectIdBox','ProjectIdHint','BranchLabel','BranchBox','TokenLabel','TokenBox','TokenHint','TestBtn') {
            $u[$n].Visibility = $vGl
        }
        # UrlBox/ProjectIdBox/BranchBox/TokenBox はキーに無いが個別取得済
        $win.FindName('UrlBox').Visibility        = $vGl
        $win.FindName('ProjectIdBox').Visibility  = $vGl
        $win.FindName('BranchBox').Visibility     = $vGl
        $win.FindName('TokenBox').Visibility      = $vGl
        foreach ($n in 'LocalRootLabel','LocalRootBox','BrowseBtn','LocalRootHint') {
            $u[$n].Visibility = $vLo
        }
    }
    _SetVis
    $u.ModeCombo.Add_SelectionChanged({ _SetVis })

    $u.BrowseBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'WorkTime データを保管するフォルダを選択 (共有ドライブ可)'
        if ($u.LocalRootBox.Text -and (Test-Path -LiteralPath $u.LocalRootBox.Text)) {
            $dlg.SelectedPath = $u.LocalRootBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $u.LocalRootBox.Text = $dlg.SelectedPath
        }
    })

    $script:Result = $false

    $u.TestBtn.Add_Click({
        $u.StatusText.Text = '接続テスト中...'
        $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Goldenrod
        try {
            $tok = if ($u.TokenBox.Password) { $u.TokenBox.Password } elseif (Test-GitLabTokenStored) { Get-GitLabToken } else { '' }
            if (-not $tok) { throw 'トークン未入力' }
            $ctx = New-GitLabContext -BaseUrl $u.UrlBox.Text -ProjectId $u.ProjectIdBox.Text `
                                     -Branch  $u.BranchBox.Text -Token $tok
            $proj = Test-GitLabConnection -Ctx $ctx
            $u.StatusText.Text = "OK: $($proj.name_with_namespace) (default branch: $($proj.default_branch))"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } catch {
            $u.StatusText.Text = "失敗: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
        }
    })

    $u.SaveBtn.Add_Click({
        $missing = New-Object System.Collections.Generic.List[string]
        $mode = $u.ModeCombo.SelectedItem.Content
        if (-not $u.MemberIdBox.Text.Trim()) { $missing.Add('あなたの Member ID') }
        if ($mode -eq 'gitlab') {
            if (-not $u.UrlBox.Text.Trim())       { $missing.Add('GitLab URL') }
            if (-not $u.ProjectIdBox.Text.Trim()) { $missing.Add('Project ID / Path') }
            if (-not $u.BranchBox.Text.Trim())    { $missing.Add('ブランチ') }
            if (-not $u.TokenBox.Password -and -not (Test-GitLabTokenStored)) {
                $missing.Add('Project Access Token')
            }
        } elseif ($mode -eq 'local') {
            if (-not $u.LocalRootBox.Text.Trim()) { $missing.Add('データフォルダ') }
            elseif (-not (Test-Path -LiteralPath $u.LocalRootBox.Text.Trim())) {
                $u.StatusText.Text = '指定したデータフォルダが存在しません。'
                $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
                return
            }
        }
        if ($missing.Count -gt 0) {
            $u.StatusText.Text = "未入力の項目があります: " + ($missing -join '、')
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
            return
        }
        try {
            $Config.mode       = $mode
            $Config.gitlab_url = $u.UrlBox.Text.Trim()
            $Config.project_id = $u.ProjectIdBox.Text.Trim()
            $Config.branch     = $u.BranchBox.Text.Trim()
            $Config.member_id  = $u.MemberIdBox.Text.Trim()
            $Config.local_root = $u.LocalRootBox.Text.Trim()
            Save-Config -Config $Config
            if ($u.TokenBox.Password) {
                Save-GitLabToken -Token $u.TokenBox.Password
            }
            $script:Result = $true
            $win.Close()
        } catch {
            $u.StatusText.Text = "保存失敗: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
        }
    })

    $u.CancelBtn.Add_Click({
        $script:Result = $false
        $win.Close()
    })

    [void]$win.ShowDialog()
    return $script:Result
}
