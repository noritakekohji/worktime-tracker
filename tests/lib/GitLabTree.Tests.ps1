# GitLabTree.Tests.ps1 — tree API のページング
#
# 回帰防止の狙い:
#   Get-GitLabTree が 1 ページ目 (100 件) で打ち切られると、それ以降の
#   ファイルが同期対象から「静かに」消える。エラーにならず、
#   「取得したのに個人明細が無い」「日付が足りない」という形でしか出ない。
#
#   元のコードは終了条件に X-Total-Pages を使っていたが、tree エンドポイントは
#   総件数の算出コストが高いためこのヘッダを返さない。[int]$null = 0 となって
#   必ず 1 ページで止まっていた。
#   recursive=true ではディレクトリ項目も枠を消費するので、
#   10 名 × 12 ヶ月程度でも容易に 100 件を超える。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')

    $script:Ctx = New-GitLabContext -BaseUrl 'https://gitlab.example.com' -ProjectId '123' `
                                    -Branch 'main' -Token 'dummy-token'

    # ページ番号 → 返す item 数 を決めて偽レスポンスを組み立てる
    function New-FakeResponse {
        param([int]$Page, [int]$Count, [hashtable]$Headers = @{})
        $items = @()
        for ($i = 0; $i -lt $Count; $i++) {
            $n = ($Page - 1) * 100 + $i
            $items += [pscustomobject]@{
                id   = ("sha{0:D5}" -f $n)
                name = ("f{0}.json" -f $n)
                type = 'blob'
                path = ("data/f{0}.json" -f $n)
            }
        }
        return [pscustomobject]@{
            Content = ($items | ConvertTo-Json -Depth 5 -Compress)
            Headers = $Headers
        }
    }
}

Describe 'Get-GitLabTree のページング' -Tag 'lib' {

    It 'X-Next-Page をたどって全ページ取得する' {
        # 3 ページ (100 + 100 + 30 = 230 件)
        Mock -CommandName Invoke-WebRequest -MockWith {
            $p = 1
            # '&page=' に限定すること。'page=(\d+)' だと per_page=100 に
            # 先にマッチして常に 100 ページ目扱いになる
            if ($Uri -match '&page=(\d+)') { $p = [int]$Matches[1] }
            switch ($p) {
                1 { New-FakeResponse -Page 1 -Count 100 -Headers @{ 'X-Next-Page' = '2' } }
                2 { New-FakeResponse -Page 2 -Count 100 -Headers @{ 'X-Next-Page' = '3' } }
                default { New-FakeResponse -Page 3 -Count 30 -Headers @{ 'X-Next-Page' = '' } }
            }
        }
        # 素の代入で受けること。@() で囲むと単一オブジェクト扱いの配列が
        # さらに包まれて件数が 1 に化ける (本番でこれをやって障害になった)
        $r = Get-GitLabTree -Ctx $script:Ctx -Path 'data'
        $r.Count | Should -Be 230
    }

    It 'X-Total-Pages が無くても 100 件で打ち切らない (本件の再発検出)' {
        # tree エンドポイントの実挙動: 総件数ヘッダを返さない。
        # X-Next-Page も無い実装を想定し、満杯なら次を試すフォールバックを検証。
        Mock -CommandName Invoke-WebRequest -MockWith {
            $p = 1
            # '&page=' に限定すること。'page=(\d+)' だと per_page=100 に
            # 先にマッチして常に 100 ページ目扱いになる
            if ($Uri -match '&page=(\d+)') { $p = [int]$Matches[1] }
            if ($p -eq 1) { New-FakeResponse -Page 1 -Count 100 }
            elseif ($p -eq 2) { New-FakeResponse -Page 2 -Count 33 }
            else { New-FakeResponse -Page $p -Count 0 }
        }
        # 素の代入で受けること。@() で囲むと単一オブジェクト扱いの配列が
        # さらに包まれて件数が 1 に化ける (本番でこれをやって障害になった)
        $r = Get-GitLabTree -Ctx $script:Ctx -Path 'data'
        $r.Count | Should -Be 133
    }

    It '1 ページに収まる場合は 1 回で終わる' {
        Mock -CommandName Invoke-WebRequest -MockWith {
            New-FakeResponse -Page 1 -Count 12 -Headers @{ 'X-Next-Page' = '' }
        }
        $r = Get-GitLabTree -Ctx $script:Ctx -Path 'master'
        $r.Count | Should -Be 12
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It '空の結果でも落ちない' {
        Mock -CommandName Invoke-WebRequest -MockWith {
            New-FakeResponse -Page 1 -Count 0 -Headers @{ 'X-Next-Page' = '' }
        }
        $r = Get-GitLabTree -Ctx $script:Ctx -Path 'data'
        @($r).Count | Should -Be 0
    }

    It 'X-Next-Page が現在ページ以下でも無限ループしない' {
        # 壊れたヘッダを返すプロキシ等への防御
        Mock -CommandName Invoke-WebRequest -MockWith {
            New-FakeResponse -Page 1 -Count 100 -Headers @{ 'X-Next-Page' = '1' }
        }
        # 素の代入で受けること。@() で囲むと単一オブジェクト扱いの配列が
        # さらに包まれて件数が 1 に化ける (本番でこれをやって障害になった)
        $r = Get-GitLabTree -Ctx $script:Ctx -Path 'data'
        $r.Count | Should -Be 100
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }
}

Describe '_RemoteBlobMap (障害の直接原因だった箇所)' -Tag 'lib' {

    # 障害内容:
    #   foreach ($item in @(Get-GitLabTree ...)) と書いたため、配列が
    #   「1 要素の配列」に包まれて 1 件として回った。しかも PS のメンバー列挙で
    #     $item.type      -> @('blob','blob',...)  → -ne 'blob' が False
    #     [string]$item.path -> "a.json b.json ..." → .EndsWith('.json') が True
    #   と両方のガードをすり抜け、存在しないパス 1 件だけのマップができていた。
    #   その 1 件は GET が 404 になって握りつぶされるため、
    #   「エラーは出ないが一切ダウンロードされない」状態になった。

    BeforeAll {
        . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')
        $script:Src = [pscustomobject]@{ Mode='gitlab'; LocalRoot='C:\nope'; RemoteCtx=$script:Ctx }
    }

    It 'blob を全件 {path -> id} で返す' {
        Mock -CommandName Get-GitLabTree -MockWith {
            $l = New-Object 'System.Collections.Generic.List[object]'
            [void]$l.Add([pscustomobject]@{ type='tree'; path='data/2026';         id='t1' })
            [void]$l.Add([pscustomobject]@{ type='tree'; path='data/2026/07';      id='t2' })
            [void]$l.Add([pscustomobject]@{ type='blob'; path='data/2026/07/a.json'; id='sha-a' })
            [void]$l.Add([pscustomobject]@{ type='blob'; path='data/2026/07/b.json'; id='sha-b' })
            [void]$l.Add([pscustomobject]@{ type='blob'; path='data/README.md';      id='sha-r' })
            return ,$l.ToArray()
        }
        $map = _RemoteBlobMap -Source $script:Src -Path 'data'
        $map.Count | Should -Be 2
        $map['data/2026/07/a.json'] | Should -Be 'sha-a'
        $map['data/2026/07/b.json'] | Should -Be 'sha-b'
        # ディレクトリと非 json は除外される
        $map.ContainsKey('data/2026')      | Should -BeFalse
        $map.ContainsKey('data/README.md') | Should -BeFalse
    }

    It '空白連結された偽キーが混入しない (二重ラップの再発検出)' {
        Mock -CommandName Get-GitLabTree -MockWith {
            $l = New-Object 'System.Collections.Generic.List[object]'
            foreach ($i in 0..4) { [void]$l.Add([pscustomobject]@{ type='blob'; path="data/f$i.json"; id="s$i" }) }
            return ,$l.ToArray()
        }
        $map = _RemoteBlobMap -Source $script:Src -Path 'data'
        $map.Count | Should -Be 5
        foreach ($k in $map.Keys) {
            $k | Should -Not -Match '\s' -Because "パスに空白が入るのは配列が文字列化された証拠"
        }
    }

    It 'blob が 1 件だけでも配列として扱える' {
        Mock -CommandName Get-GitLabTree -MockWith {
            $l = New-Object 'System.Collections.Generic.List[object]'
            [void]$l.Add([pscustomobject]@{ type='blob'; path='master/members.json'; id='sha-m' })
            return ,$l.ToArray()
        }
        $map = _RemoteBlobMap -Source $script:Src -Path 'master'
        $map.Count | Should -Be 1
        $map['master/members.json'] | Should -Be 'sha-m'
    }

    It 'tree が空でも空のマップを返す' {
        Mock -CommandName Get-GitLabTree -MockWith { return ,@() }
        (_RemoteBlobMap -Source $script:Src -Path 'data').Count | Should -Be 0
    }
}

Describe '_ResponseHeader' -Tag 'lib' {

    It '存在するヘッダを返す' {
        $resp = [pscustomobject]@{ Headers = @{ 'X-Next-Page' = '4' } }
        (_ResponseHeader -Response $resp -Name 'X-Next-Page') | Should -Be '4'
    }

    It '存在しないヘッダは例外にせず空文字' {
        $resp = [pscustomobject]@{ Headers = @{ 'X-Page' = '1' } }
        (_ResponseHeader -Response $resp -Name 'X-Next-Page') | Should -Be ''
    }

    It 'Headers 自体が無くても空文字' {
        (_ResponseHeader -Response ([pscustomobject]@{}) -Name 'X-Next-Page') | Should -Be ''
    }

    It '添字アクセスが例外になる型でも空文字に落とす' {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $d.Add('X-Page', '1')
        $resp = [pscustomobject]@{ Headers = $d }
        (_ResponseHeader -Response $resp -Name 'X-Next-Page') | Should -Be ''
    }
}
