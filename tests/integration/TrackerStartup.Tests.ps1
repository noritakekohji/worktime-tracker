# TrackerStartup.Tests.ps1 — 実プロセスで日次入力画面の起動を確認するスモークテスト

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:TrackerScript = Join-Path $script:RepoRoot 'client\WorkTimeTracker.ps1'
}

Describe 'WorkTime Tracker 起動スモークテスト' -Tag 'integration','ui','smoke' {
    It '初回データ読込を最初の画面描画後に開始する' {
        $scriptText = Get-Content -LiteralPath $script:TrackerScript -Raw -Encoding UTF8
        $scriptText | Should -Match 'Add_ContentRendered'
        $scriptText | Should -Match 'InitialViewLoadTimer'
        $scriptText | Should -Not -Match '(?m)^Load-ViewMonth\s*$'
    }

    It '設定データに依存せず MainWindow を実表示して正常終了する' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SmokeTest' -f $script:TrackerScript)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)

        try {
            $process.WaitForExit(15000) | Should -Be $true -Because 'Tracker の起動スモークテストは 15 秒以内に完了する必要がある'
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because ("Tracker の起動に失敗しました.`nstdout:`n{0}`nstderr:`n{1}" -f $stdout, $stderr)
        } finally {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    }
}
