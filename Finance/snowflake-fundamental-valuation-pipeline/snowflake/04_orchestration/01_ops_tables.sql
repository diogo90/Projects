/* =============================================================================
   ORCHESTRATION 01 - Operational tables (observability)
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE
   Every stored procedure writes one row per execution to PIPELINE_RUN_LOG;
   the finalizer task writes data-quality outcomes to DQ_CHECK_RESULTS.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE TABLE IF NOT EXISTS PIPELINE_RUN_LOG (
    log_id          NUMBER(38,0) IDENTITY(1,1),
    step_name       VARCHAR       NOT NULL,
    status          VARCHAR       NOT NULL,     -- SUCCEEDED | SKIPPED | FAILED
    details         VARIANT,                    -- row counts, files, error message
    started_at      TIMESTAMP_LTZ NOT NULL,
    finished_at     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'One row per stored-procedure execution';

CREATE TABLE IF NOT EXISTS DQ_CHECK_RESULTS (
    dq_run_id       VARCHAR       NOT NULL,
    check_name      VARCHAR       NOT NULL,
    severity        VARCHAR       NOT NULL,     -- ERROR | WARN | INFO
    object_name     VARCHAR       NOT NULL,
    failing_rows    NUMBER(38,0)  NOT NULL,
    status          VARCHAR       NOT NULL,     -- PASS | FAIL
    sample          VARIANT,                    -- a few offending keys for triage
    checked_at      TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Data-quality check outcomes written by the finalizer task';

CREATE OR REPLACE VIEW V_PIPELINE_RUN_DURATIONS AS
SELECT step_name, status, started_at, finished_at,
       DATEDIFF('second', started_at, finished_at) AS duration_s,
       details
FROM PIPELINE_RUN_LOG
ORDER BY log_id DESC;
