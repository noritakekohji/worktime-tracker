# ログ出力先設定化 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ログ出力先フォルダを ConfigDialog から設定できるようにし、ブランクのときはログを出力しない。

**Architecture:** `config.json` に `log_dir` フィールドを追加し、ConfigDialog にフォルダ選択UIを追加する。`WorkTimeTracker.ps1` と `ReportViewer.ps1` は Config ロード後に `$Script:LogPath` を更新する関数を呼ぶ。ブランクのとき `$Script:LogPath` を `$null` にし、`Write-FatalLog` / `_Trace` / `_Diag` は `$null` チェックで早期 return する。

**Tech Stack:** PowerShell 5.1, WPF (XAML), Pester 5

---

## ファイル構成

| ファイル | 変更種別 | 内容 |
|---|---|---|
| `client/lib/Config.ps1` | Modify | `New-DefaultConfig` に `log_dir = ''` 追加 |
| `client/ConfigDialog.xaml` | Modify | `LogDirBox`・`BrowseLogBtn`・ヒント TextBlock を追加 (Row 13) |
| `client/lib/ConfigDialog.ps1` | Modify | `LogDirBox`/`BrowseLogBtn` を FindName 配列に追加、初期化・参照ボタン・保存ロジック追加 |
| `client/WorkTimeTracker.ps1` | Modify | 起動時の固定 LogPath 初期化を除去し、Config ロード後に `Update-LogPath` 呼び出し |
| `reports/ReportViewer.ps1` | Modify | 同上。加えて `_Trace` / `_Diag` / `_TraceMgr` も `$Script:LogPath` 参照に統一 |
| `tests/lib/Config.Tests.ps1` | Create | `log_dir` フィールドの補完・Save・Load ラウンドトリップをテスト |

---

### Task 1: `Config.ps1` に `log_dir` フィールドを追加する

**Files:**
- Modify: `client/lib/Config.ps1`
- Create: `tests/lib/Config.Tests.ps1`

- [ ] **Step 1: テストファイルを新規作成する**

`tests/lib/Config.Tests.ps1` を以下の内容で作成する（UTF-8 BOM 付き）:

```powershell
# Config.Tests.ps1 — log_dir フィールドの補完・保存・読込テスト

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
}

Describe 'New-DefaultConfig' -Tag 'unit','config' {
    It 'log_dir フィールドが空文字で存在する' {
        $cfg = New-DefaultConfig
        $cfg.PSObject.Properties.Name | Should -Contain 'log_dir'
        $cfg.log_dir | Should -Be ''
    }
}

Describe 'Load-Config: log_dir 補完' -Tag 'unit','config' {
    It '既存 config.json に log_dir がない場合 空文字で補完される' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            # log_dir を含まない旧形式の config を書く
            '{"mode":"local","member_id":"E001","local_store":"C:\\tmp\\store","branch":"main","gitlab_url":"","project_id":""}' |
                Set-Content -LiteralPath $cfgPath -Encoding UTF8

            # Get-ConfigPath を一時パスに差し替えるためスコープを操作する
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = Load-Config
                $cfg.log_dir | Should -Be ''
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Save-Config / Load-Config: log_dir ラウンドトリップ' -Tag 'unit','config' {
    It 'log_dir を保存して読み戻せる' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = New-DefaultConfig
                $cfg.log_dir = 'C:\logs\worktime'
                Save-Config -Config $cfg
                $loaded = Load-Config
                $loaded.log_dir | Should -Be 'C:\logs\worktime'
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'log_dir が空文字のとき保存・読込後も空文字' {
        $tmp = Join-Path $env:TEMP ("wt-cfg-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'config.json'
            $origFn = ${function:Get-ConfigPath}
            ${function:Get-ConfigPath} = { return $cfgPath }
            try {
                $cfg = New-DefaultConfig
                $cfg.log_dir = ''
                Save-Config -Config $cfg
                $loaded = Load-Config
                $loaded.log_dir | Should -Be ''
            } finally {
                ${function:Get-ConfigPath} = $origFn
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: テストを実行して FAIL することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1 -Tag config
```

期待: `log_dir フィールドが空文字で存在する` が FAIL する（`New-DefaultConfig` にまだ `log_dir` がないため）

- [ ] **Step 3: `Config.ps1` の `New-DefaultConfig` に `log_dir` を追加する**

`client/lib/Config.ps1` の `New-DefaultConfig` を以下に修正する:

```powershell
function New-DefaultConfig {
    return [pscustomobject]@{
        mode         = 'local'                    # 'local' | 'gitlab'
        gitlab_url   = 'https://gitlab.example.com'
        project_id   = ''
        branch       = 'main'
        member_id    = ''
        local_store  = (Get-DefaultLocalStore)
        local_root   = ''                         # (旧設定; 互換)
        log_dir      = ''                         # ログ出力先フォルダ (空文字 = 出力なし)
    }
}
```

- [ ] **Step 4: テストを実行して PASS することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1 -Tag config
```

期待: `Tests Passed: 4, Failed: 0`

- [ ] **Step 5: BOM チェックを実施する**

```powershell
powershell -ExecutionPolicy Bypass -Command "
@('client/lib/Config.ps1','tests/lib/Config.Tests.ps1') | ForEach-Object {
    $f = Join-Path (Get-Location) $_
    $b = [System.IO.File]::ReadAllBytes($f)
    if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
        $c = [System.IO.File]::ReadAllText($f)
        [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding(`$true)))
        Write-Host \"BOM added: $_\"
    } else { Write-Host \"BOM OK: $_\" }
}"
```

- [ ] **Step 6: 全テストを実行して回帰がないことを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

期待: `Failed: 0`

- [ ] **Step 7: コミットする**

```bash
git add client/lib/Config.ps1 tests/lib/Config.Tests.ps1
git commit -m "$(cat <<'EOF'
feat(config): log_dir フィールドを追加 (ブランク=ログなし)

- New-DefaultConfig に log_dir = '' を追加
- Load-Config の欠損補完ロジックで既存 config にも自動補完
- tests/lib/Config.Tests.ps1 を新設 (補完・保存・読込 4ケース)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ConfigDialog に「ログ出力先」UIを追加する

**Files:**
- Modify: `client/ConfigDialog.xaml`
- Modify: `client/lib/ConfigDialog.ps1`

ConfigDialog.xaml の現状: Grid に 15 行 (Row 0〜14) 定義。Row 13 は空き。Row 14 に `StatusText`。
Row 13 に `LogDirBox` + `BrowseLogBtn`、Row 14 にヒント TextBlock を追加し、`StatusText` を Row 15 に移す。

- [ ] **Step 1: `ConfigDialog.xaml` を修正する**

`ConfigDialog.xaml` の Grid 行定義（現在 15 行 = Row 0〜14）を 17 行（Row 0〜16）に拡張する。

現在の行定義（7ペア + 1 = 15行）:
```xml
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
```

修正後（8ペア + 1 = 17行。最後から2行目のペアを追加）:
```xml
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
```

- [ ] **Step 2: `ConfigDialog.xaml` にログ出力先UIを追加する**

`ConfigDialog.xaml` の現在の `StatusText` (Row 14) の直前に以下を挿入し、`StatusText` を Row 16 に変更する。

現在の StatusText:
```xml
            <TextBlock Grid.Row="14" Grid.Column="0" Grid.ColumnSpan="3" x:Name="StatusText" FontSize="12" Margin="0,14,0,0" TextWrapping="Wrap"/>
```

挿入するコード（Row 13〜15 に追加）と StatusText の移動:
```xml
            <!-- ログ出力先 (全モード共通・任意) -->
            <Label Grid.Row="13" Grid.Column="0" Content="ログ出力先:"/>
            <TextBox Grid.Row="13" Grid.Column="1" x:Name="LogDirBox"/>
            <Button  Grid.Row="13" Grid.Column="2" x:Name="BrowseLogBtn" Content="📁 参照…"/>
            <TextBlock Grid.Row="14" Grid.Column="1" Grid.ColumnSpan="2" FontSize="11"
                       Text="ブランクのとき出力なし (last_error.log / report_trace.log)"/>

            <TextBlock Grid.Row="16" Grid.Column="0" Grid.ColumnSpan="3" x:Name="StatusText" FontSize="12" Margin="0,14,0,0" TextWrapping="Wrap"/>
```

また `Window` の `Height` を `680` から `730` に変更してダイアログを縦に広げる:
```xml
    Height="730" Width="640"
```

- [ ] **Step 3: `ConfigDialog.ps1` の FindName 配列に `LogDirBox`・`BrowseLogBtn` を追加する**

`client/lib/ConfigDialog.ps1` の FindName 配列（現在の `foreach ($n in @('ModeCombo', ...))` の箇所）を修正する。

現在:
```powershell
    foreach ($n in 'ModeCombo','UrlBox','ProjectIdBox','BranchBox','TokenBox','MemberIdBox','StatusText','TestBtn','SaveBtn','CancelBtn',
                   'UrlLabel','ProjectIdLabel','ProjectIdHint','BranchLabel','TokenLabel','TokenHint',
                   'LocalRootBox','BrowseBtn') {
```

修正後（末尾に `LogDirBox`, `BrowseLogBtn` を追加）:
```powershell
    foreach ($n in 'ModeCombo','UrlBox','ProjectIdBox','BranchBox','TokenBox','MemberIdBox','StatusText','TestBtn','SaveBtn','CancelBtn',
                   'UrlLabel','ProjectIdLabel','ProjectIdHint','BranchLabel','TokenLabel','TokenHint',
                   'LocalRootBox','BrowseBtn','LogDirBox','BrowseLogBtn') {
```

- [ ] **Step 4: `ConfigDialog.ps1` の初期化部分に `LogDirBox` の値設定を追加する**

`$u.LocalRootBox.Text = ...` の行の直後に追加する。

現在（`$u.LocalRootBox.Text` の行）:
```powershell
    $u.LocalRootBox.Text = if ($Config.local_store) { $Config.local_store } else { (Get-DefaultLocalStore) }
```

修正後（`$u.LogDirBox.Text` の行を追加）:
```powershell
    $u.LocalRootBox.Text = if ($Config.local_store) { $Config.local_store } else { (Get-DefaultLocalStore) }
    $u.LogDirBox.Text    = if ($Config.PSObject.Properties['log_dir']) { $Config.log_dir } else { '' }
```

- [ ] **Step 5: `ConfigDialog.ps1` に `BrowseLogBtn` のクリックハンドラを追加する**

`$u.BrowseBtn.Add_Click({...})` ブロックの直後に追加する:

```powershell
    $u.BrowseLogBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'ログ出力先フォルダ (ブランクのとき出力なし)'
        if ($u.LogDirBox.Text -and (Test-Path -LiteralPath $u.LogDirBox.Text)) {
            $dlg.SelectedPath = $u.LogDirBox.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $u.LogDirBox.Text = $dlg.SelectedPath
        }
    })
```

- [ ] **Step 6: `ConfigDialog.ps1` の保存ロジックに `log_dir` の書き込みを追加する**

保存ロジック内の `$Config.local_store = $lr` の行の直後に追加する。

現在（`$Config.local_store = $lr` の行）:
```powershell
            $Config.local_store = $lr
            if ($mode -eq 'gitlab') {
```

修正後:
```powershell
            $Config.local_store = $lr
            $Config.log_dir     = $u.LogDirBox.Text.Trim()
            if ($mode -eq 'gitlab') {
```

- [ ] **Step 7: BOM チェックを実施する**

```powershell
powershell -ExecutionPolicy Bypass -Command "
@('client/ConfigDialog.xaml','client/lib/ConfigDialog.ps1') | ForEach-Object {
    $f = Join-Path (Get-Location) $_
    $b = [System.IO.File]::ReadAllBytes($f)
    if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
        $c = [System.IO.File]::ReadAllText($f)
        [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding(`$true)))
        Write-Host \"BOM added: $_\"
    } else { Write-Host \"BOM OK: $_\" }
}"
```

- [ ] **Step 8: 全テストを実行して PASS することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

期待: `Failed: 0`（XAML パース + FindName 整合テストが通ること）

- [ ] **Step 9: コミットする**

```bash
git add client/ConfigDialog.xaml client/lib/ConfigDialog.ps1
git commit -m "$(cat <<'EOF'
feat(ui): ConfigDialog にログ出力先フォルダ選択UIを追加

- ConfigDialog.xaml に LogDirBox / BrowseLogBtn / ヒント TextBlock 追加 (Row 13-14)
- ConfigDialog.ps1: 初期化・参照ボタン・保存ロジックに log_dir を追加

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `WorkTimeTracker.ps1` のログ初期化を Config ロード後に移す

**Files:**
- Modify: `client/WorkTimeTracker.ps1`

起動冒頭のハードコードされたログ初期化を `$null` に変更し、Config ロード後 (`Initialize-AppContext` 後) に `Update-LogPath` で再設定する。

- [ ] **Step 1: `WorkTimeTracker.ps1` のログ初期化部分を修正する**

現在（行 15〜20）:
```powershell
# ---- 致命エラーログ + 持続表示 ----
$Script:LogDir = Join-Path $env:APPDATA 'worktime-tracker'
if (-not (Test-Path -LiteralPath $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}
$Script:LogPath = Join-Path $Script:LogDir 'last_error.log'
```

修正後:
```powershell
# ---- 致命エラーログ ----
# Config ロード前は $null (出力なし)。Initialize-AppContext 後に Update-LogPath で確定。
$Script:LogPath = $null
```

- [ ] **Step 2: `Write-FatalLog` に `$null` チェックを追加する**

現在:
```powershell
function Write-FatalLog {
    param([string]$Text)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] $Text`r`n" -Encoding UTF8
    } catch { }
}
```

修正後:
```powershell
function Write-FatalLog {
    param([string]$Text)
    if (-not $Script:LogPath) { return }
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] $Text`r`n" -Encoding UTF8
    } catch { }
}
```

- [ ] **Step 3: `trap` の `$Script:LogPath` 参照メッセージを修正する**

現在の `trap` 内:
```powershell
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)`n`n--- 詳細はログ: $Script:LogPath"
```

修正後:
```powershell
    $logNote = if ($Script:LogPath) { "`n`n--- 詳細はログ: $Script:LogPath" } else { '' }
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)$logNote"
```

- [ ] **Step 4: `Update-LogPath` 関数を追加する**

`Write-FatalLog` 関数の直後に追加する:

```powershell
function Update-LogPath {
    param([Parameter(Mandatory)]$Config)
    $dir = if ($Config.PSObject.Properties['log_dir']) { $Config.log_dir } else { '' }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $Script:LogPath = $null
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { $Script:LogPath = $null; return }
    }
    $Script:LogPath = Join-Path $dir 'last_error.log'
}
```

- [ ] **Step 5: `Initialize-AppContext` の後で `Update-LogPath` を呼ぶ**

`Initialize-AppContext` の戻り値を受け取って `$Script:Config` を設定する箇所（現行 246〜258 行付近）の直後に追加する。

現在（`$Script:Config = $ctx['Config']` の行）:
```powershell
$Script:Config     = $ctx['Config']
```

修正後:
```powershell
$Script:Config     = $ctx['Config']
Update-LogPath -Config $Script:Config
```

- [ ] **Step 6: `Write-FatalLog` の起動時2行（START / PSVersion）は移動不要、ログパスが $null なら自動スキップされる**

確認のみ。変更不要。

- [ ] **Step 7: BOM チェックを実施する**

```powershell
powershell -ExecutionPolicy Bypass -Command "
$f = 'client/WorkTimeTracker.ps1'
$fp = Join-Path (Get-Location) $f
$b = [System.IO.File]::ReadAllBytes($fp)
if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
    $c = [System.IO.File]::ReadAllText($fp)
    [System.IO.File]::WriteAllText($fp, $c, (New-Object System.Text.UTF8Encoding(`$true)))
    Write-Host 'BOM added'
} else { Write-Host 'BOM OK' }"
```

- [ ] **Step 8: 全テストを実行して PASS することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

期待: `Failed: 0`

- [ ] **Step 9: コミットする**

```bash
git add client/WorkTimeTracker.ps1
git commit -m "$(cat <<'EOF'
feat(tracker): ログパスを config.log_dir から動的に決定する

- 起動冒頭の固定 LogPath 初期化を $null に変更
- Write-FatalLog に $null チェックを追加 (ログなしモード対応)
- Update-LogPath 関数を追加: Config ロード後にログパスを確定
- Initialize-AppContext 後に Update-LogPath を呼び出す

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `ReportViewer.ps1` のログ初期化を Config ロード後に移す

**Files:**
- Modify: `reports/ReportViewer.ps1`

`WorkTimeTracker.ps1` と同様の変更に加え、`_Trace` / `_Diag` / `_TraceMgr` 内のハードコードされたパスを `$Script:LogPath` 参照に変更する。

- [ ] **Step 1: `ReportViewer.ps1` のログ初期化部分を修正する**

現在（行 12〜17）:
```powershell
# ---- 致命エラーログ (Tracker と共用) ----
$Script:LogDir = Join-Path $env:APPDATA 'worktime-tracker'
if (-not (Test-Path -LiteralPath $Script:LogDir)) {
    New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
}
$Script:LogPath = Join-Path $Script:LogDir 'last_error.log'
```

修正後:
```powershell
# ---- 致命エラーログ ----
# Config ロード前は $null (出力なし)。Initialize-DataContext 後に Update-LogPath で確定。
$Script:LogPath = $null
```

- [ ] **Step 2: `Write-FatalLog` に `$null` チェックを追加する**

現在:
```powershell
function Write-FatalLog {
    param([string]$Text)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] [Report] $Text`r`n" -Encoding UTF8
    } catch { }
}
```

修正後:
```powershell
function Write-FatalLog {
    param([string]$Text)
    if (-not $Script:LogPath) { return }
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$stamp] [Report] $Text`r`n" -Encoding UTF8
    } catch { }
}
```

- [ ] **Step 3: `ReportViewer.ps1` の `trap` の `$Script:LogPath` 参照メッセージを修正する**

現在:
```powershell
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)`n`n--- 詳細: $Script:LogPath"
```

修正後:
```powershell
    $logNote = if ($Script:LogPath) { "`n`n--- 詳細: $Script:LogPath" } else { '' }
    $msg = "$($_.Exception.Message)`n`n--- StackTrace ---`n$($_.ScriptStackTrace)$logNote"
```

- [ ] **Step 4: `Update-LogPath` 関数を `Write-FatalLog` 直後に追加する**

```powershell
function Update-LogPath {
    param([Parameter(Mandatory)]$Config)
    $dir = if ($Config.PSObject.Properties['log_dir']) { $Config.log_dir } else { '' }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $Script:LogPath  = $null
        $Script:TracePath = $null
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {
            $Script:LogPath   = $null
            $Script:TracePath = $null
            return
        }
    }
    $Script:LogPath   = Join-Path $dir 'last_error.log'
    $Script:TracePath = Join-Path $dir 'report_trace.log'
}
```

- [ ] **Step 5: `Initialize-DataContext` の後で `Update-LogPath` を呼ぶ**

`$Script:Config = $ctx.Config` の行の直後に追加する（行 70 付近）:

現在:
```powershell
$Script:Config        = $ctx.Config
```

修正後:
```powershell
$Script:Config        = $ctx.Config
Update-LogPath -Config $Script:Config
```

- [ ] **Step 6: `_Trace` 関数（行 427〜435 付近）を `$Script:TracePath` 参照に変更する**

現在:
```powershell
    function _Trace {
        param([string]$Tag, [string]$Msg)
        try {
            $logDir = Join-Path $env:APPDATA 'worktime-tracker'
            if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $logDir 'report_trace.log') `
                -Value ("[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
        } catch { }
    }
```

修正後:
```powershell
    function _Trace {
        param([string]$Tag, [string]$Msg)
        if (-not $Script:TracePath) { return }
        try {
            Add-Content -LiteralPath $Script:TracePath `
                -Value ("[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
        } catch { }
    }
```

- [ ] **Step 7: `$Script:DiagLogPath` と `_Diag` 関数（行 1172〜1178 付近）を `$Script:TracePath` 参照に変更する**

現在:
```powershell
# 必ず書ける場所に診断ログを出す (Desktop に固定)
$Script:DiagLogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'report_trace.log'
function _Diag {
    param([string]$Msg)
    try {
        Add-Content -LiteralPath $Script:DiagLogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) -Encoding UTF8
    } catch { }
}
```

修正後:
```powershell
function _Diag {
    param([string]$Msg)
    if (-not $Script:TracePath) { return }
    try {
        Add-Content -LiteralPath $Script:TracePath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) -Encoding UTF8
    } catch { }
}
```

- [ ] **Step 8: `_TraceMgr` 関数（行 2294〜2302 付近）を `$Script:TracePath` 参照に変更する**

現在:
```powershell
function _TraceMgr {
    param([string]$Tag, [string]$Msg)
    try {
        $logDir = Join-Path $env:APPDATA 'worktime-tracker'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $logDir 'report_trace.log') `
            -Value ("[{0}] [mgr] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
    } catch { }
}
```

修正後:
```powershell
function _TraceMgr {
    param([string]$Tag, [string]$Msg)
    if (-not $Script:TracePath) { return }
    try {
        Add-Content -LiteralPath $Script:TracePath `
            -Value ("[{0}] [mgr] {1} {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Tag, $Msg) -Encoding UTF8
    } catch { }
}
```

- [ ] **Step 9: BOM チェックを実施する**

```powershell
powershell -ExecutionPolicy Bypass -Command "
$f = 'reports/ReportViewer.ps1'
$fp = Join-Path (Get-Location) $f
$b = [System.IO.File]::ReadAllBytes($fp)
if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
    $c = [System.IO.File]::ReadAllText($fp)
    [System.IO.File]::WriteAllText($fp, $c, (New-Object System.Text.UTF8Encoding(`$true)))
    Write-Host 'BOM added'
} else { Write-Host 'BOM OK' }"
```

- [ ] **Step 10: 全テストを実行して PASS することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

期待: `Failed: 0`

- [ ] **Step 11: コミットする**

```bash
git add reports/ReportViewer.ps1
git commit -m "$(cat <<'EOF'
feat(report): ログパスを config.log_dir から動的に決定する

- 起動冒頭の固定 LogPath 初期化を $null に変更
- Write-FatalLog に $null チェックを追加
- Update-LogPath 関数を追加: $Script:LogPath / $Script:TracePath を設定
- _Trace / _Diag / _TraceMgr を $Script:TracePath 参照に統一
- デスクトップ固定の DiagLogPath を廃止 ($Script:TracePath に一本化)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: CHANGELOG を更新してタグを打つ

> **事前確認:** CLAUDE.md のバージョニング規約により、バージョン番号の変更前にユーザーに確認する。
> `1.0.0 → 1.1.0` への変更を実施する前に確認を取ること。

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: `CHANGELOG.md` を更新する**

`CHANGELOG.md` の `[Unreleased]` セクション (または `[1.0.0]` の直上) に以下を追記する:

```markdown
## [1.1.0] - 2026-06-20

### Added
- 設定画面（接続設定）にログ出力先フォルダ選択UIを追加
- `config.json` に `log_dir` フィールドを追加（ブランク = ログなし）
- `last_error.log` / `report_trace.log` の出力先を `log_dir` に従って動的に変更

### Changed
- ログ出力先のデフォルトを「なし」に変更（旧デフォルト: `%APPDATA%\worktime-tracker`）
  - 既存ユーザーは設定画面で `log_dir` を指定すれば従来どおりログが出力される
```

- [ ] **Step 2: `Version.ps1` のバージョン番号を更新する**

`client/lib/Version.ps1` の `$Script:AppVersion` を `'1.0.0'` から `'1.1.0'` に変更する:

```powershell
$Script:AppVersion       = '1.1.0'
```

- [ ] **Step 3: BOM チェックを実施する**

```powershell
powershell -ExecutionPolicy Bypass -Command "
@('CHANGELOG.md','client/lib/Version.ps1') | ForEach-Object {
    $f = Join-Path (Get-Location) $_
    $b = [System.IO.File]::ReadAllBytes($f)
    if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
        $c = [System.IO.File]::ReadAllText($f)
        [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding(`$true)))
        Write-Host \"BOM added: $_\"
    } else { Write-Host \"BOM OK: $_\" }
}"
```

- [ ] **Step 4: 全テストを実行して PASS することを確認する**

```
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
```

期待: `Failed: 0`

- [ ] **Step 5: コミットしてタグを打つ**

```bash
git add CHANGELOG.md client/lib/Version.ps1
git commit -m "$(cat <<'EOF'
chore: v1.1.0 リリース — ログ出力先設定化

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git tag v1.1.0
git push && git push --tags
```
