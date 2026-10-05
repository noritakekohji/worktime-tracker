# UserPrefsUnitDefaults.Tests.ps1 — ユニット別デフォルト (テンプレート) / お気に入り切替
#
# 回帰防止の狙い:
#   - user_prefs.json に unit_defaults を足しても、favorite_projects など既存キーを消さない
#     (個人設定ダイアログが favorite_projects だけで上書きしていた形を再発させない)
#   - 1 件だけのお気に入りが JSON 上で文字列に潰れない (PS 5.1 の 1 要素 unwrap)
#   - テンプレートの保存 → 読込で値が往復する

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/UserPrefs.ps1')

    # %APPDATA% を差し替えてユーザーの実ファイルを触らない
    $script:OrigAppData = $env:APPDATA
    $script:TmpAppData  = Join-Path ([System.IO.Path]::GetTempPath()) ("wtt-prefs-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TmpAppData -Force | Out-Null
    $env:APPDATA = $script:TmpAppData
}

AfterAll {
    $env:APPDATA = $script:OrigAppData
    Remove-Item -LiteralPath $script:TmpAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'ユニット別デフォルト' -Tag 'unit' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-UserPrefsPath) -Force -ErrorAction SilentlyContinue
    }

    It '未登録なら $null' {
        Get-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' | Should -BeNullOrEmpty
    }

    It '保存した値が読み戻せる' {
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{
            process_code = 'DSN'; task_group_code = 'DB'; task_code = 'ERD'
            category = 'DESIGN'; hours = 2.5; comment = '定例'
        }
        $d = Get-UnitDefault -MemberId 'E001' -UnitCode 'ABC001'
        $d.process_code    | Should -Be 'DSN'
        $d.task_group_code | Should -Be 'DB'
        $d.task_code       | Should -Be 'ERD'
        $d.category        | Should -Be 'DESIGN'
        $d.hours           | Should -Be 2.5
        $d.comment         | Should -Be '定例'
    }

    It 'テンプレート保存でお気に入りが消えない' {
        Set-UserPrefs -MemberId 'E001' -Prefs @{ favorite_projects = @('ABC001') }
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{ process_code = 'DSN' }
        @((Get-UserPrefs -MemberId 'E001').favorite_projects) | Should -Be @('ABC001')
    }

    It '他メンバーの設定に影響しない' {
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{ process_code = 'DSN' }
        Get-UnitDefault -MemberId 'E002' -UnitCode 'ABC001' | Should -BeNullOrEmpty
    }

    It '解除できる' {
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{ process_code = 'DSN' }
        Set-UnitDefault -MemberId 'E001' -UnitCode 'XYZ002' -Default @{ process_code = 'IMP' }
        Remove-UnitDefault -MemberId 'E001' -UnitCode 'ABC001'
        Get-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' | Should -BeNullOrEmpty
        (Get-UnitDefault -MemberId 'E001' -UnitCode 'XYZ002').process_code | Should -Be 'IMP'
    }

    It '登録済みユニットコード一覧が 1 件でも配列で返る' {
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{ process_code = 'DSN' }
        $codes = Get-UnitDefaultCodes -MemberId 'E001'
        ,$codes | Should -BeOfType [array]
        $codes.Count | Should -Be 1
    }
}

Describe '最近の組み合わせの表示件数' -Tag 'unit' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-UserPrefsPath) -Force -ErrorAction SilentlyContinue
    }

    It '未設定なら既定の 5' {
        Get-RecentComboCount -MemberId 'E001' | Should -Be 5
    }

    It '保存した値が読み戻せ、他のキーを消さない' {
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $true
        Set-RecentComboCount -MemberId 'E001' -Count 3
        Get-RecentComboCount -MemberId 'E001' | Should -Be 3
        @((Get-UserPrefs -MemberId 'E001').favorite_projects) | Should -Be @('ABC001')
    }

    It '0 (非表示) を保存できる' {
        Set-RecentComboCount -MemberId 'E001' -Count 0
        Get-RecentComboCount -MemberId 'E001' | Should -Be 0
    }

    It '範囲外や数値でない値は 0〜10 に丸める / 既定に戻す' {
        Set-RecentComboCount -MemberId 'E001' -Count 99
        Get-RecentComboCount -MemberId 'E001' | Should -Be 10
        Set-UserPrefs -MemberId 'E001' -Prefs @{ recent_combo_count = 'abc' }
        Get-RecentComboCount -MemberId 'E001' | Should -Be 5
    }
}

Describe 'お気に入り切替' -Tag 'unit' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-UserPrefsPath) -Force -ErrorAction SilentlyContinue
    }

    It '追加・削除ができ、テンプレートは残る' {
        Set-UnitDefault -MemberId 'E001' -UnitCode 'ABC001' -Default @{ process_code = 'DSN' }
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $true
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'XYZ002' -IsFavorite $true
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $false
        @((Get-UserPrefs -MemberId 'E001').favorite_projects) | Should -Be @('XYZ002')
        (Get-UnitDefault -MemberId 'E001' -UnitCode 'ABC001').process_code | Should -Be 'DSN'
    }

    It 'お気に入り 1 件でも JSON 上は配列のまま' {
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $true
        $raw = Get-Content -LiteralPath (Get-UserPrefsPath) -Raw -Encoding UTF8
        $raw | Should -Match '"favorite_projects"\s*:\s*\['
    }

    It '同じコードを二重に登録しない' {
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $true
        Set-FavoriteProject -MemberId 'E001' -UnitCode 'ABC001' -IsFavorite $true
        @((Get-UserPrefs -MemberId 'E001').favorite_projects).Count | Should -Be 1
    }
}
