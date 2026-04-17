"""
test_validator.py

Tests the Pydantic validation layer.
"""

import pandas as pd
import pytest
from f1_qualifying_dashboard.ingestion.validator import validate_qualifying_df


def test_validator_accepts_valid_data(fake_laps_df):
    validated = validate_qualifying_df(fake_laps_df)
    assert len(validated) == 2


def test_validator_rejects_negative_lap_time(fake_laps_df):
    df = fake_laps_df.copy()
    df.loc[0, "lap_time"] = -5

    with pytest.raises(ValueError):
        validate_qualifying_df(df)