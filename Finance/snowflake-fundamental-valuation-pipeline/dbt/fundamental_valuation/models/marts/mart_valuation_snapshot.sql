{{ config(materialized='table') }}

/*
  Relative-value screen as of the latest trading day: one row per company.
  Answers "which names look cheap or rich vs their own 3-year history and vs
  their sector?", the starting point of an equity research / PM workflow.
*/
with as_of as (
    select max(trade_date) as as_of_date
    from {{ source('consumption', 'fct_daily_valuation') }}
),

valuation as (
    select v.*, c.company_name, c.sector_theme
    from {{ source('consumption', 'fct_daily_valuation') }} v
    join {{ source('consumption', 'dim_company') }} c
      on c.company_key = v.company_key
),

-- each company's P/E distribution over the trailing 3 years
pe_history as (
    select
        company_key,
        trade_date,
        percent_rank() over (partition by company_key order by pe_ratio) as pe_percentile_3y,
        median(pe_ratio) over (partition by company_key)                 as pe_median_3y,
        min(pe_ratio)    over (partition by company_key)                 as pe_min_3y,
        max(pe_ratio)    over (partition by company_key)                 as pe_max_3y
    from valuation
    where pe_ratio is not null
      and trade_date >= dateadd(year, -3, (select as_of_date from as_of))
),

returns as (
    select
        company_key,
        trade_date,
        adj_close_price / nullif(lag(adj_close_price, 21)  over (partition by company_key order by trade_date), 0) - 1 as return_1m,
        adj_close_price / nullif(lag(adj_close_price, 252) over (partition by company_key order by trade_date), 0) - 1 as return_1y,
        volatility_30d_ann,
        close_price / nullif(sma_200d, 0) - 1 as distance_from_sma_200d
    from {{ source('consumption', 'fct_daily_prices') }}
),

latest as (
    select v.*
    from valuation v
    where v.trade_date = (select as_of_date from as_of)
),

sector_stats as (
    select sector_theme, median(pe_ratio) as sector_median_pe
    from latest
    group by sector_theme
)

select
    l.trade_date                                    as as_of_date,
    l.ticker,
    l.company_name,
    l.sector_theme,
    l.close_price,
    l.eps_diluted_ttm,
    l.pe_ratio,
    l.earnings_yield,
    s.sector_median_pe,
    l.pe_ratio / nullif(s.sector_median_pe, 0) - 1  as pe_premium_to_sector,
    h.pe_median_3y,
    h.pe_min_3y,
    h.pe_max_3y,
    h.pe_percentile_3y,
    l.debt_to_equity,
    l.net_margin_ttm,
    l.revenue_growth_yoy,
    r.return_1m,
    r.return_1y,
    r.volatility_30d_ann,
    r.distance_from_sma_200d,
    l.fiscal_quarter_end                            as fundamentals_as_of_quarter,
    l.is_fundamentals_stale,
    case
        when l.pe_ratio is null                 then 'NOT_MEANINGFUL'
        when h.pe_percentile_3y <= 0.20         then 'CHEAP_VS_OWN_HISTORY'
        when h.pe_percentile_3y >= 0.80         then 'RICH_VS_OWN_HISTORY'
        else 'WITHIN_NORMAL_RANGE'
    end                                             as valuation_signal
from latest l
left join sector_stats s on s.sector_theme = l.sector_theme
left join pe_history h   on h.company_key = l.company_key and h.trade_date = l.trade_date
left join returns r      on r.company_key = l.company_key and r.trade_date = l.trade_date
