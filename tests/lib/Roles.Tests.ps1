# Roles.Tests.ps1 — Has-Role / Get-MemberRoles の挙動 (旧/新スキーマ両対応)

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
}

Describe 'Get-MemberRoles' -Tag 'lib','unit','roles' {

    Context '新スキーマ (roles 配列)' {
        It '複数ロール配列を返す' {
            $m = [pscustomobject]@{ id='E1'; roles=@('admin','leader','member') }
            $r = Get-MemberRoles -Member $m
            $r.Count | Should -Be 3
            $r | Should -Contain 'admin'
            $r | Should -Contain 'leader'
            $r | Should -Contain 'member'
        }
        It '空配列なら member 既定にフォールバック' {
            $m = [pscustomobject]@{ id='E1'; roles=@() }
            (Get-MemberRoles -Member $m) | Should -Be @('member')
        }
        It '単一要素 admin' {
            $m = [pscustomobject]@{ id='E1'; roles=@('admin') }
            (Get-MemberRoles -Member $m) | Should -Be @('admin')
        }
    }

    Context '旧スキーマ (role 単一文字列)' {
        It 'role="admin" → @("admin")' {
            $m = [pscustomobject]@{ id='E1'; role='admin' }
            (Get-MemberRoles -Member $m) | Should -Be @('admin')
        }
        It 'role="member" → @("member")' {
            $m = [pscustomobject]@{ id='E1'; role='member' }
            (Get-MemberRoles -Member $m) | Should -Be @('member')
        }
    }

    Context 'roles と role 両方持つ' {
        It 'roles を優先' {
            $m = [pscustomobject]@{ id='E1'; role='member'; roles=@('admin','leader') }
            $r = Get-MemberRoles -Member $m
            $r | Should -Contain 'admin'
            $r | Should -Contain 'leader'
            $r | Should -Not -Contain 'member'   # roles 優先のため
        }
    }

    Context '異常系' {
        It '$null メンバーは空配列' {
            (Get-MemberRoles -Member $null) | Should -BeNullOrEmpty
        }
        It 'roles も role も無いと既定 member' {
            $m = [pscustomobject]@{ id='E1'; name='テスト' }
            (Get-MemberRoles -Member $m) | Should -Be @('member')
        }
    }
}

Describe 'Has-Role' -Tag 'lib','unit','roles' {
    It 'admin チェック (roles 配列)' {
        $m = [pscustomobject]@{ id='E1'; roles=@('admin','member') }
        Has-Role -Member $m -Role 'admin'  | Should -Be $true
        Has-Role -Member $m -Role 'leader' | Should -Be $false
        Has-Role -Member $m -Role 'member' | Should -Be $true
    }
    It '旧 role="admin" でも admin と判定' {
        $m = [pscustomobject]@{ id='E1'; role='admin' }
        Has-Role -Member $m -Role 'admin' | Should -Be $true
    }
    It '$null メンバーは常に false' {
        Has-Role -Member $null -Role 'admin' | Should -Be $false
    }
}
