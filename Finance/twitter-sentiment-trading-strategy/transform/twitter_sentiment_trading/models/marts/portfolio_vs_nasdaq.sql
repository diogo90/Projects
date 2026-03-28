-- MART MODEL: mart_portfolio_vs_nasdaq
--
-- Purpose:
-- Combines the equal‑weighted portfolio returns with the Nasdaq (QQQ)
-- benchmark returns into a single table for performance comparison.
--
-- Steps:
-- 1. Select daily portfolio returns from int_equal_weighted_portfolio_returns.
-- 2. Select daily Nasdaq returns from int_nasdaq_returns.
-- 3. Join on date.
-- 4. Output a clean comparison table.

with portfolio as (

    select
        date,
        portfolio_return
    from {{ ref('int_equal_weighted_portfolio_returns') }}

),

nasdaq as (

    select
        date,
        nasdaq_return
    from {{ ref('int_nasdaq_returns') }}

),

combined as (

    select
        p.date,
        p.portfolio_return,
        n.nasdaq_return
    from portfolio p
    left join nasdaq n
        on p.date = n.date
)

select *
from combined
order by date