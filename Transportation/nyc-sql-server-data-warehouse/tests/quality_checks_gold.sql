/*
===============================================================================
Quality Checks: Gold Layer
===============================================================================
Script Purpose:
    Validates the star schema after gold.load_gold. Same report format as
    quality_checks_silver.sql (PASS / WARN / FAIL, THROW on any FAIL).

    What is NOT tested here, because constraints already guarantee it:
      - surrogate key uniqueness (PRIMARY KEY)
      - business key uniqueness (UNIQUE filtered indexes)
      - fact -> dimension referential integrity (FOREIGN KEY)
    What IS tested:
      - that those foreign keys are still TRUSTED (a disabled/re-enabled FK
        without re-validation silently stops protecting the data and stops
        helping the optimizer)
      - reconciliation Silver -> fact_trips -> fact_trips_hourly
      - use of the special members (-1 Unknown / -2 Not Applicable)
      - completeness of the generated dimensions

Usage:
    Run the whole script after EXEC gold.load_gold (or etl.run_pipeline).
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

DECLARE @reject_mask         INT = (SELECT SUM(rule_bit) FROM etl.dq_rule WHERE severity = 'REJECT');
DECLARE @negative_amount_bit INT = (SELECT rule_bit FROM etl.dq_rule WHERE rule_code = 'NEGATIVE_AMOUNT');

-- =============================================================================
-- 1. CONSTRAINT HEALTH
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Integrity', 'All Gold foreign keys enabled and trusted', 'gold.*', '0 untrusted/disabled FKs',
       CONCAT(COUNT(*), ' untrusted/disabled: ', ISNULL(STRING_AGG(name, ', '), '-')),
       IIF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM sys.foreign_keys
WHERE SCHEMA_NAME(schema_id) = 'gold'
  AND (is_not_trusted = 1 OR is_disabled = 1);

-- =============================================================================
-- 2. RECONCILIATION - Silver (eligible rows) -> fact_trips, per service
-- =============================================================================
WITH silver_side AS (
    SELECT 'yellow' AS service_code, COUNT_BIG(*) AS row_count, SUM(total_amount) AS amount
    FROM silver.yellow_tripdata WHERE dq_flags & @reject_mask = 0
    UNION ALL
    SELECT 'green', COUNT_BIG(*), SUM(total_amount)
    FROM silver.green_tripdata WHERE dq_flags & @reject_mask = 0
    UNION ALL
    SELECT 'fhv', COUNT_BIG(*), NULL
    FROM silver.fhv_tripdata WHERE dq_flags & @reject_mask = 0
    UNION ALL
    SELECT 'fhvhv', COUNT_BIG(*), SUM(passenger_total_amount)
    FROM silver.fhvhv_tripdata WHERE dq_flags & @reject_mask = 0
),
gold_side AS (
    SELECT s.service_code, COUNT_BIG(*) AS row_count, SUM(f.total_amount) AS amount
    FROM gold.fact_trips AS f
    JOIN gold.dim_service AS s ON s.service_key = f.service_key
    GROUP BY s.service_code
)
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Reconciliation', CONCAT('Silver -> fact_trips rows and total_amount (', s.service_code, ')'), 'gold.fact_trips',
       'rows and amount equal',
       CONCAT(FORMAT(ISNULL(g.row_count, 0), 'N0'), ' vs ', FORMAT(s.row_count, 'N0'), ' rows; amount diff ',
              ISNULL(CAST(g.amount - s.amount AS VARCHAR(30)), 'n/a')),
       IIF(ISNULL(g.row_count, 0) = s.row_count AND ISNULL(g.amount, 0) = ISNULL(s.amount, 0), 'PASS', 'FAIL')
FROM silver_side AS s
LEFT JOIN gold_side AS g ON g.service_code = s.service_code;

-- Detail fact -> aggregate fact (they must never disagree)
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Reconciliation', 'fact_trips_hourly = SUM(fact_trips): trips, amount, driver pay', 'gold.fact_trips_hourly',
       'all three equal',
       CONCAT(FORMAT(h.trips, 'N0'), ' vs ', FORMAT(d.trips, 'N0'), ' trips; amount diff ',
              ISNULL(h.amount, 0) - ISNULL(d.amount, 0), '; driver pay diff ', ISNULL(h.pay, 0) - ISNULL(d.pay, 0)),
       IIF(h.trips = d.trips AND ISNULL(h.amount, 0) = ISNULL(d.amount, 0) AND ISNULL(h.pay, 0) = ISNULL(d.pay, 0), 'PASS', 'FAIL')
FROM (SELECT SUM(CAST(trip_count AS BIGINT)) AS trips, SUM(total_amount_sum) AS amount, SUM(driver_pay_sum) AS pay
      FROM gold.fact_trips_hourly) AS h
CROSS JOIN (SELECT SUM(CAST(trip_count AS BIGINT)) AS trips, SUM(total_amount) AS amount, SUM(driver_pay) AS pay
            FROM gold.fact_trips) AS d;

-- trip_count = 0 exactly for the reversal/refund rows
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Consistency', 'trip_count = 0 if and only if NEGATIVE_AMOUNT is flagged', 'gold.fact_trips', '0 rows',
       CONCAT(COUNT_BIG(*), ' rows'), IIF(COUNT_BIG(*) = 0, 'PASS', 'FAIL')
FROM gold.fact_trips
WHERE (trip_count = 0 AND dq_flags & @negative_amount_bit = 0)
   OR (trip_count = 1 AND dq_flags & @negative_amount_bit <> 0);

-- No REJECT-severity rows reached Gold
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Consistency', 'No REJECT-flagged rows in the fact', 'gold.fact_trips', '0 rows',
       CONCAT(COUNT_BIG(*), ' rows'), IIF(COUNT_BIG(*) = 0, 'PASS', 'FAIL')
FROM gold.fact_trips
WHERE dq_flags & @reject_mask <> 0;

-- =============================================================================
-- 3. SPECIAL MEMBERS - how often facts fall back to -1 Unknown
--    -2 Not Applicable is expected (e.g. FHV has no payment type); -1 on an
--    attribute the service DOES report means a code is missing from the
--    reference data and should be added to tlc_code_values.csv.
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Special members', CONCAT('Unknown (-1) ', v.dimension, ' for ', s.service_code), 'gold.fact_trips', v.expectation,
       CONCAT(FORMAT(v.unknown_rows, 'N0'), ' rows (', CAST(100.0 * v.unknown_rows / NULLIF(v.total_rows, 0) AS DECIMAL(5,2)), '%)'),
       IIF(1.0 * v.unknown_rows / NULLIF(v.total_rows, 0) <= v.max_share, 'PASS', 'WARN')
FROM gold.dim_service AS s
CROSS APPLY (
    SELECT dimension, expectation, max_share, unknown_rows, total_rows
    FROM (
        SELECT
            SUM(IIF(f.vendor_key       = -1, 1, 0)) AS vendor_unknown,
            SUM(IIF(f.payment_type_key = -1, 1, 0)) AS payment_unknown,
            SUM(IIF(f.pickup_zone_key  = -1, 1, 0)) AS pickup_zone_unknown,
            SUM(IIF(f.weather_key      = -1, 1, 0)) AS weather_unknown,
            COUNT_BIG(*)                            AS total_rows
        FROM gold.fact_trips AS f
        WHERE f.service_key = s.service_key
    ) AS agg
    CROSS APPLY (VALUES
        ('vendor',       '0%',    0.0,  agg.vendor_unknown),
        ('payment type', '0%',    0.0,  agg.payment_unknown),
        ('pickup zone',  '<= 5%', 0.05, agg.pickup_zone_unknown),
        ('weather',      '0%',    0.0,  agg.weather_unknown)
    ) AS m (dimension, expectation, max_share, unknown_rows)
) AS v;

-- =============================================================================
-- 4. GENERATED DIMENSIONS - complete and correct
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'dim_date is a contiguous calendar (no gaps)', 'gold.dim_date',
       'rows = days between min and max',
       CONCAT(COUNT(*), ' rows vs ', DATEDIFF(DAY, MIN(full_date), MAX(full_date)) + 1, ' days'),
       IIF(COUNT(*) = DATEDIFF(DAY, MIN(full_date), MAX(full_date)) + 1, 'PASS', 'FAIL')
FROM gold.dim_date;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'Holiday rules: 11 US federal holidays per year', 'gold.dim_date', '11 per year',
       STRING_AGG(CONCAT(year_number, '=', holidays), ', '),
       IIF(MIN(holidays) = 11 AND MAX(holidays) = 11, 'PASS', 'FAIL')
FROM (SELECT year_number, SUM(CAST(is_holiday AS INT)) AS holidays FROM gold.dim_date GROUP BY year_number) AS y;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'MLK Day 2025 falls on 2025-01-20', 'gold.dim_date', 'Martin Luther King Jr. Day',
       ISNULL(holiday_name, 'NULL'), IIF(holiday_name = 'Martin Luther King Jr. Day', 'PASS', 'FAIL')
FROM gold.dim_date
WHERE date_key = 20250120;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'dim_time has 1,440 minutes', 'gold.dim_time', '1440 rows',
       CONCAT(COUNT(*), ' rows'), IIF(COUNT(*) = 1440, 'PASS', 'FAIL')
FROM gold.dim_time;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'dim_trip_profile holds every flag combination', 'gold.dim_trip_profile', '2187 rows (3 x 3^6)',
       CONCAT(COUNT(*), ' rows'), IIF(COUNT(*) = 2187, 'PASS', 'FAIL')
FROM gold.dim_trip_profile;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'dim_zone holds every Silver zone plus the Unknown member', 'gold.dim_zone',
       CONCAT((SELECT COUNT(*) FROM silver.tlc_taxi_zone_lookup) + 1, ' rows'),
       CONCAT(COUNT(*), ' rows'),
       IIF(COUNT(*) = (SELECT COUNT(*) FROM silver.tlc_taxi_zone_lookup) + 1, 'PASS', 'FAIL')
FROM gold.dim_zone;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Dimensions', 'Every hour of weather is in dim_weather', 'gold.dim_weather',
       CONCAT((SELECT COUNT(*) FROM silver.openmeteo_weather_hourly), ' hourly rows (+1 Unknown)'),
       CONCAT(COUNT(*) - 1, ' hourly rows'),
       IIF(COUNT(*) - 1 = (SELECT COUNT(*) FROM silver.openmeteo_weather_hourly), 'PASS', 'FAIL')
FROM gold.dim_weather;

-- =============================================================================
-- 5. BUSINESS SANITY - results a domain expert would expect
-- =============================================================================
INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
-- Compared on DROPOFF date: the toll is charged when the vehicle enters the
-- zone, so a trip picked up late on 4 Jan and entering after midnight is
-- legitimately charged (~1.6K such trips in Jan 2025).
SELECT 'Business sanity', 'CBD congestion fee only on trips ending after go-live (2025-01-05)', 'gold.fact_trips',
       '0 trips', CONCAT(COUNT_BIG(*), ' trips'), IIF(COUNT_BIG(*) = 0, 'PASS', 'WARN')
FROM gold.fact_trips AS f
JOIN gold.dim_date   AS d ON d.full_date = CAST(f.dropoff_datetime AS DATE)
WHERE d.is_congestion_pricing_active = 0 AND f.cbd_congestion_fee > 0;

INSERT INTO #dq_results (check_group, check_name, object_name, expectation, actual, status)
SELECT 'Business sanity', 'HVFHV driver pay does not exceed rider total (take rate >= 0)', 'gold.fact_trips',
       'aggregate driver_pay < total_amount',
       CONCAT('driver pay = ', CAST(100.0 * SUM(f.driver_pay) / NULLIF(SUM(f.total_amount), 0) AS DECIMAL(5,1)), '% of rider total'),
       IIF(SUM(f.driver_pay) < SUM(f.total_amount), 'PASS', 'FAIL')
FROM gold.fact_trips  AS f
JOIN gold.dim_service AS s ON s.service_key = f.service_key
WHERE s.service_code = 'fhvhv';

-- =============================================================================
-- REPORT
-- =============================================================================
SELECT check_id, status, check_group, check_name, object_name, expectation, actual
FROM #dq_results
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, check_id;

SELECT status, COUNT(*) AS checks FROM #dq_results GROUP BY status;

IF EXISTS (SELECT 1 FROM #dq_results WHERE status = 'FAIL')
    THROW 50101, 'Gold quality checks FAILED. See the report above.', 1;
ELSE
    PRINT 'Gold quality checks completed with no failures.';
GO
