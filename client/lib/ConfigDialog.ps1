# ConfigDialog.ps1 — 初回設定/設定変更ダイアログを表示
#
# 返り値: $true なら保存された / $false ならキャンセル

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Credential.ps1')
. (Join-Path $PSScriptRoot 'GitLab.ps1')

function Show-ConfigDialog {
    param([Parameter(Mandatory)]$Config)

    Add-Type -AssemblyName PresentationFramework

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConfigDialog.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $u = @{}
    foreach ($n in 'ModeCombo','UrlBox','ProjectIdBox','BranchBox','TokenBox','MemberIdBox','StatusText','TestBtn','SaveBtn','CancelBtn') {
        $u[$n] = $win.FindName($n)
    }

    # 現在値で初期化
    $u.UrlBox.Text       = $Config.gitlab_url
    $u.ProjectIdBox.Text = $Config.project_id
    $u.BranchBox.Text    = $Config.branch
    $u.MemberIdBox.Text  = $Config.member_id
    foreach ($i in $u.ModeCombo.Items) {
        if ($i.Content -eq $Config.mode) { $u.ModeCombo.SelectedItem = $i }
    }
    if (Test-GitLabTokenStored) {
        $u.TokenBox.Password = ''
        $u.StatusText.Text = '(既存トークンを保管中。変更する場合のみ入力)'
        $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Gray
    }

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
        try {
            $Config.mode       = $u.ModeCombo.SelectedItem.Content
            $Config.gitlab_url = $u.UrlBox.Text.Trim()
            $Config.project_id = $u.ProjectIdBox.Text.Trim()
            $Config.branch     = $u.BranchBox.Text.Trim()
            $Config.member_id  = $u.MemberIdBox.Text.Trim()
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
