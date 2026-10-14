/* =============================================================================
   ORCHESTRATION 02 - Task graph (DAG), executed ON DEMAND
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE (needs EXECUTE TASK, granted in 00_setup/01)

                       TSK_00_INGEST_LANDING           (root, NO schedule)
                                 |
                       TSK_10_LOAD_REFERENCE
                          /              \
          TSK_20_CURATE_PRICES      TSK_30_CURATE_SEC   (run in parallel)
                          \              /
                       TSK_40_BUILD_CONSUMPTION
                                 |
                       TSK_50_DBT_BUILD                 (dbt Projects on Snowflake)

                       TSK_99_FINALIZER  -> DQ checks, always runs last

   ON DEMAND, NOT SCHEDULED: the root task has no SCHEDULE, so it never runs on
   its own and never wakes a warehouse. It only runs on EXECUTE TASK. To make
   it a daily batch, add SCHEDULE = 'USING CRON 0 22 * * MON-FRI Europe/London'.

   Each step is a stored procedure, so the business logic is versioned in
   one place, can be called by hand for debugging, and the task only orchestrates.

   Warehouse vs serverless tasks: user-managed warehouses are used here
   because the per-second warehouse cost for a ~2 minute run is tiny and
   predictable, and resource monitors can cap it. Serverless tasks
   (omit WAREHOUSE) suit frequent, short, variable workloads.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

-- Suspend the graph before (re)creating tasks
ALTER TASK IF EXISTS TSK_00_INGEST_LANDING SUSPEND;

CREATE OR REPLACE TASK TSK_00_INGEST_LANDING
  WAREHOUSE = WH_INGEST
  USER_TASK_TIMEOUT_MS = 900000            -- 15 min hard stop
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Root: trigger Snowpipes and wait for the landing zone to be loaded'
AS
  CALL VALUATION_DB.OPS.SP_INGEST_LANDING(600);

CREATE OR REPLACE TASK TSK_10_LOAD_REFERENCE
  WAREHOUSE = WH_INGEST
  COMMENT = 'Full refresh of universe, split history and SEC ticker map'
  AFTER TSK_00_INGEST_LANDING
AS
  CALL VALUATION_DB.OPS.SP_LOAD_REFERENCE_DATA();

CREATE OR REPLACE TASK TSK_20_CURATE_PRICES
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Stream -> MERGE into CURATED.MARKET_PRICES_DAILY'
  AFTER TSK_10_LOAD_REFERENCE
AS
  CALL VALUATION_DB.OPS.SP_CURATE_MARKET_PRICES();

CREATE OR REPLACE TASK TSK_30_CURATE_SEC
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Snowpark: flatten SEC JSON -> facts -> standardised metrics'
  AFTER TSK_10_LOAD_REFERENCE
AS
  CALL VALUATION_DB.OPS.SP_CURATE_SEC_FUNDAMENTALS(FALSE);

CREATE OR REPLACE TASK TSK_40_BUILD_CONSUMPTION
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Rebuild star schema (dims + facts) in one transaction'
  AFTER TSK_20_CURATE_PRICES, TSK_30_CURATE_SEC
AS
  CALL VALUATION_DB.OPS.SP_BUILD_CONSUMPTION();

-- Requires the dbt project object from 07_dbt/deploy_dbt_project.sql.
-- If you skip dbt, drop this task: the graph is complete without it.
CREATE OR REPLACE TASK TSK_50_DBT_BUILD
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'dbt build (run + test) of ANALYTICS marts on top of CONSUMPTION'
  AFTER TSK_40_BUILD_CONSUMPTION
AS
  EXECUTE DBT PROJECT VALUATION_DB.OPS.FUNDAMENTAL_VALUATION_DBT ARGS = 'build --target prod';

-- Finalizer: runs once all other tasks finish, whether they succeeded or failed
CREATE OR REPLACE TASK TSK_99_FINALIZER
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Data-quality checks + run summary; always runs'
  FINALIZE = TSK_00_INGEST_LANDING
AS
  CALL VALUATION_DB.OPS.SP_RUN_DQ_CHECKS();

-- Resume every child task (+ root). Because the root has no SCHEDULE,
-- "resumed" only means "allowed to run when the graph is executed".
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('VALUATION_DB.OPS.TSK_00_INGEST_LANDING');

SHOW TASKS IN SCHEMA VALUATION_DB.OPS;
