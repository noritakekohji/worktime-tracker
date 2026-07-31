# Changelog

本ツールの変更履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 準拠、
バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に準拠する。

バージョン定義 (この repo の運用):
- **MAJOR**: 既存データ/設定 (master/*.json, data/**/*.json, config.json) との後方互換を壊す変更
- **MINOR**: 後方互換のある機能追加
- **PATCH**: 後方互換のあるバグ修正

`client/lib/Version.ps1` の `$Script:AppVersion` を変更すると、全画面のタイトルバーが
連動して更新される。

---

## [Unreleased]

### Added
- `scripts/import-excel-workentries.ps1` — Excel の作業実績を月次 JSON (`data/YYYY/MM/<member_id>.json`) に変換する取込スクリプト
  - 日本語ヘッダー (日付 / 案件コード / 工程 / 工数 / コメント 等) を標準フィールドへ自動解決。`-ColumnMapPath` で JSON による列マップの上書きも可能
  - `member_id` は列から取得、無ければファイル名から `-MemberIdPattern` で抽出
  - 対象年月外の日付、非数値の工数、1 ファイルに複数メンバーが混在する場合はエラーで停止する
  - `-DryRun` で書き込まずに変換結果だけ確認できる。既存ファイルの上書きには `-Force` が必要
  - 出力先は `-OutputRoot` 配下のみ。`local_store` にも Gitlab にも書き込まない
  - **Microsoft Excel が必要** (Excel COM を使用)。クライアント本体とは独立したオフライン変換ツール
- `tests/unit/ExcelImport.Tests.ps1` — 列解決・変換・年月チェック・上書き防止の回帰防止 (4 ケース)

---

## [1.3.0] - 2026-07-31

### Added
- ReportViewer の共通フィルタに **会社** を追加。`members.json` の `company` から選択肢を生成し、全タブの集計母集団に反映する
- 会社を選ぶとメンバーフィルタの一覧もその会社所属者だけに絞られる (会社 → メンバーのファネル)
- `company` 未設定のメンバーを絞り込むための `(未設定)` 選択肢
- Gitlab 同期の**差分同期**。tree API が返す blob SHA を `local_store/.sync_state.json` に記録し、変更のないファイルはダウンロードしない
- Report の「📥 取得」に進捗表示 (`(n/N) パス`) を追加。変更がなければ「最新です」と表示する
- `tests/lib/SyncState.Tests.ps1` — 同期状態の読み書き・ハッシュ・戻り値スキーマの回帰防止 (17 ケース)
- `tests/unit/ReportResolvers.Tests.ps1` — Report の名称解決と集計ヘルパの回帰防止 (22 ケース)。`ReportViewer.ps1` は読み込むと WPF ウインドウが起動するため、AST から対象関数の定義だけを取り出して検証する
- `tests/ui/ReportTabs.Tests.ps1` — タブ構成と遅延構築の位置宣言の突き合わせ (9 ケース)。タブを足し引きして index がずれると「開いても白いまま」になり例外が出ないため、XAML の実構造と `$Script:Views` を照合する
- **集計グリッドのドリルダウン**。メンバー別 / プロジェクト別 / システム別 / 会社別のセルをダブルクリックすると、その値で共通フィルタを絞って 📋 明細タブへ遷移する
- **⚠ チェックタブのバッジ**。異常検知 + 未入力検知の件数をタブ見出しに出し、開かなくても要対応に気づけるようにした
- 期間 (From / To) の変更もその場で反映する。`[🔍 フィルタ適用]` の押し忘れで古い数字を見る事故を防ぐ (ボタンは明示的な再計算用に残す)

- `scripts/test-gitlab.ps1` / `.cmd` — Gitlab 連携の診断スクリプト
  - 既定は**読み取り専用**。接続、tree API のページング健全性 (100 件打ち切りの検出)、マスタ/実績の在り処、リモートとローカルの突き合わせ、実ダウンロード 1 件を確認する
  - `-RoundTrip` で「Tracker と同じ経路で書込 → Gitlab 送信 → ローカル削除 → 取得 → Report と同じ関数でフィルタ・集計」を通しで検証。判定ロジックは書き写さず `ReportViewer.ps1` の AST から実物の関数を読み込む
  - 検証用ファイルは実データと衝突しない `data/2099/12/` に作り、終了時に Gitlab 上からも自動削除する。実行前に内容を表示して確認を求める (`-Yes` で省略)
  - `-FixState` で差分同期の状態ファイルを削除し、次回の取得で全件取り直す
- `Remove-GitLabFile` — 診断スクリプトの後片付け用にファイル削除 API を追加

### Changed
- **同期の高速化**。`Sync-Pull-Masters` / `Sync-Pull-AllData` は「変更なし」なら tree 取得の 1 リクエストで完了する (従来はファイル数ぶんの GET を毎回直列実行)
- `Sync-Push-MyData` の往復を 1 ファイル 3 → 最大 2 リクエストに削減。`files/:path` が `content` と `last_commit_id` を同時に返すことを利用し、raw 取得とメタ取得を 1 回にまとめた
- `Sync-Push-MyData` / `Sync-Push-Masters` は前回 push 時と内容が同一のファイルを**通信なし**で飛ばす (空コミットの抑止も兼ねる)
- `ServicePointManager` の接続数上限を 16 に引き上げ、Nagle と `Expect: 100-continue` を無効化
- 全 HTTP 関数で `$ProgressPreference` を抑止 (PS 5.1 は進捗バー描画にリクエスト本体より長い時間を使う)
- 起動時のマスタ取得ダイアログの文言を差分同期に合わせた (更新 0 件を「失敗」と誤解させない)

- **Report の高速化**。`Resolve-*` の線形検索 (`Where-Object`) をマスタ索引 (hashtable) + 解決結果のメモ化に置き換えた。従来は 1 明細行あたり 6〜8 回の線形検索が走り、行数 × 呼出回数 × マスタ件数の比較が発生していた
- 日付を `Reload-Entries` で 1 度だけ解決して保持。フィルタ変更のたびに全行を `TryParse` し直さない
- 集計を `Group-Object` から hashtable の 1 パス集計 (`_SumBy`) に置き換え。明細行の生成もパイプラインから `foreach` + `List` に変更
- **Report のタブを 14 のフラット構成から 5 グループ + サブタブに再編**。`📊 概要` / `👥 メンバー` / `📁 案件・PJ` / `⚠ チェック` / `📋 明細`。横スクロールが消え、目的の画面に着きやすくなった
- **重い集計をタブ表示時の遅延構築に変更**。従来はフィルタを 1 つ変えるたびに 9 つの `Build-*` を全実行し、見ていないタブのキャンバス描画やピボット生成まで毎回やり直していた。開かないタブの計算は起きなくなった
- 未入力検知を `👥 メンバー負荷` タブ内から `⚠ チェック` グループの独立タブへ移設

### Removed
- 業務種別比率タブ内の専用フィルタ (システム / プロジェクト) を削除。判定が上部の共通フィルタと同一 (`target_system` 一致 / `unit_code` 一致) で、共通フィルタ適用後の行をさらに絞るだけの二重適用だった。「共通で CRM / タブで ERP」を選ぶと必ず 0 件になるなど有害でしかなかった
- 代わりに、共通の業務種別フィルタが効いている間だけ「比率がその業務種別だけの内訳になっている」旨の注意書きを表示する

### Fixed
- **Gitlab から最新状態が取得できない不具合を修正**。`_RemoteBlobMap` が `@(Get-GitLabTree ...)` と書かれており、「配列を 1 要素だけ持つ配列」に二重ラップされていた。PS のメンバー列挙により `$item.type` が `@('blob',...)` となって `-ne 'blob'` が偽になり、`[string]$item.path` も空白連結された文字列が `.json` で終わるため両方のガードをすり抜け、**存在しないパス 1 件だけのマップ**ができていた。その 1 件は GET が 404 で握りつぶされるため、エラーは出ないのに一切ダウンロードされない状態だった
- **`Get-GitLabTree` が 100 件までしか取得できない不具合を修正**。終了条件に `X-Total-Pages` を使っていたが、`/repository/tree` は総件数の算出コストが高いためこのヘッダを返さない。`[int]$null` = 0 となり 1 ページ目で必ず打ち切られていた。`recursive=true` ではディレクトリ項目も 100 件の枠を消費するため、10 名 × 12 ヶ月程度でも上限を超える。`X-Next-Page` をたどる方式に変更 (この不具合は差分同期の導入以前から存在)
- **特定メンバーでフィルタするとエラーになる不具合を修正**。`_SumBy` の戻り値が 1 行のとき PS 5.1 の戻り値展開で `PSCustomObject` 単体になり、`ItemsSource` への代入が「IEnumerable に変換できません」で失敗していた
- `_ContentHash` の到達しない `$null` 判定を除去 (`[string]` 型指定により `$null` は空文字に変換されるため)

### Documentation
- `CLAUDE.md` / `AGENTS.md` の PS 5.1 落とし穴表を修正。単一要素配列の unwrap 対策として `Write-Output -NoEnumerate` を挙げていたが、**関数の唯一の出力だと結局展開されて効かない**ことを検証で確認したため `return ,$arr` (カンマ演算子) に改めた。tree API のページングと `ItemsSource` の型変換エラーも追記

---

## [1.2.0] - 2026-07-06

### Added
- ReportViewer の共通フィルタにシステム / 業務種別 / プロジェクトを追加し、全タブの集計母集団へ反映

### Changed
- ReportViewer の明細、グラフ、ヒートマップ、メンバー×PJ、異常検知、CSV 出力をコード表示中心から名称併記中心へ変更
- ReportViewer の工程 / タスクグループ / タスク名称解決で、プロジェクトの `task_pattern_id` を優先

### Fixed
- 業務種別比率タブで、システム選択後も関係ないプロジェクトが候補表示される問題を修正

---

## [1.1.0] - 2026-06-20

### Added
- 接続設定画面（ConfigDialog）にログ出力先フォルダ選択 UI を追加
- `config.json` に `log_dir` フィールドを追加（ブランク = ログなし）

### Changed
- `last_error.log` / `report_trace.log` の出力先を `config.log_dir` に従って動的に変更
- ログ出力先のデフォルトを「なし」に変更（旧デフォルト: `%APPDATA%\worktime-tracker`）
  - 既存ユーザーは設定画面でログ出力先を指定すれば従来どおりログが出力される

---

## [1.0.0] - 2026-05-25

初回正式リリース。社内チーム規模の作業実績管理として実用可能な状態。

### Added — 入力機能
- **WorkTime Tracker**: 日次実績入力 (4 段カスケード + バックデート + 行複製/編集/削除)
- **WBS Input**: 3 ペイン WBS 形式実績入力 (ツリー / グリッド+ガント / TaskView)
- WBS 項目を **プロジェクト定義** (`wbs_items[]`) として保存 (チーム共有)
- WBS 行に `status` (未着手/進捗中/完了/中止) を導入し、完了/中止のフィルタ切替
- WBS 編集列 (別名/担当/計画/期間/状態) を leader/admin のみ編集可に
- Tracker のカスケードを `wbs_items` で絞り込み (入力ミス防止)
- タスクパターンに **「説明」(desc)** を追加 → Tracker で黄帯表示
- エントリに **休暇属性 (is_leave)** を追加 (プロジェクト省略可、未入力検知から除外)

### Added — 管理者機能
- **AdminDialog**: マスタ編集 (members / projects / task_patterns / categories / holidays)
- 他者データ編集タブ
- JSON 直接編集タブ
- タスクパターン編集 (3 階層 + 兄弟/子追加 + 並び替え + テンプレートコピー)
- メンバー role を **複数選択 (admin / leader / member)** に対応

### Added — レポート
- **ReportViewer**: 期間 / メンバーフィルタ + クイック選択 (当月/前月/今年度)
- 14 タブ: ダッシュボード / 明細 / メンバー別 / プロジェクト別 / カテゴリ別 / **🖥 システム別** / **🏢 会社別** /
  分析 / ヒートマップ / メンバー負荷 / メンバー×PJ / **💼 業務種別比率** /
  異常検知 / グラフ
- 業務種別比率タブにシステム/プロジェクトの専用フィルタ
- 案件対応/維持運用ドリルダウンに **円グラフ + 月別積上棒グラフ**
- ヒートマップ軸切替 (日付×PJ / 日付×メンバー / メンバー×PJ)
- 表示は **コードでなく名称併記** ("E001 山田太郎" "ABC001 ABC案件" など)

### Added — ストレージ
- **ハイブリッド構造**: 常時ローカルキャッシュ + 任意で Gitlab REST API 同期
- DPAPI 暗号化トークン保管
- 起動時に「Gitlab から取得しますか?」Yes/No 確認
- ボタン用語規約 (📋 読込 / 📥 取得 / 💾 保存 / 📤 送信)

### Added — 配置・運用
- `scripts/setup.cmd`: 配布 zip からの初期セットアップ
- `scripts/uninstall.cmd`: 段階確認付きアンインストール
- `scripts/load-demo.cmd`: 4 メンバー × 2 ヶ月分のデモデータ生成 (シード固定で再現性)

### Added — 品質
- Pester 5 テストスイート (119 ケース)
- PSScriptAnalyzer 静的解析 (高シグナル 16 ルール)
- 全 .ps1 構文 + BOM チェック / XAML パース + FindName 整合
- 回帰防止テスト: ロール直接比較 / DataGrid 列定義
- CLAUDE.md: AI コーディング指針 (PS 5.1 落とし穴 11 項目, ロール / 用語 / テスト等)

### Fixed (1.0.0 リリース前に対処済の代表事例)
- PS 5.1 `@($List[object])` ArgumentException → foreach コピー
- 関数 return の単一要素 unwrap → `Write-Output -NoEnumerate -InputObject`
- DataGrid AutoGenerateColumns + 特殊文字 → `Set-PivotGrid` セーフ列名方式
- `param([switch]$Pull)` 内で `$pull = ...` した型上書き
- AdminBtn click が旧 `.role -eq 'admin'` 残骸で silent return
- WBS パターン行削除で後続のコード/名称が消える ($matches 自動変数 / SuppressEdit 漏れ)
- ReportViewer ハンドラ内未捕捉例外でウインドウ消滅 → `_SafeRun` 全包み
- Categoryなど summary grid が AutoGen=False + Columns 未定義で空表

[Unreleased]: https://github.com/noritakekohji/worktime-tracker/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/noritakekohji/worktime-tracker/releases/tag/v1.2.0
[1.1.0]: https://github.com/noritakekohji/worktime-tracker/releases/tag/v1.1.0
[1.0.0]: https://github.com/noritakekohji/worktime-tracker/releases/tag/v1.0.0
