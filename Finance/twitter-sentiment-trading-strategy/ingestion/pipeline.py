"""
pipeline.py

This module orchestrates the ingestion flow for the Twitter sentiment data:

1. Load raw data from a local CSV.
2. Validate each row using Pydantic models.
3. Persist the validated data into DuckDB.
4. Persist price data into DuckDB.
"""

from .local_loader import load_local_data, validate_twitter_sentiment_df
from .duckdb_writer import save_validated_sentiment_to_duckdb
from .yahoo_stock_prices import download_and_save_prices
from .yahoo_nasdaq_prices import download_and_save_nasdaq_prices
from loguru import logger


def main():
    """
    Orchestrate the ingestion pipeline for Twitter sentiment data.

    STEPS:
    - For Twitter sentiment data:
        - Load the raw CSV into a pandas DataFrame.
        - Validate each row into a TwitterSentimentRow model.
        - Save the validated rows into a DuckDB table.
        - Print a small preview for manual inspection during development.
    - For Yahoo stock price data:
        - Ingest fresh Yahoo stock price data with yfinance 
        - Download and save the data into a DuckDB table. 
    - For the NASDAQ (QQQ) benchmark prices:
        - Ingest NASDAQ (QQQ) benchmark prices using yfinance
        - Download and save the data into a DuckDB table. 
    """
    logger.info("Starting ingestion pipeline")

    # 1. Load raw data
    df = load_local_data("data/raw/sentiment_data.csv")
    logger.info(f"Loaded {len(df)} raw rows")

    # 2. Validate rows using Pydantic
    validated_rows = validate_twitter_sentiment_df(df)
    logger.info(f"Validated {len(validated_rows)} rows successfully")


    print("Data validation passed successfully.")
    print("Example validated row:", validated_rows[0])
    print("Raw DataFrame preview:")
    print(df.head())

    # 3. Save validated data into DuckDB
    save_validated_sentiment_to_duckdb(
        validated_rows,
        db_path="data/processed/sentiment.duckdb",
        table_name="twitter_sentiment",
    )

    print("Validated sentiment data successfully written to DuckDB.")
    logger.info("Saved validated sentiment data to DuckDB")
    
    # 4. Download & save stock price data

    logger.info("Starting stock price ingestion step")
    download_and_save_prices(
        db_path="data/processed/sentiment.duckdb",
        table_name="prices_daily",
        start_date="2021-01-01",
        end_date="2023-03-01"
    )
    logger.info("Stock price ingestion completed")

    logger.info("Full ingestion pipeline completed successfully")
    
    # 5. Download the NASDAQ (QQQ) benchmark prices 
    
    logger.info("Starting Nasdaq (QQQ) benchmark price ingestion")
    download_and_save_nasdaq_prices(
        db_path="data/processed/sentiment.duckdb",
        table_name="nasdaq_prices_daily",
        start_date="2021-01-01",
        end_date="2023-03-01"
    )
    logger.info("Nasdaq (QQQ) benchmark price ingestion completed")

if __name__ == "__main__":
    main()