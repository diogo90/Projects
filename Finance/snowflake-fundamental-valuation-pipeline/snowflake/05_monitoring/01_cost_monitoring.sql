/* =============================================================================
   MONITORING 01 - Cost & resource monitoring
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE (has IMPORTED PRIVILEGES on the SNOWFLAKE database)

   Sources
     SNOWFLAKE.ACCOUNT_USAGE.*  - 365 days of history, latency 45 min - 3 h
     <db>.INFORMATION_SCHEMA.*  - near real-time, short history (7-14 days)
   UI equivalent: Snowsight > Admin > Cost Management (Consumption, Budgets).
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE WAREHOUSE WH_ANALYTICS;

-- 1. Credits per warehouse per day (compute + cloud services)
SELECT TO_DATE(start_time)                    AS usage_date,
       warehouse_name,
       ROUND(SUM(credits_used_compute), 4)        AS compute_credits,
       ROUND(SUM(credits_used_cloud_services), 4) AS cloud_services_credits,
       ROUND(SUM(credits_used), 4)                AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC, 5 DESC;

-- 2. Everything that consumed credits, by service type (warehouses, Snowpipe,
--    serverless tasks, auto-clustering ...). Cloud services are only billed
--    above 10% of daily compute, hence the adjustment column.
SELECT usage_date, service_type,
       ROUND(SUM(credits_used), 4)                         AS credits_used,
       ROUND(SUM(credits_adjustment_cloud_services), 4)    AS cloud_services_adjustment,
       ROUND(SUM(credits_billed), 4)                       AS credits_billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;

-- 3. Month-to-date spend vs the resource monitor quota
SHOW RESOURCE MONITORS;
SELECT "name", "credit_quota", "used_credits", "remaining_credits",
       ROUND("used_credits" / NULLIF("credit_quota", 0) * 100, 1) AS pct_used
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- 4. Snowpipe ingestion volume and credits (serverless, billed per GB)
SELECT pipe_name, TO_DATE(start_time) AS usage_date,
       SUM(files_inserted) AS files, ROUND(SUM(bytes_inserted) / POWER(1024, 2), 2) AS mb,
       ROUND(SUM(credits_used), 6) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 2 DESC;

-- 5. Storage footprint per table (active + time travel + fail-safe bytes).
--    Shows why TRANSIENT landing/curated tables carry no fail-safe cost.
SELECT table_schema, table_name, is_transient,
       ROUND(active_bytes      / POWER(1024, 2), 2) AS active_mb,
       ROUND(time_travel_bytes / POWER(1024, 2), 2) AS time_travel_mb,
       ROUND(failsafe_bytes    / POWER(1024, 2), 2) AS failsafe_mb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE table_catalog = 'VALUATION_DB' AND deleted = FALSE
ORDER BY active_bytes DESC;

-- 6. Most expensive queries of the pipeline (approximate cost attribution)
SELECT query_id, warehouse_name, LEFT(query_text, 80) AS query,
       ROUND(total_elapsed_time / 1000, 1)           AS elapsed_s,
       ROUND(bytes_scanned / POWER(1024, 2), 1)      AS mb_scanned,
       partitions_scanned, partitions_total,
       bytes_spilled_to_local_storage, bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND warehouse_name IN ('WH_INGEST', 'WH_TRANSFORM', 'WH_ANALYTICS')
ORDER BY total_elapsed_time DESC
LIMIT 20;

-- 7. Per-query credit attribution (ACCOUNT_USAGE view available on most accounts)
SELECT warehouse_name, query_tag, COUNT(*) AS queries,
       ROUND(SUM(credits_attributed_compute), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY credits DESC;

-- 8. Safety check: any warehouse left running, or without auto-suspend?
SHOW WAREHOUSES;
SELECT "name", "state", "size", "auto_suspend", "resource_monitor"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "state" = 'STARTED' OR "auto_suspend" IS NULL OR "auto_suspend" > 300;
