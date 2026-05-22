# tests/

UIとライブラリのスモークテスト。社内 PC でも追加インストールなしで実行可能 (PS 5.1 標準のみ)。

## 起動

```
tests\run-tests.cmd
```

または PowerShell から:
```
powershell -ExecutionPolicy Bypass -File tests\Test-Smoke.ps1
```

## 検査内容

| Section | 内容 | 失敗時の影響 |
|---------|------|------|
| 1. XAML パース | 全 XAML ファイルが `XamlReader.Load` でロード可能か | 起動時にウインドウが開かなくなるので必須 |
| 2. 名前参照整合 | PS 側 `FindName('xxx')` の `xxx` が XAML に `x:Name="xxx"` として存在するか | UI 要素が null になり実行時クラッシュ |
| 3. lib 関数公開 | 主要な関数 (`Load-Config`, `Save-MasterHolidays`, `Initialize-DataContext` 等) が定義されているか | エントリポイントの import 漏れ検知 |
| 4. DataStore ラウンドトリップ | マスタ/月次エントリの書込→読込で同一データに復元できるか | I/O 層の回帰防止 |
| 5. 純粋関数 | 日付正規化 / メンバー2文字短縮 などのロジック | UI 内蔵の純粋関数を単体検証 |

## 検出できる典型バグ

- XAML の `x:Name` を消したが PS の `FindName` 参照が残っている → 起動時 `$null.Property` クラッシュを事前検知
- `lib/DataStore.ps1` の関数名タイプミス
- 同梱マスタ JSON の壊れ (パースエラー)
- 日付正規化ロジックのリグレッション

## 限界

- WPF ウインドウを実際に表示してマウス/キーボード操作する E2E テストは含まれません (WinAppDriver 等の追加導入が必要なため)。
- PS 5.1 の `$ErrorActionPreference = 'Stop'` で失敗を検知しますが、ハードクラッシュ (PowerShell.exe 自体が落ちる) は捕捉できません。

## CI 連携

GitHub Actions など Windows ランナーで実行する場合:
```yaml
- name: Run smoke tests
  shell: pwsh
  run: powershell -ExecutionPolicy Bypass -File tests/Test-Smoke.ps1
```

`exit 1` で失敗を返すのでビルドが正しく fail します。
