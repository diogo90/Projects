/* =============================================================================
   OPS.SP_RUN_DQ_CHECKS  - data-quality gate (runs in the FINALIZER task)
   -----------------------------------------------------------------------------
   A finalizer task runs after every task graph execution, even when an earlier
   task failed, so DQ results and the run summary are always recorded.

   Checks are declarative rows (check name, severity, failing-row count, sample)
   assembled with UNION ALL. Adding a check = adding one SELECT.
   (Snowflake Data Metric Functions are the managed alternative on Enterprise
   edition; this procedure keeps the project portable to Standard edition.)
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_RUN_DQ_CHECKS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Runs data-quality checks over CURATED and CONSUMPTION and records the outcome'
AS
$$
DECLARE
    started_at  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    dq_run_id   VARCHAR DEFAULT UUID_STRING();
    n_errors    NUMBER;
    n_warnings  NUMBER;
    result      VARIANT;
BEGIN
    INSERT INTO VALUATION_DB.OPS.DQ_CHECK_RESULTS
        (dq_run_id, check_name, severity, object_name, failing_rows, status, sample)
    WITH checks AS (
        -- 1. Grain: exactly one row per ticker x trading day
        SELECT 'prices_unique_ticker_date' AS check_name, 'ERROR' AS severity,
               'CURATED.MARKET_PRICES_DAILY' AS object_name,
               COUNT(*) AS failing_rows, ARRAY_SLICE(ARRAY_AGG(ticker || ' ' || trade_date), 0, 5) AS sample
        FROM (SELECT ticker, trade_date FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY
              GROUP BY 1, 2 HAVING COUNT(*) > 1)
        UNION ALL
        -- 2. Every ticker in the universe has prices
        SELECT 'universe_has_prices', 'ERROR', 'CURATED.MARKET_PRICES_DAILY',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(s.ticker), 0, 5)
        FROM VALUATION_DB.CURATED.SECURITY_MASTER s
        WHERE NOT EXISTS (SELECT 1 FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY p WHERE p.ticker = s.ticker)
        UNION ALL
        -- 3. Market data freshness: latest trading day not older than 5 days
        SELECT 'prices_freshness_5d', 'WARN', 'CURATED.MARKET_PRICES_DAILY',
               IFF(DATEDIFF('day', MAX(trade_date), CURRENT_DATE()) > 5, 1, 0),
               ARRAY_CONSTRUCT(MAX(trade_date))
        FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY
        UNION ALL
        -- 4. Gaps: tickers missing a day on which the rest of the market traded
        SELECT 'prices_missing_trading_days', 'WARN', 'CONSUMPTION.FCT_DAILY_PRICES',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(c.ticker || ' ' || d.calendar_date), 0, 5)
        FROM VALUATION_DB.CONSUMPTION.DIM_DATE d
        CROSS JOIN VALUATION_DB.CONSUMPTION.DIM_COMPANY c
        WHERE d.is_trading_day
          AND d.calendar_date BETWEEN (SELECT MIN(trade_date) FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY)
                                  AND (SELECT MAX(trade_date) FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY)
          AND NOT EXISTS (SELECT 1 FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_PRICES f
                          WHERE f.company_key = c.company_key AND f.date_key = d.date_key)
        UNION ALL
        -- 5. Rows quarantined in the last 24 hours
        SELECT 'prices_quarantined_24h', 'WARN', 'CURATED.MARKET_PRICES_QUARANTINE',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(reject_reason), 0, 5)
        FROM VALUATION_DB.CURATED.MARKET_PRICES_QUARANTINE
        WHERE _quarantined_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
        UNION ALL
        -- 6. Universe CIKs agree with the SEC's current ticker map
        SELECT 'cik_matches_sec_ticker_map', 'WARN', 'CURATED.SECURITY_MASTER',
               COUNT_IF(NOT is_cik_validated), ARRAY_SLICE(ARRAY_AGG(IFF(NOT is_cik_validated, ticker, NULL)), 0, 5)
        FROM VALUATION_DB.CURATED.SECURITY_MASTER
        UNION ALL
        -- 7. Companies without a trailing-twelve-month EPS (e.g. multi-class EPS filers)
        SELECT 'company_has_ttm_eps', 'WARN', 'CONSUMPTION.FCT_FUNDAMENTALS_QUARTERLY',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(c.ticker), 0, 5)
        FROM VALUATION_DB.CONSUMPTION.DIM_COMPANY c
        WHERE NOT EXISTS (SELECT 1 FROM VALUATION_DB.CONSUMPTION.FCT_FUNDAMENTALS_QUARTERLY f
                          WHERE f.company_key = c.company_key AND f.has_full_ttm)
        UNION ALL
        -- 8. Stale fundamentals on the latest trading day (> 135 days since last filing)
        SELECT 'fundamentals_not_stale', 'WARN', 'CONSUMPTION.FCT_DAILY_VALUATION',
               COUNT_IF(is_fundamentals_stale), ARRAY_SLICE(ARRAY_AGG(IFF(is_fundamentals_stale, ticker, NULL)), 0, 5)
        FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION
        WHERE trade_date = (SELECT MAX(trade_date) FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION)
        UNION ALL
        -- 9. Look-ahead guard: fundamentals must never be "known" on/after the trade date
        SELECT 'no_look_ahead_bias', 'ERROR', 'CONSUMPTION.FCT_DAILY_VALUATION',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(ticker || ' ' || trade_date), 0, 5)
        FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION
        WHERE fundamentals_known_date >= trade_date
        UNION ALL
        -- 10. Extreme P/E (informational: usually depressed earnings, not bad data)
        SELECT 'pe_ratio_above_300', 'INFO', 'CONSUMPTION.FCT_DAILY_VALUATION',
               COUNT(*), ARRAY_SLICE(ARRAY_AGG(DISTINCT ticker), 0, 5)
        FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION
        WHERE pe_ratio > 300
    )
    SELECT :dq_run_id, check_name, severity, object_name, failing_rows,
           IFF(failing_rows = 0, 'PASS', 'FAIL'), sample
    FROM checks;

    SELECT COUNT_IF(status = 'FAIL' AND severity = 'ERROR'),
           COUNT_IF(status = 'FAIL' AND severity = 'WARN')
      INTO :n_errors, :n_warnings
      FROM VALUATION_DB.OPS.DQ_CHECK_RESULTS
     WHERE dq_run_id = :dq_run_id;

    result := OBJECT_CONSTRUCT('dq_run_id', dq_run_id, 'errors', n_errors, 'warnings', n_warnings);
    INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
        SELECT 'SP_RUN_DQ_CHECKS', IFF(:n_errors = 0, 'SUCCEEDED', 'FAILED'), :result, :started_at;
    RETURN result;
END;
$$;
