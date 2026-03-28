-- INTERMEDIATE MODEL: int_equal_weighted_portfolio_returns
--
-- Purpose:
-- This model computes the daily equal‑weighted portfolio return
-- based on the top 5 stocks selected each month (from int_top5_monthly_stocks).
--
-- Steps:
-- 1. Compute daily log returns for each stock.
-- 2. Join returns with the monthly top‑5 stock selections.
-- 3. For each month, filter to the selected stocks.
-- 4. Compute the equal‑weighted average return for each day.
-- - For each month: take the selected stocks and average their returns.

with prices as (

    select
        date,
        symbol,
        "Close" as close_price
    from {{ ref('stg_daily_stock_prices') }}

),

-- 1. Compute daily log returns
returns as (

    select
        date,
        symbol,
        ln(close_price) 
            - lag(ln(close_price)) over (partition by symbol order by date) 
            as log_return
    from prices

),

-- 2. Bring in the monthly top 5 stocks
top5 as (

    select
        investment_month,
        symbol
    from {{ ref('int_stocks_to_invest_by_month') }}

),

-- 3. Join returns with the monthly selection window
returns_with_selection as (

    select
        r.date,
        r.symbol,
        r.log_return,
        t.investment_month,
        date_trunc('month', r.date) as return_month
    from returns r
    left join top5 t
        on r.symbol = t.symbol
        and date_trunc('month', r.date) = t.investment_month

),

-- 4. Compute equal‑weighted portfolio return for each day
portfolio as (

    select
        date,
        avg(log_return) as portfolio_return
    from returns_with_selection
    where investment_month is not null   -- only keep selected stocks
    group by date
)

select * from portfolio order by date