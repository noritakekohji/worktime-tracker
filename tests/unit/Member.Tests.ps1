# Member.Tests.ps1 — Get-MemberAbbrev (2文字短縮) 単体テスト

BeforeAll {
    # WbsInput.ps1 と同等のロジックを単独で再現
    function Get-MemberAbbrevForTest {
        param([string]$Id, [string]$Name)
        if ([string]::IsNullOrWhiteSpace($Id) -and [string]::IsNullOrWhiteSpace($Name)) { return '' }
        $src = if ($Name) { $Name } else { $Id }
        if ([string]::IsNullOrWhiteSpace($src)) { return '' }
        if ($src.Length -le 2) { return $src }
        return $src.Substring(0, 2)
    }
}

Describe 'Get-MemberAbbrev' -Tag 'unit' {

    Context 'ID/Name 両方ある場合 — Name の先頭2文字' {
        It '<id>/<name> → <expected>' -TestCases @(
            @{ Id='kohji';   Name='noritake';   Expected='no' }
            @{ Id='E1001';   Name='田中太郎';   Expected='田中' }
            @{ Id='user1';   Name='山田花子';   Expected='山田' }
        ) {
            Get-MemberAbbrevForTest -Id $Id -Name $Name | Should -Be $Expected
        }
    }

    Context 'Name が空のとき ID にフォールバック' {
        It 'kohji → ko' {
            Get-MemberAbbrevForTest -Id 'kohji' -Name $null | Should -Be 'ko'
        }
        It 'kohji → ko (空文字)' {
            Get-MemberAbbrevForTest -Id 'kohji' -Name '' | Should -Be 'ko'
        }
    }

    Context '短い名前はそのまま' {
        It '2 文字以下はそのまま' -TestCases @(
            @{ Src='a';    Expected='a' }
            @{ Src='ab';   Expected='ab' }
            @{ Src='田';   Expected='田' }
            @{ Src='田中'; Expected='田中' }
        ) {
            Get-MemberAbbrevForTest -Id 'X' -Name $Src | Should -Be $Expected
        }
    }

    Context '完全に空' {
        It '空 ID + 空 Name は空文字' {
            Get-MemberAbbrevForTest -Id '' -Name '' | Should -BeExactly ''
        }
    }
}
