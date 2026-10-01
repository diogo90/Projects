/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
Script Purpose:
    Creates the tables of the 'silver' schema (dropping them if they exist).
    Silver holds cleansed, standardised and CONFORMED data:

      - Conformed naming: the same concept has the same snake_case name in every
        source (e.g. tpep_pickup_datetime / lpep_pickup_datetime / pickup_datetime
        -> pickup_datetime; trip_miles / trip_distance -> trip_distance_miles;
        tips / tip_amount -> tip_amount).
      - Right-sized types: FLOAT money -> DECIMAL(10,2) (exact arithmetic, no
        floating-point drift in sums), microsecond timestamps -> DATETIME2(0),
        integer codes -> TINYINT/SMALLINT, Y/N text flags -> BIT.
      - Data-quality flags: rows are NOT deleted for quality reasons. Each trip
        carries dq_flags, a bitmask of the etl.dq_rule rules it breaks. Silver
        stays a complete, auditable copy; Gold decides what to exclude.
        (Exact duplicates are the one exception: they are removed, because a
        duplicate is not a separate event.)
      - Technical columns: dwh_batch_id / dwh_load_datetime trace every row to
        the pipeline run that produced it.

Keys & constraints (only where the data supports them):
    - Reference tables get PRIMARY KEYs on their natural keys (location_id,
      code_type + code, weather hour). These are real business rules and a
      duplicate would silently fan out joins downstream.
    - zone_name is deliberately NOT unique: the TLC lookup reuses names
      (LocationID 56/57 are both "Corona"; 103-105 share one name).
    - Trip tables have no natural key (no trip id in any feed). trip_id is a
      surrogate IDENTITY used for lineage from Gold back to Silver. On the
      columnstore tables no PK is declared: enforcing it would cost a 25M-row
      B-tree for a value IDENTITY already guarantees. green_tripdata is
      rowstore, and a rowstore table needs a clustered key anyway, so there the
      PK on trip_id is free and is declared.

Indexing:
    - Trip tables: CLUSTERED COLUMNSTORE (scan-heavy Silver -> Gold processing,
      high compression). green_tripdata stays rowstore (below the 102,400-row
      compressed rowgroup minimum).
    - Reference tables: clustered PK (tiny, used for key lookups).
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =============================================================================
-- Reference data
-- =============================================================================

IF OBJECT_ID('silver.tlc_taxi_zone_lookup', 'U') IS NOT NULL
    DROP TABLE silver.tlc_taxi_zone_lookup;
GO

CREATE TABLE silver.tlc_taxi_zone_lookup (
    location_id       SMALLINT     NOT NULL,
    borough           VARCHAR(20)  NOT NULL,
    zone_name         VARCHAR(60)  NOT NULL,
    service_zone      VARCHAR(20)  NOT NULL,
    dwh_batch_id      INT          NOT NULL,
    dwh_load_datetime DATETIME2(0) NOT NULL CONSTRAINT df_silver_zone_load_dt DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_tlc_taxi_zone_lookup PRIMARY KEY CLUSTERED (location_id)
);
GO

IF OBJECT_ID('silver.tlc_code_values', 'U') IS NOT NULL
    DROP TABLE silver.tlc_code_values;
GO

CREATE TABLE silver.tlc_code_values (
    code_type         VARCHAR(20)  NOT NULL,
    code              VARCHAR(10)  NOT NULL,
    code_description  VARCHAR(100) NOT NULL,
    code_group        VARCHAR(50)  NULL,
    source_document   VARCHAR(100) NULL,
    dwh_batch_id      INT          NOT NULL,
    dwh_load_datetime DATETIME2(0) NOT NULL CONSTRAINT df_silver_code_load_dt DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_tlc_code_values PRIMARY KEY CLUSTERED (code_type, code),
    -- The seed file is hand-maintained: the CHECK stops a typo in code_type
    -- from creating a code set no dimension will ever read.
    CONSTRAINT ck_silver_tlc_code_values_type
        CHECK (code_type IN ('service_type', 'vendor', 'rate_code', 'payment_type', 'trip_type'))
);
GO

IF OBJECT_ID('silver.openmeteo_weather_hourly', 'U') IS NOT NULL
    DROP TABLE silver.openmeteo_weather_hourly;
GO

CREATE TABLE silver.openmeteo_weather_hourly (
    weather_datetime       DATETIME2(0) NOT NULL,  -- start of the hour, NYC local time
    temperature_c          DECIMAL(4,1) NULL,
    apparent_temperature_c DECIMAL(4,1) NULL,      -- "feels like"
    precipitation_mm       DECIMAL(5,1) NULL,
    rain_mm                DECIMAL(5,1) NULL,
    snowfall_cm            DECIMAL(5,2) NULL,
    snow_depth_cm          DECIMAL(6,1) NULL,      -- source is metres, converted to cm
    weather_code           TINYINT      NULL,      -- WMO weather interpretation code
    weather_condition      VARCHAR(30)  NOT NULL,  -- derived from weather_code
    cloud_cover_pct        TINYINT      NULL,
    wind_speed_kmh         DECIMAL(5,1) NULL,
    dwh_batch_id           INT          NOT NULL,
    dwh_load_datetime      DATETIME2(0) NOT NULL CONSTRAINT df_silver_weather_load_dt DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_openmeteo_weather_hourly PRIMARY KEY CLUSTERED (weather_datetime),
    CONSTRAINT ck_silver_weather_cloud_cover CHECK (cloud_cover_pct BETWEEN 0 AND 100)
);
GO

-- =============================================================================
-- Trip records
-- =============================================================================

IF OBJECT_ID('silver.yellow_tripdata', 'U') IS NOT NULL
    DROP TABLE silver.yellow_tripdata;
GO

CREATE TABLE silver.yellow_tripdata (
    trip_id               BIGINT        IDENTITY(1,1) NOT NULL,
    vendor_id             TINYINT       NULL,
    pickup_datetime       DATETIME2(0)  NOT NULL,
    dropoff_datetime      DATETIME2(0)  NOT NULL,
    pickup_location_id    SMALLINT      NULL,
    dropoff_location_id   SMALLINT      NULL,
    passenger_count       TINYINT       NULL,
    trip_distance_miles   DECIMAL(9,2)  NULL,
    trip_duration_seconds INT           NULL,       -- derived: dropoff - pickup (NULL if it overflows INT)
    rate_code_id          TINYINT       NOT NULL,
    payment_type_id       TINYINT       NOT NULL,
    is_store_and_forward  BIT           NULL,
    fare_amount           DECIMAL(10,2) NULL,
    extra_amount          DECIMAL(10,2) NULL,
    mta_tax               DECIMAL(10,2) NULL,
    tip_amount            DECIMAL(10,2) NULL,
    tolls_amount          DECIMAL(10,2) NULL,
    improvement_surcharge DECIMAL(10,2) NULL,
    congestion_surcharge  DECIMAL(10,2) NULL,
    airport_fee           DECIMAL(10,2) NULL,
    cbd_congestion_fee    DECIMAL(10,2) NULL,
    total_amount          DECIMAL(10,2) NULL,
    dq_flags              INT           NOT NULL,
    dwh_batch_id          INT           NOT NULL,
    dwh_load_datetime     DATETIME2(0)  NOT NULL CONSTRAINT df_silver_yellow_load_dt DEFAULT SYSDATETIME(),
    INDEX cci_silver_yellow_tripdata CLUSTERED COLUMNSTORE
);
GO

IF OBJECT_ID('silver.green_tripdata', 'U') IS NOT NULL
    DROP TABLE silver.green_tripdata;
GO

-- Same shape as yellow plus trip_type_id. ehail_fee is intentionally dropped:
-- it has been 100% NULL for years (a Silver quality check alerts if TLC starts
-- populating it again).
CREATE TABLE silver.green_tripdata (
    trip_id               BIGINT        IDENTITY(1,1) NOT NULL,
    vendor_id             TINYINT       NULL,
    pickup_datetime       DATETIME2(0)  NOT NULL,
    dropoff_datetime      DATETIME2(0)  NOT NULL,
    pickup_location_id    SMALLINT      NULL,
    dropoff_location_id   SMALLINT      NULL,
    passenger_count       TINYINT       NULL,
    trip_distance_miles   DECIMAL(9,2)  NULL,
    trip_duration_seconds INT           NULL,
    rate_code_id          TINYINT       NOT NULL,
    payment_type_id       TINYINT       NOT NULL,
    trip_type_id          TINYINT       NULL,
    is_store_and_forward  BIT           NULL,
    fare_amount           DECIMAL(10,2) NULL,
    extra_amount          DECIMAL(10,2) NULL,
    mta_tax               DECIMAL(10,2) NULL,
    tip_amount            DECIMAL(10,2) NULL,
    tolls_amount          DECIMAL(10,2) NULL,
    improvement_surcharge DECIMAL(10,2) NULL,
    congestion_surcharge  DECIMAL(10,2) NULL,
    cbd_congestion_fee    DECIMAL(10,2) NULL,
    total_amount          DECIMAL(10,2) NULL,
    dq_flags              INT           NOT NULL,
    dwh_batch_id          INT           NOT NULL,
    dwh_load_datetime     DATETIME2(0)  NOT NULL CONSTRAINT df_silver_green_load_dt DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_green_tripdata PRIMARY KEY CLUSTERED (trip_id)
    -- Rowstore needs a clustered key; trip_id is narrow and ever-increasing.
);
GO

IF OBJECT_ID('silver.fhv_tripdata', 'U') IS NOT NULL
    DROP TABLE silver.fhv_tripdata;
GO

CREATE TABLE silver.fhv_tripdata (
    trip_id               BIGINT       IDENTITY(1,1) NOT NULL,
    dispatching_base_num  CHAR(6)      NULL,  -- validated format: B + 5 digits
    affiliated_base_num   CHAR(6)      NULL,  -- validated format; free-text garbage -> NULL
    pickup_datetime       DATETIME2(0) NOT NULL,
    dropoff_datetime      DATETIME2(0) NOT NULL,
    pickup_location_id    SMALLINT     NULL,
    dropoff_location_id   SMALLINT     NULL,
    trip_duration_seconds INT          NULL,
    is_shared_ride        BIT          NOT NULL,  -- SR_Flag: 1 -> 1, NULL -> 0 (per dictionary)
    dq_flags              INT          NOT NULL,
    dwh_batch_id          INT          NOT NULL,
    dwh_load_datetime     DATETIME2(0) NOT NULL CONSTRAINT df_silver_fhv_load_dt DEFAULT SYSDATETIME(),
    INDEX cci_silver_fhv_tripdata CLUSTERED COLUMNSTORE
);
GO

IF OBJECT_ID('silver.fhvhv_tripdata', 'U') IS NOT NULL
    DROP TABLE silver.fhvhv_tripdata;
GO

CREATE TABLE silver.fhvhv_tripdata (
    trip_id                BIGINT        IDENTITY(1,1) NOT NULL,
    hvfhs_license_num      CHAR(6)       NOT NULL,
    dispatching_base_num   CHAR(6)       NULL,
    originating_base_num   CHAR(6)       NULL,
    request_datetime       DATETIME2(0)  NOT NULL,
    on_scene_datetime      DATETIME2(0)  NULL,
    pickup_datetime        DATETIME2(0)  NOT NULL,
    dropoff_datetime       DATETIME2(0)  NOT NULL,
    pickup_location_id     SMALLINT      NULL,
    dropoff_location_id    SMALLINT      NULL,
    trip_distance_miles    DECIMAL(9,2)  NULL,
    trip_duration_seconds  INT           NULL,   -- source trip_time (authoritative)
    pickup_wait_seconds    INT           NULL,   -- derived: pickup - request
    base_passenger_fare    DECIMAL(10,2) NULL,
    tolls_amount           DECIMAL(10,2) NULL,
    black_car_fund_amount  DECIMAL(10,2) NULL,
    sales_tax              DECIMAL(10,2) NULL,
    congestion_surcharge   DECIMAL(10,2) NULL,
    airport_fee            DECIMAL(10,2) NULL,
    cbd_congestion_fee     DECIMAL(10,2) NULL,
    tip_amount             DECIMAL(10,2) NULL,
    passenger_total_amount DECIMAL(10,2) NULL,   -- derived: everything the rider paid
    driver_pay             DECIMAL(10,2) NULL,
    is_shared_request      BIT           NULL,
    is_shared_match        BIT           NULL,
    is_access_a_ride       BIT           NULL,
    is_wav_request         BIT           NULL,
    is_wav_match           BIT           NULL,
    dq_flags               INT           NOT NULL,
    dwh_batch_id           INT           NOT NULL,
    dwh_load_datetime      DATETIME2(0)  NOT NULL CONSTRAINT df_silver_fhvhv_load_dt DEFAULT SYSDATETIME(),
    INDEX cci_silver_fhvhv_tripdata CLUSTERED COLUMNSTORE
);
GO
