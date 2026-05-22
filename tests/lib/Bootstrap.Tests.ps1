# Bootstrap.Tests.ps1 — Initialize-DataContext / Reload-MasterContext のテスト
# Mock を活用して I/O から切り離し、関数の振る舞いだけ検証する

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Bootstrap.ps1')
}

Describe 'Initialize-DataContext' -Tag 'lib','unit' {

    # 注: 設定未完了パス (Test-ConfigComplete=$false) は [System.Windows.MessageBox]::Show
    #     を呼ぶため、.NET 静的メソッドが Mock できない & UI 不在環境でブロックの恐れあり。
    #     → ヘッドレスで安全に動く成功パスのみ検証する。

    Context '設定完了かつ standalone モード' {
        BeforeEach {
            $tmp = Join-Path $env:TEMP ("worktime-bootstrap-" + (Get-Random))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $script:tmpDir = $tmp
            Mock Load-Config {
                [pscustomobject]@{ mode='local'; member_id='ut'; local_store=$script:tmpDir }
            }
            Mock Test-ConfigComplete { $true }
            # 各 Get-Master* は空 (デフォルト) を返す
            Mock Get-MasterMembers      { @() }
            Mock Get-MasterProjects     { @() }
            Mock Get-MasterCategories   { @() }
            Mock Get-MasterTaskPatterns { @() }
            Mock Get-MasterHolidays     { @() }
        }
        AfterEach { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

        It '全マスタのキーが context に存在する (空配列でも OK)' {
            $r = Initialize-DataContext -AppName 'Test'
            $r | Should -Not -BeNullOrEmpty
            $r.Config       | Should -Not -BeNullOrEmpty
            $r.Source       | Should -Not -BeNullOrEmpty
            # 空配列を BeNullOrEmpty 判定すると true になるため、キーの存在のみ検証
            $r.ContainsKey('Members')      | Should -Be $true
            $r.ContainsKey('Projects')     | Should -Be $true
            $r.ContainsKey('Categories')   | Should -Be $true
            $r.ContainsKey('TaskPatterns') | Should -Be $true
            $r.ContainsKey('Holidays')     | Should -Be $true
        }

        It 'standalone モードでは Token=$null / RemoteCtx=$null' {
            $r = Initialize-DataContext -AppName 'Test'
            $r.Token | Should -BeNullOrEmpty
            $r.Source.RemoteCtx | Should -BeNullOrEmpty
        }

        It 'CurrentMember はマスタから解決' {
            Mock Get-MasterMembers {
                @([pscustomobject]@{ id='ut'; name='テスト'; active=$true; role='member' })
            }
            $r = Initialize-DataContext -AppName 'Test'
            $r.CurrentMember | Should -Not -BeNullOrEmpty
            [string]$r.CurrentMember.name | Should -Be 'テスト'
        }
    }
}

Describe 'Reload-MasterContext' -Tag 'lib','unit' {

    It '全マスタを再取得して返す' {
        Mock Get-MasterMembers      { @([pscustomobject]@{ id='m1' }) }
        Mock Get-MasterProjects     { @([pscustomobject]@{ unit_code='p1' }) }
        Mock Get-MasterCategories   { @([pscustomobject]@{ code='c1' }) }
        Mock Get-MasterTaskPatterns { @([pscustomobject]@{ id='t1' }) }
        Mock Get-MasterHolidays     { @([pscustomobject]@{ date='2026-01-01' }) }
        $src = [pscustomobject]@{ Mode='local'; LocalRoot='C:\tmp'; RemoteCtx=$null }
        $r = Reload-MasterContext -Source $src
        $r.Members.Count      | Should -Be 1
        $r.Projects.Count     | Should -Be 1
        $r.Categories.Count   | Should -Be 1
        $r.TaskPatterns.Count | Should -Be 1
        $r.Holidays.Count     | Should -Be 1
    }
}
