"""
pipeline.py

Main orchestration script for the qualifying ingestion pipeline.

Steps performed:
1. Load raw qualifying data from FastF1.
2. Validate each row using Pydantic.
3. Persist validated data into DuckDB.
4. Log progress for transparency and debugging.

This script is the entry point for your ingestion workflow.
"""

from f1_qualifying_dashboard.config.fastf1_cache import *

from loguru import logger
from f1_qualifying_dashboard.ingestion.fastf1_loader import load_qualifying_data
from f1_qualifying_dashboard.ingestion.validator import validate_qualifying_df
from f1_qualifying_dashboard.ingestion.duckdb_writer import save_qualifying_to_duckdb

# Add file logging
logger.add("logs/ingestion.log", rotation="10 MB", retention="10 days", level="INFO")

def run_ingestion(year: int, round: int):
    logger.info(f"Loading qualifying data for {year} Round {round}")

    df = load_qualifying_data(year, round)
    logger.info(f"Loaded {len(df)} raw laps")

    validated = validate_qualifying_df(df)
    logger.info(f"Validated {len(validated)} laps")

    save_qualifying_to_duckdb(validated)
    logger.info("Saved validated qualifying data to DuckDB")


if __name__ == "__main__":
    run_ingestion(2023, 20)  # Example: Brazil 2023