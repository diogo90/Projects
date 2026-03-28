"""
duckdb_writer.py

This module contains utilities for persisting validated data into DuckDB.

DESIGN CHOICE:
- We only write *validated* data (Pydantic models), not the raw DataFrame.
- This ensures that DuckDB never sees unvalidated or malformed rows.
"""

from typing import List
import duckdb
import pandas as pd

from .models import TwitterSentimentRow


def save_validated_sentiment_to_duckdb(
    rows: List[TwitterSentimentRow],
    db_path: str = "data/processed/sentiment.duckdb",
    table_name: str = "twitter_sentiment",
) -> None:
    """
    Save a list of validated TwitterSentimentRow objects into a DuckDB table.

    HOW IT WORKS:
    - Convert the list of Pydantic models into a pandas DataFrame.
    - Open (or create) a DuckDB database at `db_path`.
    - Replace the target table with the new validated data.

    PARAMETERS:
    - rows: list of validated TwitterSentimentRow instances.
    - db_path: path to the DuckDB file on disk.
    - table_name: name of the table to create/replace in DuckDB.

    NOTE:
    - For now, we use a simple "drop and recreate" strategy.
      This is fine for a batch ingestion pipeline.
    """
    if not rows:
        # No data to write; we choose to treat this as a no-op.
        return

    # Convert Pydantic models to a clean DataFrame
    df = pd.DataFrame([row.model_dump() for row in rows])

    # Connect to DuckDB (creates the file if it doesn't exist)
    conn = duckdb.connect(db_path)

    try:
        # Register the DataFrame as a DuckDB view
        conn.register("validated_df", df)

        # Drop and recreate the table to ensure it matches the current schema
        conn.execute(f"DROP TABLE IF EXISTS {table_name}")
        conn.execute(f"CREATE TABLE {table_name} AS SELECT * FROM validated_df")
    finally:
        conn.close()