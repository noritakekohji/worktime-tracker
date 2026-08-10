# AutoUpdate.Tests.ps1 - update availability is determined by the remote app version only.

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/AutoUpdate.ps1')
}

Describe 'Auto update version checks' -Tag 'lib' {
    It 'compares semantic versions numerically' {
        (Compare-AppVersion -Current '1.5.0' -Candidate '1.10.0') | Should -BeGreaterThan 0
        (Compare-AppVersion -Current '1.5.0' -Candidate '1.5.0') | Should -Be 0
        (Compare-AppVersion -Current '1.5.0' -Candidate '1.4.9') | Should -BeLessThan 0
    }

    It 'offers an update only when the GitLab version is newer' {
        Mock -CommandName Get-GitLabFileRaw -MockWith { "`$Script:AppVersion = '1.6.0'" }
        $source = [pscustomobject]@{ RemoteCtx = [pscustomobject]@{} }
        $result = Test-AutoUpdateAvailable -Source $source -CurrentVersion '1.5.0'
        $result.Available | Should -BeTrue
        $result.Version | Should -Be '1.6.0'
    }

    It 'ignores a missing or malformed remote version file' {
        Mock -CommandName Get-GitLabFileRaw -MockWith { 'not a version file' }
        $source = [pscustomobject]@{ RemoteCtx = [pscustomobject]@{} }
        (Test-AutoUpdateAvailable -Source $source -CurrentVersion '1.5.0').Available | Should -BeFalse
    }
}
