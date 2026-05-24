# worktime-tracker 機能仕様書

> 本書は現行コードベース (2026-05 時点) の機能仕様をまとめたものです。
> 設計の経緯・運用前提については [SPEC.md](SPEC.md) を参照してください。

---

## 1. 概要

社内チーム (10〜50 名) の作業実績を記録・集計するための業務ツール。

| 項目 | 内容 |
|---|---|
| クライアント | Windows 10/11 + PowerShell 5.1 + WPF (OS 標準のみ) |
| データ保管 | ハイブリッド (ローカルキャッシュ + GitLab REST API) |
| 認証 | GitLab Project Access Token (DPAPI 暗号化) |
| 集計 | ローカル GUI ビューア / Excel COM 生成 / GitLab CI ダッシュボード |
| 動作モード | `local` (スタンドアローン) / `gitlab` (ハイブリッド) |
| テスト | Pester 5 (53 ケース) |

**追加インストール不要**:`git` CLI、Python、PowerShell モジュールいずれも不要。

---

## 2. アプリケーション構成

| 画面 / スクリプト | 役割 |
|---|---|
| `client/WorkTimeTracker.ps1` | メイン入力画面 (日次エントリ) |
| `client/WbsInput.ps1` | WBS 実績入力 (3 ペイン構成、計画 + 実績) |
| `client/lib/AdminDialog.ps1` | マスタ編集 / 他者データ編集 / JSON 直接編集 |
| `client/lib/ConfigDialog.ps1` | 初回設定 (モード・接続・PAT) |
| `client/lib/UserPrefsDialog.ps1` | お気に入りプロジェクト等 |
| `reports/ReportViewer.ps1` | ローカル集計ビューア |
| `analysis/build-analysis-xlsx.ps1` | Excel ピボット + ダッシュボード生成 |
| `ci/aggregate.py` | GitLab CI 用 pandas+plotly 集計 (常時公開ダッシュボード) |

---

## 3. データモデル

### 3.1 マスタ (`master/*.json`)

| ファイル | 内容 | 主キー |
|---|---|---|
| `members.json` | メンバー (id, name, company, department, rank, **roles[]**, active) | `id` |
| `projects.json` | プロジェクト (unit_code, project_name, unit_name, target_system, work_type, period_from, period_to, **task_pattern_id**, active) | `unit_code` |
| `task_patterns.json` | WBS テンプレート (id, name, processes → task_groups → tasks) | `id` |
| `categories.json` | 作業カテゴリ (code, name) | `code` |
| `holidays.json` | 会社休業日 (date=`yyyy-MM-dd`, name) | `date` |

`projects.task_pattern_id` で `task_patterns` を参照することにより、複数プロジェクトで同一 WBS テンプレートを共有できる。

### 3.2 実績データ (`data/YYYY/MM/<member_id>.json`)

```json
{
  "member_id": "E1001", "year": 2026, "month": 5,
  "entries": [
    {
      "date": "2026-05-18",
      "project_code": "ABC001",
      "process_code": "DESIGN",
      "task_group_code": "DB",
      "task_code": "ERD",
      "alias": "",
      "category": "DESIGN",
      "hours": 3.5,
      "comment": "ER 図ドラフト"
    }
  ]
}
```

- **1 人 1 月 1 ファイル** (コンフリクト最小化)
- `alias` を追加することで「同一タスクを別の名前で複数行に分割」可能

### 3.3 プロジェクト WBS 定義 (`master/projects.json` 内 `wbs_items` 配列)

プロジェクトで使う WBS 項目を **プロジェクト定義の一部** として保持 (旧 `wbs_plans/...` は廃止)。
チーム全員で共有される (master/projects.json 自体が全員共通)。

```json
{
  "unit_code": "ABC001",
  "project_name": "ABC案件",
  "task_pattern_id": "PAT001",
  "wbs_items": [
    {
      "process_code": "DESIGN",
      "task_group_code": "DB",
      "task_code": "ERD",
      "alias": "ER図 - 顧客マスタ",
      "status": "進行中",
      "planned_hours": 8.0,
      "assignee": "山田",
      "planned_start": "2026-05-01",
      "planned_end":   "2026-05-10"
    }
  ]
}
```

- 同一パターン項目を **別名違いで複数行** 追加可能 → 行のユニークキーは `(process_code, task_group_code, task_code, alias)`
- タスクグループレベルの実績は `task_code = "-"` で表現
- 計画/期間/担当は **全月共通** (月ごとに設定する仕様ではなく、プロジェクト寿命中固定)
- `status`: `未着手` / `進捗中` / `完了` / `中止` — WbsInput の「完了/中止も表示」OFF で `完了` / `中止` 行を非表示にしてリストを整理可

### 3.4 ローカルストレージ

| 種別 | パス |
|---|---|
| 設定 | `%APPDATA%\worktime-tracker\config.json` |
| 暗号化トークン | `%APPDATA%\worktime-tracker\token.dat` (DPAPI) |
| ユーザ設定 | `%APPDATA%\worktime-tracker\user_prefs.json` |
| 致命エラーログ | `%APPDATA%\worktime-tracker\last_error.log` |
| データキャッシュ | `config.local_store` で指定 (既定: `%LOCALAPPDATA%\worktime-tracker\store`) |

---

## 4. 機能詳細

### 4.1 WorkTime Tracker (`WorkTimeTracker.ps1`) — 日次実績入力

**休暇登録**: エントリフォームの「🏖 休暇」CheckBox を ON にすると、プロジェクト/工程/タスク選択を省略可能。`is_leave: true` でエントリに保存され、Report の「未入力検知」では「入力あり」として扱われる (休暇日が未入力警告に出ない)。

#### 入力機能
- **日付選択**: カレンダー + バックデート (任意日を直接入力)
- **4 段カスケード**: project → process → task_group → task (`task_patterns` 経由で展開)
- **カテゴリ**: マスタから選択
- **時間**: 0.25 h 単位を推奨 (制限なし)
- **コメント**: 自由記述
- **連続入力**: Enter キー / 「行追加」ボタン
- **未保存行ハイライト**: 編集後・追加後の行は黄系の背景でマーク

#### 保存
- 「**保存**」: ローカルキャッシュへ書き込み
- 「**📤 送信**」: ローカル保存 → GitLab API (`PUT` with `last_commit_id` で楽観排他) → push 結果サマリ表示
- 表示月と異なる日付は確認ダイアログを経て別月ファイルに振り分け
- スタンドアローン (`mode=local`) では送信ボタンを無効化

#### フッタ
- 選択日の合計時間 / 当月合計を常時表示

#### ユーザ設定 (`UserPrefsDialog`)
- お気に入りプロジェクト (上部に固定表示)

---

### 4.2 WBS Input (`WbsInput.ps1`) — WBS 実績入力

3 ペイン構成 (TreeView | DataGrid + Gantt | TaskView)。

#### トップバー
- プロジェクト選択 / 年・月選択 / **読込** / **管理画面** / **保存** / **送信**
- *担当者選択は無し* (実績は常にログインユーザ本人のファイルに保存)
- ステータス表示 (色付き)

#### 左ペイン: WBS ツリー
- プロジェクトの `task_pattern_id` に基づき `task_patterns` から階層表示
- 工程 ⚙ / タスクグループ 🗂 / タスク • のアイコン
- ノード選択で「行追加」ボタン有効化 → グリッドに新規行を挿入
- パターン未一致時は診断メッセージ (`task_pattern_id='xxx' に一致するパターンなし` 等)

#### 中央ペイン: DataGrid + Gantt
- 内部列: `_pc / _tgc / _tc / _proc_idx / _sort_key`
- 表示列: `WBS / 工程 / タスクグループ / タスク / 別名 / 担当 / 計画 / 合計 / 進捗 / 開始 / 終了`
- 日付列: 当月日数ぶん `yyyy-MM-dd` 列を動的生成
- **ガントセル**: `IMultiValueConverter` (C# Add-Type) により以下で着色
  - 土日・会社休業日 (薄グレー)
  - `planned_start` 〜 `planned_end` 範囲 (薄青)
  - 実績入力済セル (緑系)
- **進捗カラム**: 計画工数に対する実績比 (%) + プログレスバー文字
- ソート: `_sort_key ASC, 別名 ASC, 開始 ASC`
- **行追加 (AddRowBtn)**: ツリー選択タスクを別名 (`#2, #3...` 自動採番) で追加可能
- **DataGridCell** のフォーカス枠は無効化 (見た目をフラットに)
- 日付セルは表示優先のため編集不可、計画/開始/終了/別名のみ編集可

#### 右ペイン: TaskView
- 選択行のタスク単位の **詳細エントリ** を日付・カテゴリ・時間ごとに追加・削除
- 同一タスクを同日内で複数カテゴリに分割可能

#### 保存ロジック (`_DoSave`)
1. **個人実績**: `Save-EntriesGrouped` で本人ファイルへ merge (他プロジェクト分は維持)
2. **プロジェクト定義**: `Save-ProjectWbsItems` で `master/projects.json` 内の対象プロジェクトの `wbs_items` を差し替え (他プロジェクトは温存)
   - 「送信」ボタン押下時に `Sync-Push-Masters` でリモートにも反映 → チーム全員に共有

---

### 4.3 管理者モード (`AdminDialog.ps1`) — `roles` に `admin` を含むメンバーのみ表示

**ロール (複数選択可)**:
| ロール | 権限 |
|---|---|
| `admin` | 管理者モード (マスタ編集 + 他者データ編集) |
| `leader` | WBS でプロジェクトの WBS 項目を追加・削除、行の編集 (別名/担当/計画/期間/状態) |
| `member` | 作業実績を計上 (Tracker / WbsInput TaskView)。WBS の編集列は閲覧のみ |

`members.json` 内では `"roles": ["admin","leader","member"]` 配列。旧スキーマの `"role": "admin"` 単一文字列も読込時に受理 (後方互換)。

タブ構成:

タブ構成:

#### 👤 メンバー
- DataGrid 編集 (追加・削除・active トグル・role)
- `id` 重複はバリデーション

#### 🏢 プロジェクト
- DataGrid 編集
- **task_pattern_id 列**: `DataGridComboBoxColumn` プルダウン (タスクパターンから `id — name` 表示)
- `period_from` / `period_to` セルの編集確定時に `yyyyMMdd` → `yyyy-MM-dd` 自動正規化

#### 🧩 タスクパターン
- 左: パターン一覧 (id (name))
- 中: 階層ツリー (パターン → 工程 → タスクグループ → タスク)
- 右: 選択ノードの code / name 編集
- 操作: 子追加 (＋子) / 兄弟追加 (＋兄弟) / 削除 / ▲▼ 並べ替え / 📋 テンプレートコピー
- TextChanged 中はリスト再描画しない (フォーカス保持) → LostFocus で確定反映

#### 📂 カテゴリ / 🏖 休業日
- シンプル DataGrid 編集
- 休業日は `WbsInput` のガント着色に即反映
- 個人の休暇は **エントリ属性** で管理 (4.1 参照、カテゴリでは扱わない)

#### 🛠 他者データ編集
- メンバー / 年 / 月 を選んで実績ファイルを読込 → 編集 → 保存
- 保存時の commit author は管理者 ID で記録 (誰が代理編集したか追跡可)

#### 📝 JSON 直接編集
- 対象 (members / projects / task_patterns / categories) を選んで JSON テキストエディットで上書き
- `JSON 検証` ボタンで構文チェック / `JSON 適用` で内部コレクションへ反映 (保存は別途)

#### 保存
- 「**保存**」: 5 マスタ全部をローカル + (gitlab モード時) リモートへ push、結果サマリをダイアログ表示

---

### 4.4 ReportViewer (`reports/ReportViewer.ps1`)

チームマネージャがチーム内の作業を横断的に確認するためのビュー。期間 / メンバー / プロジェクト フィルタで絞り込み。

タブ構成:

| タブ | 内容 |
|---|---|
| 📊 ダッシュボード | KPI カード (総工数 / メンバー数 / プロジェクト数 / 日平均 / 一人平均) + Top プロジェクト棒 |
| 📋 明細 | 全エントリの一覧 (DataGrid) |
| 👥 メンバー別 | メンバー単位の合計・件数 |
| 📁 プロジェクト別 | プロジェクト単位の合計・件数 |
| 🏷 カテゴリ別 | カテゴリ単位の合計・件数 |
| 📈 分析 | 詳細クロス集計 (任意軸) |
| 🔥 ヒートマップ | 軸切替: `日付×プロジェクト` / `日付×メンバー (個人別)` / `メンバー×プロジェクト` |
| 👥 メンバー負荷 | 週次稼働マトリクス (🔴=超過 / 🟡=目標超) + 未入力検知 (平日 × メンバー で 0h の日) |
| 🔀 メンバー×PJ | メンバー × プロジェクト クロス集計 (委任・代わり検討用) |
| 💼 業務種別比率 | サブタブ構成: ① 概要 (KPI + メンバー別) / ② 案件対応 分析 (行=プロジェクト × 列=工程 or タスクグループ 切替) / ③ 維持運用 分析 (行=対象システム × 列=工程 or タスクグループ 切替) |
| ⚠ 異常検知 | 過剰入力・高負荷・入力ゼロ日候補 |
| 📉 グラフ | 任意軸での集計棒グラフ |

- CSV エクスポート (列選択ダイアログ付き)
- ハイブリッドモード (ローカルキャッシュ + リモート pull)
- `業務種別` は `master/projects.json` の `work_type` (案件対応 / 維持運用 / その他) を参照

---

### 4.5 Excel 分析ブック (`analysis/build-analysis-xlsx.ps1`)

- PowerShell + Excel COM で `worktime-analysis.xlsx` を生成
- ピボット + スライサー + ダッシュボード (棒・円・線・KPI カード)
- 配布用 xlsx として commit + 共有

---

### 4.6 GitLab CI ダッシュボード (`ci/aggregate.py`)

- `data/**` または `master/**` への push をトリガに pandas + plotly で集計
- `public/index.html` を生成 → GitLab Pages 公開
- 月次 × メンバー (積上棒) / プロジェクト別 (横棒) / カテゴリ比率 (円) / 工程集計表

---

## 4.7 ボタン用語規約

全画面で以下の動詞を統一:

| 動詞 | 意味 | スタンドアローン | Gitlab モード |
|---|---|---|---|
| **📋 読込** | ローカルから読込 | ✓ | ✓ (リモート未参照) |
| **📥 取得** | リモートから取得 → ローカル読込 | (無効) | ✓ |
| **💾 保存** | ローカルに保存 | ✓ | ✓ (リモート未送信) |
| **📤 送信** | ローカル保存 → リモートに反映 | (無効) | ✓ |

起動時挙動 (Gitlab モードのみ):
- 「Gitlab からマスタを取得しますか?」 Yes/No ダイアログを表示
- Yes: `Sync-Pull-Masters` → ローカル読込 (最新)
- No: ローカルキャッシュから読込 (オフライン可)

## 5. ストレージ抽象 (`DataStore.ps1` / `Bootstrap.ps1`)

### 5.1 モード

| Mode | RemoteCtx | 動作 |
|---|---|---|
| `local` | $null | 全 I/O が `local_store` 配下のローカル FS |
| `gitlab` | あり | 起動時にマスタを pull → 編集はローカル → 「送信」でリモート push |

### 5.2 主要関数

| 関数 | 用途 |
|---|---|
| `Initialize-DataContext` | 起動時にマスタ + 設定 + 認証 + 現在ユーザを解決 |
| `Reload-MasterContext` | 管理画面の保存後などに 5 マスタを再取得 |
| `Get-Master*` | members / projects / categories / task_patterns / holidays の取得 |
| `Save-Master*` | 各マスタ保存 (ローカル → リモート PUT) |
| `Load-MonthEntries` | 指定メンバー・年月の実績取得 |
| `Save-EntriesGrouped` | エントリを年月でグルーピングし保存 (他月もマージ) |
| `Get-ProjectWbsItems` / `Save-ProjectWbsItems` | プロジェクト定義の wbs_items 取得・保存 (projects.json 内) |
| `Sync-Push-MyData` | 本人データをリモートへ push (last_commit_id で楽観排他) |
| `Sync-Push-Masters` | マスタ一括 push |

### 5.3 認証 (`Credential.ps1`)
- `Save-Token` / `Load-Token`: DPAPI (`ConvertTo-SecureString -Key` 不使用、ユーザ・マシン束縛)
- TLS 1.2 を明示的に有効化 (PS 5.1 デフォルト無効対策)

---

## 6. UI / UX

### 6.1 デザイン
- カラーパレット: 青基調 (`#0ea5e9`)、警告 `#f59e0b`、成功 `#10b981`、エラー `#ef4444`
- DataGrid: ヘッダ薄グレー、選択行強調、未保存行はハイライト
- Gantt セル: WPF Style + `IMultiValueConverter`

### 6.2 操作性
- カスケードドロップダウンは選択保持 (再選択時に下位を維持)
- 入力中に上位が再描画されない (フォーカス保持優先)
- バックデート時は確認ダイアログ表示

---

## 7. テスト (`tests/`)

Pester 5 で 53 ケース (全 PASS)。

| 区分 | ファイル | 内容 |
|---|---|---|
| unit | `Date.Tests.ps1` | 日付正規化 14 ケース (`yyyyMMdd` / 区切り混在 / 空白) |
| unit | `Member.Tests.ps1` | メンバー略称 10 ケース (Name 優先・ID フォールバック・全角) |
| lib | `Bootstrap.Tests.ps1` | `Initialize-DataContext` / `Reload-MasterContext` (Mock) |
| lib | `DataStore.Tests.ps1` | ファイル I/O ラウンドトリップ |
| ui | `Xaml.Tests.ps1` | XAML パース + 主要 `x:Name` の FindName 解決 |
| integration | `EndToEnd.Tests.ps1` | End-to-End シナリオ |

実行: `tests\run-tests.cmd` または `pwsh tests\Invoke-Tests.ps1`
結果: `tests\results\TestResults.xml` (NUnit 形式)

---

## 8. 配布・運用

### 8.1 配布
1. リポジトリを zip 化
2. 配布
3. 受け取った各 PC で `scripts\setup.cmd` をダブルクリック
   - `%LOCALAPPDATA%\worktime-tracker` にコピー
   - デスクトップに **WorkTime Tracker** / **WBS Input** / **WorkTime Report** のショートカット作成

### 8.1.0 デモ用サンプルデータ投入
`scripts\load-demo.cmd` をダブルクリックで実行。`config.json` の `local_store` 配下に以下を一括投入 (既存ファイルは上書き):

| 投入対象 | 内容 |
|---|---|
| `master/members.json` | 4 メンバー (admin/leader/member 混在) + 退職者 1 |
| `master/projects.json` | 4 プロジェクト (案件対応 2 + 維持運用 2) + `wbs_items` |
| `master/task_patterns.json` | 共通パターン 2 (新規開発 / 維持運用) |
| `master/categories.json` | 9 カテゴリ |
| `master/holidays.json` | 2026 GW + 月例祝日 |
| `data/YYYY/MM/E001-E004.json` | 当月 + 前月の実績エントリ (有給休暇含む、シード固定で再現性あり) |

オプション: `-LocalStore <path>` で投入先を明示指定、`-Force` で確認スキップ。

### 8.1.1 アンインストール
`scripts\uninstall.cmd` をダブルクリックで起動 (`-Force` で確認スキップ可)。削除対象:

| 段階 | 対象 |
|---|---|
| 1 | `%LOCALAPPDATA%\worktime-tracker` (インストール先) |
| 2 | デスクトップショートカット 3 個 |
| 3 | `%APPDATA%\worktime-tracker` (config / token / user_prefs / ログ) — `-KeepUserData` でスキップ可 |
| 4 | `config.local_store` のローカルキャッシュ (重要データのため個別確認) |

### 8.2 初回設定
- ConfigDialog で以下を入力
  - 動作モード (スタンドアローン / Gitlab)
  - GitLab URL / Project ID / Branch
  - Project Access Token (PAT)
  - Member ID
- PAT は DPAPI 暗号化して `token.dat` に保管

### 8.3 マスタ更新運用
- 管理者が **管理画面** で編集 → 保存 (ローカル + リモート push)
- 各クライアントは起動時 / 「再読込」ボタンで最新を取得

### 8.4 エンコーディング規約
- `.ps1` / `.xaml`: **UTF-8 with BOM**
- `.cmd`: **CRLF + Shift-JIS**

---

## 9. 制約と既知事項

| 項目 | 内容 |
|---|---|
| OS | Windows 10/11 のみ (WPF 依存) |
| PowerShell | 5.1 想定 (6/7 でも動作可だが未保証) |
| 同時編集 | 同一メンバーが同月ファイルを複数 PC から編集すると競合 (1 人 1 月 1 ファイル設計のためレアケース) |
| GitLab | self-hosted / SaaS いずれも可、 PAT 必要 |
| ファイルサイズ | 1 月あたり数 KB〜数十 KB を想定 |

---

## 10. 将来課題

- 上長承認フロー (Merge Request ベース)
- 個人別月次 PDF 出力
- 旧 Excel → JSON 移行ツール
- 異常検知 / 月次サマリの自動配信 (Slack/Teams)
- ヒートマップ・ダッシュボード強化

---

*Last updated: 2026-05-23*
