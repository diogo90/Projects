"""
Dataset 2 extractor - SEC EDGAR "Company Facts" (XBRL financial statement data).

The SEC bulk archive (companyfacts.zip, ~1.4 GB zipped / ~20k JSON files) is far
larger than the 50-company universe needs. Instead of unzipping it, this script
reads the archive's central directory and streams ONLY the target members, writing
each one straight to a gzip file. Payload bytes are untouched (bronze = "as
delivered"), but disk usage drops from ~223 MB to ~15 MB, and Snowflake reads
.gz natively, so nothing has to be decompressed before staging.

It also downloads the SEC ticker -> CIK mapping file (company_tickers.json) and
validates the universe against it before extracting. This catches stale or wrong
CIKs (e.g. a ticker whose registrant changed after a holding-company
reorganisation) before they silently produce empty or wrong fundamentals.

Usage:
    python ingestion/extract_sec_companyfacts.py \
        --zip data/raw/companyfacts.zip \
        --out data/raw/dataset2 \
        --user-agent "Your Name your.email@example.com"
"""
from __future__ import annotations

import argparse
import csv
import gzip
import json
import logging
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

SEC_TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_UNIVERSE = REPO_ROOT / "config" / "ticker_universe.csv"

log = logging.getLogger("extract_sec")


def load_universe(universe_csv: Path) -> list[dict[str, str]]:
    with universe_csv.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def member_name(cik: str | int) -> str:
    """SEC file naming convention: CIK zero-padded to 10 digits (CIK0000320193.json)."""
    return f"CIK{int(cik):010d}.json"


def download_ticker_mapping(out_dir: Path, user_agent: str) -> Path:
    """SEC fair-access policy requires a descriptive User-Agent with contact email."""
    dest = out_dir / "reference" / "company_tickers.json.gz"
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(SEC_TICKERS_URL, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req, timeout=60) as resp, gzip.open(dest, "wb") as dst:
        shutil.copyfileobj(resp, dst)
    log.info("Ticker mapping saved -> %s", dest)
    return dest


def validate_universe(universe: list[dict[str, str]], mapping_path: Path) -> int:
    """Warn when a ticker's PRIMARY CIK differs from the SEC's current mapping."""
    with gzip.open(mapping_path, "rt", encoding="utf-8") as f:
        sec = {v["ticker"]: (int(v["cik_str"]), v["title"]) for v in json.load(f).values()}
    issues = 0
    for row in universe:
        if row.get("cik_role", "primary") != "primary":
            continue
        expected = sec.get(row["ticker"])
        if expected is None:
            log.warning("%s not present in SEC ticker map", row["ticker"])
            issues += 1
        elif expected[0] != int(row["cik"]):
            log.warning("%s: universe CIK %s != SEC CIK %s (%s)",
                        row["ticker"], row["cik"], expected[0], expected[1])
            issues += 1
    log.info("Universe validation finished with %d issue(s)", issues)
    return issues


def extract_companyfacts(zip_path: Path, out_dir: Path, targets: dict[str, str]) -> int:
    companyfacts_dir = out_dir / "companyfacts"
    companyfacts_dir.mkdir(parents=True, exist_ok=True)
    extracted = 0
    with zipfile.ZipFile(zip_path) as archive:
        members = {info.filename: info for info in archive.infolist()}
        missing = sorted(set(targets) - set(members))
        if missing:
            log.warning("Not found in archive: %s", ", ".join(missing))
        for name in sorted(set(targets) & set(members)):
            dest = companyfacts_dir / f"{name}.gz"
            # Stream member -> gzip in 1 MB chunks: never holds a full file in memory
            # and never writes the uncompressed JSON to disk.
            with archive.open(name) as src, gzip.open(dest, "wb", compresslevel=9) as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
            extracted += 1
            log.info("%-6s %s -> %s (%.2f MB uncompressed, %.2f MB gz)",
                     targets[name], name, dest.name,
                     members[name].file_size / 1e6, dest.stat().st_size / 1e6)
    return extracted


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--zip", type=Path, required=True, help="Path to SEC companyfacts.zip")
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "data" / "raw" / "dataset2")
    parser.add_argument("--universe", type=Path, default=DEFAULT_UNIVERSE)
    parser.add_argument("--user-agent", required=True, help='e.g. "Jane Doe jane@example.com"')
    parser.add_argument("--skip-mapping", action="store_true", help="Do not download/validate company_tickers.json")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    universe = load_universe(args.universe)
    if not args.skip_mapping:
        validate_universe(universe, download_ticker_mapping(args.out, args.user_agent))

    # Every CIK (primary and predecessor) is extracted: predecessors hold the history.
    targets = {member_name(row["cik"]): row["ticker"] for row in universe}
    count = extract_companyfacts(args.zip, args.out, targets)
    log.info("Extracted %d / %d company files", count, len(targets))
    return 0 if count == len(targets) else 1


if __name__ == "__main__":
    sys.exit(main())
