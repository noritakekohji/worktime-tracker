# SyncMonitor.Tests.ps1 - regression tests for non-destructive remote update notices.

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/SyncMonitor.ps1')

    function New-MonitorSource {
        $dir = Join-Path $env:TEMP ("worktime-monitor-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return [pscustomobject]@{ LocalRoot = $dir; RemoteCtx = [pscustomobject]@{} }
    }
}

Describe 'GitLab update monitor' -Tag 'lib' {
    BeforeEach {
        $script:source = New-MonitorSource
        $script:treeId = 'blob-a'
        Mock -CommandName Get-GitLabTree -MockWith {
            param($Ctx, $Path)
            return ,@([pscustomobject]@{ type = 'blob'; path = "$Path/file.json"; id = $script:treeId })
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:source.LocalRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'first check establishes a baseline without a notice' {
        $result = Test-RemoteUpdateNotice -Source $script:source -Master -DataPath 'data'
        $result.MasterChanged | Should -BeFalse
        $result.DataChanged | Should -BeFalse
        $result.Errors.Count | Should -Be 0
    }

    It 'changed blob ID raises a pending notice until accepted' {
        [void](Test-RemoteUpdateNotice -Source $script:source -Master)
        $script:treeId = 'blob-b'
        $changed = Test-RemoteUpdateNotice -Source $script:source -Master
        $changed.MasterChanged | Should -BeTrue
        Clear-RemoteUpdateNotice -Source $script:source -Master
        (Test-RemoteUpdateNotice -Source $script:source -Master).MasterChanged | Should -BeFalse
    }
}
