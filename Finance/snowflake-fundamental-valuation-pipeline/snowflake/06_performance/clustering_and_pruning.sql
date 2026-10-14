/* =============================================================================
   PERFORMANCE - Micro-partitions, pruning and clustering strategy
   -----------------------------------------------------------------------------
   MICRO-PARTITIONS (automatic)
   Snowflake stores every table as immutable micro-partitions of
   ~50-500 MB uncompressed (~16 MB compressed), columnar inside. For each
   partition it records metadata: min/max per column, distinct counts, NULL
   counts. A query with WHERE trade_date BETWEEN ... skips ("prunes") every
   partition whose min/max range cannot match. Pruning is the #1 performance
   lever in Snowflake. There are no indexes to tune.

   CLUSTERING = how well partition ranges line up with your filters
   - Natural clustering: data is clustered in the order it was inserted.
     Daily price files arrive in date order, so date ranges are already tight.
     The gold build also inserts ORDER BY (trade_date, ticker).
   - Clustering key (ALTER TABLE ... CLUSTER BY): Automatic Clustering re-sorts
     data in the background on SERVERLESS credits. It is worth it only when
     (a) the table is large (multi-TB / many thousands of partitions),
     (b) queries filter on the same columns, and (c) natural order decays
     (e.g. late-arriving or updated data).

   DECISION FOR THIS PROJECT: no clustering keys.
   Every table here fits in a few micro-partitions, so pruning has
   nothing to skip and Automatic Clustering would only burn credits.
   The keys below are what I would add at full-market scale (~8,000 US
   tickers x 20 years ~ 40M price rows; SEC facts for ~20k filers ~ 1B rows).
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE WAREHOUSE WH_ANALYTICS;
USE DATABASE VALUATION_DB;

-- 1. Inspect clustering quality for a candidate key (cheap metadata call).
--    average_depth ~1 = well clustered; large depth = overlapping ranges.
SELECT SYSTEM$CLUSTERING_INFORMATION('CONSUMPTION.FCT_DAILY_VALUATION', '(trade_date)');
SELECT SYSTEM$CLUSTERING_INFORMATION('CURATED.SEC_FINANCIAL_FACTS', '(cik, concept)');

-- 2. Measure pruning for a typical query: compare partitions scanned vs total
--    in the query profile (Snowsight > Query History > Profile > TableScan).
SELECT ticker, AVG(pe_ratio)
FROM CONSUMPTION.FCT_DAILY_VALUATION
WHERE trade_date BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY ticker;

SELECT query_id, partitions_scanned, partitions_total,
       ROUND(100 * (1 - partitions_scanned / NULLIF(partitions_total, 0)), 1) AS pct_pruned
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION())
WHERE query_text ILIKE '%FCT_DAILY_VALUATION%BETWEEN%'
ORDER BY start_time DESC
LIMIT 1;

/* 3. Keys I WOULD use at scale (documented, intentionally not executed)

   -- Time-series facts: most queries are "a date range, all/some tickers".
   -- Date first (low-ish cardinality, matches range filters), ticker second.
   ALTER TABLE CONSUMPTION.FCT_DAILY_PRICES    CLUSTER BY (trade_date, ticker);
   ALTER TABLE CONSUMPTION.FCT_DAILY_VALUATION CLUSTER BY (trade_date, ticker);

   -- SEC facts: access pattern is "one company (or a few), some concepts".
   ALTER TABLE CURATED.SEC_FINANCIAL_FACTS CLUSTER BY (cik, concept);

   -- If dates are timestamps, cluster on an expression to keep cardinality low:
   --   CLUSTER BY (TO_DATE(event_ts), ticker)

   -- Point lookups on a high-cardinality column (e.g. one ticker's full
   -- history over a huge table): Search Optimization Service (Enterprise),
   -- instead of a clustering key.
   ALTER TABLE CONSUMPTION.FCT_DAILY_VALUATION ADD SEARCH OPTIMIZATION ON EQUALITY(ticker);

   -- Cost control for automatic clustering:
   ALTER TABLE CONSUMPTION.FCT_DAILY_PRICES SUSPEND RECLUSTER;
   SELECT * FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(
       DATE_RANGE_START => DATEADD('day', -7, CURRENT_DATE())));
*/

-- 4. Other performance levers used in this project
--    - Result cache: identical queries within 24h return instantly at zero compute.
--    - Warehouse cache: warm local SSD cache while a warehouse is running
--      (a reason not to set AUTO_SUSPEND too low on BI warehouses).
--    - Column pruning: columnar storage, so select only needed columns (no SELECT * in gold).
--    - VARIANT: frequently used JSON paths (cik, entityName) are promoted to
--      typed columns at load time, so filters on them get min/max pruning.
--    - Query Acceleration Service (Enterprise) can offload large scans for
--      outlier queries on a warehouse:  ALTER WAREHOUSE WH_ANALYTICS SET ENABLE_QUERY_ACCELERATION = TRUE;
