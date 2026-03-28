-- INTERMEDIATE MODEL: int_nasdaq_returns
--
-- Purpose:
-- Computes the daily log returns for the Nasdaq benchmark ETF (QQQ).
--
-- Steps:
-- 1. Select the Close price from the staging model.
-- 2. Compute daily log returns using ln(close) - ln(close_lag).
-- 3. Output a clean table with date and nasdaq_return.

with prices as (

    select
        date,
        symbol,
        "Close" as close_price
    from {{ ref('stg_nasdaq_prices') }}

),

returns as (

    select
        date,
        symbol,
        ln(close_price)
            - lag(ln(close_price)) over (partition by symbol order by date)
            as nasdaq_return
    from prices

)

select
    date,
    nasdaq_return
from returns
order by date