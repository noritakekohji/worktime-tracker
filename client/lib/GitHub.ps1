# GitHub.ps1 — GitHub Contents API クライアント (git CLI 不要)
#
# 使用エンドポイント:
#   GET    /repos/{owner}/{repo}/contents/{path}?ref={branch}
#   PUT    /repos/{owner}/{repo}/contents/{path}          # 作成/更新 (sha 必須 if 更新)
#   GET    /repos/{owner}/{repo}/git/trees/{branch}?recursive=1
#   GET    /repos/{owner}/{repo}
#
# 認証: Authorization: Bearer <PAT>  (classic / fine-grained 両対応)

. (Join-Path $PSScriptRoot 'Credential.ps1')

[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

function _GH_StripCtrl { param([string]$s)
    if ($null -eq $s) { return '' }
    -join ($s.ToCharArray() | Where-Object { -not [char]::IsControl($_) })
}

function New-GitHubContext {
    param(
        [Parameter(Mandatory)][string]$Repo,    # "owner/repo"
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Token,
        [string]$ApiBase = 'https://api.github.com'
    )
    $cleanToken = (_GH_StripCtrl $Token).Trim()
    if (-not $cleanToken) { throw 'GitHub PAT が空または制御文字のみです' }
    $cleanRepo  = (_GH_StripCtrl $Repo).Trim().Trim('/')
    if ($cleanRepo -notmatch '^[^/]+/[^/]+$') { throw 'Repo は "owner/repo" 形式で指定してください' }
    $cleanBr    = (_GH_StripCtrl $Branch).Trim()
    return [pscustomobject]@{
        ApiBase = $ApiBase.TrimEnd('/')
        Repo    = $cleanRepo
        Branch  = $cleanBr
        Headers = @{
            'Authorization' = "Bearer $cleanToken"
            'Accept'        = 'application/vnd.github+json'
            'User-Agent'    = 'worktime-tracker'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
    }
}

function _GH_EncodePath { param([string]$Path)
    # GitHub のパスは / を生のまま、各セグメントだけ URL エンコード
    return ($Path.Split('/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
}

function _GH_ContentToString {
    param($Response)
    # PS 5.1 と 7 の差吸収
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

function Get-GitHubFileMeta {
    # ファイルメタ (sha 含む) を取得。存在しなければ $null
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Path)
    $url = "$($Ctx.ApiBase)/repos/$($Ctx.Repo)/contents/$(_GH_EncodePath $Path)?ref=$($Ctx.Branch)"
    try {
        return Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
        throw
    }
}

function Get-GitHubFileRaw {
    # ファイル内容を UTF-8 文字列で返す。なければ $null
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Path)
    $meta = Get-GitHubFileMeta -Ctx $Ctx -Path $Path
    if (-not $meta) { return $null }
    if ($meta.encoding -eq 'base64' -and $meta.content) {
        $bytes = [System.Convert]::FromBase64String(($meta.content -replace "`r?`n",''))
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    # download_url 経由フォールバック
    if ($meta.download_url) {
        $resp = Invoke-WebRequest -Uri $meta.download_url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
        return _GH_ContentToString $resp
    }
    return $null
}

function Set-GitHubFile {
    # 作成/更新。既存ファイルがあれば sha を載せて PUT。
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$CommitMessage,
        [string]$AuthorName,
        [string]$AuthorEmail
    )
    $meta = Get-GitHubFileMeta -Ctx $Ctx -Path $Path
    $base64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
    $body = [ordered]@{
        message = $CommitMessage
        content = $base64
        branch  = $Ctx.Branch
    }
    if ($meta -and $meta.sha) { $body.sha = $meta.sha }
    if ($AuthorName -and $AuthorEmail) {
        $body.committer = @{ name = $AuthorName; email = $AuthorEmail }
        $body.author    = @{ name = $AuthorName; email = $AuthorEmail }
    }
    $url = "$($Ctx.ApiBase)/repos/$($Ctx.Repo)/contents/$(_GH_EncodePath $Path)"
    $json = $body | ConvertTo-Json -Depth 5
    return Invoke-RestMethod -Uri $url -Method PUT -Headers $Ctx.Headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -UseBasicParsing
}

function Get-GitHubTree {
    # ブランチ全体の再帰ツリーを取得し、Path の prefix に一致する blob だけ返す
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Path)
    $url = "$($Ctx.ApiBase)/repos/$($Ctx.Repo)/git/trees/$(_GH_EncodePath $Ctx.Branch)?recursive=1"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return ,@() }
        throw
    }
    if (-not $resp.tree) { return ,@() }
    $prefix = $Path.TrimEnd('/') + '/'
    $items  = $resp.tree | Where-Object { $_.type -eq 'blob' -and (($_.path -eq $Path) -or $_.path.StartsWith($prefix)) }
    # GitLab tree 互換のオブジェクトに整形
    return ,@($items | ForEach-Object { [pscustomobject]@{ type = 'blob'; path = $_.path; sha = $_.sha } })
}

function Test-GitHubConnection {
    param([Parameter(Mandatory)]$Ctx)
    $url = "$($Ctx.ApiBase)/repos/$($Ctx.Repo)"
    $repo = Invoke-RestMethod -Uri $url -Headers $Ctx.Headers -UseBasicParsing -ErrorAction Stop
    return [pscustomobject]@{
        name_with_namespace = $repo.full_name
        default_branch      = $repo.default_branch
        web_url             = $repo.html_url
        private             = $repo.private
    }
}
