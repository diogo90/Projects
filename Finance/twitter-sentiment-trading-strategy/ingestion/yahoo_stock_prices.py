"""
yahoo_stock_prices.py

This module handles downloading daily stock price data for all symbols
present in the validated sentiment dataset and storing them in DuckDB.

Steps:
1. Connect to the existing DuckDB sentiment database.
2. Extract the list of unique stock symbols.
3. Download historical price data from Yahoo Finance.
4. Clean and flatten the data.
5. Persist the price data into DuckDB as a new table.
"""

import duckdb
import yfinance as yf
import pandas as pd
from loguru import logger


def download_and_save_prices(
    db_path="data/processed/sentiment.duckdb",
    table_name="prices_daily",
    start_date="2021-01-01",
    end_date="2023-03-01"
):
    logger.info("Starting stock price ingestion step")

    # 1. Connect to DuckDB
    con = duckdb.connect(db_path)

    # 2. Extract unique symbols from the sentiment table
    logger.info("Extracting list of symbols from DuckDB")
    symbols = con.execute("""
        SELECT DISTINCT symbol
        FROM twitter_sentiment
    """).df()["symbol"].tolist()

    logger.info(f"Found {len(symbols)} unique symbols")

    # 3. Download price data
    logger.info("Downloading price data from Yahoo Finance")
    raw = yf.download(
        tickers=symbols,
        start=start_date,
        end=end_date,
        group_by="ticker"
    )

    # 4. Transform into long format
    logger.info("Transforming price data into long format")

    # Reset index so the date becomes a column
    df = raw.reset_index()

    # Flatten MultiIndex columns into simple strings
    df.columns = [
        col[0] if col[0] == "Date" else f"{col[0]}_{col[1]}"
        for col in df.columns
    ]

    # Rename Date column to date
    df = df.rename(columns={"Date": "date"})

    # Melt into long format
    long_df = df.melt(
        id_vars=["date"],
        var_name="symbol_price",
        value_name="value"
    )

    # Split "symbol_price" into symbol + price_type
    long_df[["symbol", "price_type"]] = long_df["symbol_price"].str.split("_", expand=True)

    # Pivot into tidy OHLCV format
    long_df = long_df.pivot_table(
        index=["date", "symbol"],
        columns="price_type",
        values="value",
        aggfunc="first"
    ).reset_index()

    # Clean column names
    long_df.columns.name = None

    logger.info("Saving transformed price data to DuckDB")

    con.execute(f"CREATE OR REPLACE TABLE {table_name} AS SELECT * FROM long_df")

    con.close()
    logger.info("Stock price ingestion completed successfully")