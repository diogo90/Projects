"""
test_duckdb_writer.py

Tests writing validated rows into DuckDB.
"""

import duckdb
from f1_qualifying_dashboard.ingestion.duckdb_writer import save_qualifying_to_duckdb


def test_duckdb_writer_creates_table(fake_validated_rows, tmp_duckdb_path):
    save_qualifying_to_duckdb(fake_validated_rows, db_path=str(tmp_duckdb_path))

    con = duckdb.connect(str(tmp_duckdb_path))
    df = con.execute("SELECT * FROM qualifying_laps").df()

    assert len(df) == 2
    assert "driver" in df.columns