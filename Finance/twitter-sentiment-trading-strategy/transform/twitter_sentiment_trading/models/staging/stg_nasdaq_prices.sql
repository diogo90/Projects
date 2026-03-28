-- STAGING MODEL: stg_nasdaq_prices
--
-- Purpose:
-- Standardizes the raw Nasdaq (QQQ) price data into a clean staging layer.
-- This model simply selects all columns from the source table.

with source as (

    select
        date,
        symbol,
        "Open",
        "High",
        "Low",
        "Close",
        "Adj Close",
        "Volume"
    from {{ source('nasdaq_prices', 'nasdaq_prices_daily') }}

)
select * from source order by date