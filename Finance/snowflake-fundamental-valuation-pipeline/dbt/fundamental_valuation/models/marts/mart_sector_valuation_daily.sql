{{ config(materialized='table') }}

/*
  Sector-level valuation time series: one row per sector per trading day.
  Median rather than mean, because P/E is heavy-tailed (one name with
  near-zero earnings would dominate an average).
*/
select
    v.trade_date,
    d.year_quarter,
    c.sector_theme,
    count(*)                                         as companies,
    count(v.pe_ratio)                                as companies_with_pe,
    count_if(v.is_loss_making)                       as loss_making_companies,
    median(v.pe_ratio)                               as median_pe,
    avg(v.earnings_yield)                            as avg_earnings_yield,
    median(v.debt_to_equity)                         as median_debt_to_equity,
    median(v.net_margin_ttm)                         as median_net_margin_ttm,
    median(v.revenue_growth_yoy)                     as median_revenue_growth_yoy
from {{ source('consumption', 'fct_daily_valuation') }} v
join {{ source('consumption', 'dim_company') }} c on c.company_key = v.company_key
join {{ source('consumption', 'dim_date') }}    d on d.date_key   = v.date_key
where v.eps_diluted_ttm is not null
group by v.trade_date, d.year_quarter, c.sector_theme
