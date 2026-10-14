/* =============================================================================
   02 - Virtual warehouses (compute)
   -----------------------------------------------------------------------------
   Run as: ACCOUNTADMIN (then ownership is handed to VALUATION_PIPELINE)

   SIZING RATIONALE (data volume of this project)
     - Raw input: ~8 MB of price CSV + ~230 MB of SEC JSON (uncompressed),
       ~63k price rows, ~2M flattened XBRL facts after parsing.
     - An X-SMALL warehouse (1 credit/hour on Gen1, billed per second with a
       60-second minimum on each resume) processes this in seconds to a couple
       of minutes. A bigger size would finish faster, but it would not cost less
       for this little data. Credits double with each size step (XS=1, S=2, M=4,
       L=8 ...), so you only size up when a query spills to disk or misses an SLA.

   WORKLOAD ISOLATION (the main bottleneck-avoidance lever)
     One warehouse per workload type, so a heavy transform never queues behind
     (or slows down) ingestion or BI queries, and cost is attributable per workload:
       WH_INGEST     - COPY INTO of reference files (Snowpipe itself is serverless)
       WH_TRANSFORM  - stored procedures, tasks, dbt
       WH_ANALYTICS  - ad-hoc / BI queries; multi-cluster for concurrency

   SCALE UP vs SCALE OUT
     - Scale UP (bigger size): one complex query is slow or spills to
       local/remote storage -> more memory/CPU per query.
     - Scale OUT (multi-cluster, Enterprise edition): many concurrent queries
       are QUEUED -> Snowflake adds clusters (MIN..MAX) and removes them when
       the queue drains. ECONOMY policy favours cost (only adds a cluster when
       there is enough work to keep it busy ~6 min); STANDARD favours latency.
============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_INGEST
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60          -- seconds idle before suspending (stop paying)
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE        -- creating it costs nothing
  STATEMENT_TIMEOUT_IN_SECONDS = 600
  COMMENT = 'Bulk COPY INTO for reference/snapshot files';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 1800  -- kill runaway transforms after 30 min
  STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600
  COMMENT = 'Stored procedures, task graph and dbt runs';

-- Multi-cluster requires Enterprise edition (choose Enterprise for the trial).
-- On Standard edition remove MIN/MAX_CLUSTER_COUNT and SCALING_POLICY.
CREATE WAREHOUSE IF NOT EXISTS WH_ANALYTICS
  WAREHOUSE_SIZE      = 'XSMALL'
  MIN_CLUSTER_COUNT   = 1
  MAX_CLUSTER_COUNT   = 2           -- scale OUT under concurrency, capped for cost
  SCALING_POLICY      = 'ECONOMY'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 900
  COMMENT = 'Ad-hoc analysis and BI queries on CONSUMPTION / ANALYTICS';

GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE WH_INGEST    TO ROLE VALUATION_PIPELINE;
GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE WH_TRANSFORM TO ROLE VALUATION_PIPELINE;
GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE WH_ANALYTICS TO ROLE VALUATION_PIPELINE;
GRANT USAGE                   ON WAREHOUSE WH_ANALYTICS TO ROLE VALUATION_ANALYST;

/* Gen2 note: depending on region/org defaults, new standard warehouses may be
   created as Generation 2 (faster, but a higher credit rate per hour). For a
   tiny batch workload Gen1 is the cheaper choice; check SHOW WAREHOUSES
   (column resource_constraint) and, if needed:
     ALTER WAREHOUSE WH_TRANSFORM SET RESOURCE_CONSTRAINT = STANDARD_GEN_1;     */
