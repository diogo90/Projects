"""
Source 2 - Transfermarkt (Kaggle: davidcariboo/player-scores) extractor.

Pulls only the 5 relational CSVs the pipeline needs out of the Kaggle archive
and writes them one-folder-per-table, ready for the S3 bronze layer.

Get the archive first (Kaggle CLI or the web UI):
    kaggle datasets download -d davidcariboo/player-scores -p data/raw/dataset_2

Usage:
    python scripts/extract_transfermarkt.py --zip data/raw/dataset_2/archive.zip --out data/raw_to_s3/dataset_2
"""
import argparse
import shutil
import zipfile
from datetime import date
from pathlib import Path

# Tables used downstream (the large match-level CSVs are deliberately skipped)
TABLES = ["competitions", "clubs", "players", "player_valuations", "transfers"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", default="data/raw/dataset_2/archive.zip")
    parser.add_argument("--out", default="data/raw_to_s3/dataset_2")
    args = parser.parse_args()

    # Each extract lands in a dated folder so new Kaggle refreshes can be added
    # incrementally later without overwriting previous snapshots.
    snapshot = f"snapshot_date={date.today().isoformat()}"
    out = Path(args.out) / "transfermarkt"

    with zipfile.ZipFile(args.zip) as archive:
        for table in TABLES:
            target = out / table / snapshot / f"{table}.csv"
            target.parent.mkdir(parents=True, exist_ok=True)
            # Stream-copy so large files never sit fully in memory
            with archive.open(f"{table}.csv") as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            print(f"{table:<18} -> {target} ({target.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
