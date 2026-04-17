"""
test_fastf1_loader.py

Tests the FastF1 loader using mocks so no real API calls occur.
"""

import pandas as pd
from unittest.mock import MagicMock, patch
from f1_qualifying_dashboard.ingestion.fastf1_loader import load_qualifying_data


@patch("f1_qualifying_dashboard.ingestion.fastf1_loader.fastf1")
def test_load_qualifying_data(mock_fastf1):
    # Mock session object
    mock_session = MagicMock()
    mock_session.event = {"EventName": "Brazil GP"}

    # Mock laps DataFrame
    mock_laps = pd.DataFrame({
        "Driver": ["VER"],
        "LapTime": pd.to_timedelta([70.0], unit="s"),
        "SpeedST": [320.0],
    })

    mock_session.laps.pick_quicklaps.return_value = mock_laps
    mock_fastf1.get_session.return_value = mock_session

    df = load_qualifying_data(2023, 20)

    assert len(df) == 1
    assert df.loc[0, "driver"] == "VER"
    assert df.loc[0, "track"] == "Brazil GP"
    assert df.loc[0, "session"] == "Q"