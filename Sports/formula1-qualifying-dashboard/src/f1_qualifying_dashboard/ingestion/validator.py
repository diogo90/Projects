"""
validator.py

Validates each row of the qualifying DataFrame using the QualifyingLap model.

Steps performed:
1. Convert each DataFrame row into a dict.
2. Attempt to instantiate a QualifyingLap model.
3. Raise a clear, row-specific error if validation fails.
4. Return a list of validated model instances.
"""

from typing import List
from pydantic import ValidationError
from .models import QualifyingLap


def validate_qualifying_df(df) -> List[QualifyingLap]:
    rows = []
    for idx, record in enumerate(df.to_dict(orient="records")):
        try:
            row = QualifyingLap(**record)
            rows.append(row)
        except ValidationError as e:
            raise ValueError(f"Row {idx} failed validation: {e}")
    return rows