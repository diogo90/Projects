"""
Dataset 1 extractor - daily OHLCV market data from Yahoo Finance (yfinance).

Two load patterns, mirroring how a production market-data feed is consumed:

  backfill  One file holding the full history window (initial/historical load).
  delta     One file PER TRADING DAY (prices_YYYY-MM-DD.csv) - the incremental
            "daily delta" files that are dropped into the stage after the
            backfill and picked up by Snowpipe -> Stream -> Task MERGE.
  splits    Full stock-split history per ticker (corporate actions reference).
            Needed to put SEC per-share figures (EPS) on the same share basis as
            the split-adjusted price history, including splits that pre-date
            the price window (e.g. NVDA 4:1 in July 2021).

Output is a tidy (long) CSV: one row per ticker per trading day. Prices are kept
unadjusted (close) alongside the adjusted close and corporate actions, so the
curated layer, not the extractor, decides how to treat splits and dividends.

Usage:
    python ingestion/extract_market_prices.py backfill --start 2021-10-01 --end 2026-09-30
    python ingestion/extract_market_prices.py delta    --start 2026-10-01 --end 2026-10-13
    python ingestion/extract_market_prices.py splits   --start 2010-01-01
"""
from __future__ import annotations

import argparse
import csv
import logging
import shutil
import sys
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import yfinance as yf

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_UNIVERSE = REPO_ROOT / "config" / "ticker_universe.csv"
DEFAULT_OUT = REPO_ROOT / "data" / "raw" / "dataset1"

COLUMNS = ["ticker", "trade_date", "open", "high", "low", "close", "adj_close",
           "volume", "dividends", "stock_splits", "source", "extracted_at_utc"]
RENAME = {"Open": "open", "High": "high", "Low": "low", "Close": "close",
          "Adj Close": "adj_close", "Volume": "volume", "Dividends": "dividends",
          "Stock Splits": "stock_splits"}

log = logging.getLogger("extract_prices")


def load_tickers(universe_csv: Path) -> list[str]:
    # A ticker can map to several SEC registrants (cik_role), so de-duplicate.
    with universe_csv.open(newline="", encoding="utf-8") as f:
        return list(dict.fromkeys(row["ticker"] for row in csv.DictReader(f)))


def fetch(tickers: list[str], start: date, end: date) -> pd.DataFrame:
    """Download [start, end] inclusive and return a long-format frame."""
    wide = yf.download(
        tickers,
        start=start.isoformat(),
        end=(end + timedelta(days=1)).isoformat(),  # yfinance 'end' is exclusive
        interval="1d",
        auto_adjust=False,
        actions=True,
        group_by="ticker",
        threads=True,
        progress=False,
    )
    if wide.empty:
        return pd.DataFrame(columns=COLUMNS)

    frames = []
    for ticker in tickers:
        if ticker not in wide.columns.get_level_values(0):
            log.warning("No data returned for %s", ticker)
            continue
        df = wide[ticker].rename(columns=RENAME).dropna(subset=["close"])
        df = df.reset_index().rename(columns={"Date": "trade_date"})
        df.insert(0, "ticker", ticker)
        frames.append(df)

    out = pd.concat(frames, ignore_index=True)
    out["trade_date"] = pd.to_datetime(out["trade_date"]).dt.date
    out["volume"] = out["volume"].astype("int64")
    out["source"] = "yahoo_finance"
    out["extracted_at_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for col in ("dividends", "stock_splits"):
        if col not in out:
            out[col] = 0.0
    return out[COLUMNS].sort_values(["trade_date", "ticker"])


def fetch_splits(tickers: list[str], start: date) -> pd.DataFrame:
    rows = []
    for ticker in tickers:
        splits = yf.Ticker(ticker).splits
        for ts, ratio in splits.items():
            if ts.date() >= start:
                rows.append({"ticker": ticker, "split_date": ts.date(), "split_ratio": float(ratio)})
    out = pd.DataFrame(rows, columns=["ticker", "split_date", "split_ratio"])
    out["source"] = "yahoo_finance"
    out["extracted_at_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return out.sort_values(["ticker", "split_date"])


def write(df: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(path, index=False, float_format="%.6f")
    log.info("Wrote %s (%d rows, %d tickers)", path, len(df), df["ticker"].nunique())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["backfill", "delta", "splits"])
    parser.add_argument("--start", type=date.fromisoformat, required=True)
    parser.add_argument("--end", type=date.fromisoformat, default=date.today() - timedelta(days=1))
    parser.add_argument("--universe", type=Path, default=DEFAULT_UNIVERSE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    tickers = load_tickers(args.universe)

    # Keep yfinance's timezone/cookie cache in ONE fixed temp folder (a few KB)
    # instead of the user profile. On Windows its SQLite files stay locked until
    # the process exits, so a per-run folder could not be deleted reliably.
    cache_dir = Path(tempfile.gettempdir()) / "yfinance_cache_valuation_pipeline"
    cache_dir.mkdir(exist_ok=True)
    yf.set_tz_cache_location(str(cache_dir))
    try:
        if args.mode == "splits":
            write(fetch_splits(tickers, args.start), args.out / "reference" / "stock_splits.csv")
            return 0
        df = fetch(tickers, args.start, args.end)
    finally:
        shutil.rmtree(cache_dir, ignore_errors=True)   # best effort; see note above

    if df.empty:
        log.error("No rows returned for %s..%s", args.start, args.end)
        return 1

    if args.mode == "backfill":
        write(df, args.out / "backfill" / f"prices_backfill_{args.start}_{args.end}.csv")
    else:
        for trade_date, day in df.groupby("trade_date"):
            write(day, args.out / "daily" / f"prices_{trade_date}.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
