/*
===============================================================================
DDL Script: Create Bronze Tables
===============================================================================
Script Purpose:
    Creates the tables of the 'bronze' schema (dropping them if they exist).
    Bronze stores the source data exactly as delivered: same column names,
    same column order, no cleansing. It is the replayable "raw copy" that
    every downstream layer can be rebuilt from.

Naming:
    <source_system>_<entity>. The source systems are the four TLC trip feeds
    (yellow, green, fhv, fhvhv), TLC reference data (tlc) and the weather
    API (openmeteo). Column names are kept as in the source (e.g. VendorID,
    PULocationID) so lineage back to the data dictionaries is exact; they are
    renamed to snake_case in Silver.

Data types:
    - Parquet sources are strongly typed, so their Bronze tables use the
      equivalent SQL Server types (Parquet DOUBLE -> FLOAT, TIMESTAMP ->
      DATETIME2(6), etc.). Nothing is rounded or narrowed at this stage.
    - CSV/API sources are text, so their Bronze tables are VARCHAR. Typing
      happens in Silver with TRY_CAST, where bad values can be handled.

Storage / indexing:
    - Large trip tables use a CLUSTERED COLUMNSTORE INDEX (CCI):
        * They are only ever read by full scans (Bronze -> Silver), which is
          the access pattern columnstore is built for.
        * Typical compression is 5-10x. SQL Server Express caps each database
          (10 GB up to SQL Server 2022; 2025 raised the limit), and ~26M raw rows
          stored three times (Bronze, Silver, Gold) would not fit comfortably
          as uncompressed rowstore.
        * BULK INSERT with BATCHSIZE >= 102,400 writes straight into compressed
          rowgroups (no delta-store round trip).
    - green_tripdata (~50K rows/month) and the reference tables stay as heaps:
      they never reach the 102,400-row minimum of a compressed rowgroup, so a
      columnstore would add overhead without any benefit.
    - No primary keys: Bronze must accept whatever the source sends (including
      duplicates) so that Silver can detect and report them.
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- -----------------------------------------------------------------------------
-- Yellow taxi trip records (TPEP)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.yellow_tripdata', 'U') IS NOT NULL
    DROP TABLE bronze.yellow_tripdata;
GO

CREATE TABLE bronze.yellow_tripdata (
    VendorID              INT,
    tpep_pickup_datetime  DATETIME2(6),
    tpep_dropoff_datetime DATETIME2(6),
    passenger_count       BIGINT,
    trip_distance         FLOAT,
    RatecodeID            BIGINT,
    store_and_fwd_flag    VARCHAR(10),
    PULocationID          INT,
    DOLocationID          INT,
    payment_type          BIGINT,
    fare_amount           FLOAT,
    extra                 FLOAT,
    mta_tax               FLOAT,
    tip_amount            FLOAT,
    tolls_amount          FLOAT,
    improvement_surcharge FLOAT,
    total_amount          FLOAT,
    congestion_surcharge  FLOAT,
    Airport_fee           FLOAT,
    cbd_congestion_fee    FLOAT,
    INDEX cci_bronze_yellow_tripdata CLUSTERED COLUMNSTORE
);
GO

-- -----------------------------------------------------------------------------
-- Green taxi trip records (LPEP) - heap, see header note
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.green_tripdata', 'U') IS NOT NULL
    DROP TABLE bronze.green_tripdata;
GO

CREATE TABLE bronze.green_tripdata (
    VendorID              INT,
    lpep_pickup_datetime  DATETIME2(6),
    lpep_dropoff_datetime DATETIME2(6),
    store_and_fwd_flag    VARCHAR(10),
    RatecodeID            BIGINT,
    PULocationID          INT,
    DOLocationID          INT,
    passenger_count       BIGINT,
    trip_distance         FLOAT,
    fare_amount           FLOAT,
    extra                 FLOAT,
    mta_tax               FLOAT,
    tip_amount            FLOAT,
    tolls_amount          FLOAT,
    ehail_fee             FLOAT,
    improvement_surcharge FLOAT,
    total_amount          FLOAT,
    payment_type          BIGINT,
    trip_type             BIGINT,
    congestion_surcharge  FLOAT,
    cbd_congestion_fee    FLOAT
);
GO

-- -----------------------------------------------------------------------------
-- For-Hire Vehicle trip records (FHV - livery, black car, luxury limousine)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.fhv_tripdata', 'U') IS NOT NULL
    DROP TABLE bronze.fhv_tripdata;
GO

CREATE TABLE bronze.fhv_tripdata (
    dispatching_base_num   VARCHAR(50),
    pickup_datetime        DATETIME2(6),
    dropOff_datetime       DATETIME2(6),
    PUlocationID           BIGINT,
    DOlocationID           BIGINT,
    SR_Flag                BIGINT,
    Affiliated_base_number VARCHAR(50),
    INDEX cci_bronze_fhv_tripdata CLUSTERED COLUMNSTORE
);
GO

-- -----------------------------------------------------------------------------
-- High-Volume For-Hire Vehicle trip records (HVFHV - Uber, Lyft, ...)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.fhvhv_tripdata', 'U') IS NOT NULL
    DROP TABLE bronze.fhvhv_tripdata;
GO

CREATE TABLE bronze.fhvhv_tripdata (
    hvfhs_license_num    VARCHAR(50),
    dispatching_base_num VARCHAR(50),
    originating_base_num VARCHAR(50),
    request_datetime     DATETIME2(6),
    on_scene_datetime    DATETIME2(6),
    pickup_datetime      DATETIME2(6),
    dropoff_datetime     DATETIME2(6),
    PULocationID         INT,
    DOLocationID         INT,
    trip_miles           FLOAT,
    trip_time            BIGINT,
    base_passenger_fare  FLOAT,
    tolls                FLOAT,
    bcf                  FLOAT,
    sales_tax            FLOAT,
    congestion_surcharge FLOAT,
    airport_fee          FLOAT,
    tips                 FLOAT,
    driver_pay           FLOAT,
    shared_request_flag  VARCHAR(10),
    shared_match_flag    VARCHAR(10),
    access_a_ride_flag   VARCHAR(10),
    wav_request_flag     VARCHAR(10),
    wav_match_flag       VARCHAR(10),
    cbd_congestion_fee   FLOAT,
    INDEX cci_bronze_fhvhv_tripdata CLUSTERED COLUMNSTORE
);
GO

-- -----------------------------------------------------------------------------
-- TLC taxi zone lookup (CSV -> text columns)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.tlc_taxi_zone_lookup', 'U') IS NOT NULL
    DROP TABLE bronze.tlc_taxi_zone_lookup;
GO

CREATE TABLE bronze.tlc_taxi_zone_lookup (
    LocationID   VARCHAR(50),
    Borough      VARCHAR(50),
    Zone         VARCHAR(100),
    service_zone VARCHAR(50)
);
GO

-- -----------------------------------------------------------------------------
-- TLC code values transcribed from the data dictionaries (CSV -> text)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.tlc_code_values', 'U') IS NOT NULL
    DROP TABLE bronze.tlc_code_values;
GO

CREATE TABLE bronze.tlc_code_values (
    code_type        VARCHAR(50),
    code             VARCHAR(50),
    code_description VARCHAR(200),
    code_group       VARCHAR(100),
    source_document  VARCHAR(200)
);
GO

-- -----------------------------------------------------------------------------
-- Open-Meteo hourly weather for Central Park (API -> CSV -> text)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('bronze.openmeteo_weather_hourly', 'U') IS NOT NULL
    DROP TABLE bronze.openmeteo_weather_hourly;
GO

CREATE TABLE bronze.openmeteo_weather_hourly (
    [time]               VARCHAR(50),
    temperature_2m       VARCHAR(50),
    apparent_temperature VARCHAR(50),
    precipitation        VARCHAR(50),
    rain                 VARCHAR(50),
    snowfall             VARCHAR(50),
    snow_depth           VARCHAR(50),
    weather_code         VARCHAR(50),
    cloud_cover          VARCHAR(50),
    wind_speed_10m       VARCHAR(50)
);
GO
