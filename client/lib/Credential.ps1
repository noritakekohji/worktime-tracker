# Credential.ps1 — GitLab Project Access Token を DPAPI で暗号化保管
#
# 保管場所: %APPDATA%\worktime-tracker\token.dat
# DPAPI なので「同一 Windows ユーザ・同一マシン」でのみ復号可能。

function Get-AppDataDir {
    $d = Join-Path $env:APPDATA 'worktime-tracker'
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    return $d
}

function Get-TokenPath {
    return Join-Path (Get-AppDataDir) 'token.dat'
}

function Save-GitLabToken {
    param([Parameter(Mandatory)][string]$Token)
    $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString -SecureString $secure
    [System.IO.File]::WriteAllText((Get-TokenPath), $encrypted, [System.Text.ASCIIEncoding]::new())
}

function Get-GitLabToken {
    $p = Get-TokenPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $encrypted = ([System.IO.File]::ReadAllText($p, [System.Text.ASCIIEncoding]::new())).Trim()
    if ([string]::IsNullOrEmpty($encrypted)) { return $null }
    $secure = ConvertTo-SecureString -String $encrypted
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Test-GitLabTokenStored {
    return Test-Path -LiteralPath (Get-TokenPath)
}

function Remove-GitLabToken {
    $p = Get-TokenPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
