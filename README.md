# worktime-tracker

チームメンバーの作業実績を管理するツール一式。

- **クライアント**: PowerShell + WPF (Windows 標準, インストール不要)
- **データ保管**: Git リポジトリ (JSON, 1人1ファイル/月)
- **集計・可視化**: GitLab CI で自動集計 → HTML レポートを Pages 公開 + ローカル GUI ビューア
- **運用ホスティング**: GitLab / **開発ホスティング**: GitHub (本リポジトリ)

詳細は [docs/SPEC.md](docs/SPEC.md) を参照。

## ディレクトリ構成

```
worktime-tracker/
├── master/          管理者が編集するマスタデータ (YAML)
│   ├── members.yaml      作業者マスタ
│   ├── projects.yaml     プロジェクト階層 (4段: project > process > task_group > task)
│   └── categories.yaml   作業カテゴリ
├── data/            日々の実績データ (1人1ファイル/月)
│   └── YYYY/MM/<member_id>.json
├── client/          PowerShell+WPF クライアント
├── reports/         ローカル集計 GUI ビューア
├── ci/              GitLab CI 用の集計スクリプト
├── scripts/         セットアップ・配布補助スクリプト
└── docs/            仕様書・運用ドキュメント
```

## セットアップ (作業者向け)

1. `scripts/setup.ps1` を実行
2. 初回起動時に GitLab Project Access Token を入力 (Windows 資格情報マネージャに保管)
3. デスクトップに作成されるショートカットから起動

## 開発状況

仕様策定・初期構造のセットアップ中。
