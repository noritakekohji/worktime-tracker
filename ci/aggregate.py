"""worktime-tracker 集計スクリプト

GitLab CI から実行。data/**/*.json と master/*.json を読み込み、
集計結果と Plotly グラフを 1 枚の HTML にまとめて public/index.html に出力する。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pandas as pd
import plotly.express as px
import plotly.io as pio

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
MASTER_DIR = ROOT / "master"
OUT_DIR = ROOT / "public"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_entries() -> pd.DataFrame:
    rows: list[dict] = []
    for f in DATA_DIR.rglob("*.json"):
        try:
            doc = load_json(f)
        except Exception as e:  # noqa: BLE001
            print(f"skip {f}: {e}")
            continue
        member_id = doc.get("member_id", "")
        for e in doc.get("entries", []) or []:
            rows.append({"member_id": member_id, **e})
    if not rows:
        return pd.DataFrame(
            columns=[
                "member_id", "date", "project_code", "process_code",
                "task_group_code", "task_code", "category", "hours", "comment",
            ]
        )
    df = pd.DataFrame(rows)
    df["date"] = pd.to_datetime(df["date"], errors="coerce")
    df["hours"] = pd.to_numeric(df["hours"], errors="coerce").fillna(0.0)
    df["year_month"] = df["date"].dt.strftime("%Y-%m")
    return df


def load_masters() -> dict[str, Any]:
    masters = {}
    for key in ("members", "projects", "categories"):
        p = MASTER_DIR / f"{key}.json"
        masters[key] = load_json(p) if p.exists() else []
    member_map = {m["id"]: m.get("name", m["id"]) for m in masters["members"]}
    project_map = {p["code"]: p.get("name", p["code"]) for p in masters["projects"]}
    category_map = {c["code"]: c.get("name", c["code"]) for c in masters["categories"]}
    return {
        "member_name": member_map,
        "project_name": project_map,
        "category_name": category_map,
    }


def enrich(df: pd.DataFrame, masters: dict[str, Any]) -> pd.DataFrame:
    if df.empty:
        return df
    df = df.copy()
    df["member_name"] = df["member_id"].map(masters["member_name"]).fillna(df["member_id"])
    df["project_name"] = df["project_code"].map(masters["project_name"]).fillna(df["project_code"])
    df["category_name"] = df["category"].map(masters["category_name"]).fillna(df["category"])
    return df


def fig_to_html(fig) -> str:
    return pio.to_html(fig, include_plotlyjs="cdn", full_html=False)


def build_html(df: pd.DataFrame) -> str:
    if df.empty:
        return _wrap_html("<h1>worktime-tracker</h1><p>データがありません。</p>")

    total = df["hours"].sum()
    members = df["member_id"].nunique()
    projects = df["project_code"].nunique()
    months = df["year_month"].nunique()

    # 月次 × メンバー (積み上げ棒)
    monthly_member = (
        df.groupby(["year_month", "member_name"], as_index=False)["hours"].sum()
    )
    fig1 = px.bar(
        monthly_member, x="year_month", y="hours", color="member_name",
        title="月次 × メンバー別 工数",
        labels={"year_month": "年月", "hours": "工数(h)", "member_name": "メンバー"},
    )

    # プロジェクト別合計 (横棒)
    by_project = (
        df.groupby("project_name", as_index=False)["hours"].sum()
        .sort_values("hours", ascending=True)
    )
    fig2 = px.bar(
        by_project, x="hours", y="project_name", orientation="h",
        title="プロジェクト別 合計工数",
        labels={"hours": "工数(h)", "project_name": "プロジェクト"},
    )

    # カテゴリ別比率 (円)
    by_category = df.groupby("category_name", as_index=False)["hours"].sum()
    fig3 = px.pie(by_category, names="category_name", values="hours", title="カテゴリ別 比率")

    # プロジェクト × 工程 (テーブル)
    by_proc = (
        df.groupby(["project_name", "process_code"], as_index=False)["hours"].sum()
        .sort_values(["project_name", "hours"], ascending=[True, False])
    )
    table_html = by_proc.to_html(index=False, classes="data-table", border=0)

    summary = f"""
    <div class="summary">
      <div><span class="label">総工数</span><span class="value">{total:,.1f} h</span></div>
      <div><span class="label">メンバー数</span><span class="value">{members}</span></div>
      <div><span class="label">プロジェクト数</span><span class="value">{projects}</span></div>
      <div><span class="label">対象月数</span><span class="value">{months}</span></div>
    </div>
    """

    body = f"""
    <h1>worktime-tracker ダッシュボード</h1>
    <p class="generated">生成日時: {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    {summary}
    <h2>月次 × メンバー</h2>
    {fig_to_html(fig1)}
    <h2>プロジェクト別 合計</h2>
    {fig_to_html(fig2)}
    <h2>カテゴリ別 比率</h2>
    {fig_to_html(fig3)}
    <h2>プロジェクト × 工程</h2>
    {table_html}
    """
    return _wrap_html(body)


def _wrap_html(body: str) -> str:
    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>worktime-tracker</title>
<style>
  body {{ font-family: -apple-system, "Segoe UI", "Hiragino Sans", sans-serif;
          background: #1e1e2e; color: #cdd6f4; margin: 0; padding: 20px; }}
  h1 {{ color: #a6e3a1; border-bottom: 2px solid #313244; padding-bottom: 8px; }}
  h2 {{ color: #89b4fa; margin-top: 30px; }}
  .generated {{ color: #6c7086; font-size: 12px; }}
  .summary {{ display: flex; gap: 16px; margin: 20px 0; flex-wrap: wrap; }}
  .summary > div {{ background: #181825; padding: 14px 20px; border-radius: 8px;
                    border-left: 4px solid #a6e3a1; min-width: 140px; }}
  .summary .label {{ display: block; font-size: 12px; color: #a6adc8; }}
  .summary .value {{ display: block; font-size: 22px; font-weight: bold; color: #f9e2af; }}
  .data-table {{ border-collapse: collapse; width: 100%; background: #181825; }}
  .data-table th {{ background: #313244; color: #cdd6f4; padding: 8px; text-align: left; }}
  .data-table td {{ padding: 6px 8px; border-top: 1px solid #313244; }}
</style>
</head>
<body>
{body}
</body>
</html>
"""


def main() -> None:
    OUT_DIR.mkdir(exist_ok=True)
    df = load_entries()
    masters = load_masters()
    df = enrich(df, masters)
    html = build_html(df)
    out = OUT_DIR / "index.html"
    out.write_text(html, encoding="utf-8")
    print(f"wrote {out} (entries={len(df)})")


if __name__ == "__main__":
    main()
