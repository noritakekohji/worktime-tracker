# worktime-tracker 仕様書

## 1. 目的

チーム (10〜50名規模, 社内+リモート混在) のメンバーが日々の作業実績を簡易に報告し、
管理者が集計・可視化できる仕組みを提供する。

**重要な制約**: 社内 PC への追加ソフトウェアのインストールは不可。
Windows + PowerShell 5.1 のみで動作する。git CLI も不要。

## 2. 全体アーキテクチャ

```
┌──────────────────┐  HTTPS / GitLab REST API   ┌──────────────────┐
│ クライアント     │ ◄────────────────────────► │ GitLab repo      │
│ (PowerShell+WPF) │  PRIVATE-TOKEN: <PAT>      │ (worktime-data)  │
└──────────────────┘                            └────────┬─────────┘
                                                         │ push trigger
                                                         ▼
                                                ┌──────────────────┐
                                                │  GitLab CI       │
                                                │  pandas+plotly   │
                                                │  → HTML 生成     │
                                                └────────┬─────────┘
                                                         ▼
┌──────────────────┐  HTTPS / GitLab REST API   ┌──────────────────┐
│ ReportViewer     │ ◄────────────────────────► │ GitLab Pages     │
│ (ローカル GUI)   │                            │ (常時ダッシュ)   │
└──────────────────┘                            └──────────────────┘
```

- **開発リポジトリ**: GitHub `noritakekohji/worktime-tracker` (本リポジトリ)
- **運用リポジトリ**: GitLab に同名でミラー (コード) + データリポジトリ

## 3. 認証

GitLab **Project Access Token** (group/personal account 不要) を使用。

- 管理者が GitLab プロジェクトで PAT 発行
  - role: Developer 以上, scope: `api`, `write_repository`
- 同一 PAT を全クライアントで共有
- 各クライアント PC で **DPAPI 暗号化** して `%APPDATA%\worktime-tracker\token.dat` に保管
- git の commit author は PAT ボットだが、**JSON 内 `member_id` で実作業者を識別**するため集計に支障なし
- 流出時は GitLab 側で revoke → 新 PAT を全クライアントに再配布

## 4. データモデル

### 4.1 マスタ (`master/*.json`)

#### members.json
```json
[
  {"id": "E1001", "name": "山田太郎", "department": "開発1課", "role": "member", "active": true}
]
```
role は `member` または `admin`。`admin` のクライアントでは管理者モードが表示される。

#### projects.json — 4段階層
```json
[
  {
    "code": "ABC001", "name": "ABC案件", "active": true,
    "processes": [
      {
        "code": "DESIGN", "name": "設計",
        "task_groups": [
          {
            "code": "DB", "name": "DB設計",
            "tasks": [{"code": "ERD", "name": "ER図作成"}]
          }
        ]
      }
    ]
  }
]
```
階層: **project_code > process_code > task_group_code > task_code**

#### categories.json
```json
[{"code": "DESIGN", "name": "設計"}, {"code": "IMPL", "name": "実装"}]
```

### 4.2 実績データ (`data/YYYY/MM/<member_id>.json`)

```json
{
  "member_id": "E1001", "year": 2026, "month": 5,
  "entries": [
    {
      "date": "2026-05-18",
      "project_code": "ABC001", "process_code": "DESIGN",
      "task_group_code": "DB", "task_code": "ERD",
      "category": "DESIGN", "hours": 3.5,
      "comment": "ER図ドラフト"
    }
  ]
}
```

**1 人 1 月 1 ファイル**でコンフリクト回避。

## 5. クライアント

### 5.1 構成

```
client/
├── WorkTimeTracker.ps1       エントリポイント
├── MainWindow.xaml           メイン画面
├── ConfigDialog.xaml         初回設定ダイアログ
├── AdminDialog.xaml          管理者モード (マスタ JSON 編集)
├── launch.cmd                ダブルクリック起動
└── lib/
    ├── Config.ps1            %APPDATA% の config.json 読書
    ├── Credential.ps1        DPAPI による token 暗号化保管
    ├── GitLab.ps1            GitLab REST API ラッパ
    ├── DataStore.ps1         マスタ・月次データの CRUD (gitlab/local 両対応)
    ├── ConfigDialog.ps1      ConfigDialog のイベントハンドラ
    └── AdminDialog.ps1       AdminDialog のイベントハンドラ
```

### 5.2 設定ファイル

`%APPDATA%\worktime-tracker\config.json`:
```json
{
  "mode": "gitlab",
  "gitlab_url": "https://gitlab.example.com",
  "project_id": "12345",
  "branch": "main",
  "member_id": "E1001"
}
```
`mode=local` は開発用 (ローカル FS をリポジトリとして扱う)。

### 5.3 GitLab REST API 利用エンドポイント

| 用途 | メソッド | エンドポイント |
|---|---|---|
| ファイル取得 (raw) | GET | `/api/v4/projects/:id/repository/files/:path/raw?ref=:branch` |
| ファイルメタ | GET | `/api/v4/projects/:id/repository/files/:path?ref=:branch` |
| ファイル作成 | POST | `/api/v4/projects/:id/repository/files/:path` |
| ファイル更新 | PUT | `/api/v4/projects/:id/repository/files/:path` (last_commit_id で楽観排他) |
| ツリー取得 | GET | `/api/v4/projects/:id/repository/tree?path=:path&recursive=true` |
| プロジェクトメタ | GET | `/api/v4/projects/:id` (接続テスト用) |

認証: `PRIVATE-TOKEN: <PAT>` ヘッダ。TLS 1.2 を明示的に有効化 (PS 5.1 デフォルト無効対策)。

### 5.4 主要操作フロー

#### 起動
1. `Load-Config` で `%APPDATA%\...config.json` 読込
2. 未設定なら `ConfigDialog` を表示 (PAT を DPAPI で暗号化保管)
3. `Get-MasterMembers/Projects/Categories` を GitLab API 経由で取得

#### エントリ追加
- 日付選択 (バックデート可)
- 4段カスケード ドロップダウン (project → process → task_group → task)
- 表示中月と異なる日付なら確認ダイアログ → 別月ファイルに振分

#### 保存
- `Save-EntriesGrouped` がエントリを年月でグルーピング
- 表示月: 全置換 (PUT)
- 他月 (バックデート分): 既存とマージして PUT
- GitLab API 内部で last_commit_id を渡し楽観排他

#### 管理者モード
- role=admin のクライアントで「管理者モード」ボタン表示
- マスタ JSON を直接編集 → JSON 検証 → 保存 (PUT)

## 6. 集計・可視化

### 6.1 GitLab CI (常時ダッシュボード)

`.gitlab-ci.yml`:
- trigger: `data/**` または `master/**` への push
- pandas + plotly で集計 → `public/index.html` 生成
- GitLab Pages で公開

生成グラフ:
- 月次 × メンバー (積み上げ棒)
- プロジェクト別 合計 (横棒)
- カテゴリ別 比率 (円)
- プロジェクト × 工程 集計表

### 6.2 ローカル ReportViewer

- 期間 / メンバー / プロジェクトでフィルタ
- 明細 + メンバー別 / プロジェクト別 / カテゴリ別の 3 軸集計
- CSV エクスポート

## 7. 配布・運用

### 7.1 配布

1. リポジトリ全体を zip 化
2. 配布
3. 受け取った人が任意フォルダに展開し `scripts\setup.ps1` 実行
   - `%LOCALAPPDATA%\worktime-tracker` にコピー
   - デスクトップにショートカット 2 つ (Tracker / Report)

### 7.2 マスタ更新運用

- 管理者が AdminDialog で編集 → 保存 (PUT)
- 各クライアントは起動時 / 「再読込」ボタンで最新を取得

### 7.3 エンコーディング規約

`.ps1` ファイルは **UTF-8 with BOM** で保存。PS 5.1 は BOM 無し UTF-8 を CP932 として
解釈するため、日本語を含むスクリプトは BOM 必須。

## 8. 未実装 / 将来課題

- 計画工数 vs 実績工数の比較 (`master/plans.json` 追加)
- 上長承認フロー (Merge Request での承認運用も可)
- 個人別月次レポート PDF 出力
- データ移行ツール (旧 Excel → JSON)
