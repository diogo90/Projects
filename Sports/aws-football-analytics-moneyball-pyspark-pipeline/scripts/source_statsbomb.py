"""
Source 1 - StatsBomb Open Data downloader.

Fetches only the competitions/seasons we need (Euro 2024 + Copa America 2024)
from the public hudl/open-data GitHub repo instead of cloning the multi-GB repo.
Output is laid out with Hive-style partitions so it can be uploaded to the S3
bronze layer as-is.

Usage:
    python scripts/source_statsbomb.py --out data/raw_to_s3/dataset_1
"""
import argparse
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

BASE_URL = "https://raw.githubusercontent.com/hudl/open-data/master/data"

# (competition_name, season_name) pairs to download
TARGETS = [
    ("UEFA Euro", "2024"),
    ("Copa America", "2024"),
]


def fetch_json(url: str):
    """GET a JSON file; raise on HTTP errors so failures are never silent."""
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return resp.json()


def save_json(data, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def download_match(match_id: int, part: str, out: Path) -> None:
    """Download the events and lineups files for one match (skips files already on disk)."""
    for entity in ("events", "lineups"):
        target = out / entity / part / f"{match_id}.json"
        if target.exists():
            continue
        save_json(fetch_json(f"{BASE_URL}/{entity}/{match_id}.json"), target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="data/raw_to_s3/dataset_1")
    args = parser.parse_args()
    out = Path(args.out) / "statsbomb"

    # 1. Competition catalog -> pick the target competition/season ids
    competitions = fetch_json(f"{BASE_URL}/competitions.json")
    save_json(competitions, out / "competitions" / "competitions.json")
    jobs = [c for c in competitions if (c["competition_name"], c["season_name"]) in TARGETS]
    if not jobs:
        raise SystemExit("None of the target competitions were found in the catalog.")

    for comp in jobs:
        part = f"competition_id={comp['competition_id']}/season_id={comp['season_id']}"

        # 2. Match metadata for the competition/season
        matches = fetch_json(f"{BASE_URL}/matches/{comp['competition_id']}/{comp['season_id']}.json")
        save_json(matches, out / "matches" / part / "matches.json")
        print(f"{comp['competition_name']} {comp['season_name']}: {len(matches)} matches")

        # 3. Nested event + lineup files, one per match (downloaded in parallel)
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda m: download_match(m["match_id"], part, out), matches))

    print("StatsBomb download complete ->", out)


if __name__ == "__main__":
    main()
