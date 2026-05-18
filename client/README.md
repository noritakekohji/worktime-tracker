# client (PowerShell + WPF)

## ファイル

| ファイル | 役割 |
|---|---|
| `WorkTimeTracker.ps1` | エントリポイント |
| `MainWindow.xaml` | メイン画面レイアウト |
| `launch.cmd` | ダブルクリック起動用ランチャ |
| `lib/Yaml.ps1` | YAML 読込ヘルパ (powershell-yaml 依存) |
| `lib/DataStore.ps1` | マスタ/実績データの読み書き |

## 起動

```cmd
launch.cmd
```

もしくは PowerShell から:

```powershell
powershell -ExecutionPolicy Bypass -File client\WorkTimeTracker.ps1
```

初回起動時は `powershell-yaml` モジュールを CurrentUser スコープで自動インストールします。

## 現状の機能 (プロトタイプ)

- マスタ YAML 読込 (members / projects / categories)
- 4段カスケード ドロップダウン (project → process → task_group → task)
- 表示年月の切替・当月エントリ一覧表示
- 新規エントリ追加 (**バックデート可** — 任意の過去日)
- 行削除
- ローカル JSON 保存 (バックデート分は該当月のファイルに自動振分)

## 未実装 (次フェーズ)

- git pull --rebase / commit / push 自動化
- 資格情報マネージャ I/O (GitLab Project Access Token 保管)
- 管理者モード (マスタ YAML の GUI 編集)
- 既存エントリの編集 (現状は削除 → 再追加)

## 注意 (PowerShell 5.1)

`.ps1` ファイルは **UTF-8 with BOM** で保存する必要があります (日本語コメント・文字列のため)。
編集後はエンコーディングを確認してください。
