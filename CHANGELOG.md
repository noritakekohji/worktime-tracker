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

(次バージョンへの変更を記録)

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

[Unreleased]: https://github.com/noritakekohji/worktime-tracker/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/noritakekohji/worktime-tracker/releases/tag/v1.0.0
