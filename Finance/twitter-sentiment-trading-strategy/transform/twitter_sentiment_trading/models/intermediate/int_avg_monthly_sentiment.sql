-- INTERMEDIATE MODEL
-- Computes monthly average engagement_ratio and ranks symbols per month.

with monthly_agg as (
    
    select
        date_trunc('month', date) as month,
        symbol,
        avg(engagement_ratio) as engagement_ratio
    
    from {{ ref('int_twitter_sentiment') }}
    
    group by 1, 2

)

select
    month,
    symbol,
    engagement_ratio,
    rank() over (
        partition by month
        order by engagement_ratio desc
    ) as rank

from monthly_agg

order by month, rank