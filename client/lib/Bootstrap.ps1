# Bootstrap.ps1 — 共通初期化ロジック
#
# WorkTimeTracker / WbsInput / ReportViewer の重複初期化コードを集約。
# 単発初期化用 (再試行ループなし) の Initialize-DataContext を提供する。
#
# 戻り値: ハッシュテーブル
#   @{ Config; Token; Source; Members; Projects; Categories; TaskPatterns; CurrentMember }
# 失敗時は $null を返す。エラーは MessageBox で通知。

# 依存: Config.ps1 / Credential.ps1 / GitLab.ps1 / DataStore.ps1 が事前に dot-source されていること
# 注: Has-Role / Get-MemberRoles は DataStore.ps1 に定義済み (全画面共通利用のため)

function Initialize-DataContext {
    [CmdletBinding()]
    param(
        # 設定未完了時のメッセージ (画面名を入れると親切)
        [string]$AppName = 'WorkTime Tracker',
        # マスタ読込もここで行う (false ならスキップ)
        [bool]$LoadMasters = $true,
        # Gitlab モード時にマスタの「取得」を確認するか
        #   true (既定): Yes/No モーダルで聞く
        #   false: 何も聞かずローカルキャッシュのみ
        [bool]$PromptPull = $true
    )

    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

    $cfg = Load-Config
    if (-not (Test-ConfigComplete -Config $cfg)) {
        try {
            [System.Windows.MessageBox]::Show(
                "$AppName の初回設定が完了していません。`nWorkTimeTracker を先に起動して設定してください。",
                $AppName, 'OK', 'Warning') | Out-Null
        } catch { Write-Host "設定未完了: $AppName" -ForegroundColor Yellow }
        return $null
    }

    $token = $null
    if ($cfg.mode -eq 'gitlab') {
        try { $token = Get-GitLabToken } catch {
            try {
                [System.Windows.MessageBox]::Show("GitLab トークン取得失敗:`n$_", $AppName, 'OK', 'Error') | Out-Null
            } catch { }
            return $null
        }
    }

    $source = New-DataSource -Config $cfg -Token $token

    # Gitlab モードならマスタを「取得」(remote → local) するか確認
    if ($PromptPull -and $source.RemoteCtx) {
        $r = [System.Windows.MessageBox]::Show(
            "$AppName を起動します。`n`nGitlab からマスタを取得しますか?`n  [はい] リモートから取得 → ローカルから読込 (最新)`n  [いいえ] ローカルキャッシュから読込 (オフライン可)",
            "$AppName  起動オプション", 'YesNo', 'Question')
        if ($r -eq 'Yes') {
            try {
                $pull = Sync-Pull-Masters -Source $source
                [System.Windows.MessageBox]::Show(
                    ("マスタ取得完了: pulled={0} missing={1} errors={2}" -f $pull.Pulled, $pull.Missing, $pull.Errors.Count),
                    $AppName, 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show(
                    "マスタ取得失敗 (ローカルキャッシュで続行):`n$($_.Exception.Message)",
                    $AppName, 'OK', 'Warning') | Out-Null
            }
        }
    }

    $result = @{
        Config        = $cfg
        Token         = $token
        Source        = $source
        Members       = $null
        Projects      = $null
        Categories    = $null
        TaskPatterns  = $null
        Holidays      = $null
        CurrentMember = $null
    }

    if ($LoadMasters) {
        try {
            $result.Members      = @(Get-MasterMembers      -Source $source)
            $result.Projects     = @(Get-MasterProjects     -Source $source)
            $result.Categories   = @(Get-MasterCategories   -Source $source)
            $result.TaskPatterns = @(Get-MasterTaskPatterns -Source $source)
            $result.Holidays     = @(Get-MasterHolidays     -Source $source)
        } catch {
            try {
                [System.Windows.MessageBox]::Show("マスタ読込失敗:`n$_", $AppName, 'OK', 'Error') | Out-Null
            } catch { }
            return $null
        }

        # 現在ログイン中メンバーを解決
        $result.CurrentMember = $result.Members | Where-Object {
            $_.id -eq $cfg.member_id -and $_.active
        } | Select-Object -First 1
    }

    return $result
}

# 共通: マスタだけ再読込 (返り値は読み直したマスタ郡)
function Reload-MasterContext {
    param([Parameter(Mandatory)]$Source)
    return @{
        Members      = @(Get-MasterMembers      -Source $Source)
        Projects     = @(Get-MasterProjects     -Source $Source)
        Categories   = @(Get-MasterCategories   -Source $Source)
        TaskPatterns = @(Get-MasterTaskPatterns -Source $Source)
        Holidays     = @(Get-MasterHolidays     -Source $Source)
    }
}
