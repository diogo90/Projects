/*
===============================================================================
Quality Checks: Silver Layer
===============================================================================
Script Purpose:
    Validates the Silver layer after silver.load_silver. Every check writes
    one row to a results table instead of returning ad-hoc result sets, so
    the whole suite reads as a single report:

        check_group | check_name | object_name | expectation | actual | status

    Status:
        PASS - expectation met
        WARN - known/accepted data condition worth monitoring (thresholds)
        FAIL - the load is wrong; investigate before using the data

    The script ends with THROW if any check FAILs, so it can gate a SQL Agent
    job step or a CI pipeline, not just be eyeballed in SSMS.

    Checks already enforced by constraints (PK uniqueness, NOT NULL, CHECK)
    are not repeated here. These tests cover what constraints cannot:
    reconciliation, cross-table consistency, distributions and thresholds.

Usage:
    Run the whole script in SSMS (or sqlcmd -i) after EXEC silver.load_silver.
===============================================================================
*/

USE nyc_tlc_dwh;
GO

SET NOCOUNT ON;

DROP TABLE IF EXISTS #dq_results;
CREATE TABLE #dq_results (
    check_id     INT IDENTITY(1,1) PRIMARY KEY,
    check_group  VARCHAR(30)   NOT NULL,
    check_name   VARCHAR(150)  NOT NULL,
    object_name  VARCHAR(60)   NOT NULL,
    expectation  VARCHAR(150)  NOT NULL,
    actual       VARCHAR(150)  NOT NULL,
    status       VARCHAR(4)    NOT NULL
);

DECLARE @period_start DATE = (SELECT MIN(reporting_month) FROM etl.file_manifest);
DECLARE @period_end   DATE = DATEADD(MONTH, 1, @period_start);
DECLARE @reject_mask  INT  = (SELECT SUM(rule_bit) FROM etl.dq_rule WHERE severity = 'REJECT');
DECLARE @all_rules_mask       INT = (SELECT SUM(rule_bit) FROM etl.dq_rule);
DECLARE @dq_out_of_period     INT = (SELECT rule_bit FROM etl.dq_rule WHERE rule_code = 'OUT_OF_PERIOD');
DECLARE @dq_negative_duration INT = (SELECT rule_bit FROM etl.dq_rule WHERE rule_code = 'NEGATIVE_DURATION');
DECLARE @dq_missing_location  INT = (SELECT rule_bit FROM etl.dq_rule WHERE rule_code = 'MISSING_LOCATION');

-- =============================================================================
-- 1. COMPLETENESS - row reconciliation Bronze -> Silver
--    Silver flags bad rows instead of deleting them, so counts must match
--    exactly. FHV is the one exception: exact duplicates are removed.
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Completeness', 'Row count Bronze = Silver', v.object_name, 'silver = bronze',
       CONCAT(FORMAT(v.silver_rows, 'N0'), ' vs ', FORMAT(v.bronze_rows, 'N0')),
       IIF(v.silver_rows = v.bronze_rows, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.yellow_tripdata',          (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata),          (SELECT COUNT_BIG(*) FROM bronze.yellow_tripdata)),
    ('silver.green_tripdata',           (SELECT COUNT_BIG(*) FROM silver.green_tripdata),           (SELECT COUNT_BIG(*) FROM bronze.green_tripdata)),
    ('silver.fhvhv_tripdata',           (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata),           (SELECT COUNT_BIG(*) FROM bronze.fhvhv_tripdata)),
    ('silver.tlc_taxi_zone_lookup',     (SELECT COUNT_BIG(*) FROM silver.tlc_taxi_zone_lookup),     (SELECT COUNT_BIG(*) FROM bronze.tlc_taxi_zone_lookup)),
    ('silver.tlc_code_values',          (SELECT COUNT_BIG(*) FROM silver.tlc_code_values),          (SELECT COUNT_BIG(*) FROM bronze.tlc_code_values)),
    ('silver.openmeteo_weather_hourly', (SELECT COUNT_BIG(*) FROM silver.openmeteo_weather_hourly), (SELECT COUNT_BIG(*) FROM bronze.openmeteo_weather_hourly))
) AS v (object_name, silver_rows, bronze_rows);

-- FHV: Bronze = Silver + removed duplicates, and Silver has no duplicates left.
WITH fhv_dupes AS (
    SELECT COUNT_BIG(*) - 1 AS extra_copies
    FROM silver.fhv_tripdata
    GROUP BY dispatching_base_num, affiliated_base_num, pickup_datetime, dropoff_datetime,
             pickup_location_id, dropoff_location_id, is_shared_ride
    HAVING COUNT_BIG(*) > 1
)
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Uniqueness', 'No exact duplicate trips remain', 'silver.fhv_tripdata', '0 duplicate rows',
       CONCAT(ISNULL(SUM(extra_copies), 0), ' duplicate rows'),
       IIF(ISNULL(SUM(extra_copies), 0) = 0, 'PASS', 'FAIL')
FROM fhv_dupes;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Completeness', 'Rows removed as duplicates (Bronze - Silver)', 'silver.fhv_tripdata',
       'removed < 1% of Bronze',
       CONCAT(FORMAT(b.n - s.n, 'N0'), ' removed (', CAST(100.0 * (b.n - s.n) / NULLIF(b.n, 0) AS DECIMAL(5,2)), '%)'),
       CASE WHEN s.n > b.n THEN 'FAIL'
            WHEN 1.0 * (b.n - s.n) / NULLIF(b.n, 0) >= 0.01 THEN 'WARN'
            ELSE 'PASS' END
FROM (SELECT COUNT_BIG(*) AS n FROM bronze.fhv_tripdata) AS b
CROSS JOIN (SELECT COUNT_BIG(*) AS n FROM silver.fhv_tripdata) AS s;

-- Weather: one row per hour of the reporting month, no gaps.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Completeness', 'One weather row per hour of the reporting month', 'silver.openmeteo_weather_hourly',
       CONCAT(DATEDIFF(HOUR, @period_start, @period_end), ' hours'),
       CONCAT(COUNT(DISTINCT weather_datetime), ' hours'),
       IIF(COUNT(DISTINCT weather_datetime) = DATEDIFF(HOUR, @period_start, @period_end), 'PASS', 'FAIL')
FROM silver.openmeteo_weather_hourly
WHERE weather_datetime >= @period_start AND weather_datetime < @period_end;

-- =============================================================================
-- 2. ACCURACY - financial reconciliation (FLOAT -> DECIMAL must not lose money)
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Accuracy', CONCAT('SUM(', v.measure, ') Bronze = Silver (to the cent)'), v.object_name, 'difference < $1.00',
       CONCAT('diff = ', CAST(v.silver_sum - v.bronze_sum AS DECIMAL(18,2))),
       IIF(ABS(v.silver_sum - v.bronze_sum) < 1, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.yellow_tripdata', 'total_amount',
        (SELECT SUM(total_amount) FROM silver.yellow_tripdata),
        (SELECT CAST(SUM(CAST(total_amount AS DECIMAL(10,2))) AS DECIMAL(18,2)) FROM bronze.yellow_tripdata)),
    ('silver.green_tripdata', 'total_amount',
        (SELECT SUM(total_amount) FROM silver.green_tripdata),
        (SELECT CAST(SUM(CAST(total_amount AS DECIMAL(10,2))) AS DECIMAL(18,2)) FROM bronze.green_tripdata)),
    ('silver.fhvhv_tripdata', 'base_passenger_fare',
        (SELECT SUM(base_passenger_fare) FROM silver.fhvhv_tripdata),
        (SELECT CAST(SUM(CAST(base_passenger_fare AS DECIMAL(10,2))) AS DECIMAL(18,2)) FROM bronze.fhvhv_tripdata)),
    ('silver.fhvhv_tripdata', 'driver_pay',
        (SELECT SUM(driver_pay) FROM silver.fhvhv_tripdata),
        (SELECT CAST(SUM(CAST(driver_pay AS DECIMAL(10,2))) AS DECIMAL(18,2)) FROM bronze.fhvhv_tripdata))
) AS v (object_name, measure, silver_sum, bronze_sum);

-- HVFHV derived total must equal the sum of its components.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Accuracy', 'passenger_total_amount = sum of fare components', 'silver.fhvhv_tripdata', '0 mismatches',
       CONCAT(COUNT_BIG(*), ' mismatches'), IIF(COUNT_BIG(*) = 0, 'PASS', 'FAIL')
FROM silver.fhvhv_tripdata
WHERE passenger_total_amount <> ISNULL(base_passenger_fare, 0) + ISNULL(tolls_amount, 0) + ISNULL(black_car_fund_amount, 0)
                              + ISNULL(sales_tax, 0) + ISNULL(congestion_surcharge, 0) + ISNULL(airport_fee, 0)
                              + ISNULL(cbd_congestion_fee, 0) + ISNULL(tip_amount, 0);

-- =============================================================================
-- 3. VALIDITY - codes must exist in the reference data (orphans)
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Validity', CONCAT(v.check_name, ' exists in tlc_code_values'), v.object_name, '0 orphan rows',
       CONCAT(FORMAT(v.orphans, 'N0'), ' orphan rows'), IIF(v.orphans = 0, 'PASS', 'WARN')
FROM (VALUES
    ('vendor_id', 'silver.yellow_tripdata',
        (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata t WHERE NOT EXISTS
            (SELECT 1 FROM silver.tlc_code_values c WHERE c.code_type = 'vendor' AND c.code = CAST(t.vendor_id AS VARCHAR(10))))),
    ('payment_type_id', 'silver.yellow_tripdata',
        (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata t WHERE NOT EXISTS
            (SELECT 1 FROM silver.tlc_code_values c WHERE c.code_type = 'payment_type' AND c.code = CAST(t.payment_type_id AS VARCHAR(10))))),
    ('rate_code_id', 'silver.yellow_tripdata',
        (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata t WHERE NOT EXISTS
            (SELECT 1 FROM silver.tlc_code_values c WHERE c.code_type = 'rate_code' AND c.code = CAST(t.rate_code_id AS VARCHAR(10))))),
    ('vendor_id', 'silver.green_tripdata',
        (SELECT COUNT_BIG(*) FROM silver.green_tripdata t WHERE NOT EXISTS
            (SELECT 1 FROM silver.tlc_code_values c WHERE c.code_type = 'vendor' AND c.code = CAST(t.vendor_id AS VARCHAR(10))))),
    ('hvfhs_license_num', 'silver.fhvhv_tripdata',
        (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata t WHERE NOT EXISTS
            (SELECT 1 FROM silver.tlc_code_values c WHERE c.code_type = 'vendor' AND c.code = t.hvfhs_license_num)))
) AS v (check_name, object_name, orphans);

-- Location ids used by trips must exist in the zone lookup.
WITH used_locations AS (
    SELECT pickup_location_id AS location_id FROM silver.yellow_tripdata UNION
    SELECT dropoff_location_id FROM silver.yellow_tripdata UNION
    SELECT pickup_location_id FROM silver.green_tripdata UNION
    SELECT dropoff_location_id FROM silver.green_tripdata UNION
    SELECT pickup_location_id FROM silver.fhv_tripdata UNION
    SELECT dropoff_location_id FROM silver.fhv_tripdata UNION
    SELECT pickup_location_id FROM silver.fhvhv_tripdata UNION
    SELECT dropoff_location_id FROM silver.fhvhv_tripdata
)
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Validity', 'Every trip location_id exists in the zone lookup', 'silver.*_tripdata', '0 unknown location ids',
       CONCAT(COUNT(*), ' unknown location ids'), IIF(COUNT(*) = 0, 'PASS', 'WARN')
FROM used_locations AS u
WHERE u.location_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM silver.tlc_taxi_zone_lookup z WHERE z.location_id = u.location_id);

-- =============================================================================
-- 4. STANDARDISATION - cleansing rules were applied
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'No leading/trailing spaces or N/A placeholders', 'silver.tlc_taxi_zone_lookup', '0 rows',
       CONCAT(COUNT(*), ' rows'), IIF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM silver.tlc_taxi_zone_lookup
WHERE borough <> TRIM(borough) OR zone_name <> TRIM(zone_name) OR service_zone <> TRIM(service_zone)
   OR 'N/A' IN (borough, zone_name, service_zone);

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'Base numbers match licence format B#####', v.object_name, '0 rows',
       CONCAT(v.bad_rows, ' rows'), IIF(v.bad_rows = 0, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.fhv_tripdata',   (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata
                               WHERE dispatching_base_num NOT LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                                  OR affiliated_base_num  NOT LIKE 'B[0-9][0-9][0-9][0-9][0-9]')),
    ('silver.fhvhv_tripdata', (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata
                               WHERE dispatching_base_num NOT LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                                  OR originating_base_num NOT LIKE 'B[0-9][0-9][0-9][0-9][0-9]'))
) AS v (object_name, bad_rows);

-- Informational: how much free text the base-number validation discarded.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'Affiliated base numbers invalidated by format check', 'silver.fhv_tripdata',
       '< 2% of rows',
       CONCAT(FORMAT(SUM(IIF(affiliated_base_num IS NULL, 1, 0)), 'N0'), ' NULL (',
              CAST(100.0 * SUM(IIF(affiliated_base_num IS NULL, 1, 0)) / COUNT(*) AS DECIMAL(5,2)), '%)'),
       IIF(1.0 * SUM(IIF(affiliated_base_num IS NULL, 1, 0)) / COUNT(*) < 0.02, 'PASS', 'WARN')
FROM silver.fhv_tripdata;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'passenger_count is NULL or 1-9 (0 converted to NULL)', v.object_name, '0 rows',
       CONCAT(v.bad_rows, ' rows'), IIF(v.bad_rows = 0, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.yellow_tripdata', (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE passenger_count NOT BETWEEN 1 AND 9)),
    ('silver.green_tripdata',  (SELECT COUNT_BIG(*) FROM silver.green_tripdata  WHERE passenger_count NOT BETWEEN 1 AND 9))
) AS v (object_name, bad_rows);

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'pickup_wait_seconds is never negative', 'silver.fhvhv_tripdata', '0 rows',
       CONCAT(COUNT_BIG(*), ' rows'), IIF(COUNT_BIG(*) = 0, 'PASS', 'FAIL')
FROM silver.fhvhv_tripdata
WHERE pickup_wait_seconds < 0;

-- Schema-drift canary: ehail_fee was dropped in Silver because it is always NULL.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Standardisation', 'Dropped column ehail_fee is still 100% NULL in the source', 'bronze.green_tripdata',
       '0 non-NULL values', CONCAT(COUNT_BIG(ehail_fee), ' non-NULL values'),
       IIF(COUNT_BIG(ehail_fee) = 0, 'PASS', 'WARN')
FROM bronze.green_tripdata;

-- =============================================================================
-- 5. CONSISTENCY - the DQ flags agree with the data they describe
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Consistency', 'Every pickup outside the period carries OUT_OF_PERIOD', v.object_name, '0 rows',
       CONCAT(v.bad_rows, ' rows'), IIF(v.bad_rows = 0, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.yellow_tripdata', (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata
        WHERE (pickup_datetime < @period_start OR pickup_datetime >= @period_end) AND dq_flags & @dq_out_of_period = 0)),
    ('silver.green_tripdata',  (SELECT COUNT_BIG(*) FROM silver.green_tripdata
        WHERE (pickup_datetime < @period_start OR pickup_datetime >= @period_end) AND dq_flags & @dq_out_of_period = 0)),
    ('silver.fhv_tripdata',    (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata
        WHERE (pickup_datetime < @period_start OR pickup_datetime >= @period_end) AND dq_flags & @dq_out_of_period = 0)),
    ('silver.fhvhv_tripdata',  (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata
        WHERE (pickup_datetime < @period_start OR pickup_datetime >= @period_end) AND dq_flags & @dq_out_of_period = 0))
) AS v (object_name, bad_rows);

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Consistency', 'Every dropoff-before-pickup trip carries NEGATIVE_DURATION', v.object_name, '0 rows',
       CONCAT(v.bad_rows, ' rows'), IIF(v.bad_rows = 0, 'PASS', 'FAIL')
FROM (VALUES
    ('silver.yellow_tripdata', (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE dropoff_datetime < pickup_datetime AND dq_flags & @dq_negative_duration = 0)),
    ('silver.fhv_tripdata',    (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata    WHERE dropoff_datetime < pickup_datetime AND dq_flags & @dq_negative_duration = 0)),
    ('silver.fhvhv_tripdata',  (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata  WHERE dropoff_datetime < pickup_datetime AND dq_flags & @dq_negative_duration = 0))
) AS v (object_name, bad_rows);

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Consistency', 'dq_flags only uses bits defined in etl.dq_rule', 'silver.*_tripdata', '0 rows',
       CONCAT(SUM(v.bad_rows), ' rows'), IIF(SUM(v.bad_rows) = 0, 'PASS', 'FAIL')
FROM (VALUES
    ((SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE dq_flags & ~@all_rules_mask <> 0)),
    ((SELECT COUNT_BIG(*) FROM silver.green_tripdata  WHERE dq_flags & ~@all_rules_mask <> 0)),
    ((SELECT COUNT_BIG(*) FROM silver.fhv_tripdata    WHERE dq_flags & ~@all_rules_mask <> 0)),
    ((SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata  WHERE dq_flags & ~@all_rules_mask <> 0))
) AS v (bad_rows);

-- =============================================================================
-- 6. THRESHOLDS - rejected share per feed. A spike means an upstream problem
--    (e.g. a bad file), not just a few bad trips.
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Threshold', 'Share of rows REJECTed by quality rules', v.object_name, '< 0.5% (WARN) / < 2% (FAIL)',
       CONCAT(FORMAT(v.rejected, 'N0'), ' rows (', CAST(100.0 * v.rejected / NULLIF(v.total, 0) AS DECIMAL(6,3)), '%)'),
       CASE WHEN 1.0 * v.rejected / NULLIF(v.total, 0) >= 0.02  THEN 'FAIL'
            WHEN 1.0 * v.rejected / NULLIF(v.total, 0) >= 0.005 THEN 'WARN'
            ELSE 'PASS' END
FROM (VALUES
    ('silver.yellow_tripdata', (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE dq_flags & @reject_mask <> 0), (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata)),
    ('silver.green_tripdata',  (SELECT COUNT_BIG(*) FROM silver.green_tripdata  WHERE dq_flags & @reject_mask <> 0), (SELECT COUNT_BIG(*) FROM silver.green_tripdata)),
    ('silver.fhv_tripdata',    (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata    WHERE dq_flags & @reject_mask <> 0), (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata)),
    ('silver.fhvhv_tripdata',  (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata  WHERE dq_flags & @reject_mask <> 0), (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata))
) AS v (object_name, rejected, total);

-- FHV bases rarely report zones; monitored, not failed.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Threshold', 'Share of trips with a missing pickup/dropoff zone', v.object_name, '< 5%',
       CONCAT(CAST(100.0 * v.missing / NULLIF(v.total, 0) AS DECIMAL(5,2)), '%'),
       IIF(1.0 * v.missing / NULLIF(v.total, 0) < 0.05, 'PASS', 'WARN')
FROM (VALUES
    ('silver.yellow_tripdata', (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE dq_flags & @dq_missing_location <> 0), (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata)),
    ('silver.fhv_tripdata',    (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata    WHERE dq_flags & @dq_missing_location <> 0), (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata)),
    ('silver.fhvhv_tripdata',  (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata  WHERE dq_flags & @dq_missing_location <> 0), (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata))
) AS v (object_name, missing, total);

-- Weather readings within physically plausible NYC ranges.
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Threshold', 'Temperature between -30C and 45C, precipitation 0-100 mm/h', 'silver.openmeteo_weather_hourly', '0 rows',
       CONCAT(COUNT(*), ' rows'), IIF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM silver.openmeteo_weather_hourly
WHERE temperature_c NOT BETWEEN -30 AND 45 OR precipitation_mm NOT BETWEEN 0 AND 100;

-- =============================================================================
-- REPORT
-- =============================================================================
SELECT check_id, status, check_group, check_name, object_name, expectation, actual
FROM #dq_results
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, check_id;

SELECT status, COUNT(*) AS checks FROM #dq_results GROUP BY status;

IF EXISTS (SELECT 1 FROM #dq_results WHERE status = 'FAIL')
    THROW 50100, 'Silver quality checks FAILED. See the report above.', 1;
ELSE
    PRINT 'Silver quality checks completed with no failures.';
GO
