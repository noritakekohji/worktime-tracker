# SyncState.Tests.ps1 — 差分同期の状態管理 (.sync_state.json)
#
# 回帰防止の狙い:
#   Sync-Pull-* / Sync-Push-* は blob SHA / content hash を local_store の
#   .sync_state.json に記録し、変化のないファイルの HTTP 往復を丸ごと省く。
#   状態の読み書きが壊れると「毎回全件ダウンロード」に静かに退化し、
#   症状は「遅い」だけでエラーにならないためテストで押さえる。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')

    function New-TempDataSource {
        $tmp = Join-Path $env:TEMP ("worktime-sync-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $cfg = [pscustomobject]@{ mode='local'; member_id='ut'; local_store=$tmp }
        $src = New-DataSource -Config $cfg
        return [pscustomobject]@{ Source=$src; Dir=$tmp }
    }

    function Remove-TempDataSource {
        param($Ctx)
        if ($Ctx -and $Ctx.Dir) { Remove-Item -LiteralPath $Ctx.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe '同期状態ファイル (.sync_state.json)' -Tag 'lib' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It '未作成なら pull / push とも空ハッシュテーブルを返す' {
        $st = _LoadSyncState -Source $script:ctx.Source
        $st.pull.Count | Should -Be 0
        $st.push.Count | Should -Be 0
    }

    It '保存 → 読込でラウンドトリップする' {
        $st = _LoadSyncState -Source $script:ctx.Source
        $st.pull['data/2026/07/ut.json'] = 'abc123'
        $st.push['master/members.json'] = 'DEADBEEF'
        _SaveSyncState -Source $script:ctx.Source -State $st

        $again = _LoadSyncState -Source $script:ctx.Source
        $again.pull['data/2026/07/ut.json'] | Should -Be 'abc123'
        $again.push['master/members.json'] | Should -Be 'DEADBEEF'
    }

    It '状態ファイルは local_store 直下に置かれ master/ data/ を汚さない' {
        $st = _LoadSyncState -Source $script:ctx.Source
        $st.pull['x'] = 'y'
        _SaveSyncState -Source $script:ctx.Source -State $st

        $p = _SyncStatePath -Source $script:ctx.Source
        Test-Path -LiteralPath $p | Should -BeTrue
        (Split-Path $p -Parent) | Should -Be $script:ctx.Source.LocalRoot
        # push 対象 (master/ data/) の中に紛れ込んでいないこと
        @(Get-ChildItem -Path (Join-Path $script:ctx.Source.LocalRoot 'data') -Recurse -File).Count | Should -Be 0
        @(Get-ChildItem -Path (Join-Path $script:ctx.Source.LocalRoot 'master') -Recurse -File).Count | Should -Be 0
    }

    It '壊れた JSON でも例外を投げず空状態に退化する (全件 DL で復旧できる)' {
        [System.IO.File]::WriteAllText((_SyncStatePath -Source $script:ctx.Source), '{ this is not json',
                                       [System.Text.UTF8Encoding]::new($false))
        $st = _LoadSyncState -Source $script:ctx.Source
        $st.pull.Count | Should -Be 0
        $st.push.Count | Should -Be 0
    }
}

Describe '_ContentHash' -Tag 'lib' {

    It '同一文字列は同一ハッシュ' {
        (_ContentHash 'hello') | Should -Be (_ContentHash 'hello')
    }

    It '1 文字違えば別ハッシュ' {
        (_ContentHash 'hello') | Should -Not -Be (_ContentHash 'hellO')
    }

    It '日本語を含む内容でも安定する (UTF-8 で評価)' {
        $a = _ContentHash '{"comment":"設計レビュー"}'
        $b = _ContentHash '{"comment":"設計レビュー"}'
        $c = _ContentHash '{"comment":"実装レビュー"}'
        $a | Should -Be $b
        $a | Should -Not -Be $c
    }

    It '空文字も空でないハッシュを返す (未 push と区別できる)' {
        (_ContentHash '') | Should -Not -BeNullOrEmpty
    }

    It '$null は [string] 強制変換で空文字と同じ扱いになる' {
        # param([string]$Text) のため $null は '' に変換される。
        # 状態ファイル上は「未記録 = キー無し」で区別するので実害はない。
        (_ContentHash $null) | Should -Be (_ContentHash '')
    }
}

Describe 'ローカルモードでは同期関数が通信せず 0 件を返す' -Tag 'lib' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It 'Sync-Pull-Masters は Pulled/Skipped/Missing/Errors を持つ' {
        $r = Sync-Pull-Masters -Source $script:ctx.Source
        $r.Pulled  | Should -Be 0
        $r.Skipped | Should -Be 0
        $r.Missing | Should -Be 0
        $r.Errors.Count | Should -Be 0
    }

    It 'Sync-Pull-AllData は Pulled/Skipped/Total/Errors を持つ' {
        $r = Sync-Pull-AllData -Source $script:ctx.Source
        $r.Pulled  | Should -Be 0
        $r.Skipped | Should -Be 0
        $r.Total   | Should -Be 0
        $r.Errors.Count | Should -Be 0
    }

    It 'Sync-Push-Masters は Pushed/SkippedNoDiff/Errors を持つ' {
        $r = Sync-Push-Masters -Source $script:ctx.Source -AuthorName 'ut' -AuthorEmail 'ut@local'
        $r.Pushed | Should -Be 0
        $r.SkippedNoDiff | Should -Be 0
        $r.Errors.Count | Should -Be 0
    }

    It 'Sync-Push-MyData はリモート未設定なら例外' {
        { Sync-Push-MyData -Source $script:ctx.Source -MemberId 'ut' } | Should -Throw
    }
}

Describe 'Get-GitLabFileMetaContent (raw + meta の 2 往復を 1 往復にするための復号)' -Tag 'lib' {

    It 'base64 の content を UTF-8 文字列に戻す' {
        $text = '{"member_id":"ut","comment":"日本語テスト"}'
        $b64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
        $meta = [pscustomobject]@{ encoding='base64'; content=$b64; last_commit_id='abc' }
        (Get-GitLabFileMetaContent -Meta $meta) | Should -Be $text
    }

    It 'meta が $null なら $null' {
        (Get-GitLabFileMetaContent -Meta $null) | Should -Be $null
    }

    It 'content が空なら空文字' {
        $meta = [pscustomobject]@{ encoding='base64'; content=''; last_commit_id='abc' }
        (Get-GitLabFileMetaContent -Meta $meta) | Should -Be ''
    }

    It 'base64 でない encoding はそのまま返す' {
        $meta = [pscustomobject]@{ encoding='text'; content='plain'; last_commit_id='abc' }
        (Get-GitLabFileMetaContent -Meta $meta) | Should -Be 'plain'
    }
}
