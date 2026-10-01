"""
===============================================================================
Extract & Parse: Sources -> Landing Zone (CSV)
===============================================================================
Script Purpose:
    SQL Server (including 2025 Express) cannot read local Parquet files: the
    OPENROWSET(FORMAT = 'PARQUET') connector only supports object storage.
    This script is the "File Parsing" step of the pipeline. It:

      1. PULLS the hourly weather for the reporting month from the Open-Meteo
         Historical Weather API (pull extraction, no API key needed) and stores
         the response as a CSV in datasets/source_weather/.
      2. VALIDATES every TLC Parquet file against its expected column contract
         (schema-drift detection: the run fails loudly if TLC adds, removes or
         renames a column, instead of silently loading shifted data).
      3. PARSES every source (Parquet + reference CSVs + weather CSV) into a
         uniform CSV format that BULK INSERT can read reliably:
         UTF-8, comma-delimited, double-quoted text, LF line endings, header row,
         NULL written as an empty field.
      4. WRITES a manifest (_manifest.csv) with the row count of every landed
         file. bronze.load_bronze reconciles the rows it loads against this
         manifest, so a truncated or partially-read file fails the batch.

    No business transformation happens here: values are landed as-is
    (Bronze = raw). Column names and order are preserved exactly.

Usage:
    pip install -r requirements.txt
    python scripts/extract/extract_sources.py --landing-dir "C:\\sql\\nyc_tlc_dwh\\landing"

Important:
    The landing folder must be readable by the SQL Server service account
    (e.g. NT Service\\MSSQL$SQLEXPRESS). Folders under C:\\Users\\<you>\\Documents
    usually are NOT, which is why the default is C:\\sql\\nyc_tlc_dwh\\landing.
===============================================================================
"""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import duckdb

PROJECT_ROOT = Path(__file__).resolve().parents[2]

# -----------------------------------------------------------------------------
# Source contracts: expected columns (name, parquet type) in source order.
# Taken from the TLC data dictionaries (March 2025 revision) and verified
# against the January 2025 files.
# -----------------------------------------------------------------------------
TLC_CONTRACTS: dict[str, list[tuple[str, str]]] = {
    "yellow": [
        ("VendorID", "INTEGER"), ("tpep_pickup_datetime", "TIMESTAMP"),
        ("tpep_dropoff_datetime", "TIMESTAMP"), ("passenger_count", "BIGINT"),
        ("trip_distance", "DOUBLE"), ("RatecodeID", "BIGINT"),
        ("store_and_fwd_flag", "VARCHAR"), ("PULocationID", "INTEGER"),
        ("DOLocationID", "INTEGER"), ("payment_type", "BIGINT"),
        ("fare_amount", "DOUBLE"), ("extra", "DOUBLE"), ("mta_tax", "DOUBLE"),
        ("tip_amount", "DOUBLE"), ("tolls_amount", "DOUBLE"),
        ("improvement_surcharge", "DOUBLE"), ("total_amount", "DOUBLE"),
        ("congestion_surcharge", "DOUBLE"), ("Airport_fee", "DOUBLE"),
        ("cbd_congestion_fee", "DOUBLE"),
    ],
    "green": [
        ("VendorID", "INTEGER"), ("lpep_pickup_datetime", "TIMESTAMP"),
        ("lpep_dropoff_datetime", "TIMESTAMP"), ("store_and_fwd_flag", "VARCHAR"),
        ("RatecodeID", "BIGINT"), ("PULocationID", "INTEGER"),
        ("DOLocationID", "INTEGER"), ("passenger_count", "BIGINT"),
        ("trip_distance", "DOUBLE"), ("fare_amount", "DOUBLE"), ("extra", "DOUBLE"),
        ("mta_tax", "DOUBLE"), ("tip_amount", "DOUBLE"), ("tolls_amount", "DOUBLE"),
        ("ehail_fee", "DOUBLE"), ("improvement_surcharge", "DOUBLE"),
        ("total_amount", "DOUBLE"), ("payment_type", "BIGINT"),
        ("trip_type", "BIGINT"), ("congestion_surcharge", "DOUBLE"),
        ("cbd_congestion_fee", "DOUBLE"),
    ],
    "fhv": [
        ("dispatching_base_num", "VARCHAR"), ("pickup_datetime", "TIMESTAMP"),
        ("dropOff_datetime", "TIMESTAMP"), ("PUlocationID", "BIGINT"),
        ("DOlocationID", "BIGINT"), ("SR_Flag", "BIGINT"),
        ("Affiliated_base_number", "VARCHAR"),
    ],
    "fhvhv": [
        ("hvfhs_license_num", "VARCHAR"), ("dispatching_base_num", "VARCHAR"),
        ("originating_base_num", "VARCHAR"), ("request_datetime", "TIMESTAMP"),
        ("on_scene_datetime", "TIMESTAMP"), ("pickup_datetime", "TIMESTAMP"),
        ("dropoff_datetime", "TIMESTAMP"), ("PULocationID", "INTEGER"),
        ("DOLocationID", "INTEGER"), ("trip_miles", "DOUBLE"), ("trip_time", "BIGINT"),
        ("base_passenger_fare", "DOUBLE"), ("tolls", "DOUBLE"), ("bcf", "DOUBLE"),
        ("sales_tax", "DOUBLE"), ("congestion_surcharge", "DOUBLE"),
        ("airport_fee", "DOUBLE"), ("tips", "DOUBLE"), ("driver_pay", "DOUBLE"),
        ("shared_request_flag", "VARCHAR"), ("shared_match_flag", "VARCHAR"),
        ("access_a_ride_flag", "VARCHAR"), ("wav_request_flag", "VARCHAR"),
        ("wav_match_flag", "VARCHAR"), ("cbd_congestion_fee", "DOUBLE"),
    ],
}

# Reference CSVs (small, version-controlled in datasets/source_reference).
REFERENCE_FILES = {
    "tlc_taxi_zone_lookup": "taxi_zone_lookup.csv",
    "tlc_code_values": "tlc_code_values.csv",
}

# Open-Meteo Historical Weather API (ERA5-based reanalysis, CC BY 4.0).
# Coordinates: Central Park, Manhattan - the reference station for NYC weather.
WEATHER_API = "https://archive-api.open-meteo.com/v1/archive"
WEATHER_LATITUDE = 40.7812
WEATHER_LONGITUDE = -73.9665
WEATHER_VARIABLES = [
    "temperature_2m", "apparent_temperature", "precipitation", "rain",
    "snowfall", "snow_depth", "weather_code", "cloud_cover", "wind_speed_10m",
]


def log(message: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def sql_path(path: Path) -> str:
    """Path literal safe to embed in a DuckDB SQL string."""
    return str(path).replace("\\", "/").replace("'", "''")


# -----------------------------------------------------------------------------
# 1. Pull extraction: weather API
# -----------------------------------------------------------------------------
def pull_weather(month: str, weather_dir: Path, refresh: bool) -> Path:
    year, mon = (int(part) for part in month.split("-"))
    last_day = calendar.monthrange(year, mon)[1]
    target = weather_dir / f"openmeteo_weather_hourly_{month}.csv"

    if target.exists() and not refresh:
        log(f"Weather file already pulled, reusing: {target.name} (use --refresh-weather to re-pull)")
        return target

    params = {
        "latitude": WEATHER_LATITUDE,
        "longitude": WEATHER_LONGITUDE,
        "start_date": f"{month}-01",
        "end_date": f"{month}-{last_day:02d}",
        "hourly": ",".join(WEATHER_VARIABLES),
        # TLC timestamps are NYC local time, so weather is requested in the same zone.
        "timezone": "America/New_York",
    }
    url = f"{WEATHER_API}?{urllib.parse.urlencode(params)}"
    log(f"Pulling weather from Open-Meteo: {url}")

    with urllib.request.urlopen(url, timeout=60) as response:
        payload = json.load(response)

    hourly = payload["hourly"]
    columns = ["time"] + WEATHER_VARIABLES
    weather_dir.mkdir(parents=True, exist_ok=True)
    with target.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(columns)
        writer.writerows(zip(*(hourly[col] for col in columns)))

    log(f"Weather saved: {target.name} ({len(hourly['time'])} hourly rows)")
    return target


# -----------------------------------------------------------------------------
# 2. Schema contract validation
# -----------------------------------------------------------------------------
def validate_contract(con: duckdb.DuckDBPyConnection, source: str, parquet: Path) -> None:
    actual = [
        (row[0], row[1])
        for row in con.execute(f"DESCRIBE SELECT * FROM read_parquet('{sql_path(parquet)}')").fetchall()
    ]
    expected = TLC_CONTRACTS[source]

    actual_names = [name for name, _ in actual]
    expected_names = [name for name, _ in expected]
    if actual_names != expected_names:
        missing = sorted(set(expected_names) - set(actual_names))
        extra = sorted(set(actual_names) - set(expected_names))
        raise ValueError(
            f"Schema drift in {parquet.name}: missing={missing} unexpected={extra} "
            f"(or column order changed). Update the contract and the Bronze DDL together."
        )

    type_changes = [
        f"{name}: expected {exp_type}, got {act_type}"
        for (name, act_type), (_, exp_type) in zip(actual, expected)
        if act_type != exp_type
    ]
    if type_changes:
        # Type changes are reported but not fatal: Bronze types are wide enough
        # for integer/float widening, and a real incompatibility fails BULK INSERT.
        log(f"  WARNING type changes in {parquet.name}: {type_changes}")


# -----------------------------------------------------------------------------
# 3. File parsing: anything -> uniform CSV
# -----------------------------------------------------------------------------
COPY_OPTIONS = "(FORMAT CSV, HEADER TRUE, DELIMITER ',', QUOTE '\"', NULLSTR '')"


def parse_parquet(con, source: str, parquet: Path, landing_dir: Path) -> tuple[str, int]:
    columns = ", ".join(f'"{name}"' for name, _ in TLC_CONTRACTS[source])
    target = landing_dir / f"{source}_tripdata.csv"
    con.execute(
        f"COPY (SELECT {columns} FROM read_parquet('{sql_path(parquet)}')) "
        f"TO '{sql_path(target)}' {COPY_OPTIONS}"
    )
    rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{sql_path(parquet)}')").fetchone()[0]
    return target.name, rows


def parse_csv(con, source_csv: Path, target_name: str, landing_dir: Path) -> tuple[str, int]:
    # all_varchar keeps values exactly as written in the source (no type inference).
    reader = f"read_csv('{sql_path(source_csv)}', header = true, all_varchar = true)"
    target = landing_dir / target_name
    con.execute(f"COPY (SELECT * FROM {reader}) TO '{sql_path(target)}' {COPY_OPTIONS}")
    rows = con.execute(f"SELECT COUNT(*) FROM {reader}").fetchone()[0]
    return target.name, rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract and parse NYC TLC sources into the landing zone.")
    parser.add_argument("--month", default="2025-01", help="Reporting month YYYY-MM (default: 2025-01)")
    parser.add_argument("--source-dir", type=Path, default=PROJECT_ROOT / "datasets" / "source_tlc",
                        help="Folder holding the TLC parquet files")
    parser.add_argument("--reference-dir", type=Path, default=PROJECT_ROOT / "datasets" / "source_reference")
    parser.add_argument("--weather-dir", type=Path, default=PROJECT_ROOT / "datasets" / "source_weather")
    parser.add_argument("--landing-dir", type=Path, default=Path(r"C:\sql\nyc_tlc_dwh\landing"),
                        help="Folder readable by the SQL Server service account")
    parser.add_argument("--refresh-weather", action="store_true", help="Re-pull weather even if the file exists")
    parser.add_argument("--skip-weather", action="store_true", help="Do not call the weather API")
    parser.add_argument("--memory-limit", default="2GB", help="DuckDB memory cap (default: 2GB)")
    args = parser.parse_args()

    args.landing_dir.mkdir(parents=True, exist_ok=True)
    # Remove the previous manifest first: if this run fails half-way, Bronze
    # must not load a mix of old and new files.
    (args.landing_dir / "_manifest.csv").unlink(missing_ok=True)
    started = datetime.now(timezone.utc)
    manifest: list[dict] = []
    con = duckdb.connect()
    # Stream large files instead of buffering them: cap memory, allow spilling
    # to disk, and drop insertion-order preservation (row order carries no
    # meaning in a relational table). Without this the 20M-row HVFHV file can
    # exhaust memory on a laptop.
    spill_dir = args.landing_dir / "_duckdb_spill"
    con.execute(f"SET memory_limit = '{args.memory_limit}'")
    con.execute(f"SET temp_directory = '{sql_path(spill_dir)}'")
    con.execute("SET preserve_insertion_order = false")

    def record(source_system: str, source_file: Path, landed: tuple[str, int]) -> None:
        file_name, rows = landed
        manifest.append({
            "file_name": file_name,
            "source_system": source_system,
            "reporting_month": f"{args.month}-01",
            "source_file": source_file.name,
            "row_count": rows,
            "file_size_bytes": (args.landing_dir / file_name).stat().st_size,
            "extracted_at_utc": started.strftime("%Y-%m-%d %H:%M:%S"),
        })
        log(f"  -> {file_name}: {rows:,} rows")

    try:
        # Weather (pull extraction)
        weather_file = args.weather_dir / f"openmeteo_weather_hourly_{args.month}.csv"
        if not args.skip_weather:
            weather_file = pull_weather(args.month, args.weather_dir, args.refresh_weather)
        if not weather_file.exists():
            raise FileNotFoundError(f"Weather file not found: {weather_file}")
        log("Parsing weather")
        record("openmeteo", weather_file, parse_csv(con, weather_file, "openmeteo_weather_hourly.csv", args.landing_dir))

        # Reference data
        for source_system_entity, file_name in REFERENCE_FILES.items():
            source_csv = args.reference_dir / file_name
            log(f"Parsing reference file {file_name}")
            record("tlc", source_csv, parse_csv(con, source_csv, f"{source_system_entity}.csv", args.landing_dir))

        # TLC trip records
        for source in TLC_CONTRACTS:
            parquet = args.source_dir / f"{source}_tripdata_{args.month}.parquet"
            if not parquet.exists():
                raise FileNotFoundError(f"Missing source file: {parquet}")
            log(f"Validating + parsing {parquet.name}")
            validate_contract(con, source, parquet)
            record(source, parquet, parse_parquet(con, source, parquet, args.landing_dir))

        # Manifest last: its presence means the landing zone is complete.
        manifest_path = args.landing_dir / "_manifest.csv"
        with manifest_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(manifest[0].keys()), lineterminator="\n")
            writer.writeheader()
            writer.writerows(manifest)
        log(f"Manifest written: {manifest_path} ({len(manifest)} files)")
        return 0

    except Exception as exc:  # noqa: BLE001 - top-level guard, report and fail the batch
        log(f"EXTRACTION FAILED: {exc}")
        return 1
    finally:
        con.close()
        if spill_dir.exists():
            for leftover in spill_dir.glob("*"):
                leftover.unlink(missing_ok=True)
            spill_dir.rmdir()


if __name__ == "__main__":
    sys.exit(main())
