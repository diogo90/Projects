/* =============================================================================
   OPS.SP_INGEST_LANDING  - root step of the task graph
   -----------------------------------------------------------------------------
   1. Asks both Snowpipes to queue any staged file that is not loaded yet
      (ALTER PIPE ... REFRESH: load history makes this idempotent).
   2. Waits until the pipes report zero pending files. Snowpipe is
      asynchronous, and downstream tasks must not start before the raw tables
      hold the new rows.

   Why REFRESH and not the REST API? Files are uploaded by hand to an
   INTERNAL stage, which emits no event notifications. For an on-demand batch,
   one REFRESH per run is the simplest trigger that needs no extra
   credentials. With an S3 external stage this procedure would be unnecessary:
   AUTO_INGEST = TRUE + SQS events load files the moment they land.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_INGEST_LANDING(MAX_WAIT_SECONDS NUMBER DEFAULT 600)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Triggers the landing Snowpipes and waits for them to drain'
AS
$$
DECLARE
    started_at     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    prices_queued  NUMBER DEFAULT 0;
    sec_queued     NUMBER DEFAULT 0;
    pending        NUMBER DEFAULT 0;
    waited         NUMBER DEFAULT 0;
    result         VARIANT;
    ingest_timeout EXCEPTION (-20001, 'Snowpipe did not drain within MAX_WAIT_SECONDS');
BEGIN
    ALTER PIPE VALUATION_DB.LANDING.PIPE_MARKET_PRICES REFRESH;
    SELECT COUNT_IF("Status" = 'SENT') INTO :prices_queued FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    ALTER PIPE VALUATION_DB.LANDING.PIPE_SEC_COMPANYFACTS REFRESH;
    SELECT COUNT_IF("Status" = 'SENT') INTO :sec_queued FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    pending := prices_queued + sec_queued;

    -- Poll pipe status until every queued file has been loaded (or timeout)
    WHILE (pending > 0 AND waited < MAX_WAIT_SECONDS) DO
        SELECT SYSTEM$WAIT(10);
        waited := waited + 10;
        SELECT PARSE_JSON(SYSTEM$PIPE_STATUS('VALUATION_DB.LANDING.PIPE_MARKET_PRICES')):pendingFileCount::NUMBER
             + PARSE_JSON(SYSTEM$PIPE_STATUS('VALUATION_DB.LANDING.PIPE_SEC_COMPANYFACTS')):pendingFileCount::NUMBER
          INTO :pending;
    END WHILE;

    result := OBJECT_CONSTRUCT('price_files_queued', prices_queued,
                               'sec_files_queued',   sec_queued,
                               'pending_after_wait', pending,
                               'waited_seconds',     waited);

    IF (pending > 0) THEN
        INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
            SELECT 'SP_INGEST_LANDING', 'FAILED', :result, :started_at;
        RAISE ingest_timeout;    -- fail the task so the graph stops
    END IF;

    INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
        SELECT 'SP_INGEST_LANDING', 'SUCCEEDED', :result, :started_at;
    RETURN result;
END;
$$;
