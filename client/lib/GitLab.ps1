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

function Set-GitLabFile {
    # 作成または更新。存在チェックして POST/PUT を切替。
    # 楽観排他: last_commit_id を渡して衝突検知。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    $meta = Get-GitLabFileMeta -Ctx $Ctx -Path $Path
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
    return Invoke-RestMethod -Uri $url -Method $method -Headers $Ctx.Headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -UseBasicParsing
}

function Get-GitLabTree {
    # 指定パス配下のファイル一覧 (再帰)。配列を返す。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path
    )
    $results = New-Object System.Collections.Generic.List[object]
    $page = 1
    do {
        $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)/repository/tree?path=$(_EncodePath $Path)&ref=$($Ctx.Branch)&recursive=true&per_page=100&page=$page"
        try {
            $resp = Invoke-WebRequest -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { break }
            throw
        }
        $items = (_ResponseToString $resp) | ConvertFrom-Json
        foreach ($i in $items) { $results.Add($i) }
        $totalPages = [int]($resp.Headers['X-Total-Pages'] | Select-Object -First 1)
        $page++
    } while ($page -le $totalPages -and $totalPages -gt 0)
    return ,$results.ToArray()
}

function Test-GitLabConnection {
    # 認証確認用: project メタ取得
    param([Parameter(Mandatory)]$Ctx)
    $url = "$($Ctx.BaseUrl)/api/v4/projects/$($Ctx.ProjectId)"
    return Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
}
