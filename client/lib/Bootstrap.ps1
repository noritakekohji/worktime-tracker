# Bootstrap.ps1 — 共通初期化ロジック
#
# WorkTimeTracker / WbsInput / ReportViewer の重複初期化コードを集約。
# 単発初期化用 (再試行ループなし) の Initialize-DataContext を提供する。
#
# 戻り値: ハッシュテーブル
#   @{ Config; Token; Source; Members; Projects; Categories; TaskPatterns; CurrentMember }
# 失敗時は $null を返す。エラーは MessageBox で通知。

# 依存: Config.ps1 / Credential.ps1 / GitLab.ps1 / DataStore.ps1 が事前に dot-source されていること

# ---- ロール判定 (member / leader / admin の複数選択対応) ----
# 新スキーマ: members.json の各要素に "roles": ["admin","leader","member"] 配列を持つ
# 旧スキーマ: "role": "admin" / "member" の単一文字列 (後方互換で受理)
function Get-MemberRoles {
    param($Member)
    if (-not $Member) { return @() }
    if ($Member.PSObject.Properties['roles'] -and $Member.roles) {
        return @($Member.roles | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    if ($Member.PSObject.Properties['role'] -and $Member.role) {
        return @([string]$Member.role)
    }
    # 既定: member 扱い
    return @('member')
}

function Has-Role {
    param($Member, [string]$Role)
    $roles = Get-MemberRoles -Member $Member
    return ($roles -contains $Role)
}

function Initialize-DataContext {
    [CmdletBinding()]
    param(
        # 設定未完了時のメッセージ (画面名を入れると親切)
        [string]$AppName = 'WorkTime Tracker',
        # マスタ読込もここで行う (false ならスキップ)
        [bool]$LoadMasters = $true
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
