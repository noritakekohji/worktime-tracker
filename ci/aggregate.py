"""worktime-tracker 集計スクリプト (GitLab CI から実行)

data/**/*.json と master/*.yaml を読み込み、
集計結果を HTML レポートとして public/ に出力する。
GitLab Pages 公開用。

TODO:
  - pandas で集計
  - plotly でグラフ生成
  - public/index.html 出力
"""

from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
MASTER_DIR = ROOT / "master"
OUT_DIR = ROOT / "public"


def load_entries() -> list[dict]:
    entries: list[dict] = []
    for f in DATA_DIR.rglob("*.json"):
        with f.open(encoding="utf-8") as fh:
            doc = json.load(fh)
        for e in doc.get("entries", []):
            entries.append({"member_id": doc["member_id"], **e})
    return entries


def main() -> None:
    OUT_DIR.mkdir(exist_ok=True)
    entries = load_entries()
    # TODO: 集計・HTML 生成
    (OUT_DIR / "index.html").write_text(
        f"<html><body><h1>worktime-tracker</h1><p>entries: {len(entries)}</p></body></html>",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
