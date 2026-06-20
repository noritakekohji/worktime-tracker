# ConfigDialog.ps1 — 初回設定/設定変更ダイアログ
#
# モード:
#   local  : スタンドアローン (ローカル保管のみ)
#   gitlab : Gitlab モード (ローカル保管 + 送信ボタンで Gitlab に同期)
#
# ModeCombo.SelectedItem.Tag が config.mode に対応 ('local'/'gitlab')

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
                   'LocalRootBox','BrowseBtn','LogDirBox','BrowseLogBtn') {
        $u[$n] = $win.FindName($n)
    }

    # 現在値で初期化
    $u.UrlBox.Text       = $Config.gitlab_url
    $u.BranchBox.Text    = $Config.branch
    $u.MemberIdBox.Text  = if ($Config.member_id) { $Config.member_id } else { $env:USERNAME }
    $u.LocalRootBox.Text = if ($Config.local_store) { $Config.local_store } else { (Get-DefaultLocalStore) }
    $u.LogDirBox.Text    = if ($Config.PSObject.Properties['log_dir']) { $Config.log_dir } else { '' }
    $u.ProjectIdBox.Text = [string]$Config.project_id

    $modeWanted = if ($Config.mode -and ($Config.mode -eq 'gitlab')) { 'gitlab' } else { 'local' }
    foreach ($i in $u.ModeCombo.Items) {
        if ([string]$i.Tag -eq $modeWanted) { $u.ModeCombo.SelectedItem = $i; break }
    }

    if (Test-GitLabTokenStored) {
        $u.TokenBox.Password = ''
        $u.StatusText.Text = '(既存トークンを保管中。変更する場合のみ入力)'
        $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Gray
    }

    function _GetMode {
        $sel = $u.ModeCombo.SelectedItem
        if ($sel) { return [string]$sel.Tag } else { return 'local' }
    }

    function _SetVis {
        $mode = _GetMode
        $remote = ($mode -eq 'gitlab')
        $vRemote = if ($remote) { 'Visible' } else { 'Collapsed' }

        $u.UrlLabel.Visibility       = $vRemote
        $win.FindName('UrlBox').Visibility = $vRemote

        $u.ProjectIdLabel.Visibility = $vRemote
        $win.FindName('ProjectIdBox').Visibility = $vRemote
        $u.ProjectIdHint.Visibility  = $vRemote
        $u.BranchLabel.Visibility    = $vRemote
        $win.FindName('BranchBox').Visibility = $vRemote
        $u.TokenLabel.Visibility     = $vRemote
        $win.FindName('TokenBox').Visibility  = $vRemote
        $u.TokenHint.Visibility      = $vRemote
        $u.TestBtn.Visibility        = $vRemote

        if ($remote) {
            $u.ProjectIdLabel.Content = 'Project ID / Path:'
            $u.ProjectIdHint.Text     = '数値 ID (例: 12345) または "group/subgroup/project"'
            $u.TokenHint.Text         = 'Gitlab Project Access Token (api, write_repository)。DPAPI 暗号化保管。'
        }
    }
    _SetVis
    $u.ModeCombo.Add_SelectionChanged({ _SetVis })

    $u.BrowseBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'ローカル保管先 (master/ と data/ を作成)'
        if ($u.LocalRootBox.Text -and (Test-Path -LiteralPath $u.LocalRootBox.Text)) {
            $dlg.SelectedPath = $u.LocalRootBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $u.LocalRootBox.Text = $dlg.SelectedPath
        }
    })

    $u.BrowseLogBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'ログ出力先フォルダ (ブランクのとき出力なし)'
        if ($u.LogDirBox.Text -and (Test-Path -LiteralPath $u.LogDirBox.Text)) {
            $dlg.SelectedPath = $u.LogDirBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $u.LogDirBox.Text = $dlg.SelectedPath
        }
    })

    $script:Result = $false

    $u.TestBtn.Add_Click({
        $u.StatusText.Text = '接続テスト中...'
        $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Goldenrod
        try {
            $mode = _GetMode
            $tok = if ($u.TokenBox.Password) { $u.TokenBox.Password } elseif (Test-GitLabTokenStored) { Get-GitLabToken } else { '' }
            if (-not $tok) { throw 'トークン未入力' }
            if ($mode -eq 'gitlab') {
                $ctx = New-GitLabContext -BaseUrl $u.UrlBox.Text -ProjectId $u.ProjectIdBox.Text `
                                         -Branch  $u.BranchBox.Text -Token $tok
                $proj = Test-GitLabConnection -Ctx $ctx
            } else {
                throw 'スタンドアローン モードでは接続テスト不要です'
            }
            $u.StatusText.Text = "OK: $($proj.name_with_namespace) (default branch: $($proj.default_branch))"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } catch {
            $u.StatusText.Text = "失敗: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
        }
    })

    $u.SaveBtn.Add_Click({
        $missing = New-Object System.Collections.Generic.List[string]
        $mode = _GetMode
        if (-not $u.MemberIdBox.Text.Trim()) { $missing.Add('あなたの Member ID') }
        if (-not $u.LocalRootBox.Text.Trim()) {
            $missing.Add('ローカル保管先')
        }
        if ($mode -eq 'gitlab') {
            if (-not $u.UrlBox.Text.Trim())       { $missing.Add('Gitlab URL') }
            if (-not $u.ProjectIdBox.Text.Trim()) { $missing.Add('Project ID / Path') }
            if (-not $u.BranchBox.Text.Trim())    { $missing.Add('ブランチ') }
            if (-not $u.TokenBox.Password -and -not (Test-GitLabTokenStored)) { $missing.Add('Access Token') }
        }
        if ($missing.Count -gt 0) {
            $u.StatusText.Text = "未入力の項目があります: " + ($missing -join '、')
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
            return
        }
        $lr = $u.LocalRootBox.Text.Trim()
        if (-not (Test-Path -LiteralPath $lr)) {
            try { New-Item -ItemType Directory -Path $lr -Force | Out-Null }
            catch {
                $u.StatusText.Text = "ローカル保管先を作成できません: $_"
                $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
                return
            }
        }
        try {
            $Config.mode        = $mode
            $Config.branch      = $u.BranchBox.Text.Trim()
            $Config.member_id   = $u.MemberIdBox.Text.Trim()
            $Config.local_store = $lr
            $Config.log_dir     = $u.LogDirBox.Text.Trim()
            if ($mode -eq 'gitlab') {
                $Config.gitlab_url = $u.UrlBox.Text.Trim()
                $Config.project_id = $u.ProjectIdBox.Text.Trim()
            }
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
