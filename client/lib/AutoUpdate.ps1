# AutoUpdate.ps1 - GitLab archive based application updater (no git.exe required).

. (Join-Path $PSScriptRoot 'GitLab.ps1')

function Compare-AppVersion {
    param([Parameter(Mandatory)][string]$Current, [Parameter(Mandatory)][string]$Candidate)
    $currentVersion = [version]$Current
    $candidateVersion = [version]$Candidate
    return $candidateVersion.CompareTo($currentVersion)
}

function Get-RemoteAppVersion {
    param([Parameter(Mandatory)]$Source)
    if (-not $Source.RemoteCtx) { return $null }
    $raw = Get-GitLabFileRaw -Ctx $Source.RemoteCtx -Path 'client/lib/Version.ps1'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $hits = [regex]::Match($raw, "AppVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
    if (-not $hits.Success) { return $null }
    return $hits.Groups[1].Value
}

function Test-AutoUpdateAvailable {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$CurrentVersion)
    $remoteVersion = Get-RemoteAppVersion -Source $Source
    if (-not $remoteVersion) { return [pscustomobject]@{ Available = $false; Version = ''; Error = '' } }
    try {
        return [pscustomobject]@{
            Available = ((Compare-AppVersion -Current $CurrentVersion -Candidate $remoteVersion) -gt 0)
            Version   = $remoteVersion
            Error     = ''
        }
    } catch {
        return [pscustomobject]@{ Available = $false; Version = ''; Error = $_.Exception.Message }
    }
}

function Start-AutoUpdateProbe {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$CurrentVersion)
    $shell = [powershell]::Create()
    $file = $PSCommandPath.Replace("'", "''")
    $script = "param(`$source, `$currentVersion); . '$file'; Test-AutoUpdateAvailable -Source `$source -CurrentVersion `$currentVersion"
    [void]$shell.AddScript($script).AddArgument($Source).AddArgument($CurrentVersion)
    return [pscustomobject]@{ Shell = $shell; Async = $shell.BeginInvoke() }
}

function Complete-AutoUpdateProbe {
    param($Probe)
    if (-not $Probe -or -not $Probe.Async.IsCompleted) { return $null }
    try {
        return @($Probe.Shell.EndInvoke($Probe.Async)) | Select-Object -Last 1
    } catch {
        return [pscustomobject]@{ Available = $false; Version = ''; Error = $_.Exception.Message }
    } finally {
        $Probe.Shell.Dispose()
    }
}

function Get-AutoUpdateArchive {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Destination)
    $ProgressPreference = 'SilentlyContinue'
    $uri = "{0}/api/v4/projects/{1}/repository/archive.zip?sha={2}" -f `
        $Ctx.BaseUrl, $Ctx.ProjectId, [System.Uri]::EscapeDataString($Ctx.Branch)
    Invoke-WebRequest -Uri $uri -Headers $Ctx.Headers -OutFile $Destination -UseBasicParsing -ErrorAction Stop
}

function Start-AutoUpdate {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][int]$ParentProcessId
    )
    if (-not $Source.RemoteCtx) { throw 'GitLab connection is not configured.' }
    $workRoot = Join-Path $env:TEMP ('worktime-tracker-update-' + $Version + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    try {
        $archive = Join-Path $workRoot 'update.zip'
        Get-AutoUpdateArchive -Ctx $Source.RemoteCtx -Destination $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $workRoot -Force
        $sourceDir = Get-ChildItem -LiteralPath $workRoot -Directory | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\setup.cmd')
        } | Select-Object -First 1
        if (-not $sourceDir) { throw 'The GitLab archive does not contain scripts\\setup.cmd.' }

        $helperPath = Join-Path $workRoot 'ApplyUpdate.ps1'
        $helper = @'
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$InstallDir,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][int]$ParentProcessId
)
$ErrorActionPreference = 'Stop'
try {
    $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($parent) { $parent.WaitForExit() }
    $setup = Join-Path $SourceDir 'scripts\setup.cmd'
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ""{0}" /force /quiet"' -f $setup) -Wait -PassThru
    if ($process.ExitCode -ne 0) { exit $process.ExitCode }
    $launch = Join-Path $InstallDir 'client\launch.cmd'
    if (Test-Path -LiteralPath $launch) { Start-Process -FilePath $launch }
} finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
'@
        [System.IO.File]::WriteAllText($helperPath, $helper, [System.Text.UTF8Encoding]::new($true))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$helperPath,
            '-SourceDir',$sourceDir.FullName,'-InstallDir',$InstallDir,'-WorkRoot',$workRoot,
            '-ParentProcessId',$ParentProcessId
        ) | Out-Null
    } catch {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Register-AutoUpdate {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [bool]$Enabled = $true
    )
    $defaultInstall = Join-Path $env:LOCALAPPDATA 'worktime-tracker'
    if (-not $Enabled -or -not $Source.RemoteCtx -or -not (Test-Path -LiteralPath (Join-Path $AppRoot 'scripts\setup.cmd'))) { return }
    if ([System.IO.Path]::GetFullPath($AppRoot).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($defaultInstall).TrimEnd('\')) { return }

    $script:AutoUpdateProbe = $null
    $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [timespan]::FromSeconds(1)
    $pollTimer.Add_Tick({
        $result = Complete-AutoUpdateProbe -Probe $script:AutoUpdateProbe
        if (-not $result) { return }
        $script:AutoUpdateProbe = $null
        if (-not $result.Available) { return }
        try {
            $Window.Title = "WorkTime Tracker - updating to v$($result.Version)..."
            Start-AutoUpdate -Source $Source -InstallDir $defaultInstall -Version $result.Version -ParentProcessId $PID
            $Window.Close()
        } catch {
            [System.Windows.MessageBox]::Show("自動アップデートに失敗しました。`n$($_.Exception.Message)", '更新エラー', 'OK', 'Warning') | Out-Null
        }
    })
    $pollTimer.Start()
    $Window.Add_Loaded({
        if (-not $script:AutoUpdateProbe) { $script:AutoUpdateProbe = Start-AutoUpdateProbe -Source $Source -CurrentVersion $CurrentVersion }
    })
    $Window.Add_Closed({
        $pollTimer.Stop()
        if ($script:AutoUpdateProbe) { $script:AutoUpdateProbe.Shell.Dispose() }
    })
}
