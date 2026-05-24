# Categories.Tests.ps1 — is_leave フラグの読み書き ラウンドトリップ

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
}

Describe 'Categories is_leave round-trip' -Tag 'lib','integration','leave' {

    BeforeEach {
        $script:tmpDir = Join-Path $env:TEMP ("worktime-cats-" + (Get-Random))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:src = [pscustomobject]@{ Mode='local'; LocalRoot=$script:tmpDir; RemoteCtx=$null }
    }
    AfterEach { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

    It '保存 → 読込で is_leave が保持される' {
        $cats = @(
            [ordered]@{ code='DESIGN'; name='設計';     is_leave=$false }
            [ordered]@{ code='IMPL';   name='実装';     is_leave=$false }
            [ordered]@{ code='PAID';   name='有給休暇'; is_leave=$true  }
            [ordered]@{ code='HALF';   name='半休';     is_leave=$true  }
        )
        Save-MasterCategories -Source $script:src -Data $cats -AuthorName 'ut' -AuthorEmail 'ut@x'

        $loaded = @(Get-MasterCategories -Source $script:src)
        $loaded.Count | Should -Be 4

        $paid = $loaded | Where-Object { $_.code -eq 'PAID' } | Select-Object -First 1
        [bool]$paid.is_leave | Should -Be $true
        ([string]$paid.name) | Should -Be '有給休暇'

        $design = $loaded | Where-Object { $_.code -eq 'DESIGN' } | Select-Object -First 1
        [bool]$design.is_leave | Should -Be $false
    }

    It 'is_leave フィールド未指定の旧スキーマも読める (false 扱い)' {
        # 旧スキーマ JSON を直接書く
        $oldJson = '[{"code":"OLD","name":"旧カテゴリ"}]'
        $path = Join-Path $script:tmpDir 'master\categories.json'
        $parent = Split-Path -Parent $path
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($path, $oldJson, [System.Text.UTF8Encoding]::new($false))

        $loaded = @(Get-MasterCategories -Source $script:src)
        $loaded.Count | Should -Be 1
        $loaded[0].code | Should -Be 'OLD'
        # is_leave プロパティ自体は無くても OK (PSCustomObject の動的プロパティ)
    }
}
