import time
import pandas as pd
from loguru import logger
from pathlib import Path
from typing import List
from pydantic import ValidationError
from .models import TwitterSentimentRow


def validate_twitter_sentiment_df(df) -> List[TwitterSentimentRow]:
    """
    Validate each row of the raw DataFrame using the TwitterSentimentRow model.

    WHY THIS EXISTS:
    - Pandas does not enforce data types strictly.
    - CSVs can contain unexpected values (strings instead of ints, missing fields, etc.).
    - This function converts each row into a Pydantic model, ensuring the data
      matches the expected schema before it enters the pipeline.

    HOW IT WORKS:
    - Convert the DataFrame into a list of dictionaries (one per row).
    - Attempt to create a TwitterSentimentRow model for each row.
    - If validation fails, raise a clear error showing which row failed and why.
    - Return a list of validated, strongly‑typed model instances.
    """
    rows = []
    for idx, record in enumerate(df.to_dict(orient="records")):
        try:
            row = TwitterSentimentRow(**record)
            rows.append(row)
        except ValidationError as e:
            raise ValueError(f"Row {idx} failed validation: {e}")
    return rows


def load_local_data(file_path: str) -> pd.DataFrame:
    """
    Load data from a local file into a DataFrame.

    Supports CSV, Parquet, and JSON files.
    """
    try:
        start_time = time.time()
        path = Path(file_path)

        if not path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        logger.info(f"Loading local file: {file_path}")

        if path.suffix == ".csv":
            df = pd.read_csv(path)
        elif path.suffix in [".parquet", ".pq"]:
            df = pd.read_parquet(path)
        elif path.suffix == ".json":
            df = pd.read_json(path)
        else:
            raise ValueError(f"Unsupported file type: {path.suffix}")

        elapsed = time.time() - start_time
        logger.info(f"Loaded file in {elapsed:.2f} seconds")

        return df

    except Exception as e:
        logger.error(f"Error loading local data: {e}")
        raise