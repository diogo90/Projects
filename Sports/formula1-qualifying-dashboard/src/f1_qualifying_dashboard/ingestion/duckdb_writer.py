"""
duckdb_writer.py

Writes validated qualifying data into a DuckDB database.

Steps performed:
1. Convert Pydantic models → pandas DataFrame.
2. Connect to DuckDB (creates file if missing).
3. Drop and recreate the target table.
4. Write the validated data.

This ensures:
- A clean, reproducible table schema.
- No partial or corrupted writes.
"""

import duckdb
import pandas as pd
from typing import List
from .models import QualifyingLap


def save_qualifying_to_duckdb(
    rows: List[QualifyingLap],
    db_path: str = "data/processed/f1.duckdb",
    table_name: str = "qualifying_laps",
):
    if not rows:
        return

    df = pd.DataFrame([row.model_dump() for row in rows])

    conn = duckdb.connect(db_path)
    try:
        conn.register("validated_df", df)
        conn.execute(f"DROP TABLE IF EXISTS {table_name}")
        conn.execute(f"CREATE TABLE {table_name} AS SELECT * FROM validated_df")
    finally:
        conn.close()