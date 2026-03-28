"""
models.py

This module defines the Pydantic data models used to validate the raw
Twitter sentiment dataset during ingestion.

WHY THIS EXISTS:
- CSV files are flexible but unreliable: columns can change, types can drift,
  and missing values can appear without warning.
- Pydantic models give us a strict schema that every row must follow.
- If the source data changes unexpectedly, validation will fail early,
  preventing bad data from silently entering the pipeline.

TwitterSentimentRow:
- Represents ONE row of the raw CSV file.
- Ensures correct data types (e.g., ints, floats, datetime).
- Converts the date string (DD/MM/YYYY) into a proper datetime object.
"""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, field_validator
import math

class TwitterSentimentRow(BaseModel):
    """
    A strongly‑typed representation of a single row in the sentiment CSV.

    Each attribute corresponds to a column in the raw dataset.
    Pydantic automatically validates and converts types where possible.
    """

    date: datetime
    symbol: str
    twitterPosts: int
    twitterComments: int
    twitterLikes: int
    twitterImpressions: int
    twitterSentiment: Optional[float]

    @field_validator("date", mode="before")
    def parse_date(cls, v):
        """
        Convert the raw date into a datetime object.

        Accepts:
        - datetime objects (returned unchanged)
        - strings in YYYY-MM-DD format
        - strings in other formats (via dateutil parser)
        """
        if isinstance(v, datetime):
            return v  # already parsed

        # If you want strict YYYY-MM-DD:
        # return datetime.strptime(v, "%Y-%m-%d")

        # If you want flexible parsing:
        from dateutil import parser
        return parser.parse(v)
    
    @field_validator("twitterSentiment")
    def validate_sentiment_range(cls, v):
        """
        Ensure sentiment is between -1 and 1.
        Allow None and NaN values.
        """
        if v is None or (isinstance(v, float) and math.isnan(v)):
            return None  # normalize NaN to None

        if not -1 <= v <= 1:
            raise ValueError("twitterSentiment must be between -1 and 1")

        return v
