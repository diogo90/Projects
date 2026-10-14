-- Singular test: a valuation row may only use fundamentals filed BEFORE the trade date.
-- Any row returned = look-ahead bias = test failure.
select ticker, trade_date, fundamentals_known_date
from {{ source('consumption', 'fct_daily_valuation') }}
where fundamentals_known_date >= trade_date
