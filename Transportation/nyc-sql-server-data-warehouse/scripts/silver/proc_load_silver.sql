/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    Cleanses, standardises and conforms the Bronze data into the 'silver'
    tables (full load: truncate & insert, one transaction per table).

Transformations applied (per the reference project's taxonomy):
    - Data cleansing      : trim/upper-case codes, '' -> NULL, remove exact
                            duplicates (FHV), invalid base numbers -> NULL,
                            impossible passenger counts (0) -> NULL.
    - Data standardisation: conformed snake_case column names across sources,
                            Y/N -> BIT, FLOAT -> DECIMAL(10,2),
                            DATETIME2(6) -> DATETIME2(0), m -> cm (snow depth).
    - Data normalisation  : missing codes mapped to the data dictionary's own
                            "unknown" code (RatecodeID NULL -> 99,
                            payment_type NULL -> 5) so there is one unknown bucket.
    - Derived columns     : trip_duration_seconds, pickup_wait_seconds,
                            passenger_total_amount, weather_condition.
    - Data enrichment     : dq_flags (bitmask of the etl.dq_rule rules broken).
    - Business rules      : reporting period read from the landing manifest;
                            quality thresholds read from etl.dq_rule.

Why flag instead of delete:
    Deleting "bad" rows in Silver loses the evidence. With flags, Silver still
    reconciles 1:1 with Bronze (minus exact duplicates), the Gold load simply
    filters REJECT-severity flags, and analysts can still study the WARN rows
    (e.g. reversals, trips with no zone).

Parameters:
    @batch_id  Optional. Supplied by etl.run_pipeline; generated if NULL.

Usage Example:
    EXEC silver.load_silver;
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE silver.load_silver
    @batch_id INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @layer_start DATETIME2(3) = SYSDATETIME(),
            @step_start  DATETIME2(3),
            @object_name NVARCHAR(128) = N'silver.load_silver',
            @rows        BIGINT,
            @message     NVARCHAR(2048);

    -- Reporting period and data-quality rule bits (resolved once, used by every table)
    DECLARE @period_start DATE,
            @period_end   DATE,
            @period_count INT;

    DECLARE @dq_out_of_period         INT,
            @dq_negative_duration     INT,
            @dq_excessive_duration    INT,
            @dq_implausible_value     INT,
            @dq_zero_duration         INT,
            @dq_negative_amount       INT,
            @dq_missing_location      INT,
            @dq_amount_not_reconciled INT;

    -- Thresholds used by the IMPLAUSIBLE_VALUE / EXCESSIVE_DURATION rules
    DECLARE @max_trip_seconds INT           = 86400,  -- 24 hours
            @max_trip_miles   DECIMAL(9,2)  = 250,
            @max_amount       DECIMAL(10,2) = 5000;

    IF @batch_id IS NULL
        SET @batch_id = NEXT VALUE FOR etl.seq_batch_id;

    BEGIN TRY
        PRINT '================================================';
        PRINT CONCAT('Loading Silver Layer | batch_id = ', @batch_id);
        PRINT '================================================';

        -- ---------------------------------------------------------------------
        -- Resolve the reporting period from the landing manifest
        -- ---------------------------------------------------------------------
        SELECT @period_start = MIN(reporting_month),
               @period_count = COUNT(DISTINCT reporting_month)
        FROM etl.file_manifest
        WHERE source_system IN ('yellow', 'green', 'fhv', 'fhvhv');

        IF @period_count <> 1
            THROW 50010, 'The landing manifest must contain exactly one reporting month for the trip files. Run bronze.load_bronze first.', 1;

        SET @period_end = DATEADD(MONTH, 1, @period_start);
        PRINT CONCAT('Reporting period: ', @period_start, ' to ', DATEADD(DAY, -1, @period_end));

        -- ---------------------------------------------------------------------
        -- Resolve data-quality rule bits from the catalogue (no magic numbers)
        -- ---------------------------------------------------------------------
        SELECT
            @dq_out_of_period         = MAX(CASE WHEN rule_code = 'OUT_OF_PERIOD'         THEN rule_bit END),
            @dq_negative_duration     = MAX(CASE WHEN rule_code = 'NEGATIVE_DURATION'     THEN rule_bit END),
            @dq_excessive_duration    = MAX(CASE WHEN rule_code = 'EXCESSIVE_DURATION'    THEN rule_bit END),
            @dq_implausible_value     = MAX(CASE WHEN rule_code = 'IMPLAUSIBLE_VALUE'     THEN rule_bit END),
            @dq_zero_duration         = MAX(CASE WHEN rule_code = 'ZERO_DURATION'         THEN rule_bit END),
            @dq_negative_amount       = MAX(CASE WHEN rule_code = 'NEGATIVE_AMOUNT'       THEN rule_bit END),
            @dq_missing_location      = MAX(CASE WHEN rule_code = 'MISSING_LOCATION'      THEN rule_bit END),
            @dq_amount_not_reconciled = MAX(CASE WHEN rule_code = 'AMOUNT_NOT_RECONCILED' THEN rule_bit END)
        FROM etl.dq_rule;

        IF @dq_out_of_period IS NULL OR @dq_negative_duration IS NULL OR @dq_excessive_duration IS NULL
           OR @dq_implausible_value IS NULL OR @dq_zero_duration IS NULL OR @dq_negative_amount IS NULL
           OR @dq_missing_location IS NULL OR @dq_amount_not_reconciled IS NULL
            THROW 50011, 'etl.dq_rule is missing one or more rule codes used by silver.load_silver.', 1;

        -- =====================================================================
        -- REFERENCE DATA
        -- =====================================================================
        PRINT '------------------------------------------------';
        PRINT 'Reference data';
        PRINT '------------------------------------------------';

        -- ---------------------------------------------------------------------
        -- silver.tlc_taxi_zone_lookup
        --   'N/A' placeholders -> 'Unknown'. Zone 265 is "Outside of NYC" but
        --   has borough 'N/A'; it gets borough 'Outside NYC' so a borough-level
        --   report does not lump out-of-city trips in with unknown ones.
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.tlc_taxi_zone_lookup';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.tlc_taxi_zone_lookup;

            INSERT INTO silver.tlc_taxi_zone_lookup (location_id, borough, zone_name, service_zone, dwh_batch_id)
            SELECT
                z.location_id,
                CASE
                    WHEN z.zone_name = 'Outside of NYC'              THEN 'Outside NYC'
                    WHEN ISNULL(z.borough, 'N/A') IN ('', 'N/A')     THEN 'Unknown'
                    ELSE z.borough
                END,
                CASE WHEN ISNULL(z.zone_name, 'N/A') IN ('', 'N/A')    THEN 'Unknown' ELSE z.zone_name END,
                CASE WHEN ISNULL(z.service_zone, 'N/A') IN ('', 'N/A') THEN 'Unknown' ELSE z.service_zone END,
                @batch_id
            FROM bronze.tlc_taxi_zone_lookup AS b
            CROSS APPLY (
                SELECT
                    TRY_CAST(TRIM(b.LocationID) AS SMALLINT) AS location_id,
                    TRIM(b.Borough)                          AS borough,
                    TRIM(b.Zone)                             AS zone_name,
                    TRIM(b.service_zone)                     AS service_zone
            ) AS z
            WHERE z.location_id IS NOT NULL;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- silver.tlc_code_values
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.tlc_code_values';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.tlc_code_values;

            INSERT INTO silver.tlc_code_values (code_type, code, code_description, code_group, source_document, dwh_batch_id)
            SELECT
                LOWER(TRIM(code_type)),
                -- Normalise code case so joins also work under a case-sensitive
                -- collation: service codes lower ('yellow'), all others upper ('HV0003').
                IIF(LOWER(TRIM(code_type)) = 'service_type', LOWER(TRIM(code)), UPPER(TRIM(code))),
                TRIM(code_description),
                NULLIF(TRIM(code_group), ''),
                NULLIF(TRIM(source_document), ''),
                @batch_id
            FROM bronze.tlc_code_values
            WHERE NULLIF(TRIM(code_type), '') IS NOT NULL
              AND NULLIF(TRIM(code), '') IS NOT NULL;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- silver.openmeteo_weather_hourly
        --   Text -> typed with TRY_CAST; WMO weather codes decoded into a
        --   readable condition (https://open-meteo.com/en/docs, "WMO codes").
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.openmeteo_weather_hourly';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.openmeteo_weather_hourly;

            INSERT INTO silver.openmeteo_weather_hourly (
                weather_datetime, temperature_c, apparent_temperature_c, precipitation_mm, rain_mm,
                snowfall_cm, snow_depth_cm, weather_code, weather_condition, cloud_cover_pct,
                wind_speed_kmh, dwh_batch_id
            )
            SELECT
                w.weather_datetime,
                TRY_CAST(b.temperature_2m       AS DECIMAL(4,1)),
                TRY_CAST(b.apparent_temperature AS DECIMAL(4,1)),
                TRY_CAST(b.precipitation        AS DECIMAL(5,1)),
                TRY_CAST(b.rain                 AS DECIMAL(5,1)),
                TRY_CAST(b.snowfall             AS DECIMAL(5,2)),
                CAST(TRY_CAST(b.snow_depth AS DECIMAL(9,4)) * 100 AS DECIMAL(6,1)),
                w.weather_code,
                CASE
                    WHEN w.weather_code IS NULL               THEN 'Unknown'
                    WHEN w.weather_code IN (0, 1)             THEN 'Clear'
                    WHEN w.weather_code = 2                   THEN 'Partly Cloudy'
                    WHEN w.weather_code = 3                   THEN 'Overcast'
                    WHEN w.weather_code IN (45, 48)           THEN 'Fog'
                    WHEN w.weather_code IN (56, 57, 66, 67)   THEN 'Freezing Rain'
                    WHEN w.weather_code BETWEEN 51 AND 55     THEN 'Drizzle'
                    WHEN w.weather_code BETWEEN 61 AND 65     THEN 'Rain'
                    WHEN w.weather_code BETWEEN 71 AND 77     THEN 'Snow'
                    WHEN w.weather_code BETWEEN 80 AND 82     THEN 'Rain Showers'
                    WHEN w.weather_code IN (85, 86)           THEN 'Snow Showers'
                    WHEN w.weather_code BETWEEN 95 AND 99     THEN 'Thunderstorm'
                    ELSE 'Unknown'
                END,
                TRY_CAST(b.cloud_cover    AS TINYINT),
                TRY_CAST(b.wind_speed_10m AS DECIMAL(5,1)),
                @batch_id
            FROM bronze.openmeteo_weather_hourly AS b
            CROSS APPLY (
                SELECT
                    -- ISO 8601 'yyyy-mm-ddThh:mi' (+ ':00' seconds) = style 126
                    TRY_CONVERT(DATETIME2(0), TRIM(b.[time]) + ':00', 126) AS weather_datetime,
                    TRY_CAST(b.weather_code AS TINYINT)                     AS weather_code
            ) AS w
            WHERE w.weather_datetime IS NOT NULL;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- =====================================================================
        -- TRIP RECORDS
        -- Pattern for every trip table:
        --   CROSS APPLY c : cleanse + standardise + rename (one place per column)
        --   CROSS APPLY d : derived columns
        --   CROSS APPLY q : dq_flags bitmask (rules OR-ed together)
        -- CROSS APPLY keeps each expression written once and referenced by name,
        -- instead of repeating the same CAST inside every rule.
        -- =====================================================================
        PRINT '------------------------------------------------';
        PRINT 'Trip records';
        PRINT '------------------------------------------------';

        -- ---------------------------------------------------------------------
        -- silver.yellow_tripdata
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.yellow_tripdata';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.yellow_tripdata;

            INSERT INTO silver.yellow_tripdata WITH (TABLOCK) (
                vendor_id, pickup_datetime, dropoff_datetime, pickup_location_id, dropoff_location_id,
                passenger_count, trip_distance_miles, trip_duration_seconds, rate_code_id, payment_type_id,
                is_store_and_forward, fare_amount, extra_amount, mta_tax, tip_amount, tolls_amount,
                improvement_surcharge, congestion_surcharge, airport_fee, cbd_congestion_fee, total_amount,
                dq_flags, dwh_batch_id
            )
            SELECT
                c.vendor_id, c.pickup_datetime, c.dropoff_datetime, c.pickup_location_id, c.dropoff_location_id,
                c.passenger_count, c.trip_distance_miles, d.trip_duration_seconds, c.rate_code_id, c.payment_type_id,
                c.is_store_and_forward, c.fare_amount, c.extra_amount, c.mta_tax, c.tip_amount, c.tolls_amount,
                c.improvement_surcharge, c.congestion_surcharge, c.airport_fee, c.cbd_congestion_fee, c.total_amount,
                q.dq_flags, @batch_id
            FROM bronze.yellow_tripdata AS b
            CROSS APPLY (
                SELECT
                    TRY_CAST(b.VendorID AS TINYINT)                         AS vendor_id,
                    CAST(b.tpep_pickup_datetime  AS DATETIME2(0))           AS pickup_datetime,
                    CAST(b.tpep_dropoff_datetime AS DATETIME2(0))           AS dropoff_datetime,
                    TRY_CAST(b.PULocationID AS SMALLINT)                    AS pickup_location_id,
                    TRY_CAST(b.DOLocationID AS SMALLINT)                    AS dropoff_location_id,
                    -- Driver-entered; 0 passengers is not a real trip value.
                    CASE WHEN b.passenger_count BETWEEN 1 AND 9
                         THEN CAST(b.passenger_count AS TINYINT) END        AS passenger_count,
                    CAST(b.trip_distance AS DECIMAL(9,2))                   AS trip_distance_miles,
                    -- Dictionary: 99 = Null/unknown. NULL/out-of-range codes join that bucket.
                    COALESCE(TRY_CAST(b.RatecodeID   AS TINYINT), 99)       AS rate_code_id,
                    -- Dictionary: 5 = Unknown.
                    COALESCE(TRY_CAST(b.payment_type AS TINYINT), 5)        AS payment_type_id,
                    CAST(CASE UPPER(TRIM(b.store_and_fwd_flag))
                              WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT)   AS is_store_and_forward,
                    CAST(b.fare_amount           AS DECIMAL(10,2))          AS fare_amount,
                    CAST(b.extra                 AS DECIMAL(10,2))          AS extra_amount,
                    CAST(b.mta_tax               AS DECIMAL(10,2))          AS mta_tax,
                    CAST(b.tip_amount            AS DECIMAL(10,2))          AS tip_amount,
                    CAST(b.tolls_amount          AS DECIMAL(10,2))          AS tolls_amount,
                    CAST(b.improvement_surcharge AS DECIMAL(10,2))          AS improvement_surcharge,
                    CAST(b.congestion_surcharge  AS DECIMAL(10,2))          AS congestion_surcharge,
                    CAST(b.Airport_fee           AS DECIMAL(10,2))          AS airport_fee,
                    CAST(b.cbd_congestion_fee    AS DECIMAL(10,2))          AS cbd_congestion_fee,
                    CAST(b.total_amount          AS DECIMAL(10,2))          AS total_amount
            ) AS c
            CROSS APPLY (
                -- DATEDIFF_BIG: the feeds contain sentinel dates (e.g. an FHV dropoff of
                -- 1900-01-01) whose gap in seconds overflows INT. The rules below use the
                -- BIGINT value; the stored duration is kept only when it fits in an INT.
                SELECT DATEDIFF_BIG(SECOND, c.pickup_datetime, c.dropoff_datetime) AS elapsed_seconds
            ) AS e
            CROSS APPLY (
                SELECT CASE WHEN e.elapsed_seconds BETWEEN -2147483648 AND 2147483647
                            THEN CAST(e.elapsed_seconds AS INT) END AS trip_duration_seconds
            ) AS d
            CROSS APPLY (
                SELECT
                      IIF(c.pickup_datetime < @period_start OR c.pickup_datetime >= @period_end, @dq_out_of_period, 0)
                    | IIF(e.elapsed_seconds < 0,                                          @dq_negative_duration, 0)
                    | IIF(e.elapsed_seconds > @max_trip_seconds,                          @dq_excessive_duration, 0)
                    | IIF(c.trip_distance_miles > @max_trip_miles OR ABS(c.total_amount) > @max_amount, @dq_implausible_value, 0)
                    | IIF(e.elapsed_seconds = 0,                                          @dq_zero_duration, 0)
                    -- Total only: Flex Fare trips (payment_type 0) carry a negative fare_amount
                    -- component on genuine trips; only a negative TOTAL marks a reversal.
                    | IIF(c.total_amount < 0,                                                   @dq_negative_amount, 0)
                    | IIF(c.pickup_location_id IS NULL OR c.dropoff_location_id IS NULL,        @dq_missing_location, 0)
                    | IIF(ABS(  ISNULL(c.fare_amount, 0) + ISNULL(c.extra_amount, 0) + ISNULL(c.mta_tax, 0)
                              + ISNULL(c.tip_amount, 0) + ISNULL(c.tolls_amount, 0) + ISNULL(c.improvement_surcharge, 0)
                              + ISNULL(c.congestion_surcharge, 0) + ISNULL(c.airport_fee, 0) + ISNULL(c.cbd_congestion_fee, 0)
                              - ISNULL(c.total_amount, 0)) > 0.01,                              @dq_amount_not_reconciled, 0)
                    AS dq_flags
            ) AS q;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- silver.green_tripdata  (same rules as yellow, plus trip_type)
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.green_tripdata';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.green_tripdata;

            INSERT INTO silver.green_tripdata WITH (TABLOCK) (
                vendor_id, pickup_datetime, dropoff_datetime, pickup_location_id, dropoff_location_id,
                passenger_count, trip_distance_miles, trip_duration_seconds, rate_code_id, payment_type_id,
                trip_type_id, is_store_and_forward, fare_amount, extra_amount, mta_tax, tip_amount,
                tolls_amount, improvement_surcharge, congestion_surcharge, cbd_congestion_fee, total_amount,
                dq_flags, dwh_batch_id
            )
            SELECT
                c.vendor_id, c.pickup_datetime, c.dropoff_datetime, c.pickup_location_id, c.dropoff_location_id,
                c.passenger_count, c.trip_distance_miles, d.trip_duration_seconds, c.rate_code_id, c.payment_type_id,
                c.trip_type_id, c.is_store_and_forward, c.fare_amount, c.extra_amount, c.mta_tax, c.tip_amount,
                c.tolls_amount, c.improvement_surcharge, c.congestion_surcharge, c.cbd_congestion_fee, c.total_amount,
                q.dq_flags, @batch_id
            FROM bronze.green_tripdata AS b
            CROSS APPLY (
                SELECT
                    TRY_CAST(b.VendorID AS TINYINT)                         AS vendor_id,
                    CAST(b.lpep_pickup_datetime  AS DATETIME2(0))           AS pickup_datetime,
                    CAST(b.lpep_dropoff_datetime AS DATETIME2(0))           AS dropoff_datetime,
                    TRY_CAST(b.PULocationID AS SMALLINT)                    AS pickup_location_id,
                    TRY_CAST(b.DOLocationID AS SMALLINT)                    AS dropoff_location_id,
                    CASE WHEN b.passenger_count BETWEEN 1 AND 9
                         THEN CAST(b.passenger_count AS TINYINT) END        AS passenger_count,
                    CAST(b.trip_distance AS DECIMAL(9,2))                   AS trip_distance_miles,
                    COALESCE(TRY_CAST(b.RatecodeID   AS TINYINT), 99)       AS rate_code_id,
                    COALESCE(TRY_CAST(b.payment_type AS TINYINT), 5)        AS payment_type_id,
                    TRY_CAST(b.trip_type AS TINYINT)                        AS trip_type_id,
                    CAST(CASE UPPER(TRIM(b.store_and_fwd_flag))
                              WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT)   AS is_store_and_forward,
                    CAST(b.fare_amount           AS DECIMAL(10,2))          AS fare_amount,
                    CAST(b.extra                 AS DECIMAL(10,2))          AS extra_amount,
                    CAST(b.mta_tax               AS DECIMAL(10,2))          AS mta_tax,
                    CAST(b.tip_amount            AS DECIMAL(10,2))          AS tip_amount,
                    CAST(b.tolls_amount          AS DECIMAL(10,2))          AS tolls_amount,
                    CAST(b.improvement_surcharge AS DECIMAL(10,2))          AS improvement_surcharge,
                    CAST(b.congestion_surcharge  AS DECIMAL(10,2))          AS congestion_surcharge,
                    CAST(b.cbd_congestion_fee    AS DECIMAL(10,2))          AS cbd_congestion_fee,
                    CAST(b.total_amount          AS DECIMAL(10,2))          AS total_amount
            ) AS c
            CROSS APPLY (
                -- DATEDIFF_BIG: the feeds contain sentinel dates (e.g. an FHV dropoff of
                -- 1900-01-01) whose gap in seconds overflows INT. The rules below use the
                -- BIGINT value; the stored duration is kept only when it fits in an INT.
                SELECT DATEDIFF_BIG(SECOND, c.pickup_datetime, c.dropoff_datetime) AS elapsed_seconds
            ) AS e
            CROSS APPLY (
                SELECT CASE WHEN e.elapsed_seconds BETWEEN -2147483648 AND 2147483647
                            THEN CAST(e.elapsed_seconds AS INT) END AS trip_duration_seconds
            ) AS d
            CROSS APPLY (
                SELECT
                      IIF(c.pickup_datetime < @period_start OR c.pickup_datetime >= @period_end, @dq_out_of_period, 0)
                    | IIF(e.elapsed_seconds < 0,                                          @dq_negative_duration, 0)
                    | IIF(e.elapsed_seconds > @max_trip_seconds,                          @dq_excessive_duration, 0)
                    | IIF(c.trip_distance_miles > @max_trip_miles OR ABS(c.total_amount) > @max_amount, @dq_implausible_value, 0)
                    | IIF(e.elapsed_seconds = 0,                                          @dq_zero_duration, 0)
                    -- Total only: Flex Fare trips (payment_type 0) carry a negative fare_amount
                    -- component on genuine trips; only a negative TOTAL marks a reversal.
                    | IIF(c.total_amount < 0,                                                   @dq_negative_amount, 0)
                    | IIF(c.pickup_location_id IS NULL OR c.dropoff_location_id IS NULL,        @dq_missing_location, 0)
                    | IIF(ABS(  ISNULL(c.fare_amount, 0) + ISNULL(c.extra_amount, 0) + ISNULL(c.mta_tax, 0)
                              + ISNULL(c.tip_amount, 0) + ISNULL(c.tolls_amount, 0) + ISNULL(c.improvement_surcharge, 0)
                              + ISNULL(c.congestion_surcharge, 0) + ISNULL(c.cbd_congestion_fee, 0)
                              - ISNULL(c.total_amount, 0)) > 0.01,                              @dq_amount_not_reconciled, 0)
                    AS dq_flags
            ) AS q;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- silver.fhv_tripdata
        --   - Base numbers are validated against the TLC licence format
        --     'B' + 5 digits. The affiliated base is effectively free text in
        --     the source ('United Cars', '1UBER', 'B3404', lower case, stray
        --     non-ASCII prefixes); invalid values become NULL rather than being
        --     guessed.
        --   - Exact duplicates (same values in every column after cleansing)
        --     are removed with ROW_NUMBER. Profiling found ~3.4K in Jan-2025 and
        --     none in the other feeds, so the (expensive) de-dup sort is only
        --     paid where it is needed; the Silver tests monitor all feeds.
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.fhv_tripdata';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.fhv_tripdata;

            WITH cleansed AS (
                SELECT
                    CASE WHEN UPPER(TRIM(b.dispatching_base_num)) LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                         THEN UPPER(TRIM(b.dispatching_base_num)) END             AS dispatching_base_num,
                    CASE WHEN UPPER(TRIM(b.Affiliated_base_number)) LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                         THEN UPPER(TRIM(b.Affiliated_base_number)) END           AS affiliated_base_num,
                    CAST(b.pickup_datetime  AS DATETIME2(0))                      AS pickup_datetime,
                    CAST(b.dropOff_datetime AS DATETIME2(0))                      AS dropoff_datetime,
                    TRY_CAST(b.PUlocationID AS SMALLINT)                          AS pickup_location_id,
                    TRY_CAST(b.DOlocationID AS SMALLINT)                          AS dropoff_location_id,
                    -- Dictionary: 1 = shared ride, NULL = not shared.
                    CAST(IIF(b.SR_Flag = 1, 1, 0) AS BIT)                         AS is_shared_ride
                FROM bronze.fhv_tripdata AS b
            ),
            deduplicated AS (
                SELECT
                    cleansed.*,
                    ROW_NUMBER() OVER (
                        PARTITION BY dispatching_base_num, affiliated_base_num, pickup_datetime, dropoff_datetime,
                                     pickup_location_id, dropoff_location_id, is_shared_ride
                        ORDER BY (SELECT NULL)
                    ) AS duplicate_rank
                FROM cleansed
            )
            INSERT INTO silver.fhv_tripdata WITH (TABLOCK) (
                dispatching_base_num, affiliated_base_num, pickup_datetime, dropoff_datetime,
                pickup_location_id, dropoff_location_id, trip_duration_seconds, is_shared_ride,
                dq_flags, dwh_batch_id
            )
            SELECT
                c.dispatching_base_num, c.affiliated_base_num, c.pickup_datetime, c.dropoff_datetime,
                c.pickup_location_id, c.dropoff_location_id, d.trip_duration_seconds, c.is_shared_ride,
                q.dq_flags, @batch_id
            FROM deduplicated AS c
            CROSS APPLY (
                -- DATEDIFF_BIG: the feeds contain sentinel dates (e.g. an FHV dropoff of
                -- 1900-01-01) whose gap in seconds overflows INT. The rules below use the
                -- BIGINT value; the stored duration is kept only when it fits in an INT.
                SELECT DATEDIFF_BIG(SECOND, c.pickup_datetime, c.dropoff_datetime) AS elapsed_seconds
            ) AS e
            CROSS APPLY (
                SELECT CASE WHEN e.elapsed_seconds BETWEEN -2147483648 AND 2147483647
                            THEN CAST(e.elapsed_seconds AS INT) END AS trip_duration_seconds
            ) AS d
            CROSS APPLY (
                SELECT
                      IIF(c.pickup_datetime < @period_start OR c.pickup_datetime >= @period_end, @dq_out_of_period, 0)
                    | IIF(e.elapsed_seconds < 0,                                   @dq_negative_duration, 0)
                    | IIF(e.elapsed_seconds > @max_trip_seconds,                   @dq_excessive_duration, 0)
                    | IIF(e.elapsed_seconds = 0,                                   @dq_zero_duration, 0)
                    | IIF(c.pickup_location_id IS NULL OR c.dropoff_location_id IS NULL, @dq_missing_location, 0)
                    AS dq_flags
            ) AS q
            WHERE c.duplicate_rank = 1;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- silver.fhvhv_tripdata
        --   - Source names conformed: trip_miles -> trip_distance_miles,
        --     trip_time -> trip_duration_seconds, tips -> tip_amount,
        --     tolls -> tolls_amount, bcf -> black_car_fund_amount.
        --   - passenger_total_amount: HVFHV has no total column. The rider's
        --     total is fare + tolls + BCF + sales tax + surcharges + tips, which
        --     makes it comparable with the taxi total_amount in Gold.
        --   - pickup_wait_seconds: request -> pickup. ~1% of trips are picked up
        --     BEFORE the request timestamp (scheduled rides / clock skew); a
        --     negative wait is meaningless, so it is set to NULL for those.
        -- ---------------------------------------------------------------------
        SET @object_name = N'silver.fhvhv_tripdata';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE silver.fhvhv_tripdata;

            INSERT INTO silver.fhvhv_tripdata WITH (TABLOCK) (
                hvfhs_license_num, dispatching_base_num, originating_base_num, request_datetime,
                on_scene_datetime, pickup_datetime, dropoff_datetime, pickup_location_id, dropoff_location_id,
                trip_distance_miles, trip_duration_seconds, pickup_wait_seconds, base_passenger_fare,
                tolls_amount, black_car_fund_amount, sales_tax, congestion_surcharge, airport_fee,
                cbd_congestion_fee, tip_amount, passenger_total_amount, driver_pay, is_shared_request,
                is_shared_match, is_access_a_ride, is_wav_request, is_wav_match, dq_flags, dwh_batch_id
            )
            SELECT
                c.hvfhs_license_num, c.dispatching_base_num, c.originating_base_num, c.request_datetime,
                c.on_scene_datetime, c.pickup_datetime, c.dropoff_datetime, c.pickup_location_id, c.dropoff_location_id,
                c.trip_distance_miles, c.trip_duration_seconds, d.pickup_wait_seconds, c.base_passenger_fare,
                c.tolls_amount, c.black_car_fund_amount, c.sales_tax, c.congestion_surcharge, c.airport_fee,
                c.cbd_congestion_fee, c.tip_amount, d.passenger_total_amount, c.driver_pay, c.is_shared_request,
                c.is_shared_match, c.is_access_a_ride, c.is_wav_request, c.is_wav_match, q.dq_flags, @batch_id
            FROM bronze.fhvhv_tripdata AS b
            CROSS APPLY (
                SELECT
                    UPPER(TRIM(b.hvfhs_license_num))                               AS hvfhs_license_num,
                    CASE WHEN UPPER(TRIM(b.dispatching_base_num)) LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                         THEN UPPER(TRIM(b.dispatching_base_num)) END              AS dispatching_base_num,
                    CASE WHEN UPPER(TRIM(b.originating_base_num)) LIKE 'B[0-9][0-9][0-9][0-9][0-9]'
                         THEN UPPER(TRIM(b.originating_base_num)) END              AS originating_base_num,
                    CAST(b.request_datetime  AS DATETIME2(0))                      AS request_datetime,
                    CAST(b.on_scene_datetime AS DATETIME2(0))                      AS on_scene_datetime,
                    CAST(b.pickup_datetime   AS DATETIME2(0))                      AS pickup_datetime,
                    CAST(b.dropoff_datetime  AS DATETIME2(0))                      AS dropoff_datetime,
                    TRY_CAST(b.PULocationID AS SMALLINT)                           AS pickup_location_id,
                    TRY_CAST(b.DOLocationID AS SMALLINT)                           AS dropoff_location_id,
                    CAST(b.trip_miles AS DECIMAL(9,2))                             AS trip_distance_miles,
                    TRY_CAST(b.trip_time AS INT)                                   AS trip_duration_seconds,
                    CAST(b.base_passenger_fare  AS DECIMAL(10,2))                  AS base_passenger_fare,
                    CAST(b.tolls                AS DECIMAL(10,2))                  AS tolls_amount,
                    CAST(b.bcf                  AS DECIMAL(10,2))                  AS black_car_fund_amount,
                    CAST(b.sales_tax            AS DECIMAL(10,2))                  AS sales_tax,
                    CAST(b.congestion_surcharge AS DECIMAL(10,2))                  AS congestion_surcharge,
                    CAST(b.airport_fee          AS DECIMAL(10,2))                  AS airport_fee,
                    CAST(b.cbd_congestion_fee   AS DECIMAL(10,2))                  AS cbd_congestion_fee,
                    CAST(b.tips                 AS DECIMAL(10,2))                  AS tip_amount,
                    CAST(b.driver_pay           AS DECIMAL(10,2))                  AS driver_pay,
                    CAST(CASE UPPER(TRIM(b.shared_request_flag)) WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS is_shared_request,
                    CAST(CASE UPPER(TRIM(b.shared_match_flag))   WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS is_shared_match,
                    CAST(CASE UPPER(TRIM(b.access_a_ride_flag))  WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS is_access_a_ride,
                    CAST(CASE UPPER(TRIM(b.wav_request_flag))    WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS is_wav_request,
                    CAST(CASE UPPER(TRIM(b.wav_match_flag))      WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS is_wav_match
            ) AS c
            CROSS APPLY (
                SELECT
                    DATEDIFF_BIG(SECOND, c.pickup_datetime, c.dropoff_datetime)   AS elapsed_seconds,
                    CASE WHEN c.pickup_datetime >= c.request_datetime
                         THEN DATEDIFF(SECOND, c.request_datetime, c.pickup_datetime) END AS pickup_wait_seconds,
                    CAST(  ISNULL(c.base_passenger_fare, 0) + ISNULL(c.tolls_amount, 0)
                         + ISNULL(c.black_car_fund_amount, 0) + ISNULL(c.sales_tax, 0)
                         + ISNULL(c.congestion_surcharge, 0) + ISNULL(c.airport_fee, 0)
                         + ISNULL(c.cbd_congestion_fee, 0) + ISNULL(c.tip_amount, 0)
                         AS DECIMAL(10,2))                                          AS passenger_total_amount
            ) AS d
            CROSS APPLY (
                SELECT
                      IIF(c.pickup_datetime < @period_start OR c.pickup_datetime >= @period_end, @dq_out_of_period, 0)
                    | IIF(d.elapsed_seconds < 0,                                         @dq_negative_duration, 0)
                    | IIF(d.elapsed_seconds > @max_trip_seconds,                         @dq_excessive_duration, 0)
                    | IIF(c.trip_distance_miles > @max_trip_miles OR ABS(d.passenger_total_amount) > @max_amount, @dq_implausible_value, 0)
                    | IIF(d.elapsed_seconds = 0,                                         @dq_zero_duration, 0)
                    | IIF(c.base_passenger_fare < 0,                                     @dq_negative_amount, 0)
                    | IIF(c.pickup_location_id IS NULL OR c.dropoff_location_id IS NULL, @dq_missing_location, 0)
                    AS dq_flags
            ) AS q;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'silver', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        EXEC etl.write_load_log @batch_id, 'silver', N'silver.load_silver', 'Succeeded', NULL, @layer_start;

        PRINT '================================================';
        PRINT 'Loading Silver Layer is Completed';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;   -- the table being loaded keeps its previous contents

        DECLARE @error_number    INT            = ERROR_NUMBER(),
                @error_line      INT            = ERROR_LINE(),
                @error_procedure NVARCHAR(128)  = ERROR_PROCEDURE(),
                @error_message   NVARCHAR(4000) = ERROR_MESSAGE();

        PRINT '================================================';
        PRINT 'ERROR OCCURRED DURING LOADING SILVER LAYER';
        PRINT CONCAT('Object       : ', @object_name);
        PRINT CONCAT('Error Number : ', @error_number);
        PRINT CONCAT('Error Line   : ', @error_line);
        PRINT CONCAT('Error Message: ', @error_message);
        PRINT '================================================';

        SET @step_start = ISNULL(@step_start, @layer_start);

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'silver', @object_name = @object_name,
            @status = 'Failed', @start_time = @step_start,
            @error_number = @error_number, @error_line = @error_line,
            @error_procedure = @error_procedure, @error_message = @error_message;

        THROW;
    END CATCH;
END;
GO
