-- INTERMEDIATE MODEL
-- Produces one row per investment month and per selected stock.

with top5 as (

    -- Use the model that already filters to top 5 and shifts month forward
    select
        investment_month,
        symbol,
        engagement_ratio,
        rank
    from {{ ref('int_top5_monthly_stocks') }}

),

final as (

    -- Select only the fields needed for downstream modeling
    select
        investment_month,
        symbol
    from top5
    order by investment_month, symbol

)

select * from final