# CLAUDE.md — worktime-tracker AI コーディング指針

このリポジトリで Claude (および他の AI アシスタント) が作業するときに **必ず参照する** 規約集。  
詳細仕様は `docs/FUNCTIONAL_SPEC.md`、設計経緯は `docs/SPEC.md` を参照。

---

## 1. プロジェクト概要

社内チーム (10〜50 名) の作業実績を記録・集計するツール。

- **クライアント**: Windows 10/11 + PowerShell 5.1 + WPF (OS 標準のみ)
- **データ**: ハイブリッド (常時ローカルキャッシュ + 任意で Gitlab REST API)
- **認証**: GitLab Project Access Token (DPAPI 暗号化)
- **追加インストール禁止**: `git` CLI 不要、Python 不要、PS モジュールは Pester / PSScriptAnalyzer のみ許容

3 つの主画面 + ローカル集計:
- `client/WorkTimeTracker.ps1` — 日次実績入力 (Tracker)
- `client/WbsInput.ps1` — WBS 形式実績入力 (3 ペイン: ツリー / グリッド+ガント / TaskView)
- `reports/ReportViewer.ps1` — チームマネージャ向け集計ビューア (12 タブ)
- `client/lib/AdminDialog.ps1` — 管理者モード (admin role 限定)

---

## 2. ファイルエンコーディング規約 (厳守)

| 拡張子 | エンコーディング | 改行 | 理由 |
|---|---|---|---|
| `*.ps1` | **UTF-8 + BOM** | LF/CRLF どちらでも | PS 5.1 は BOM 無しを CP932 として誤解釈する |
| `*.xaml` | UTF-8 + BOM | LF/CRLF どちらでも | XamlReader.Load() の Unicode 判定 |
| `*.md` | UTF-8 + BOM | LF/CRLF どちらでも | 統一のため |
| `*.cmd` | **Shift-JIS** | **CRLF** | cmd.exe が BOM/LF を誤解釈する |
| `*.json` | UTF-8 (BOM 無し) | LF/CRLF どちらでも | JSON 規格 |

### ファイル作成後の必須手順

```powershell
$f = '<パス>'
$b = [System.IO.File]::ReadAllBytes($f)
if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
    $c = [System.IO.File]::ReadAllText($f)
    [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding($true)))
}
```

`.cmd` ファイルは PowerShell で `[System.Text.Encoding]::GetEncoding('shift_jis')` で書き出し、改行を `\r\n` に統一すること。

---

## 3. 必須ワークフロー (毎回)

```
1. コード編集
2. UTF-8 BOM チェック (全変更 .ps1 / .xaml / .md)
3. Pester 全件実行: powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
   - 必ず "Failed: 0" を確認
   - PSScriptAnalyzer 違反も Pester 経由で検証される
4. git add <個別ファイル> (`git add .` や `git add -A` は禁止)
5. git commit (Co-Authored-By: Claude ... タグ付き)
6. git push
```

**未テストでコミットしない。BOM 確認漏れもよくある事故源。**

---

## 4. PowerShell 5.1 落とし穴 (頻発)

| 症状 | 真因 | 対処 |
|---|---|---|
| `引数の型が一致しません` (ItemsSource 代入時) | `@($List[object] of PSCustomObject)` が ArgumentException を投げる | `foreach` で 1 要素ずつ `List[object]` にコピー (`Set-PivotGrid` 参照) |
| `用語 'XXX' は認識されません` | 関数が dot-source されていないファイルから呼ばれている | 共通ヘルパは `DataStore.ps1` (全画面 dot-source 済み) に置く |
| ComboBox に `System.Object[]` だけ表示される | 二重ラップ: `Write-Output -NoEnumerate` した戻り値を更に `@(...)` で囲んでいる | 呼出側の `@()` を外す |
| AdminBtn を押しても無反応 | 旧 `.role -eq 'admin'` が残っている (roles 配列スキーマで silent return) | `Has-Role -Member $m -Role 'admin'` に置換。`tests/unit/RoleUsage.Tests.ps1` が検出 |
| DataGrid の表が完全に空 | `AutoGenerateColumns="False"` + `<DataGrid.Columns>` 未定義 + PS で `.Columns.Add` していない | `tests/ui/DataGridColumns.Tests.ps1` が検出 |
| `引数の型が一致しません` (AutoGen Binding) | 列名に `/` `(` `)` ` ` `~` 等が含まれ、Binding パス解析が失敗 | `Set-PivotGrid` ヘルパで内部プロパティを `col0..colN` にリネーム |
| 単一要素配列が unwrap されて WPF が型変換失敗 | PS 5.1 で関数 return が単一要素配列を unwrap | `Write-Output -NoEnumerate -InputObject $arr` を使用 (位置引数 NG) |
| WPF UI イベント中に PS が落ちる | ハンドラ内未捕捉例外で Dispatcher 経由ホスト終了 | 全ハンドラを try/catch で囲む。`_SafeRun` パターン参照 |
| `$matches` を上書きしてしまう | PS 自動変数 (regex 結果) | `$hits` 等別名を使う。PSScriptAnalyzer が `PSAvoidAssignmentToAutomaticVariable` で検出 |
| `@( (if X) {} else {} )` が parse error | PS 5.1 は `@()` 内 `if` 式を許容しない | `$x = if (...) {...} else {...}; @($x, ...)` 形式に |
| `値 '@{...}' を型 'SwitchParameter' に変換できません` | `param([switch]$X)` の中で `$x = ...` と代入。PS は大小区別なしなので **同じ変数 `$X` を別型で上書き** | param と被らない別名 (`$xResult` 等) を使う |

---

## 5. データモデル (master/)

| ファイル | キー | 主要フィールド |
|---|---|---|
| `members.json` | `id` | `name`, `roles[]` (admin/leader/member), `active` |
| `projects.json` | `unit_code` | `project_name`, `unit_name`, `target_system`, `work_type` (案件対応/維持運用/その他), `task_pattern_id`, `period_from/to`, **`wbs_items[]`**, `active` |
| `task_patterns.json` | `id` | `processes[].task_groups[].tasks[]` (各 code/name) |
| `categories.json` | `code` | `name` |
| `holidays.json` | `date` | `name` |

### `projects.wbs_items[]` (重要)

プロジェクトで使う WBS 項目をプロジェクト定義の一部として保持 (チーム共有):

```json
{
  "process_code": "DSN", "task_group_code": "DB", "task_code": "ERD",
  "alias": "ER図 - 顧客マスタ",
  "status": "進捗中",   // 未着手 / 進捗中 / 完了 / 中止
  "planned_hours": 8.0,
  "assignee": "山田", "planned_start": "2026-05-01", "planned_end": "2026-05-10"
}
```

- 行のユニークキー: `(process_code, task_group_code, task_code, alias)`
- タスクグループレベルは `task_code = "-"`
- `wbs_items` が登録されているプロジェクトは **Tracker のカスケードもこれに絞る** (入力ミス防止)

### 実績データ (`data/YYYY/MM/<member_id>.json`)

```json
{
  "date": "2026-05-25",
  "project_code": "ABC001", "process_code": "DSN", "task_group_code": "DB", "task_code": "ERD",
  "category": "DESIGN", "is_leave": false,
  "hours": 3.5, "comment": "..."
}
```

- 1 人 1 月 1 ファイル
- `is_leave: true` はエントリ属性 (カテゴリではない)。プロジェクト等選択不要、Report の未入力検知で「入力あり」扱い

---

## 6. ロールシステム (`roles[]`)

| ロール | 権限 |
|---|---|
| `admin` | 管理者モード (マスタ編集、他者データ編集) |
| `leader` | WBS の編集 (項目追加・削除、別名/担当/計画/期間/状態) |
| `member` | 作業実績の計上 (Tracker / WbsInput TaskView)。WBS は閲覧のみ |

判定は **常に** `Has-Role -Member $m -Role 'admin'` を使うこと。`.role -eq 'admin'` は旧スキーマで silent fail する (`tests/unit/RoleUsage.Tests.ps1` で push 前検出)。

---

## 7. ボタン用語規約 (全画面共通)

| ボタン | 意味 | スタンドアローン | Gitlab モード |
|---|---|---|---|
| **📋 読込** | ローカルから読込 | ✓ | ✓ (リモート未参照) |
| **📥 取得** | リモートから取得 → ローカルから読込 | (誘導メッセージ) | ✓ |
| **💾 保存** | ローカルに保存 | ✓ | ✓ (リモート未送信) |
| **📤 送信** | ローカル保存 → リモートに反映 | (誘導メッセージ) | ✓ |

起動時は Gitlab モードのみ「マスタを取得しますか? Yes/No」モーダル。Yes で `Sync-Pull-Masters`、No でローカルキャッシュのみ。

---

## 8. ストレージ抽象 (`client/lib/DataStore.ps1`)

| 関数 | 用途 |
|---|---|
| `Get-Master*` | ローカル `master/*.json` 読込 |
| `Save-Master*` | ローカル書込 (push は別関数) |
| `Save-ProjectWbsItems` | 対象プロジェクトの `wbs_items` のみ差し替え、他は温存 |
| `Load-MonthEntries` / `Save-EntriesGrouped` | 月次データ |
| `Sync-Pull-Masters` | リモート → ローカル (master 全) |
| `Sync-Pull-MyData` | リモート → ローカル (個人月次 1 ファイル) |
| `Sync-Pull-AllData` | リモート → ローカル (data/全) |
| `Sync-Push-Masters` / `Sync-Push-MyData` | ローカル → リモート |
| `Has-Role` / `Get-MemberRoles` | ロール判定 (新 `roles` 配列 / 旧 `role` 単一 両対応) |

---

## 9. テスト構成 (`tests/`)

```
tests/
├── Invoke-Tests.ps1            # Pester 5 ランナー (auto-install)
├── PSScriptAnalyzerSettings.psd1  # 高シグナル 16 ルールに絞った設定
├── unit/
│   ├── Date.Tests.ps1
│   ├── Member.Tests.ps1
│   ├── AllScripts.Tests.ps1       # 全 .ps1 構文 + BOM チェック
│   ├── PSScriptAnalyzer.Tests.ps1 # 静的解析
│   └── RoleUsage.Tests.ps1        # .role -eq 'admin' 残骸検出
├── lib/
│   ├── DataStore.Tests.ps1
│   ├── Bootstrap.Tests.ps1
│   ├── Roles.Tests.ps1
│   └── ProjectWbsItems.Tests.ps1
├── ui/
│   ├── Xaml.Tests.ps1             # XAML パース + FindName 整合
│   └── DataGridColumns.Tests.ps1  # AutoGen=False + 列定義なし 検出
└── integration/EndToEnd.Tests.ps1
```

実行: `tests\run-tests.cmd` または `tests\Invoke-Tests.ps1`  
現在 **119 ケース PASS**。

**新機能を追加したら、回帰防止テストを必ず追加すること**:
- 過去事故と同じ pattern を tests/ で検出させる
- `RoleUsage.Tests.ps1` / `DataGridColumns.Tests.ps1` が良い手本

---

## 10. 配置 / アンインストール / デモデータ

| スクリプト | 用途 |
|---|---|
| `scripts/setup.cmd` | 配布 zip 解凍後の初期セットアップ (`%LOCALAPPDATA%\worktime-tracker` にコピー + ショートカット作成) |
| `scripts/uninstall.cmd` | InstallDir / ショートカット / `%APPDATA%` / local_store キャッシュ を段階確認で削除 |
| `scripts/load-demo.cmd` | デモ用サンプルデータ投入 (4 メンバー × 2 ヶ月分、シード固定) |

---

## 11. ログ場所 (デバッグ用)

```
%APPDATA%\worktime-tracker\last_error.log    # 致命エラー (Tracker / Report 共用、[Report] タグ付き)
%APPDATA%\worktime-tracker\report_trace.log  # Report の Build-* 詳細トレース ([mgr] タグで wrapper も追跡)
%USERPROFILE%\Desktop\report_trace.log       # Report _Diag (ApplyBtn click 等)
%APPDATA%\worktime-tracker\config.json       # 設定 (local_store パス等)
%APPDATA%\worktime-tracker\token.dat         # DPAPI 暗号化 PAT
```

問題発生時はまず `last_error.log` の末尾を見る。

---

## 12. コミットメッセージ規約

```
<type>(<scope>): <短い要約>

<具体的な変更内容を箇条書き>
- ...

<原因や設計判断があれば追記>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

- `feat` / `fix` / `refactor` / `test` / `docs` / `remove` 等を type に
- **必ず HEREDOC** で `git commit -m "$(cat <<'EOF' ... EOF)"` を使う (日本語改行保持)
- 末尾の Co-Authored-By タグは必須

---

## 13. やってはいけないこと

- `git add .` / `git add -A` (個別ファイル指定のみ)
- `git push --force` (main へは絶対禁止)
- `--no-verify` / `--no-gpg-sign` (hook はバグ検出器、迂回しない)
- 新規 `.md` ファイル作成 (ユーザ明示要求がない限り。本ファイルは例外)
- `Write-Host` / `echo` でユーザに直接話しかける (ツール結果として返す)
- 設計判断を勝手にする (大きな仕様変更は `AskUserQuestion` で確認)
- BOM 抜けで commit (PS 5.1 で文字化け事故)
- 単一ファイルを編集して "完了" と返す前にテスト未実行
