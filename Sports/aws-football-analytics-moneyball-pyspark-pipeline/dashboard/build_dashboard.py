"""
Build the stakeholder dashboard (static HTML) from the Gold layer CSV exports.

Download the two CSV exports produced by Pipeline 3, then run:
    aws s3 cp s3://<bucket>/gold/exports/ ./gold_exports --recursive
    python dashboard/build_dashboard.py --matrix gold_exports/moneyball_scouting_matrix/part-*.csv \
                                        --backtest gold_exports/moneyball_backtest/part-*.csv

Writes dashboard/moneyball_dashboard.html (self-contained, open in any browser).
Standard library only - no pandas needed.
"""
import argparse
import csv
import glob
import json
import statistics
from pathlib import Path

HERE = Path(__file__).parent

# Columns shipped to the browser (keeps the page small)
KEEP = ["player_name", "player_nickname", "national_team", "competition_name", "position_group",
        "age_at_tournament", "minutes", "performance_score", "value_pre_tournament_eur",
        "value_12m_after_eur", "value_change_12m_pct", "position_median_value_eur", "current_club_name", "segment",
        "np_xg_p90", "xa_p90", "progressive_passes_p90", "defensive_actions_p90"]
NUMERIC = {"age_at_tournament", "minutes", "performance_score", "value_pre_tournament_eur",
           "value_12m_after_eur", "value_change_12m_pct", "position_median_value_eur", "np_xg_p90", "xa_p90",
           "progressive_passes_p90", "defensive_actions_p90"}


def read_csv(pattern):
    """Read the single part-file Spark wrote for an export."""
    matches = sorted(glob.glob(pattern))
    if not matches:
        raise SystemExit(f"No file matches {pattern}")
    path = matches[0]
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def num(v):
    return float(v) if v not in ("", None) else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--matrix", required=True)
    p.add_argument("--backtest", required=True)
    p.add_argument("--quality", help="optional pipeline_quality CSV with metric,value columns")
    p.add_argument("--out", default=str(HERE / "moneyball_dashboard.html"))
    a = p.parse_args()

    # 1. Player rows (typed, trimmed to the columns the page uses)
    players = []
    for r in read_csv(a.matrix):
        row = {k: (num(r[k]) if k in NUMERIC else r[k]) for k in KEEP}
        players.append(row)

    # 2. Back-test by segment
    backtest = [{k: (num(v) if k != "segment" else v) for k, v in r.items()} for r in read_csv(a.backtest)]

    # 3. Age insight: median 12-month value change by age band, below- vs above-median price
    bands = [("≤23", 0, 23), ("24–26", 24, 26), ("27–29", 27, 29), ("30+", 30, 99)]
    age = []
    for label, lo, hi in bands:
        rows = [x for x in players if x["age_at_tournament"] is not None and lo <= x["age_at_tournament"] <= hi
                and x["value_change_12m_pct"] is not None and x["position_median_value_eur"] is not None]
        cheap = [x["value_change_12m_pct"] for x in rows if x["value_pre_tournament_eur"] <= x["position_median_value_eur"]]
        dear = [x["value_change_12m_pct"] for x in rows if x["value_pre_tournament_eur"] > x["position_median_value_eur"]]
        age.append({"band": label,
                    "cheap_median": statistics.median(cheap) if cheap else None, "cheap_n": len(cheap),
                    "dear_median": statistics.median(dear) if dear else None, "dear_n": len(dear)})

    # 4. Headline KPIs
    kpi = {"eligible": len(players),
           "targets": sum(1 for x in players if x["segment"] == "Moneyball Target")}
    if a.quality:
        kpi.update({r["metric"]: num(r["value"]) for r in read_csv(a.quality)})

    data = {"players": players, "backtest": backtest, "age": age, "kpi": kpi}
    html = (HERE / "template.html").read_text(encoding="utf-8")
    html = html.replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False))
    Path(a.out).write_text(html, encoding="utf-8")
    print(f"Dashboard written -> {a.out} ({len(players)} players)")


if __name__ == "__main__":
    main()
