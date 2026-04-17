"""
conftest.py

Shared pytest fixtures for fake qualifying data and temporary DuckDB paths.
"""

import pandas as pd
import pytest
from f1_qualifying_dashboard.ingestion.models import QualifyingLap


@pytest.fixture
def fake_laps_df():
    """A small, clean DataFrame that mimics FastF1 output."""
    return pd.DataFrame({
        "driver": ["VER", "HAM"],
        "session": ["Q", "Q"],
        "lap_time": [70.123, 71.000],
        "lap_delta": [0.0, 0.877],
        "speed": [320.5, 318.0],
        "year": [2023, 2023],
        "round": [20, 20],
        "track": ["Brazil", "Brazil"],
    })


@pytest.fixture
def fake_validated_rows(fake_laps_df):
    """Convert fake DataFrame into validated Pydantic models."""
    return [QualifyingLap(**row) for row in fake_laps_df.to_dict(orient="records")]


@pytest.fixture
def tmp_duckdb_path(tmp_path):
    """Temporary DuckDB file for testing."""
    return tmp_path / "test.duckdb"