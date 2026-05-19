# analysis — Excel 分析ブック

`worktime-analysis.xlsx` は WorkTime Tracker のローカル保管先 (`local_store`) にある JSON データを **Power Query** で読み込み、ピボット・スライサー・グラフで分析するブックです。

## 使い方

1. **`worktime-analysis.xlsx` を開く**
2. 上部に「コンテンツの有効化」が出たらクリック (外部接続の許可)
3. **Settings シートの B2** (`LocalStorePath`) を自分の保管先に書き換え
   - 既定値: `%LOCALAPPDATA%\worktime-tracker\store`
   - 他人のフォルダや共有フォルダを指定する場合はフルパスで
4. **データ → すべて更新** (Ctrl+Alt+F5) でローカル JSON を再取得
5. **Dashboard シート** でピボット / スライサー / グラフが連動更新

## シート構成

| シート | 内容 |
|---|---|
| `Settings` | LocalStorePath の指定 (Excel Table `tbl_Settings`) |
| `Dashboard` | メンバー × 年月 ピボット + スライサー (プロジェクト/カテゴリ/業務種別/部署) + 円グラフ |
| `Entries` | 実績データ全件 (raw) |
| `EntriesEnriched` | マスタ結合済 (メンバー名・案件名・カテゴリ名・業務種別 等を解決) |
| `Members` | メンバーマスタ |
| `Projects` | プロジェクトマスタ |
| `Categories` | カテゴリマスタ |

## カスタマイズ

- **新しいピボット追加**: Dashboard で挿入 → ピボットテーブル → ソース = `EntriesEnrichedTable`
- **新しいスライサー追加**: ピボットを選択 → スライサーの挿入
- **CSV エクスポート**: Entries や EntriesEnriched シートで「名前を付けて保存」→ CSV

## 再生成 (開発者向け)

ブック構造を変更したい場合:
```cmd
powershell -ExecutionPolicy Bypass -File analysis\build-analysis-xlsx.ps1
```
※ Excel 2016+ が実行マシンに必要

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `Settings.tbl_Settings が見つかりません` | Settings シート A1:B2 が Excel Table 化されているか確認。再生成で復旧。 |
| すべて更新でエラー | Settings B2 のパスが存在するか確認。`master\` と `data\` がその下に存在する必要あり。 |
| 日本語が文字化け | JSON ファイル自体が UTF-8 で保存されているか確認 (WorkTime Tracker は UTF-8 で書く)。 |
| Power Query で「アクセスが拒否されました」 | 「データ ソースの設定」でフォルダのプライバシーレベルを「組織」または「パブリック」に設定。 |
