/* =============================================================================
   ORCHESTRATION 03 - Run the pipeline on demand and watch it
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   Typical sequence
     RUN 1 (initial load): upload backfill + reference + SEC files -> EXECUTE TASK
     RUN 2 (incremental):  upload one or more daily delta files      -> EXECUTE TASK
                           -> only new rows flow through the streams.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

-- 0. What is waiting in the stages? (directory tables)
ALTER STAGE VALUATION_DB.LANDING.STG_MARKET_DATA REFRESH;
ALTER STAGE VALUATION_DB.LANDING.STG_SEC_EDGAR REFRESH;
SELECT relative_path, size, last_modified FROM DIRECTORY(@VALUATION_DB.LANDING.STG_MARKET_DATA) ORDER BY 1;
SELECT relative_path, size, last_modified FROM DIRECTORY(@VALUATION_DB.LANDING.STG_SEC_EDGAR)   ORDER BY 1;

-- 1. Run the whole graph (the "run button")
EXECUTE TASK VALUATION_DB.OPS.TSK_00_INGEST_LANDING;

-- 2. Watch progress (refresh every ~30s; the full first run takes a few minutes)
SELECT name, state, scheduled_time, completed_time,
       DATEDIFF('second', query_start_time, completed_time) AS duration_s,
       return_value, error_message
FROM TABLE(VALUATION_DB.INFORMATION_SCHEMA.TASK_HISTORY(
        SCHEDULED_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
        RESULT_LIMIT => 50))
ORDER BY scheduled_time DESC, name;

-- Whole-graph view (one row per graph run)
SELECT root_task_name, state, first_error_task_name, first_error_message,
       scheduled_time, completed_time
FROM TABLE(VALUATION_DB.INFORMATION_SCHEMA.COMPLETE_TASK_GRAPHS(RESULT_LIMIT => 10))
ORDER BY scheduled_time DESC;

-- 3. Procedure-level log and data-quality outcome
SELECT * FROM VALUATION_DB.OPS.V_PIPELINE_RUN_DURATIONS LIMIT 20;
SELECT * FROM VALUATION_DB.OPS.DQ_CHECK_RESULTS
WHERE dq_run_id = (SELECT dq_run_id FROM VALUATION_DB.OPS.DQ_CHECK_RESULTS ORDER BY checked_at DESC LIMIT 1)
ORDER BY severity, check_name;

-- 4. Sanity queries on the result
USE WAREHOUSE WH_ANALYTICS;
SELECT ticker, trade_date, close_price, eps_diluted_ttm, ROUND(pe_ratio, 1) AS pe,
       ROUND(debt_to_equity, 2) AS d_e, is_fundamentals_stale
FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION
WHERE trade_date = (SELECT MAX(trade_date) FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION)
ORDER BY pe NULLS LAST;

/* -----------------------------------------------------------------------------
   Manual alternative (debugging): call the procedures one by one
   -----------------------------------------------------------------------------
   USE WAREHOUSE WH_TRANSFORM;
   CALL VALUATION_DB.OPS.SP_INGEST_LANDING(600);
   CALL VALUATION_DB.OPS.SP_LOAD_REFERENCE_DATA();
   CALL VALUATION_DB.OPS.SP_CURATE_MARKET_PRICES();
   CALL VALUATION_DB.OPS.SP_CURATE_SEC_FUNDAMENTALS(FALSE);
   CALL VALUATION_DB.OPS.SP_BUILD_CONSUMPTION();
   EXECUTE DBT PROJECT VALUATION_DB.OPS.FUNDAMENTAL_VALUATION_DBT ARGS = 'build --target prod';
   CALL VALUATION_DB.OPS.SP_RUN_DQ_CHECKS();
----------------------------------------------------------------------------- */
