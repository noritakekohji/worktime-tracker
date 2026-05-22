# tests/

Pester 5 によるテストスイート。`run-tests.cmd` 実行で Pester 5 を自動インストール → 全テスト実行。

## 起動

```
tests\run-tests.cmd
```

または PowerShell から:
```powershell
powershell -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1

# タグ絞り込み
.\tests\Invoke-Tests.ps1 -Tag unit
.\tests\Invoke-Tests.ps1 -Tag integration

# カバレッジ取得 (tests/results/Coverage.xml に JaCoCo 形式で出力)
.\tests\Invoke-Tests.ps1 -Coverage

# Pester 自動インストールを無効化 (CI で事前 setup-済みのとき等)
.\tests\Invoke-Tests.ps1 -NoInstall
```

## ファイル構成

```
tests/
├── Invoke-Tests.ps1            # Pester 5 ランナー (自動インストール対応)
├── run-tests.cmd               # Windows ランチャ
├── README.md                   # 本ファイル
├── unit/                       # 純粋関数の単体テスト
│   ├── Date.Tests.ps1          #   日付正規化
│   └── Member.Tests.ps1        #   メンバー2文字短縮
├── ui/                         # XAML / WPF 結合
│   └── Xaml.Tests.ps1          #   XAMLパース + FindName 整合
├── lib/                        # ライブラリ層
│   ├── DataStore.Tests.ps1     #   マスタ/月次I/O ラウンドトリップ
│   └── Bootstrap.Tests.ps1     #   Initialize-DataContext (Mock使用)
└── integration/                # 機能横断シナリオ
    └── EndToEnd.Tests.ps1      #   マスタ→Bootstrap→エントリ
```

## タグ

| タグ | 説明 |
|------|------|
| `unit` | 純粋関数。I/O 一切なし。最速 |
| `ui` | XAML 読込・WPF 要素生成。GUI は表示しない |
| `lib` | DataStore 等ライブラリ層 (一時ディレクトリ使用) |
| `integration` | 複数モジュールを跨ぐシナリオ |

## 結果出力

- `tests/results/TestResults.xml` — NUnit 形式 (CI で `actions/upload-artifact` 等で集約可能)
- `tests/results/Coverage.xml` — JaCoCo 形式 (`-Coverage` 指定時)

## 自動インストールについて

`Invoke-Tests.ps1` は実行時に Pester 5 が見つからない場合:
```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
```
を試行します。PSGallery への到達が必要なので、社内プロキシ環境では下記いずれかを事前実施:

- `Register-PSRepository -Default` などで PSGallery を再登録
- `$env:HTTPS_PROXY` を設定
- 別環境で `Save-Module Pester -Path ...` で取得 → 持ち込み

PS 5.1 に同梱の Pester 3.4 は構文が古く本テストでは動作しないため、5.0 以上が必須です。

## CI 連携 (GitHub Actions 例)

```yaml
- name: Run Pester tests
  shell: powershell
  run: |
    powershell -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Coverage
- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: test-results
    path: tests/results/
```

## 検査内容ハイライト

| 領域 | 代表ケース |
|------|---------|
| 日付正規化 | `19270311` → `1927-03-11`, `2026/5/1` → `2026-05-01`, 無効値はそのまま |
| メンバー短縮 | `noritake` → `no`, `田中太郎` → `田中`, 2 文字以下はそのまま |
| XAML | 6 つの XAML すべてが `XamlReader.Load` 成功 |
| 名前整合 | PS の `FindName('xxx')` が XAML に存在 (XAML 削除 → PS 漏れを即検知) |
| DataStore | マスタ/月次エントリのラウンドトリップ、別月独立、別メンバー独立 |
| Bootstrap | `Initialize-DataContext` を Mock で隔離してロジック検証 |
| 統合 | マスタ書込 → Bootstrap 読込 → CurrentMember 解決 |
