---
title: ログ出力先の設定化
date: 2026-06-20
status: approved
---

# ログ出力先の設定化

## 概要

現在ハードコードされているログファイルの出力先を、ConfigDialog から設定できるようにする。
`config.json` の `log_dir` フィールドに保存し、ブランクの場合はログ出力なし。

## 変更対象ログ

| ログファイル | 現在のパス（ハードコード） | 変更後 |
|---|---|---|
| `last_error.log` | `%APPDATA%\worktime-tracker\last_error.log` | `log_dir\last_error.log`（空なら出力なし） |
| `report_trace.log`（トレース） | `%APPDATA%\worktime-tracker\report_trace.log` | `log_dir\report_trace.log`（空なら出力なし） |
| `report_trace.log`（診断） | `%USERPROFILE%\Desktop\report_trace.log` | `log_dir\report_trace.log`（空なら出力なし） |

## データモデル変更

### `config.json` に `log_dir` 追加

```json
{
  "mode": "local",
  "log_dir": ""
}
```

- デフォルト値: `""` (空文字) → ログなし
- 既存 `config.json` に `log_dir` がない場合、`Load-Config` の欠損フィールド補完ロジックで `""` が自動補完される（後方互換）
- パス存在チェックは起動時に行い、存在しなければ自動作成

## UI 変更（ConfigDialog）

「ローカル保管先」行の直下に追加：

```
ログ出力先:  [________________________]  [📁 参照]
             ブランクのとき出力なし
```

- コントロール: `LogDirBox`（TextBox）、`BrowseLogBtn`（Button）
- 参照ボタン: FolderBrowserDialog でフォルダ選択
- 空文字も有効な入力（= ログなし）
- 保存時にパスが入力されていればディレクトリを自動作成

## ログ書き込みロジック変更

### 初期化フロー（`WorkTimeTracker.ps1` / `ReportViewer.ps1`）

1. 起動直後（Config ロード前）: `$Script:LogPath = $null` → `Write-FatalLog` は書き込みをスキップ
2. Config ロード後: `$Script:LogPath` を更新
   - `log_dir` が空文字 → `$null` のまま（ログなし）
   - `log_dir` あり → `Join-Path $cfg.log_dir 'last_error.log'`

### `Write-FatalLog` の変更

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

### `_Trace` / `_Diag`（`ReportViewer.ps1`）

- `log_dir` が空の場合は何も書かない（早期 return）
- `log_dir` が指定されている場合は `log_dir\report_trace.log` に書き込む
- デスクトップ固定の `$Script:DiagLogPath` も `log_dir` に切り替え

## 影響ファイル

| ファイル | 変更内容 |
|---|---|
| `client/lib/Config.ps1` | `New-DefaultConfig` に `log_dir = ''` 追加 |
| `client/ConfigDialog.xaml` | `LogDirBox` + `BrowseLogBtn` + ヒントテキスト追加 |
| `client/lib/ConfigDialog.ps1` | UI 初期化・参照ボタン・保存ロジック追加 |
| `client/WorkTimeTracker.ps1` | ログパス初期化を `$null` に変更 → Config ロード後に `Update-LogPath` で再設定 |
| `reports/ReportViewer.ps1` | 同上 + `_Trace` / `_Diag` も `log_dir` 参照に変更 |

## テスト方針

- `Config.ps1`: `log_dir` フィールドの補完（既存 config に `log_dir` なし → `""` になること）
- `Write-FatalLog`: `$Script:LogPath` が `$null` のとき何も書かないこと
- ConfigDialog の保存: `log_dir` が `config.json` に書き込まれること
- 手動確認: `log_dir` を空にして起動 → ログファイルが生成されないこと
- 手動確認: `log_dir` を指定して起動 → 指定フォルダにログが生成されること
