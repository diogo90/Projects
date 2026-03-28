-- Test: nasdaq_return should not be null except on the first date
-- Log return calculation will produce a NULL on the first day — that’s expected
-- But after that, NULLs would indicate missing data or a join problem

with data as (
    select
        date,
        nasdaq_return,
        row_number() over (order by date) as rn
    from {{ ref('int_nasdaq_returns') }}
)

select *
from data
where nasdaq_return is null
  and rn > 1