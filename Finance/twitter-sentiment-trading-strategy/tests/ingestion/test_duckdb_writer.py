"""
tests/ingestion/test_duckdb_writer.py

This module tests that validated TwitterSentimentRow objects can be
successfully written to and read from an in-memory DuckDB database.
"""

from datetime import datetime
import duckdb

from ingestion.models import TwitterSentimentRow
from ingestion.duckdb_writer import save_validated_sentiment_to_duckdb


def test_save_validated_sentiment_to_duckdb_in_memory(tmp_path):
    """
    GIVEN a small list of validated TwitterSentimentRow instances
    WHEN we save them into a DuckDB database
    THEN the target table should exist and contain the same number of rows.
    """
    rows = [
        TwitterSentimentRow(
            date=datetime(2021, 11, 18),
            symbol="AAPL",
            twitterPosts=100,
            twitterComments=200,
            twitterLikes=300,
            twitterImpressions=4000,
            twitterSentiment=0.5,
        )
    ]

    db_path = tmp_path / "test_sentiment.duckdb"

    # Write to DuckDB
    save_validated_sentiment_to_duckdb(rows, db_path=str(db_path), table_name="twitter_sentiment")

    # Read back from DuckDB and assert row count
    conn = duckdb.connect(str(db_path))
    try:
        result = conn.execute("SELECT COUNT(*) FROM twitter_sentiment").fetchone()[0]
    finally:
        conn.close()

    assert result == len(rows)