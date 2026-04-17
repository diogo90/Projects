"""
models.py

Defines the strongly‑typed Pydantic models used to validate each row of
qualifying data extracted from FastF1.

Why this matters:
- FastF1 returns mixed types (Timedelta, None, NaN, strings).
- Pydantic enforces a clean schema before data enters DuckDB.
- This prevents silent data corruption and makes debugging easier.
"""

from pydantic import BaseModel, field_validator
from typing import Optional
import math


class QualifyingLap(BaseModel):
    driver: str
    session: str
    lap_time: float        # seconds
    speed: Optional[float] # speed trap or None
    year: int
    round: int
    track: str

    @field_validator("lap_time")
    def validate_non_negative(cls, v):
        if v < 0:
            raise ValueError("Lap times and deltas must be non-negative")
        return v

    @field_validator("speed")
    def validate_speed(cls, v):
        if v is None or (isinstance(v, float) and math.isnan(v)):
            return None
        if v < 0:
            raise ValueError("Speed cannot be negative")
        return v