# client (PowerShell + WPF)

## 構成 (予定)

- `WorkTimeTracker.ps1` — エントリポイント。XAML をロードして起動
- `MainWindow.xaml` — メイン画面 (日次入力)
- `AdminWindow.xaml` — 管理者モード (マスタ編集)
- `lib/`
  - `Git.ps1` — git pull/commit/push ラッパー
  - `Credential.ps1` — Windows 資格情報マネージャ I/O
  - `Yaml.ps1` — YAML パーサ (powershell-yaml モジュール)
  - `DataStore.ps1` — data/*.json の読み書き

## TODO

- [ ] WPF XAML スケルトン
- [ ] 4段カスケード ドロップダウン
- [ ] git wrapper (pull --rebase / commit / push)
- [ ] 資格情報マネージャ I/O
- [ ] YAML マスタ読込
- [ ] 月次ファイル CRUD
- [ ] 管理者モード切替
