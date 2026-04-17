"""
run_ingestion_multiple_years.py

Robust multi-year qualifying ingestion:
- Preloads schedules once per year (cached)
- Uses only valid rounds per year
- Avoids rate limits
- Logs failures cleanly
"""

# 0. Enable FastF1 cache BEFORE importing fastf1
from f1_qualifying_dashboard.config.fastf1_cache import *

import time
import fastf1
import pandas as pd
from loguru import logger

# Add this after importing logger
logger.add("logs/ingestion.log", rotation="10 MB", retention="10 days", level="INFO")

from f1_qualifying_dashboard.ingestion.fastf1_loader_multiple_years import (
    load_multiple_years_rounds
)

def get_valid_rounds(year: int) -> list[int]:
    """Fetch valid rounds for a given year."""
    try:
        schedule = fastf1.get_event_schedule(year, include_testing=False)
        rounds = schedule["RoundNumber"].dropna().astype(int).tolist()
        logger.info(f"Year {year}: Found {len(rounds)} valid rounds → {rounds}")
        return rounds
    except Exception as e:
        logger.error(f"Failed to fetch schedule for {year}: {e}")
        return []


def run_ingestion_multiple(years: list[int]):
    """Main pipeline entry point."""
    logger.info(f"Loading qualifying data for years={years}")

    # Preload schedules
    schedules = {}
    for year in years:
        schedules[year] = get_valid_rounds(year)
        time.sleep(0.3)

    # Load all sessions using the robust multi-year loader
    df = load_multiple_years_rounds(years, schedules)

    logger.info(f"Loaded {len(df)} raw laps across all sessions")

    from f1_qualifying_dashboard.ingestion.validator import validate_qualifying_df
    validated = validate_qualifying_df(df)
    logger.info(f"Validated {len(validated)} laps")

    from f1_qualifying_dashboard.ingestion.duckdb_writer import save_qualifying_to_duckdb
    save_qualifying_to_duckdb(validated)
    logger.info("Saved validated qualifying data to DuckDB")


if __name__ == "__main__":
    run_ingestion_multiple(
        years=[2019, 2020, 2021, 2022, 2023, 2026]
    )