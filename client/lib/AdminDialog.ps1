# AdminDialog.ps1 — マスタ JSON を直接編集するエディタ

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
    foreach ($n in 'TargetCombo','ReloadBtn','ValidateBtn','SaveBtn','CancelBtn','JsonBox','StatusText') {
        $u[$n] = $win.FindName($n)
    }

    function _RelPath([string]$target) { "master/$target.json" }

    function _Load {
        $target = $u.TargetCombo.SelectedItem.Content
        try {
            $raw = Get-DataFile -Source $Source -RelPath (_RelPath $target)
            if (-not $raw) { $raw = '[]' }
            $u.JsonBox.Text = $raw
            $u.StatusText.Text = "読込: $target ($(($raw -split "`n").Count) 行)"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } catch {
            $u.JsonBox.Text = ''
            $u.StatusText.Text = "読込失敗: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
        }
    }

    function _Validate {
        try {
            $null = $u.JsonBox.Text | ConvertFrom-Json
            $u.StatusText.Text = 'JSON OK'
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
            return $true
        } catch {
            $u.StatusText.Text = "JSON 構文エラー: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
            return $false
        }
    }

    $u.TargetCombo.Add_SelectionChanged({ _Load })
    $u.ReloadBtn.Add_Click({ _Load })
    $u.ValidateBtn.Add_Click({ [void](_Validate) })

    $u.SaveBtn.Add_Click({
        if (-not (_Validate)) { return }
        $target = $u.TargetCombo.SelectedItem.Content
        try {
            Set-DataFile -Source $Source -RelPath (_RelPath $target) `
                         -Content $u.JsonBox.Text `
                         -CommitMessage "update master: $target" `
                         -AuthorName $MemberName -AuthorEmail "$MemberId@worktime-tracker.local"
            $u.StatusText.Text = "保存しました: $target"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::LightGreen
        } catch {
            $u.StatusText.Text = "保存失敗: $_"
            $u.StatusText.Foreground = [System.Windows.Media.Brushes]::Salmon
        }
    })

    $u.CancelBtn.Add_Click({ $win.Close() })

    _Load
    [void]$win.ShowDialog()
}
