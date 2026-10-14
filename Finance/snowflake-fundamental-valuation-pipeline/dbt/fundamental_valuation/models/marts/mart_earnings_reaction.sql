{{ config(materialized='table') }}

/*
  Earnings-reaction event study: one row per company per fiscal quarter.
  How did the stock move in the 1 and 5 trading days after its 10-Q/10-K was
  filed, in absolute terms and in excess of the equal-weighted universe?
  Pairs the market reaction with the fundamental change (YoY EPS/revenue growth).
*/
with prices as (
    select
        company_key,
        trade_date,
        adj_close_price,
        row_number() over (partition by company_key order by trade_date) as day_index
    from {{ source('consumption', 'fct_daily_prices') }}
),

-- equal-weighted universe index level (cumulative product of mean daily returns)
universe_index as (
    select
        trade_date,
        exp(sum(ln(1 + avg_return)) over (order by trade_date)) as index_level
    from (
        select trade_date, avg(coalesce(daily_return, 0)) as avg_return
        from {{ source('consumption', 'fct_daily_prices') }}
        group by trade_date
    )
),

events as (
    select company_key, ticker, fiscal_quarter_end, known_date,
           eps_diluted_q, eps_growth_yoy, revenue_growth_yoy
    from {{ source('consumption', 'fct_fundamentals_quarterly') }}
    where known_date >= (select min(trade_date) from prices)
),

-- t0 = last close at or before the filing date (filings often land after the close)
anchored as (
    select e.*, p.trade_date as t0_date, p.day_index as t0_index, p.adj_close_price as t0_price
    from events e
    asof join prices p
        match_condition (e.known_date >= p.trade_date)
        on e.company_key = p.company_key
)

select
    a.ticker,
    a.fiscal_quarter_end,
    a.known_date                                    as filing_date,
    a.t0_date,
    a.eps_diluted_q,
    a.eps_growth_yoy,
    a.revenue_growth_yoy,
    p1.adj_close_price / a.t0_price - 1             as return_1d,
    p5.adj_close_price / a.t0_price - 1             as return_5d,
    (p1.adj_close_price / a.t0_price - 1) - (u1.index_level / u0.index_level - 1) as excess_return_1d,
    (p5.adj_close_price / a.t0_price - 1) - (u5.index_level / u0.index_level - 1) as excess_return_5d
from anchored a
left join prices p1 on p1.company_key = a.company_key and p1.day_index = a.t0_index + 1
left join prices p5 on p5.company_key = a.company_key and p5.day_index = a.t0_index + 5
left join universe_index u0 on u0.trade_date = a.t0_date
left join universe_index u1 on u1.trade_date = p1.trade_date
left join universe_index u5 on u5.trade_date = p5.trade_date
