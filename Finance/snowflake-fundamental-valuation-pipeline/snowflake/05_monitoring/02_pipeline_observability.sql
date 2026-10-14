/* =============================================================================
   MONITORING 02 - Pipeline observability (loads, streams, tasks, DQ)
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE WAREHOUSE WH_ANALYTICS;
USE DATABASE VALUATION_DB;

-- Snowpipe health: executionState, pendingFileCount, lastIngestedTimestamp
SELECT PARSE_JSON(SYSTEM$PIPE_STATUS('VALUATION_DB.LANDING.PIPE_MARKET_PRICES'))    AS prices_pipe,
       PARSE_JSON(SYSTEM$PIPE_STATUS('VALUATION_DB.LANDING.PIPE_SEC_COMPANYFACTS')) AS sec_pipe;

-- File-level load history (which file, how many rows, errors)
SELECT file_name, table_name, status, row_count, row_parsed, first_error_message, last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'VALUATION_DB.LANDING.RAW_MARKET_PRICES',
        START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())))
UNION ALL
SELECT file_name, table_name, status, row_count, row_parsed, first_error_message, last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'VALUATION_DB.LANDING.RAW_SEC_COMPANYFACTS',
        START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())))
ORDER BY last_load_time DESC;

-- Streams: pending changes and staleness risk
SHOW STREAMS IN SCHEMA VALUATION_DB.LANDING;
SELECT "name", "stale", "stale_after", "mode"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
SELECT SYSTEM$STREAM_HAS_DATA('VALUATION_DB.LANDING.STRM_RAW_MARKET_PRICES')    AS prices_pending,
       SYSTEM$STREAM_HAS_DATA('VALUATION_DB.LANDING.STRM_RAW_SEC_COMPANYFACTS') AS sec_pending;

-- Task runs (last 7 days) and failure rate per task
SELECT name,
       COUNT(*)                                   AS runs,
       COUNT_IF(state = 'SUCCEEDED')              AS succeeded,
       COUNT_IF(state = 'FAILED')                 AS failed,
       ROUND(AVG(DATEDIFF('second', query_start_time, completed_time)), 1) AS avg_duration_s
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
        SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP())))
GROUP BY name
ORDER BY name;

-- Lineage audit: which file produced a given curated price?
SELECT ticker, trade_date, close_price, _source_file, _first_loaded_at, _updated_at
FROM CURATED.MARKET_PRICES_DAILY
WHERE ticker = 'NVDA'
ORDER BY trade_date DESC
LIMIT 5;

-- Data-quality trend
SELECT DATE_TRUNC('day', checked_at) AS day, severity,
       COUNT_IF(status = 'FAIL') AS failed_checks, COUNT(*) AS checks
FROM OPS.DQ_CHECK_RESULTS
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
