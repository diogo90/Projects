"""
fastf1_loader_multiple_years.py

Robust multi-year qualifying loader:
- Uses preloaded schedules (valid rounds only)
- Avoids invalid round requests
- Avoids repeated schedule API calls
- Gracefully handles failures
"""

from typing import Dict, List
import pandas as pd
from loguru import logger
from .fastf1_loader import load_qualifying_data


def load_multiple_years_rounds(
    years: List[int],
    schedules: Dict[int, List[int]]
) -> pd.DataFrame:
    """
    Load qualifying data for multiple years using preloaded valid rounds.

    Parameters
    ----------
    years : list[int]
        Years to ingest.
    schedules : dict[int, list[int]]
        Preloaded valid rounds per year (from get_valid_rounds).

    Returns
    -------
    pd.DataFrame
        Concatenated qualifying laps across all sessions.
    """

    all_dfs = []

    for year in years:
        valid_rounds = schedules.get(year, [])

        for rnd in valid_rounds:
            try:
                logger.info(f"Loading {year} Round {rnd}…")
                df = load_qualifying_data(year, rnd)
                all_dfs.append(df)
                logger.info(f"✓ Loaded {len(df)} laps for {year} Round {rnd}")

            except Exception as e:
                logger.warning(f"Skipping {year} Round {rnd}: {e}")

    if not all_dfs:
        logger.error("No data loaded — check logs.")
        return pd.DataFrame()

    return pd.concat(all_dfs, ignore_index=True)