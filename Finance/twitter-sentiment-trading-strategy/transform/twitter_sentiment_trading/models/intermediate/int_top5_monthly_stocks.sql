-- INTERMEDIATE MODEL
-- Selects the top 5 symbols per month based on engagement_ratio,
-- then shifts the month forward by 1 month to represent the
-- investment month.

with ranked as (

    select
        month,
        symbol,
        engagement_ratio,
        rank
    from {{ ref('int_avg_monthly_sentiment') }}
    where rank <= 5

),

shifted as (

    select
        -- Shift the month forward by 1 month
        month + interval 1 month as investment_month,
        symbol,
        engagement_ratio,
        rank
    from ranked

)

select *
from shifted
order by investment_month, rank