# client (PowerShell + WPF, インストール不要)

## ファイル

| ファイル | 役割 |
|---|---|
| `WorkTimeTracker.ps1` | エントリポイント |
| `MainWindow.xaml` | メイン画面 (実績入力) |
| `ConfigDialog.xaml` | 初回設定ダイアログ |
| `AdminDialog.xaml` | 管理者モード (マスタ編集) |
| `launch.cmd` | ダブルクリック起動 |
| `lib/Config.ps1` | 設定ファイル I/O |
| `lib/Credential.ps1` | PAT を DPAPI で暗号化保管 |
| `lib/GitLab.ps1` | GitLab REST API クライアント |
| `lib/DataStore.ps1` | マスタ/月次データ CRUD |
| `lib/ConfigDialog.ps1` | 初回設定ダイアログのロジック |
| `lib/AdminDialog.ps1` | 管理者モードのロジック |

## 起動

```cmd
launch.cmd
```

設定リセットしたい場合:
```cmd
powershell -ExecutionPolicy Bypass -File WorkTimeTracker.ps1 -ForceConfig
```

## 機能

- マスタを GitLab API から取得 (members / projects / categories の JSON)
- 4段カスケード ドロップダウン (project → process → task_group → task)
- 表示年月の切替・当月エントリ一覧
- 新規追加 (**バックデート可**)
- 既存行の編集・削除
- 保存 = GitLab API で PUT (last_commit_id による楽観排他)
- 管理者モード (role=admin のみ): マスタ JSON を GUI で編集

## エンコーディング注意

`.ps1` は **UTF-8 BOM 付き** で保存してください。PS 5.1 は BOM 無しを CP932 と解釈します。
