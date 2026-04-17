"""
fastf1_loader.py

Handles extraction of qualifying data from the FastF1 API.

Steps performed:
1. Load the qualifying session (Q) for a given year/round.
2. Extract quick laps only (removes out-laps, in-laps, invalid laps).
3. Convert FastF1 objects into a clean pandas DataFrame.
4. Compute lap deltas relative to the session fastest lap.
"""

import fastf1
import pandas as pd


def load_qualifying_data(year: int, round: int) -> pd.DataFrame:
    session = fastf1.get_session(year, round, "Q")
    session.load()

    laps = session.laps.pick_quicklaps()

    df = pd.DataFrame({
        "driver": laps["Driver"],
        "session": "Q",  # Qualifying session label
        "lap_time": laps["LapTime"].dt.total_seconds(),
        "speed": laps["SpeedST"],
        "year": year,
        "round": round,
        "track": session.event["EventName"],
    })

    return df