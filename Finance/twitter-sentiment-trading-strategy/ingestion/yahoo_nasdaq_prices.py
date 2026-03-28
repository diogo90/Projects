"""
yahoo_nasdaq_prices.py

Purpose:
    Downloads daily OHLCV price data for the Nasdaq-100 ETF (QQQ)
    using the yfinance package, transforms it into a tidy long-format
    structure, and stores it in DuckDB.

Notes:
    - This mirrors the structure used for daily stock prices.
    - The output table will be named `nasdaq_prices_daily`.
    - The transformation flattens the MultiIndex columns returned by yfinance.
"""

import duckdb
import yfinance as yf
import pandas as pd
from loguru import logger


def download_and_save_nasdaq_prices(
    db_path="data/processed/sentiment.duckdb",
    table_name="nasdaq_prices_daily",
    start_date="2021-01-01",
    end_date="2023-03-01"
):
    logger.info("Starting Nasdaq (QQQ) price ingestion step")

    # 1. Connect to DuckDB
    con = duckdb.connect(db_path)

    # 2. Download QQQ price data
    logger.info("Downloading QQQ price data from Yahoo Finance")

    raw = yf.download(
        tickers="QQQ",
        start=start_date,
        end=end_date,
        group_by="ticker",
        auto_adjust=False
    )

    # 3. Transform into long format
    logger.info("Transforming QQQ price data into long format")

    # Reset index so the date becomes a column
    df = raw.reset_index().copy()

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

    long_df.columns.name = None

    # 4. Save to DuckDB
    logger.info("Saving transformed QQQ price data to DuckDB")

    con.execute(f"CREATE OR REPLACE TABLE {table_name} AS SELECT * FROM long_df")

    con.close()
    logger.info("Nasdaq (QQQ) price ingestion completed successfully")