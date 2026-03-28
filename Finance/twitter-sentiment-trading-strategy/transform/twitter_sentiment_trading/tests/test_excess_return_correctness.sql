-- Test: excess_return = portfolio_return - nasdaq_return
-- Excess return should equal portfolio_return - nasdaq_return

select *
from {{ ref('strategy_performance') }}
where abs(excess_return - (portfolio_return - nasdaq_return)) > 1e-12