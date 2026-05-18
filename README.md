# worktime-tracker

チームメンバーの作業実績を管理するツール一式。**社内 PC への追加インストール不要**で動作。

- **クライアント**: PowerShell + WPF (Windows 10/11 標準, モジュール追加なし)
- **データ保管**: **GitLab REST API** (git CLI 不要) — Project Access Token 認証
- **集計・可視化**: GitLab CI で自動集計 → HTML を GitLab Pages 公開 + ローカル GUI ビューア
- **運用**: GitLab / **本開発リポジトリ**: GitHub

詳細は [docs/SPEC.md](docs/SPEC.md) を参照。

## 動作要件

- Windows 10/11
- PowerShell 5.1 以上 (OS 標準)
- インターネット (GitLab へ HTTPS でアクセス可能なネットワーク)

**不要なもの**: git CLI, Python, PowerShell モジュール (powershell-yaml など)

## ディレクトリ構成

```
worktime-tracker/
├── master/                     管理者が編集するマスタ (JSON)
│   ├── members.json                作業者
│   ├── projects.json               プロジェクト階層 (4段: project > process > task_group > task)
│   └── categories.json             作業カテゴリ
├── data/                       実績データ (1人1ファイル/月)
│   └── YYYY/MM/<member_id>.json
├── client/                     入力クライアント (PowerShell+WPF)
│   ├── WorkTimeTracker.ps1
│   ├── MainWindow.xaml
│   ├── ConfigDialog.xaml       初回設定ダイアログ
│   ├── AdminDialog.xaml        管理者モード (マスタ編集)
│   ├── launch.cmd
│   └── lib/                    Config / Credential / GitLab / DataStore / 各ダイアログ
├── reports/                    ローカル集計 GUI ビューア
│   ├── ReportViewer.ps1
│   ├── ReportViewer.xaml
│   └── launch.cmd
├── ci/aggregate.py             CI 集計スクリプト (pandas + plotly)
├── scripts/setup.ps1           クライアント PC への配布インストーラ
└── docs/SPEC.md                仕様書
```

## クイックスタート

### 管理者 (初回)

1. **GitLab** にデータ用プロジェクトを作成 (例: `worktime-data`)
2. プロジェクトの Settings → Access Tokens で **Project Access Token** を発行
   - role: `Developer` 以上, scope: `api`, `write_repository`
3. 本リポジトリの `master/` と `data/` を GitLab プロジェクトに push (初期投入)
4. クライアント zip を作成して配布

### 作業者 (各 PC)

1. 配布された zip を任意のフォルダに展開
2. `scripts\setup.ps1` をダブルクリック実行 (または右クリック → PowerShell で実行)
   - `%LOCALAPPDATA%\worktime-tracker` に展開され、デスクトップにショートカット作成
3. デスクトップの **WorkTime Tracker** を起動
4. 初回設定ダイアログで以下を入力:
   - GitLab URL (例: `https://gitlab.example.com`)
   - Project ID または `group/project` パス
   - Branch (通常 `main`)
   - Project Access Token (管理者から共有された PAT)
   - あなたの Member ID

PAT は **DPAPI で暗号化** し `%APPDATA%\worktime-tracker\token.dat` に保管 (同一ユーザ・同一マシンでのみ復号可)。

## 機能

| 画面 | 用途 |
|---|---|
| **WorkTime Tracker** | 日々の実績入力。バックデートで任意の過去日も登録可。4段カスケード ドロップダウン。行編集・削除。 |
| **管理者モード** (role=admin) | マスタ JSON を GUI で直接編集して GitLab に push。 |
| **WorkTime Report** | 期間/メンバー/プロジェクトでフィルタ → 明細・3軸集計・CSV エクスポート。 |
| **GitLab Pages** | CI が自動生成する常時公開ダッシュボード (Plotly グラフ)。 |

## 注意

- `.ps1` ファイルは **UTF-8 with BOM** で保存してください (PowerShell 5.1 が日本語を正しく解釈するため)
- 同一作業者が同一月のファイルを同時に複数 PC から編集すると競合します (1 人 1 月 1 ファイル設計のためレアケース)
