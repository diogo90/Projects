-- STAGING MODEL: stg_daily_stock_prices
--
-- Purpose:
-- This staging model standardizes the raw daily OHLCV stock price data
-- downloaded from Yahoo Finance and stored in DuckDB.
--
-- Notes:
-- - The source table `prices_daily` is created by the ingestion pipeline.
-- - Yahoo Finance returns capitalized column names (Open, High, Low, Close, Volume).
-- - This model simply exposes the raw structure in a clean, dbt‑friendly format.
-- - No transformations are applied here; transformations belong in intermediate models.

with source as (

    select
        date,
        symbol,
        "Open",
        "High",
        "Low",
        "Close",
        "Volume"
    from {{ source('yahoo_daily_stock_prices', 'prices_daily') }}

)
select * from source