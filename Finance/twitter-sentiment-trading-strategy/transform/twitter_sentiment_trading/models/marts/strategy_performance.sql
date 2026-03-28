-- MART MODEL: mart_strategy_performance
--
-- Purpose:
-- Produces a full performance comparison between the strategy’s
-- equal‑weighted portfolio and the Nasdaq benchmark (QQQ).
--
-- This mart includes:
--   - Daily portfolio returns
--   - Daily Nasdaq returns
--   - Cumulative returns for both series
--   - Daily excess returns (portfolio - benchmark)
--   - Cumulative excess returns
--
-- This is the table you will use for charts, performance evaluation,
-- and any downstream analytics.

with returns as (

    select
        p.date,
        p.portfolio_return,
        n.nasdaq_return
    from {{ ref('portfolio_vs_nasdaq') }} p
    left join {{ ref('int_nasdaq_returns') }} n
        on p.date = n.date

),

-- Compute cumulative returns using the standard formula:
-- cumulative_return_t = exp(sum(log_return up to t)) - 1
cumulative as (

    select
        date,
        portfolio_return,
        nasdaq_return,

        -- Strategy cumulative return
        exp(sum(portfolio_return) over (order by date)) - 1
            as portfolio_cumulative_return,

        -- Nasdaq cumulative return
        exp(sum(nasdaq_return) over (order by date)) - 1
            as nasdaq_cumulative_return,

        -- Daily excess return
        portfolio_return - nasdaq_return
            as excess_return,

        -- Cumulative excess return
        exp(sum(portfolio_return - nasdaq_return) over (order by date)) - 1
            as cumulative_excess_return

    from returns
)

select *
from cumulative
order by date