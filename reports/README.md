# reports (ローカル集計 GUI)

`ReportViewer.ps1` — PowerShell + WPF 製の集計ビューア。

クライアントと同じ設定 (`%APPDATA%\worktime-tracker\config.json`) を共有するため、
**先に WorkTimeTracker を起動して初回設定を済ませてから**起動してください。

## 機能

- 期間 / メンバー / プロジェクトでフィルタ
- 明細表
- メンバー別 / プロジェクト別 / カテゴリ別の 3 軸集計
- CSV エクスポート

## 起動

```cmd
launch.cmd
```

GitLab API から `data/**/*.json` を全件取得するため、初回は時間がかかります。

CI 側 (常時公開ダッシュボード) は [`ci/aggregate.py`](../ci/aggregate.py) を参照。
