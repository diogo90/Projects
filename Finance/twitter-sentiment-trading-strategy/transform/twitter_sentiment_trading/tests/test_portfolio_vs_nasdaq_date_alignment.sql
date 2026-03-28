-- Test: portfolio_return and nasdaq_return should both exist for all dates
-- Joins portfolio and Nasdaq returns
-- If a date is missing from one side, you’d get NULLs — which is a red flag

select *
from {{ ref('portfolio_vs_nasdaq') }}
where portfolio_return is null
   or nasdaq_return is null