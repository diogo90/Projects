/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
Script Purpose:
    Builds the star schema in the 'gold' schema.

    Dimensions - SCD Type 1 upsert (overwrite changed attributes, insert new
                 members, never delete):
                   dim_service, dim_vendor, dim_payment_type, dim_rate_code,
                   dim_zone, dim_weather  (sourced from Silver)
                   dim_date, dim_time, dim_trip_profile  (generated)
    Facts      - full load (truncate & insert):
                   fact_trips         <- union of the 4 Silver trip tables
                   fact_trips_hourly  <- aggregated from fact_trips

Design notes:
    - Why upsert dimensions instead of truncate & insert?
        1. TRUNCATE is not allowed on a table referenced by a FOREIGN KEY.
        2. Re-inserting would re-number IDENTITY surrogate keys every run,
           breaking anything that cached them (BI extracts, saved filters).
      An upsert keeps keys stable and is exactly what SCD Type 1 means:
      attributes are overwritten in place, no history is kept.
    - Why UPDATE + INSERT rather than MERGE?
        MERGE has a history of bugs (notably with filtered indexes, which the
        dimensions use for their business keys) and concurrency caveats.
        Two explicit statements inside one transaction are easier to reason
        about and to debug.
    - Change detection uses "WHERE EXISTS (SELECT d.cols EXCEPT SELECT s.cols)".
      EXCEPT compares NULLs as equal, so it only touches rows that really
      changed, without a long list of "OR (a <> b OR a IS NULL AND ...)".
    - Reject filter: rows whose dq_flags hit a REJECT-severity rule in
      etl.dq_rule are excluded. The mask is computed from the catalogue, so
      re-classifying a rule needs no code change.
    - Reconciliation: after the fact load, rows inserted must equal the
      eligible rows in Silver, otherwise the transaction is rolled back.

Parameters:
    @batch_id  Optional. Supplied by etl.run_pipeline; generated if NULL.

Usage Example:
    EXEC gold.load_gold;
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE gold.load_gold
    @batch_id INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @layer_start   DATETIME2(3) = SYSDATETIME(),
            @step_start    DATETIME2(3),
            @object_name   NVARCHAR(128) = N'gold.load_gold',
            @rows          BIGINT,
            @rows_updated  BIGINT,
            @expected_rows BIGINT,
            @message       NVARCHAR(2048);

    DECLARE @period_start        DATE,
            @calendar_start      DATE,
            @calendar_end        DATE,
            @congestion_start    DATE = '2025-01-05',   -- MTA Congestion Relief Zone toll go-live
            @reject_mask         INT,
            @negative_amount_bit INT;

    IF @batch_id IS NULL
        SET @batch_id = NEXT VALUE FOR etl.seq_batch_id;

    BEGIN TRY
        PRINT '================================================';
        PRINT CONCAT('Loading Gold Layer | batch_id = ', @batch_id);
        PRINT '================================================';

        -- Calendar covers the reporting year +/- 1 year; new years are added
        -- automatically as later months are loaded (insert-missing logic).
        SELECT @period_start = MIN(reporting_month) FROM etl.file_manifest;
        IF @period_start IS NULL
            THROW 50020, 'etl.file_manifest is empty. Run bronze.load_bronze first.', 1;

        SET @calendar_start = DATEFROMPARTS(YEAR(@period_start) - 1, 1, 1);
        SET @calendar_end   = DATEFROMPARTS(YEAR(@period_start) + 1, 12, 31);

        SELECT @reject_mask = ISNULL(SUM(rule_bit), 0) FROM etl.dq_rule WHERE severity = 'REJECT';
        SELECT @negative_amount_bit = rule_bit FROM etl.dq_rule WHERE rule_code = 'NEGATIVE_AMOUNT';
        IF @negative_amount_bit IS NULL
            THROW 50021, 'etl.dq_rule is missing rule NEGATIVE_AMOUNT.', 1;

        -- =====================================================================
        -- GENERATED DIMENSIONS (insert missing members only)
        -- =====================================================================
        PRINT '------------------------------------------------';
        PRINT 'Generated dimensions';
        PRINT '------------------------------------------------';

        -- ---------------------------------------------------------------------
        -- gold.dim_date
        --   Day and month names come from CHOOSE rather than DATENAME, and day
        --   of week from date arithmetic rather than DATEPART(WEEKDAY), so the
        --   result does not depend on the session's LANGUAGE / DATEFIRST.
        --   US federal holidays are computed by rule (e.g. "3rd Monday of
        --   January"), so the dimension works for any year without a
        --   hand-maintained holiday list. Observed-day shifts are not applied.
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_date';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            WITH tally AS (
                SELECT TOP (DATEDIFF(DAY, @calendar_start, @calendar_end) + 1)
                       ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
                FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
            ),
            calendar AS (
                SELECT
                    d.full_date,
                    DAY(d.full_date)                                   AS day_of_month,
                    MONTH(d.full_date)                                 AS month_number,
                    YEAR(d.full_date)                                  AS year_number,
                    DATEDIFF(DAY, '19000101', d.full_date) % 7 + 1     AS day_of_week,   -- 1900-01-01 was a Monday
                    (DAY(d.full_date) - 1) / 7 + 1                     AS weekday_occurrence,
                    CASE WHEN DAY(d.full_date) + 7 > DAY(EOMONTH(d.full_date)) THEN 1 ELSE 0 END AS is_last_occurrence
                FROM tally
                CROSS APPLY (SELECT DATEADD(DAY, tally.n, @calendar_start) AS full_date) AS d
            ),
            holidays AS (
                SELECT
                    c.*,
                    CASE
                        WHEN c.month_number = 1  AND c.day_of_month = 1                                       THEN 'New Year''s Day'
                        WHEN c.month_number = 1  AND c.day_of_week = 1 AND c.weekday_occurrence = 3           THEN 'Martin Luther King Jr. Day'
                        WHEN c.month_number = 2  AND c.day_of_week = 1 AND c.weekday_occurrence = 3           THEN 'Presidents'' Day'
                        WHEN c.month_number = 5  AND c.day_of_week = 1 AND c.is_last_occurrence = 1           THEN 'Memorial Day'
                        WHEN c.month_number = 6  AND c.day_of_month = 19                                      THEN 'Juneteenth'
                        WHEN c.month_number = 7  AND c.day_of_month = 4                                       THEN 'Independence Day'
                        WHEN c.month_number = 9  AND c.day_of_week = 1 AND c.weekday_occurrence = 1           THEN 'Labor Day'
                        WHEN c.month_number = 10 AND c.day_of_week = 1 AND c.weekday_occurrence = 2           THEN 'Columbus Day'
                        WHEN c.month_number = 11 AND c.day_of_month = 11                                      THEN 'Veterans Day'
                        WHEN c.month_number = 11 AND c.day_of_week = 4 AND c.weekday_occurrence = 4           THEN 'Thanksgiving Day'
                        WHEN c.month_number = 12 AND c.day_of_month = 25                                      THEN 'Christmas Day'
                    END AS holiday_name
                FROM calendar AS c
            )
            INSERT INTO gold.dim_date (
                date_key, full_date, day_of_month, day_of_week, day_name, day_name_short, is_weekend,
                iso_week_of_year, month_number, month_name, month_name_short, quarter_number, year_number,
                year_month, is_holiday, holiday_name, is_working_day, is_congestion_pricing_active
            )
            SELECT
                h.year_number * 10000 + h.month_number * 100 + h.day_of_month,
                h.full_date,
                h.day_of_month,
                h.day_of_week,
                CHOOSE(h.day_of_week, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
                CHOOSE(h.day_of_week, 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'),
                IIF(h.day_of_week IN (6, 7), 1, 0),
                DATEPART(ISO_WEEK, h.full_date),
                h.month_number,
                CHOOSE(h.month_number, 'January', 'February', 'March', 'April', 'May', 'June', 'July',
                                       'August', 'September', 'October', 'November', 'December'),
                CHOOSE(h.month_number, 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'),
                (h.month_number - 1) / 3 + 1,
                h.year_number,
                CONCAT(h.year_number, '-', RIGHT(CONCAT('0', h.month_number), 2)),
                IIF(h.holiday_name IS NOT NULL, 1, 0),
                h.holiday_name,
                IIF(h.day_of_week IN (6, 7) OR h.holiday_name IS NOT NULL, 0, 1),
                IIF(h.full_date >= @congestion_start, 1, 0)
            FROM holidays AS h
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date AS d WHERE d.full_date = h.full_date);

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_time (1,440 minutes)
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_time';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            WITH minutes AS (
                SELECT TOP (1440) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS minute_of_day
                FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
            ),
            parts AS (
                SELECT minute_of_day / 60 AS hour_24, minute_of_day % 60 AS minute_of_hour
                FROM minutes
            )
            INSERT INTO gold.dim_time (
                time_key, time_of_day, hour_24, minute_of_hour, hour_label, hour_12_label, quarter_hour_label, day_part
            )
            SELECT
                p.hour_24 * 100 + p.minute_of_hour,
                TIMEFROMPARTS(p.hour_24, p.minute_of_hour, 0, 0, 0),
                p.hour_24,
                p.minute_of_hour,
                CONCAT(RIGHT(CONCAT('0', p.hour_24), 2), ':00'),
                CONCAT(IIF(p.hour_24 % 12 = 0, 12, p.hour_24 % 12), IIF(p.hour_24 < 12, ' AM', ' PM')),
                CONCAT(RIGHT(CONCAT('0', p.hour_24), 2), ':', RIGHT(CONCAT('0', p.minute_of_hour / 15 * 15), 2)),
                CASE
                    WHEN p.hour_24 BETWEEN 0  AND 5  THEN 'Overnight'
                    WHEN p.hour_24 BETWEEN 6  AND 9  THEN 'Morning Rush'
                    WHEN p.hour_24 BETWEEN 10 AND 15 THEN 'Midday'
                    WHEN p.hour_24 BETWEEN 16 AND 19 THEN 'Evening Rush'
                    ELSE 'Evening'
                END
            FROM parts AS p
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_time AS t WHERE t.time_key = p.hour_24 * 100 + p.minute_of_hour);

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_trip_profile (junk dimension: every combination of flags)
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_trip_profile';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            WITH flag AS (SELECT v FROM (VALUES ('Yes'), ('No'), ('N/A')) AS f (v)),
            combinations AS (
                SELECT h.hail_type,
                       sf.v AS store_and_forward, srr.v AS shared_ride_requested, srm.v AS shared_ride_matched,
                       wr.v AS wav_requested,     wm.v  AS wav_matched,          aar.v AS access_a_ride
                FROM (VALUES ('Street-hail'), ('Dispatch'), ('Unknown')) AS h (hail_type)
                CROSS JOIN flag AS sf  CROSS JOIN flag AS srr CROSS JOIN flag AS srm
                CROSS JOIN flag AS wr  CROSS JOIN flag AS wm  CROSS JOIN flag AS aar
            )
            INSERT INTO gold.dim_trip_profile (
                hail_type, store_and_forward, shared_ride_requested, shared_ride_matched,
                wav_requested, wav_matched, access_a_ride
            )
            SELECT c.*
            FROM combinations AS c
            WHERE NOT EXISTS (
                SELECT 1 FROM gold.dim_trip_profile AS p
                WHERE p.hail_type = c.hail_type AND p.store_and_forward = c.store_and_forward
                  AND p.shared_ride_requested = c.shared_ride_requested AND p.shared_ride_matched = c.shared_ride_matched
                  AND p.wav_requested = c.wav_requested AND p.wav_matched = c.wav_matched
                  AND p.access_a_ride = c.access_a_ride
            );

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- =====================================================================
        -- SOURCED DIMENSIONS (SCD Type 1 upsert)
        -- Pattern: stage source rows in a temp table -> UPDATE changed rows ->
        --          INSERT new rows, all in one transaction.
        -- =====================================================================
        PRINT '------------------------------------------------';
        PRINT 'Sourced dimensions (SCD Type 1)';
        PRINT '------------------------------------------------';

        -- ---------------------------------------------------------------------
        -- gold.dim_service
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_service';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_service;
        SELECT
            code                                   AS service_code,
            code_description                       AS service_name,
            ISNULL(code_group, 'Unknown')          AS service_category,
            CAST(IIF(code = 'fhv', 0, 1) AS BIT)   AS has_fare_data   -- FHV records carry no fares
        INTO #src_service
        FROM silver.tlc_code_values
        WHERE code_type = 'service_type';

        BEGIN TRANSACTION;
            UPDATE d
            SET d.service_name        = s.service_name,
                d.service_category    = s.service_category,
                d.has_fare_data       = s.has_fare_data,
                d.dwh_update_datetime = SYSDATETIME()
            FROM gold.dim_service AS d
            JOIN #src_service     AS s ON s.service_code = d.service_code
            WHERE EXISTS (SELECT d.service_name, d.service_category, d.has_fare_data
                          EXCEPT
                          SELECT s.service_name, s.service_category, s.has_fare_data);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_service (service_code, service_name, service_category, has_fare_data)
            SELECT s.service_code, s.service_name, s.service_category, s.has_fare_data
            FROM #src_service AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_service AS d WHERE d.service_code = s.service_code);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_vendor
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_vendor';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_vendor;
        SELECT
            code                          AS vendor_code,
            code_description              AS vendor_name,
            ISNULL(code_group, 'Unknown') AS vendor_type
        INTO #src_vendor
        FROM silver.tlc_code_values
        WHERE code_type = 'vendor';

        BEGIN TRANSACTION;
            UPDATE d
            SET d.vendor_name         = s.vendor_name,
                d.vendor_type         = s.vendor_type,
                d.dwh_update_datetime = SYSDATETIME()
            FROM gold.dim_vendor AS d
            JOIN #src_vendor     AS s ON s.vendor_code = d.vendor_code
            WHERE EXISTS (SELECT d.vendor_name, d.vendor_type EXCEPT SELECT s.vendor_name, s.vendor_type);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_vendor (vendor_code, vendor_name, vendor_type)
            SELECT s.vendor_code, s.vendor_name, s.vendor_type
            FROM #src_vendor AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_vendor AS d WHERE d.vendor_code = s.vendor_code);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_payment_type
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_payment_type';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_payment_type;
        SELECT
            TRY_CAST(code AS TINYINT)     AS payment_type_code,
            code_description              AS payment_type_name,
            ISNULL(code_group, 'Unknown') AS payment_status
        INTO #src_payment_type
        FROM silver.tlc_code_values
        WHERE code_type = 'payment_type'
          AND TRY_CAST(code AS TINYINT) IS NOT NULL;

        BEGIN TRANSACTION;
            UPDATE d
            SET d.payment_type_name   = s.payment_type_name,
                d.payment_status      = s.payment_status,
                d.dwh_update_datetime = SYSDATETIME()
            FROM gold.dim_payment_type AS d
            JOIN #src_payment_type     AS s ON s.payment_type_code = d.payment_type_code
            WHERE EXISTS (SELECT d.payment_type_name, d.payment_status EXCEPT SELECT s.payment_type_name, s.payment_status);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_payment_type (payment_type_code, payment_type_name, payment_status)
            SELECT s.payment_type_code, s.payment_type_name, s.payment_status
            FROM #src_payment_type AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_payment_type AS d WHERE d.payment_type_code = s.payment_type_code);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_rate_code
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_rate_code';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_rate_code;
        SELECT
            TRY_CAST(code AS TINYINT)     AS rate_code_id,
            code_description              AS rate_code_name,
            ISNULL(code_group, 'Unknown') AS rate_type
        INTO #src_rate_code
        FROM silver.tlc_code_values
        WHERE code_type = 'rate_code'
          AND TRY_CAST(code AS TINYINT) IS NOT NULL;

        BEGIN TRANSACTION;
            UPDATE d
            SET d.rate_code_name      = s.rate_code_name,
                d.rate_type           = s.rate_type,
                d.dwh_update_datetime = SYSDATETIME()
            FROM gold.dim_rate_code AS d
            JOIN #src_rate_code     AS s ON s.rate_code_id = d.rate_code_id
            WHERE EXISTS (SELECT d.rate_code_name, d.rate_type EXCEPT SELECT s.rate_code_name, s.rate_type);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_rate_code (rate_code_id, rate_code_name, rate_type)
            SELECT s.rate_code_id, s.rate_code_name, s.rate_type
            FROM #src_rate_code AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_rate_code AS d WHERE d.rate_code_id = s.rate_code_id);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_zone
        --   Derived flags make common filters one click in a BI tool.
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_zone';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_zone;
        SELECT
            location_id,
            zone_name,
            borough,
            service_zone,
            CAST(IIF(service_zone IN ('Airports', 'EWR'), 1, 0) AS BIT)                                  AS is_airport,
            CAST(IIF(service_zone = 'Yellow Zone', 1, 0) AS BIT)                                         AS is_yellow_zone,
            CAST(IIF(borough IN ('Manhattan', 'Brooklyn', 'Queens', 'Bronx', 'Staten Island'), 1, 0) AS BIT) AS is_within_nyc
        INTO #src_zone
        FROM silver.tlc_taxi_zone_lookup;

        BEGIN TRANSACTION;
            UPDATE d
            SET d.zone_name           = s.zone_name,
                d.borough             = s.borough,
                d.service_zone        = s.service_zone,
                d.is_airport          = s.is_airport,
                d.is_yellow_zone      = s.is_yellow_zone,
                d.is_within_nyc       = s.is_within_nyc,
                d.dwh_update_datetime = SYSDATETIME()
            FROM gold.dim_zone AS d
            JOIN #src_zone     AS s ON s.location_id = d.location_id
            WHERE EXISTS (SELECT d.zone_name, d.borough, d.service_zone, d.is_airport, d.is_yellow_zone, d.is_within_nyc
                          EXCEPT
                          SELECT s.zone_name, s.borough, s.service_zone, s.is_airport, s.is_yellow_zone, s.is_within_nyc);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_zone (location_id, zone_name, borough, service_zone, is_airport, is_yellow_zone, is_within_nyc)
            SELECT s.location_id, s.zone_name, s.borough, s.service_zone, s.is_airport, s.is_yellow_zone, s.is_within_nyc
            FROM #src_zone AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_zone AS d WHERE d.location_id = s.location_id);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.dim_weather
        --   Bands use common meteorological thresholds (hourly precipitation:
        --   light < 2.5 mm, moderate < 7.6 mm, heavy >= 7.6 mm).
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.dim_weather';
        SET @step_start  = SYSDATETIME();

        DROP TABLE IF EXISTS #src_weather;
        SELECT
            YEAR(w.weather_datetime) * 1000000 + MONTH(w.weather_datetime) * 10000
              + DAY(w.weather_datetime) * 100 + DATEPART(HOUR, w.weather_datetime)          AS weather_key,
            w.weather_datetime,
            w.temperature_c,
            CAST(w.temperature_c * 9 / 5 + 32 AS DECIMAL(4,1))                               AS temperature_f,
            w.apparent_temperature_c,
            CASE
                WHEN w.temperature_c IS NULL THEN 'Unknown'
                WHEN w.temperature_c < -5    THEN 'Severe Cold'
                WHEN w.temperature_c < 0     THEN 'Freezing'
                WHEN w.temperature_c < 10    THEN 'Cold'
                WHEN w.temperature_c < 20    THEN 'Mild'
                ELSE 'Warm'
            END                                                                              AS temperature_band,
            w.precipitation_mm,
            w.snowfall_cm,
            w.snow_depth_cm,
            CASE
                WHEN w.snowfall_cm > 0 AND w.rain_mm > 0 THEN 'Mixed'
                WHEN w.snowfall_cm > 0                   THEN 'Snow'
                WHEN w.precipitation_mm > 0              THEN 'Rain'
                ELSE 'None'
            END                                                                              AS precipitation_type,
            CASE
                WHEN ISNULL(w.precipitation_mm, 0) = 0 THEN 'None'
                WHEN w.precipitation_mm < 2.5          THEN 'Light'
                WHEN w.precipitation_mm < 7.6          THEN 'Moderate'
                ELSE 'Heavy'
            END                                                                              AS precipitation_intensity,
            CAST(IIF(w.precipitation_mm > 0, 1, 0) AS BIT)                                   AS is_precipitating,
            w.weather_code,
            w.weather_condition,
            w.cloud_cover_pct,
            w.wind_speed_kmh
        INTO #src_weather
        FROM silver.openmeteo_weather_hourly AS w;

        BEGIN TRANSACTION;
            UPDATE d
            SET d.weather_datetime        = s.weather_datetime,
                d.temperature_c           = s.temperature_c,
                d.temperature_f           = s.temperature_f,
                d.apparent_temperature_c  = s.apparent_temperature_c,
                d.temperature_band        = s.temperature_band,
                d.precipitation_mm        = s.precipitation_mm,
                d.snowfall_cm             = s.snowfall_cm,
                d.snow_depth_cm           = s.snow_depth_cm,
                d.precipitation_type      = s.precipitation_type,
                d.precipitation_intensity = s.precipitation_intensity,
                d.is_precipitating        = s.is_precipitating,
                d.weather_code            = s.weather_code,
                d.weather_condition       = s.weather_condition,
                d.cloud_cover_pct         = s.cloud_cover_pct,
                d.wind_speed_kmh          = s.wind_speed_kmh,
                d.dwh_update_datetime     = SYSDATETIME()
            FROM gold.dim_weather AS d
            JOIN #src_weather     AS s ON s.weather_key = d.weather_key
            WHERE EXISTS (SELECT d.temperature_c, d.apparent_temperature_c, d.precipitation_mm, d.snowfall_cm,
                                 d.snow_depth_cm, d.weather_code, d.weather_condition, d.cloud_cover_pct, d.wind_speed_kmh,
                                 d.temperature_band, d.precipitation_type, d.precipitation_intensity
                          EXCEPT
                          SELECT s.temperature_c, s.apparent_temperature_c, s.precipitation_mm, s.snowfall_cm,
                                 s.snow_depth_cm, s.weather_code, s.weather_condition, s.cloud_cover_pct, s.wind_speed_kmh,
                                 s.temperature_band, s.precipitation_type, s.precipitation_intensity);
            SET @rows_updated = ROWCOUNT_BIG();

            INSERT INTO gold.dim_weather (
                weather_key, weather_datetime, temperature_c, temperature_f, apparent_temperature_c, temperature_band,
                precipitation_mm, snowfall_cm, snow_depth_cm, precipitation_type, precipitation_intensity,
                is_precipitating, weather_code, weather_condition, cloud_cover_pct, wind_speed_kmh
            )
            SELECT
                s.weather_key, s.weather_datetime, s.temperature_c, s.temperature_f, s.apparent_temperature_c, s.temperature_band,
                s.precipitation_mm, s.snowfall_cm, s.snow_depth_cm, s.precipitation_type, s.precipitation_intensity,
                s.is_precipitating, s.weather_code, s.weather_condition, s.cloud_cover_pct, s.wind_speed_kmh
            FROM #src_weather AS s
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_weather AS d WHERE d.weather_key = s.weather_key);
            SET @rows = ROWCOUNT_BIG() + @rows_updated;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- =====================================================================
        -- FACTS (truncate & insert)
        -- =====================================================================
        PRINT '------------------------------------------------';
        PRINT 'Facts';
        PRINT '------------------------------------------------';

        -- ---------------------------------------------------------------------
        -- gold.fact_trips
        --   1. UNION ALL conforms the four Silver feeds to one shape. Measures a
        --      feed does not have are NULL; flags become 'Yes'/'No'/'N/A' to
        --      match the junk dimension.
        --   2. Surrogate keys:
        --        date/time/weather -> arithmetic on the timestamp (smart keys)
        --        zone/vendor/payment/rate/profile -> lookup on the business key
        --        missing lookup -> -1 (Unknown); attribute the service never
        --        reports -> -2 (Not Applicable).
        --      A missing service or trip-profile match is left NULL on purpose:
        --      the NOT NULL constraint then fails the load loudly instead of
        --      hiding a modelling gap behind -1.
        --   3. trip_count = 0 for reversal/refund rows (NEGATIVE_AMOUNT), so
        --      revenue nets correctly without double counting trips.
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.fact_trips';
        SET @step_start  = SYSDATETIME();

        SELECT @expected_rows =
              (SELECT COUNT_BIG(*) FROM silver.yellow_tripdata WHERE dq_flags & @reject_mask = 0)
            + (SELECT COUNT_BIG(*) FROM silver.green_tripdata  WHERE dq_flags & @reject_mask = 0)
            + (SELECT COUNT_BIG(*) FROM silver.fhv_tripdata    WHERE dq_flags & @reject_mask = 0)
            + (SELECT COUNT_BIG(*) FROM silver.fhvhv_tripdata  WHERE dq_flags & @reject_mask = 0);

        BEGIN TRANSACTION;
            TRUNCATE TABLE gold.fact_trips;

            INSERT INTO gold.fact_trips WITH (TABLOCK) (
                service_key, vendor_key, pickup_date_key, pickup_time_key, pickup_zone_key, dropoff_zone_key,
                payment_type_key, rate_code_key, trip_profile_key, weather_key,
                source_trip_id, dispatching_base_num, pickup_datetime, dropoff_datetime,
                trip_count, passenger_count, trip_distance_miles, trip_duration_seconds, pickup_wait_seconds,
                fare_amount, extra_amount, mta_tax, improvement_surcharge, black_car_fund_amount, sales_tax,
                tolls_amount, congestion_surcharge, airport_fee, cbd_congestion_fee, tip_amount, total_amount,
                driver_pay, dq_flags, dwh_batch_id
            )
            SELECT
                ds.service_key,
                CASE WHEN t.service_code = 'fhv'            THEN -2 ELSE ISNULL(dv.vendor_key, -1)       END,
                k.date_key,
                k.time_key,
                ISNULL(pz.zone_key, -1),
                ISNULL(dz.zone_key, -1),
                CASE WHEN t.service_code IN ('fhv', 'fhvhv') THEN -2 ELSE ISNULL(dp.payment_type_key, -1) END,
                CASE WHEN t.service_code IN ('fhv', 'fhvhv') THEN -2 ELSE ISNULL(dr.rate_code_key, -1)    END,
                tp.trip_profile_key,
                ISNULL(dw.weather_key, -1),
                t.source_trip_id,
                t.dispatching_base_num,
                t.pickup_datetime,
                t.dropoff_datetime,
                IIF(t.dq_flags & @negative_amount_bit <> 0, 0, 1),
                t.passenger_count, t.trip_distance_miles, t.trip_duration_seconds, t.pickup_wait_seconds,
                t.fare_amount, t.extra_amount, t.mta_tax, t.improvement_surcharge, t.black_car_fund_amount, t.sales_tax,
                t.tolls_amount, t.congestion_surcharge, t.airport_fee, t.cbd_congestion_fee, t.tip_amount, t.total_amount,
                t.driver_pay,
                t.dq_flags,
                @batch_id
            FROM (
                -- Yellow taxi
                SELECT
                    'yellow' AS service_code, y.trip_id AS source_trip_id,
                    CAST(y.vendor_id AS VARCHAR(10)) AS vendor_code,
                    y.payment_type_id, y.rate_code_id,
                    'Unknown' AS hail_type,  -- yellow does not report street-hail vs dispatch
                    CASE y.is_store_and_forward WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END AS store_and_forward,
                    'N/A' AS shared_ride_requested, 'N/A' AS shared_ride_matched,
                    'N/A' AS wav_requested, 'N/A' AS wav_matched, 'N/A' AS access_a_ride,
                    CAST(NULL AS CHAR(6)) AS dispatching_base_num,
                    y.pickup_datetime, y.dropoff_datetime, y.pickup_location_id, y.dropoff_location_id,
                    y.passenger_count, y.trip_distance_miles, y.trip_duration_seconds, CAST(NULL AS INT) AS pickup_wait_seconds,
                    y.fare_amount, y.extra_amount, y.mta_tax, y.improvement_surcharge,
                    CAST(NULL AS DECIMAL(10,2)) AS black_car_fund_amount, CAST(NULL AS DECIMAL(10,2)) AS sales_tax,
                    y.tolls_amount, y.congestion_surcharge, y.airport_fee, y.cbd_congestion_fee, y.tip_amount, y.total_amount,
                    CAST(NULL AS DECIMAL(10,2)) AS driver_pay,
                    y.dq_flags
                FROM silver.yellow_tripdata AS y
                WHERE y.dq_flags & @reject_mask = 0

                UNION ALL

                -- Green taxi
                SELECT
                    'green', g.trip_id,
                    CAST(g.vendor_id AS VARCHAR(10)),
                    g.payment_type_id, g.rate_code_id,
                    CASE g.trip_type_id WHEN 1 THEN 'Street-hail' WHEN 2 THEN 'Dispatch' ELSE 'Unknown' END,
                    CASE g.is_store_and_forward WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    'N/A', 'N/A', 'N/A', 'N/A', 'N/A',
                    NULL,
                    g.pickup_datetime, g.dropoff_datetime, g.pickup_location_id, g.dropoff_location_id,
                    g.passenger_count, g.trip_distance_miles, g.trip_duration_seconds, NULL,
                    g.fare_amount, g.extra_amount, g.mta_tax, g.improvement_surcharge,
                    NULL, NULL,
                    g.tolls_amount, g.congestion_surcharge, NULL, g.cbd_congestion_fee, g.tip_amount, g.total_amount,
                    NULL,
                    g.dq_flags
                FROM silver.green_tripdata AS g
                WHERE g.dq_flags & @reject_mask = 0

                UNION ALL

                -- FHV: pre-arranged by law (no street hails) -> 'Dispatch'.
                -- SR_Flag marks a shared-ride chain -> shared_ride_matched.
                SELECT
                    'fhv', f.trip_id,
                    NULL,
                    NULL, NULL,
                    'Dispatch',
                    'N/A',
                    'N/A', CASE f.is_shared_ride WHEN 1 THEN 'Yes' ELSE 'No' END,
                    'N/A', 'N/A', 'N/A',
                    f.dispatching_base_num,
                    f.pickup_datetime, f.dropoff_datetime, f.pickup_location_id, f.dropoff_location_id,
                    NULL, NULL, f.trip_duration_seconds, NULL,
                    NULL, NULL, NULL, NULL,
                    NULL, NULL,
                    NULL, NULL, NULL, NULL, NULL, NULL,
                    NULL,
                    f.dq_flags
                FROM silver.fhv_tripdata AS f
                WHERE f.dq_flags & @reject_mask = 0

                UNION ALL

                -- HVFHV (Uber, Lyft): vendor = licensed company
                SELECT
                    'fhvhv', h.trip_id,
                    h.hvfhs_license_num,
                    NULL, NULL,
                    'Dispatch',
                    'N/A',
                    CASE h.is_shared_request WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    CASE h.is_shared_match   WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    CASE h.is_wav_request    WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    CASE h.is_wav_match      WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    CASE h.is_access_a_ride  WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' ELSE 'N/A' END,
                    h.dispatching_base_num,
                    h.pickup_datetime, h.dropoff_datetime, h.pickup_location_id, h.dropoff_location_id,
                    NULL, h.trip_distance_miles, h.trip_duration_seconds, h.pickup_wait_seconds,
                    h.base_passenger_fare, NULL, NULL, NULL,
                    h.black_car_fund_amount, h.sales_tax,
                    h.tolls_amount, h.congestion_surcharge, h.airport_fee, h.cbd_congestion_fee, h.tip_amount, h.passenger_total_amount,
                    h.driver_pay,
                    h.dq_flags
                FROM silver.fhvhv_tripdata AS h
                WHERE h.dq_flags & @reject_mask = 0
            ) AS t
            CROSS APPLY (
                SELECT
                    YEAR(t.pickup_datetime) * 10000 + MONTH(t.pickup_datetime) * 100 + DAY(t.pickup_datetime) AS date_key,
                    DATEPART(HOUR, t.pickup_datetime) * 100 + DATEPART(MINUTE, t.pickup_datetime)           AS time_key,
                    DATEPART(HOUR, t.pickup_datetime)                                                       AS hour_24
            ) AS k
            LEFT JOIN gold.dim_service      AS ds ON ds.service_code      = t.service_code
            LEFT JOIN gold.dim_vendor       AS dv ON dv.vendor_code       = t.vendor_code
            LEFT JOIN gold.dim_zone         AS pz ON pz.location_id       = t.pickup_location_id
            LEFT JOIN gold.dim_zone         AS dz ON dz.location_id       = t.dropoff_location_id
            LEFT JOIN gold.dim_payment_type AS dp ON dp.payment_type_code = t.payment_type_id
            LEFT JOIN gold.dim_rate_code    AS dr ON dr.rate_code_id      = t.rate_code_id
            LEFT JOIN gold.dim_weather      AS dw ON dw.weather_key       = k.date_key * 100 + k.hour_24
            LEFT JOIN gold.dim_trip_profile AS tp
                   ON  tp.hail_type             = t.hail_type
                   AND tp.store_and_forward     = t.store_and_forward
                   AND tp.shared_ride_requested = t.shared_ride_requested
                   AND tp.shared_ride_matched   = t.shared_ride_matched
                   AND tp.wav_requested         = t.wav_requested
                   AND tp.wav_matched           = t.wav_matched
                   AND tp.access_a_ride         = t.access_a_ride;

            SET @rows = ROWCOUNT_BIG();

            IF @rows <> @expected_rows
            BEGIN
                SET @message = CONCAT('Reconciliation failed for gold.fact_trips: expected ', @expected_rows,
                                      ' eligible Silver rows, inserted ', @rows, '. Load rolled back.');
                THROW 50022, @message, 1;
            END;
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        -- gold.fact_trips_hourly (aggregate of fact_trips)
        -- ---------------------------------------------------------------------
        SET @object_name = N'gold.fact_trips_hourly';
        SET @step_start  = SYSDATETIME();
        BEGIN TRANSACTION;
            TRUNCATE TABLE gold.fact_trips_hourly;

            INSERT INTO gold.fact_trips_hourly WITH (TABLOCK) (
                pickup_date_key, pickup_hour_key, pickup_zone_key, service_key, weather_key,
                trip_count, adjustment_count, passenger_count_sum, trip_distance_miles_sum,
                trip_duration_seconds_sum, pickup_wait_seconds_sum, pickup_wait_trip_count,
                fare_amount_sum, tip_amount_sum, total_amount_sum, driver_pay_sum, cbd_congestion_fee_sum,
                cbd_trip_count, shared_trip_count, airport_dropoff_trip_count, dwh_batch_id
            )
            SELECT
                f.pickup_date_key,
                f.pickup_time_key / 100 * 100                                          AS pickup_hour_key,
                f.pickup_zone_key,
                f.service_key,
                f.weather_key,                        -- functionally dependent on date + hour
                SUM(CAST(f.trip_count AS INT)),
                SUM(IIF(f.trip_count = 0, 1, 0)),
                SUM(CAST(f.passenger_count AS INT)),
                SUM(f.trip_distance_miles),
                SUM(CAST(f.trip_duration_seconds AS BIGINT)),
                SUM(CAST(f.pickup_wait_seconds AS BIGINT)),
                COUNT(f.pickup_wait_seconds),
                SUM(f.fare_amount),
                SUM(f.tip_amount),
                SUM(f.total_amount),
                SUM(f.driver_pay),
                SUM(f.cbd_congestion_fee),
                SUM(IIF(f.cbd_congestion_fee > 0, CAST(f.trip_count AS INT), 0)),
                SUM(IIF(tp.shared_ride_matched = 'Yes', CAST(f.trip_count AS INT), 0)),
                SUM(IIF(dz.is_airport = 1, CAST(f.trip_count AS INT), 0)),
                @batch_id
            FROM gold.fact_trips        AS f
            JOIN gold.dim_trip_profile  AS tp ON tp.trip_profile_key = f.trip_profile_key
            JOIN gold.dim_zone          AS dz ON dz.zone_key         = f.dropoff_zone_key
            GROUP BY f.pickup_date_key, f.pickup_time_key / 100 * 100, f.pickup_zone_key, f.service_key, f.weather_key;

            SET @rows = ROWCOUNT_BIG();
        COMMIT TRANSACTION;
        EXEC etl.write_load_log @batch_id, 'gold', @object_name, 'Succeeded', @rows, @step_start;

        -- ---------------------------------------------------------------------
        EXEC etl.write_load_log @batch_id, 'gold', N'gold.load_gold', 'Succeeded', NULL, @layer_start;

        PRINT '================================================';
        PRINT 'Loading Gold Layer is Completed';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @error_number    INT            = ERROR_NUMBER(),
                @error_line      INT            = ERROR_LINE(),
                @error_procedure NVARCHAR(128)  = ERROR_PROCEDURE(),
                @error_message   NVARCHAR(4000) = ERROR_MESSAGE();

        PRINT '================================================';
        PRINT 'ERROR OCCURRED DURING LOADING GOLD LAYER';
        PRINT CONCAT('Object       : ', @object_name);
        PRINT CONCAT('Error Number : ', @error_number);
        PRINT CONCAT('Error Line   : ', @error_line);
        PRINT CONCAT('Error Message: ', @error_message);
        PRINT '================================================';

        SET @step_start = ISNULL(@step_start, @layer_start);

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'gold', @object_name = @object_name,
            @status = 'Failed', @start_time = @step_start,
            @error_number = @error_number, @error_line = @error_line,
            @error_procedure = @error_procedure, @error_message = @error_message;

        THROW;
    END CATCH;
END;
GO
