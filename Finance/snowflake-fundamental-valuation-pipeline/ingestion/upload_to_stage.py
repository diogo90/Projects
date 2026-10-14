"""
Optional: land local raw files in the Snowflake internal stages and (optionally)
run the task graph. This is the scripted alternative to uploading in Snowsight.

    initial  backfill prices + split history + universe + SEC companyfacts + ticker map
    daily    one or more daily delta price files (prices_YYYY-MM-DD.csv)

PUT uploads with AUTO_COMPRESS (CSV -> .csv.gz); files already gzip-compressed
are uploaded as-is. Snowpipe load history makes re-uploads harmless: a file that
was already loaded is not loaded twice.

Authentication uses a named connection from ~/.snowflake/connections.toml
(the standard Snowflake CLI / connector config), so no secrets live in this repo.

Usage:
    pip install snowflake-connector-python
    python ingestion/upload_to_stage.py initial --connection my_trial --run
    python ingestion/upload_to_stage.py daily --dates 2026-10-12 2026-10-13 --run
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import snowflake.connector

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW = REPO_ROOT / "data" / "raw"
MARKET_STAGE = "@VALUATION_DB.LANDING.STG_MARKET_DATA"
SEC_STAGE = "@VALUATION_DB.LANDING.STG_SEC_EDGAR"
ROOT_TASK = "VALUATION_DB.OPS.TSK_00_INGEST_LANDING"

# (local glob, stage path) - mirrors the layout documented in 01_landing/01_file_formats_and_stages.sql
INITIAL_LOAD = [
    (RAW / "dataset1" / "backfill", "prices_backfill_*.csv", f"{MARKET_STAGE}/prices/backfill"),
    (RAW / "dataset1" / "reference", "stock_splits.csv", f"{MARKET_STAGE}/splits"),
    (REPO_ROOT / "config", "ticker_universe.csv", f"{MARKET_STAGE}/universe"),
    (RAW / "dataset2" / "companyfacts", "CIK*.json.gz", f"{SEC_STAGE}/companyfacts"),
    (RAW / "dataset2" / "reference", "company_tickers.json.gz", f"{SEC_STAGE}/ticker_map"),
]

log = logging.getLogger("upload_to_stage")


def put(cursor, local_dir: Path, pattern: str, stage_path: str) -> int:
    files = sorted(local_dir.glob(pattern))
    if not files:
        hint = " - run ingestion/extract_market_prices.py first" if "dataset1" in local_dir.parts else ""
        log.warning("No files match %s/%s%s", local_dir, pattern, hint)
        return 0
    already_gz = all(f.suffix == ".gz" for f in files)
    # PUT accepts a wildcard; forward slashes keep Windows paths valid in the file:// URI
    uri = f"file://{local_dir.as_posix()}/{pattern}"
    cursor.execute(
        f"PUT '{uri}' {stage_path} AUTO_COMPRESS={'FALSE' if already_gz else 'TRUE'} "
        "OVERWRITE=TRUE PARALLEL=8"
    )
    for source, _target, _ss, _ts, _sc, _tc, status, _msg in cursor.fetchall():
        log.info("%-40s -> %s [%s]", source, stage_path, status)
    return len(files)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["initial", "daily"])
    parser.add_argument("--dates", nargs="*", default=[], help="daily mode: YYYY-MM-DD dates to upload")
    parser.add_argument("--connection", default="default", help="name in ~/.snowflake/connections.toml")
    parser.add_argument("--run", action="store_true", help="EXECUTE TASK on the root task after uploading")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.mode == "initial":
        plan = INITIAL_LOAD
    else:
        if not args.dates:
            parser.error("daily mode needs --dates")
        plan = [(RAW / "dataset1" / "daily", f"prices_{d}.csv", f"{MARKET_STAGE}/prices/daily") for d in args.dates]

    with snowflake.connector.connect(connection_name=args.connection) as conn, conn.cursor() as cur:
        cur.execute("USE ROLE VALUATION_PIPELINE")
        uploaded = sum(put(cur, *step) for step in plan)
        log.info("Uploaded %d file(s)", uploaded)
        if args.run:
            cur.execute(f"EXECUTE TASK {ROOT_TASK}")
            log.info("Task graph started - follow it in Snowsight > Monitoring > Task History")
    return 0


if __name__ == "__main__":
    sys.exit(main())
