# GitLab.ps1 — GitLab Repository Files API クライアント (git CLI 不要)
#
# 使用するエンドポイント:
#   GET    /api/v4/projects/:id/repository/files/:path/raw?ref=:branch
#   POST   /api/v4/projects/:id/repository/files/:path
#   PUT    /api/v4/projects/:id/repository/files/:path
#   GET    /api/v4/projects/:id/repository/tree?path=:path&recursive=true&ref=:branch&per_page=100
#
# 認証ヘッダ: PRIVATE-TOKEN

. (Join-Path $PSScriptRoot 'Credential.ps1')

# PowerShell 5.1 で TLS 1.2 を有効化
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# ---- HTTP 性能チューニング ----
# 同期は「小さいファイルを多数」という形になるため、接続確立とハンドシェイクの
# オーバーヘッドが支配的になる。既定のままだと 1 ホスト 2 接続で直列化し、
# Nagle + Expect: 100-continue が 1 リクエストあたり数百 ms を上乗せする。
[System.Net.ServicePointManager]::DefaultConnectionLimit = 16
[System.Net.ServicePointManager]::Expect100Continue      = $false
[System.Net.ServicePointManager]::UseNagleAlgorithm      = $false

# PS 5.1 の Invoke-WebRequest / Invoke-RestMethod は $ProgressPreference が
# 'Continue' (既定) だと進捗バーの描画にリクエスト本体より長い時間を使う。
# 全 HTTP 関数の先頭でこれを呼び、呼び出し元関数のスコープで抑止する。
# (関数スコープの変数は、そこから呼ばれるコマンドレットにも波及する)
function _QuietProgress {
    Set-Variable -Name ProgressPreference -Scope 1 -Value 'SilentlyContinue'
}

function _StripCtrl { param([string]$s)
    if ($null -eq $s) { return '' }
    -join ($s.ToCharArray() | Where-Object { -not [char]::IsControl($_) })
}

function New-GitLabContext {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,    # https://gitlab.example.com
        [Parameter(Mandatory)][string]$ProjectId,  # 数値 ID または URL エンコード済 path
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Token
    )
    $cleanToken = (_StripCtrl $Token).Trim()
    if (-not $cleanToken) { throw 'PAT が空または制御文字のみです' }
    $cleanUrl    = (_StripCtrl $BaseUrl).Trim().TrimEnd('/')
    $cleanProj   = (_StripCtrl $ProjectId).Trim()
    $cleanBranch = (_StripCtrl $Branch).Trim()
    return [pscustomobject]@{
        BaseUrl   = $cleanUrl
        ProjectId = [System.Uri]::EscapeDataString($cleanProj)
        Branch    = $cleanBranch
        Headers   = @{ 'PRIVATE-TOKEN' = $cleanToken }
    }
}

function _EncodePath { param([string]$Path) [System.Uri]::EscapeDataString($Path) }

function _ResponseToString {
    # PowerShell 5.1 と 7.x で Invoke-WebRequest の .Content 型が違うのを吸収。
    # PS 5.1: string (decoded)、PS 7+: byte[]
    # 確実に UTF-8 として解釈するため RawContentStream があればそちらを優先。
    param($Response)
    $ms = $Response.RawContentStream
    if ($ms -and $ms.Length -gt 0) {
        $ms.Position = 0
        $buf = New-Object byte[] ([int]$ms.Length)
        [void]$ms.Read($buf, 0, $buf.Length)
        return [System.Text.Encoding]::UTF8.GetString($buf)
    }
    $c = $Response.Content
    if ($null -eq $c) { return '' }
    if ($c -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}

function Get-GitLabFileRaw {
    # 指定パスのファイル内容を文字列で返す。存在しなければ $null
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path
    )
    _QuietProgress
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/files/$(_EncodePath $Path)/raw?ref=$($Ctx.Branch)"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
        return _ResponseToString $resp
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

function Get-GitLabFileMeta {
    # ファイルメタ (last_commit_id 含む) を取得。存在しなければ $null
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path
    )
    _QuietProgress
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/files/$(_EncodePath $Path)?ref=$($Ctx.Branch)"
    try {
        return Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

function Get-GitLabFileMetaContent {
    # Get-GitLabFileMeta が返す meta.content (base64) を UTF-8 文字列に復号する。
    # files/:path エンドポイントは content と last_commit_id を同時に返すため、
    # 「リモート内容の取得」と「楽観排他用の last_commit_id 取得」を
    # 1 リクエストで済ませられる (raw + meta の 2 往復を 1 往復に)。
    param($Meta)
    if (-not $Meta) { return $null }
    $enc = [string]$Meta.encoding
    $c   = [string]$Meta.content
    if (-not $c) { return '' }
    if ($enc -eq 'base64') {
        try { return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($c)) }
        catch { return $null }
    }
    return $c
}

function Set-GitLabFile {
    # 作成または更新。存在チェックして POST/PUT を切替。
    # 楽観排他: last_commit_id を渡して衝突検知。
    # KnownMeta: 呼出側が既に Get-GitLabFileMeta 済みならそれを渡すことで
    #            メタ取得の往復を省ける。$null を明示的に渡す用途と区別するため
    #            MetaResolved スイッチで「解決済み」を示す。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail,
        $KnownMeta,
        [switch]$MetaResolved
    )
    $meta = if ($MetaResolved) { $KnownMeta } else { Get-GitLabFileMeta -Ctx $Ctx -Path $Path }
    _QuietProgress
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/files/$(_EncodePath $Path)"
    $body = [ordered]@{
        branch         = $Ctx.Branch
        content        = $Content
        commit_message = $CommitMessage
        encoding       = 'text'
    }
    if ($AuthorName)  { $body.author_name  = $AuthorName }
    if ($AuthorEmail) { $body.author_email = $AuthorEmail }

    if ($meta) {
        $body.last_commit_id = $meta.last_commit_id
        $method = 'PUT'
    } else {
        $method = 'POST'
    }
    $json = $body | ConvertTo-Json -Depth 5
    # PS 5.1 で byte[] body + Invoke-RestMethod の組合せが弾かれる事例があるので
    # 文字列で渡し、ContentType に charset=utf-8 を明示する
    return Invoke-RestMethod -Uri $url -Method $method -Headers $Ctx.Headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body $json `
        -UseBasicParsing
}

function Remove-GitLabFile {
    # 指定パスのファイルを削除する。存在しなければ $false を返す。
    # 通常運用では使わない。診断スクリプトが投入した検証用ファイルを
    # 後片付けするために用意している。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    _QuietProgress
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/files/$(_EncodePath $Path)"
    $body = [ordered]@{
        branch         = $Ctx.Branch
        commit_message = $CommitMessage
    }
    if ($AuthorName)  { $body.author_name  = $AuthorName }
    if ($AuthorEmail) { $body.author_email = $AuthorEmail }
    try {
        $null = Invoke-RestMethod -Uri $url -Method 'DELETE' -Headers $Ctx.Headers `
            -ContentType 'application/json; charset=utf-8' `
            -Body ($body | ConvertTo-Json -Depth 5) -UseBasicParsing
        return $true
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return $false }
        throw
    }
}

function _ResponseHeader {
    # レスポンスヘッダを安全に取り出す。
    # PS 5.1 の Headers は実装により Dictionary だったり Hashtable だったりし、
    # 存在しないキーの添字アクセスが例外になることがある。
    param($Response, [string]$Name)
    try {
        $h = $Response.Headers
        if (-not $h) { return '' }
        if ($h -is [System.Collections.IDictionary]) {
            if (-not $h.Contains($Name)) { return '' }
        } elseif ($h.PSObject.Methods['ContainsKey']) {
            if (-not $h.ContainsKey($Name)) { return '' }
        }
        return [string]($h[$Name] | Select-Object -First 1)
    } catch { return '' }
}

function Get-GitLabTree {
    # 指定パス配下のファイル一覧 (再帰)。配列を返す。
    #
    # ページング注意:
    #   tree エンドポイントは総件数の算出コストが高いため、GitLab は
    #   X-Total / X-Total-Pages を返さない。これを終了条件に使うと
    #   [int]$null = 0 となって 1 ページ目 (最大 100 件) で必ず打ち切られ、
    #   それ以降のファイルが同期対象から静かに消える。
    #   recursive=true ではディレクトリ項目も 100 件の枠を消費するため、
    #   10 名 × 12 ヶ月程度でも容易に上限を超える。
    #   → X-Next-Page を見て進め、ヘッダが無い場合は
    #     「満杯のページが返ったら次を試す」でフォールバックする。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path
    )
    _QuietProgress
    $perPage  = 100
    $maxPages = 1000     # 暴走防止 (100,000 ファイル相当)
    $results = New-Object System.Collections.Generic.List[object]
    $page = 1
    while ($page -le $maxPages) {
        $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/tree?path=$(_EncodePath $Path)&ref=$($Ctx.Branch)&recursive=true&per_page=$perPage&page=$page"
        try {
            $resp = Invoke-WebRequest -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { break }
            throw
        }
        # 注意: PS 5.1 の ConvertFrom-Json は JSON 配列を「1 個の配列オブジェクト」
        # としてパイプラインに流す。素の代入なら配列がそのまま入るが、
        # @() で囲むと「配列を 1 要素だけ持つ配列」になり件数が 1 に化ける。
        # ここは絶対に @() を付けないこと。
        $parsed = (_ResponseToString $resp) | ConvertFrom-Json
        $pageCount = 0
        foreach ($i in $parsed) {
            if ($null -eq $i) { continue }
            [void]$results.Add($i)
            $pageCount++
        }

        $next = _ResponseHeader -Response $resp -Name 'X-Next-Page'
        if ($next) {
            $n = 0
            if ([int]::TryParse($next, [ref]$n) -and $n -gt $page) { $page = $n; continue }
            break
        }
        # X-Next-Page が無い実装向けフォールバック。
        # 満杯で返ってきたなら続きがある可能性が高いので次ページを試す。
        if ($pageCount -ge $perPage) { $page++; continue }
        break
    }
    return ,$results.ToArray()
}

function Test-GitLabConnection {
    # 認証確認用: project メタ取得
    param([Parameter(Mandatory)]$Ctx)
    _QuietProgress
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)"
    return Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
}
