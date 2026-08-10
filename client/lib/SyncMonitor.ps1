# SyncMonitor.ps1 - background GitLab update checks without automatic downloads.

. (Join-Path $PSScriptRoot 'GitLab.ps1')

function _SyncMonitorPath {
    param($Source)
    return (Join-Path $Source.LocalRoot '.sync_monitor.json')
}

function _ReadSyncMonitorState {
    param($Source)
    $empty = [pscustomobject]@{
        targets = [pscustomobject]@{}
        pending = [pscustomobject]@{}
        suppress_until = [pscustomobject]@{}
    }
    $path = _SyncMonitorPath -Source $Source
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in 'targets','pending','suppress_until') {
            if (-not $loaded.PSObject.Properties[$name] -or -not $loaded.$name) {
                Add-Member -InputObject $loaded -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) -Force
            }
        }
        return $loaded
    } catch {
        return $empty
    }
}

function _WriteSyncMonitorState {
    param($Source, $State)
    try {
        $json = $State | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText((_SyncMonitorPath -Source $Source), $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # A monitor-state failure must not affect the primary sync flow.
    }
}

function _GetRemoteTreeFingerprint {
    param($Source, [string]$Path)
    $items = Get-GitLabTree -Ctx $Source.RemoteCtx -Path $Path
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        if ($item -and [string]$item.type -eq 'blob') {
            $parts.Add(('{0}|{1}' -f [string]$item.path, [string]$item.id))
        }
    }
    $text = ($parts | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return [System.BitConverter]::ToString($bytes).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Test-RemoteUpdateNotice {
    param(
        [Parameter(Mandatory)]$Source,
        [switch]$Master,
        [string]$DataPath
    )
    $result = [pscustomobject]@{ MasterChanged = $false; DataChanged = $false; Errors = @() }
    if (-not $Source.RemoteCtx) { return $result }
    $state = _ReadSyncMonitorState -Source $Source
    $checks = @()
    if ($Master) { $checks += [pscustomobject]@{ Key = 'master'; Path = 'master'; Kind = 'MasterChanged' } }
    if ($DataPath) { $checks += [pscustomobject]@{ Key = "data:$DataPath"; Path = $DataPath; Kind = 'DataChanged' } }
    foreach ($check in $checks) {
        try {
            $fingerprint = _GetRemoteTreeFingerprint -Source $Source -Path $check.Path
            $previous = [string]$state.targets.($check.Key)
            $state.targets | Add-Member -NotePropertyName $check.Key -NotePropertyValue $fingerprint -Force
            if ($previous -and $previous -ne $fingerprint) {
                $until = [datetime]::MinValue
                [void][datetime]::TryParse([string]$state.suppress_until.($check.Key), [ref]$until)
                $isSuppressed = $until -gt (Get-Date)
                $state.pending | Add-Member -NotePropertyName $check.Key -NotePropertyValue (-not $isSuppressed) -Force
            }
            if ([bool]$state.pending.($check.Key)) { $result.($check.Kind) = $true }
        } catch {
            $result.Errors += ("{0}: {1}" -f $check.Path, $_.Exception.Message)
        }
    }
    _WriteSyncMonitorState -Source $Source -State $state
    return $result
}

function Clear-RemoteUpdateNotice {
    param([Parameter(Mandatory)]$Source, [switch]$Master, [string]$DataPath)
    $state = _ReadSyncMonitorState -Source $Source
    if ($Master) { $state.pending | Add-Member -NotePropertyName 'master' -NotePropertyValue $false -Force }
    if ($DataPath) { $state.pending | Add-Member -NotePropertyName "data:$DataPath" -NotePropertyValue $false -Force }
    _WriteSyncMonitorState -Source $Source -State $state
}

function Suppress-RemoteUpdateNotice {
    param([Parameter(Mandatory)]$Source, [switch]$Master, [string]$DataPath, [int]$Minutes = 10)
    $state = _ReadSyncMonitorState -Source $Source
    $until = (Get-Date).AddMinutes($Minutes).ToString('o')
    if ($Master) { $state.suppress_until | Add-Member -NotePropertyName 'master' -NotePropertyValue $until -Force }
    if ($DataPath) { $state.suppress_until | Add-Member -NotePropertyName "data:$DataPath" -NotePropertyValue $until -Force }
    _WriteSyncMonitorState -Source $Source -State $state
}

function Start-RemoteUpdateProbe {
    # A dedicated runspace keeps the WPF Dispatcher responsive during the API call.
    param([Parameter(Mandatory)]$Source, [switch]$Master, [string]$DataPath)
    $shell = [powershell]::Create()
    $file = $PSCommandPath.Replace("'", "''")
    $script = "param(`$source, `$master, `$dataPath); . '$file'; Test-RemoteUpdateNotice -Source `$source -Master:`$master -DataPath `$dataPath"
    [void]$shell.AddScript($script).AddArgument($Source).AddArgument([bool]$Master).AddArgument($DataPath)
    return [pscustomobject]@{ Shell = $shell; Async = $shell.BeginInvoke() }
}

function Complete-RemoteUpdateProbe {
    param($Probe)
    if (-not $Probe -or -not $Probe.Async.IsCompleted) { return $null }
    try {
        return @($Probe.Shell.EndInvoke($Probe.Async)) | Select-Object -Last 1
    } catch {
        # A failed background check is intentionally silent; the next interval retries it.
        return [pscustomobject]@{ MasterChanged = $false; DataChanged = $false; Errors = @($_.Exception.Message) }
    } finally {
        $Probe.Shell.Dispose()
    }
}
