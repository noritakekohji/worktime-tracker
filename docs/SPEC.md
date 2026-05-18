# worktime-tracker 仕様書

## 1. 目的

チーム (10〜50名規模, 社内+リモート混在) のメンバーが、日々の作業実績を簡易に報告し、管理者が
集計・可視化できる仕組みを提供する。サーバ運用なし、Git リポジトリをバックエンドとして利用する。

## 2. 全体アーキテクチャ

```
┌──────────────────┐   git pull/commit/push (自動)   ┌──────────────────┐
│ クライアント     │ ◄──────────────────────────────► │ GitLab repo      │
│ (PowerShell+WPF) │                                  │ (worktime-data)  │
└──────────────────┘                                  └────────┬─────────┘
        ▲                                                      │ push trigger
        │ git pull で最新マスタ取得                            ▼
        │                                            ┌──────────────────┐
        │                                            │  GitLab CI       │
        │                                            │  集計→HTML生成   │
        │                                            └────────┬─────────┘
        │                                                     ▼
        │                                            ┌──────────────────┐
        └─── ローカル集計GUI(同梱) ──────────────►   │ GitLab Pages     │
                                                     └──────────────────┘
```

- **開発リポジトリ**: GitHub `noritakekohji/worktime-tracker` (本リポジトリ)
- **運用リポジトリ**: GitLab に同名でミラー (コード) + 別途データリポジトリ

## 3. 認証方式

GitLab **Project Access Token** を使用する (個人 GitLab アカウント不要)。

- 管理者が GitLab プロジェクトで Project Access Token (role=Developer, scope=`api`, `write_repository`) を発行
- 各クライアント PC の Windows 資格情報マネージャに token を保管
- git の commit author は bot ユーザになるが、**JSON データ内の `member_id` で実作業者を識別**するため集計には支障なし
- token 流出時は GitLab 側で revoke → 新 token を全クライアントに再配布

## 4. データモデル

### 4.1 マスタ (`master/`)

#### members.yaml — 作業者マスタ
```yaml
- id: E1234
  name: 山田太郎
  department: 開発1課
  role: member            # member | admin
  active: true
```

#### projects.yaml — プロジェクト階層 (4段)
```yaml
- code: ABC001
  name: ABC案件
  active: true
  processes:
    - code: DESIGN
      name: 設計
      task_groups:
        - code: DB
          name: DB設計
          tasks:
            - code: ERD
              name: ER図作成
            - code: DDL
              name: DDL作成
        - code: API
          name: API設計
          tasks:
            - code: SPEC
              name: API仕様書
    - code: IMPL
      name: 実装
      task_groups: []
```

階層: **project_code > process_code > task_group_code > task_code**

#### categories.yaml — 作業カテゴリ
```yaml
- code: DESIGN
  name: 設計
- code: IMPL
  name: 実装
- code: MEETING
  name: 会議
- code: REVIEW
  name: レビュー
```

### 4.2 実績データ (`data/YYYY/MM/<member_id>.json`)

```json
{
  "member_id": "E1234",
  "year": 2026,
  "month": 5,
  "entries": [
    {
      "date": "2026-05-18",
      "project_code": "ABC001",
      "process_code": "DESIGN",
      "task_group_code": "DB",
      "task_code": "ERD",
      "category": "DESIGN",
      "hours": 3.5,
      "comment": "認証エンドポイント設計"
    }
  ]
}
```

**1人1月1ファイル**の方針によりコンフリクトはほぼ発生しない。マスタ更新時のみ管理者と作業者が
同時編集する可能性があるため、保存時は `git pull --rebase` を必ず実行する。

## 5. クライアント (PowerShell + WPF)

### 5.1 主要画面

| 画面 | 概要 |
|---|---|
| ログイン | 初回のみ: member_id 選択 + GitLab Project Access Token 入力 |
| 日次入力 | カレンダーで日付選択 → 行追加で複数エントリ入力 |
| プロジェクト選択 | 4段カスケード ドロップダウン (project→process→task_group→task) |
| 月次サマリ | 当月の合計工数, プロジェクト別グラフ |
| 管理者モード | role=admin のみ表示。マスタ YAML を GUI 編集 |

### 5.2 起動・保存フロー

```
[起動]
  ↓ git pull (master/ と data/YYYY/MM/<me>.json を最新化)
[編集]
  ↓
[保存ボタン]
  ↓ git pull --rebase
  ↓ data/YYYY/MM/<me>.json 上書き
  ↓ git add → commit (message: "update: E1234 2026-05")
  ↓ git push
  ↓ 失敗時はトースト通知 + ローカル退避
```

### 5.3 依存

- Windows 10/11
- PowerShell 5.1 以上
- git CLI (バンドル不可なら setup.ps1 で winget インストール案内)

## 6. 集計・可視化

### 6.1 GitLab CI (常時公開ダッシュボード)

- `.gitlab-ci.yml` で `data/**` への push をトリガに集計 job 起動
- Python (pandas + plotly) で集計 → static HTML 生成
- GitLab Pages で公開

集計軸:
- メンバー別 月次総工数
- プロジェクト別 工数推移
- カテゴリ別 工数構成
- 工程別 進捗 (計画工数との比較は将来課題)

### 6.2 ローカル集計 GUI (`reports/ReportViewer.ps1`)

- 期間・メンバー・プロジェクトでフィルタ
- 表形式表示 + Excel/CSV エクスポート

## 7. 配布

- リリース zip に `client/`, `scripts/setup.ps1` を同梱
- `setup.ps1` 実行で:
  1. `%LOCALAPPDATA%\worktime-tracker` に git clone
  2. デスクトップにショートカット作成
  3. 資格情報マネージャに token を登録

## 8. 未確定事項 / 将来課題

- 計画工数 vs 実績工数の比較
- 承認フロー (上長承認)
- 工数の他システム (勤怠等) との連携
- 集計レポートのアクセス制御 (GitLab Pages は public/private 設定で制御可)
