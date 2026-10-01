/*
===============================================================================
DDL Script: Create Gold Tables (Star Schema)
===============================================================================
Script Purpose:
    Creates the dimensional model of the 'gold' schema: conformed dimensions
    shared by two fact tables at different grains.

      Facts
        gold.fact_trips         grain: one row per trip record, all 4 services
        gold.fact_trips_hourly  grain: pickup date x hour x pickup zone x service
                                (aggregate fact built from fact_trips)
      Dimensions
        gold.dim_date           calendar (smart key yyyymmdd, generated)
        gold.dim_time           time of day at minute grain (smart key hhmm, generated)
        gold.dim_zone           TLC taxi zones (role-played: pickup and dropoff)
        gold.dim_service        yellow / green / FHV / HVFHV
        gold.dim_vendor         company that reported the record (TPEP/LPEP provider or HVFHS company)
        gold.dim_payment_type   taxi payment types
        gold.dim_rate_code      taxi rate codes
        gold.dim_trip_profile   junk dimension of low-cardinality trip flags
        gold.dim_weather        hourly Central Park weather (external source)

Why TABLES and not VIEWS (the reference project uses views):
    Views are fine when the data is small: every query re-runs the joins. Here a
    Gold view would re-union ~25M Silver rows and re-resolve eight surrogate
    keys on EVERY dashboard query. Materialised tables let us:
      - generate surrogate keys once, and keep them stable across loads
        (ROW_NUMBER() keys in a view change whenever the data changes);
      - index the model (columnstore on facts, B-trees on dimensions);
      - enforce PRIMARY KEY / FOREIGN KEY / CHECK constraints, which a view
        cannot have;
      - pre-aggregate (fact_trips_hourly).

Keys and constraints:
    - Dimensions: clustered PK on the surrogate key + a UNIQUE filtered index on
      the business key (WHERE business_key IS NOT NULL, so the special members
      below can share a NULL business key). The unique index both guarantees one
      row per business key and serves the key lookups during the fact load.
    - Special members (Kimball): -1 = Unknown (value missing or not in the
      reference data), -2 = Not Applicable (the service never reports it,
      e.g. payment type for FHV trips). Facts therefore never hold NULL keys,
      and "unknown" and "not applicable" can be reported separately.
    - Facts: FOREIGN KEYs to every dimension. They are TRUSTED (validated), so
      besides guaranteeing referential integrity they let the optimizer skip
      joins that a query does not need. The load cost is small because every
      dimension is tiny. (At much larger scale, a common trade-off is to create
      them WITH NOCHECK and move the check into the quality tests.)
    - CHECK constraints only where a real domain exists (flag values, trip_count).

Indexing:
    - fact_trips: CLUSTERED COLUMNSTORE. Analytical queries scan a few columns
      over millions of rows and aggregate; columnstore reads only the columns
      referenced, compresses ~10x and runs in batch mode. No non-clustered
      indexes: there is no point-lookup workload on individual trips.
      Scaling note: with several years loaded, partition by pickup_date_key
      (monthly) so each month can be switched in/out and rowgroups are
      eliminated by date. Not done here because one month = one partition.
    - fact_trips_hourly: rowstore clustered PK on its grain, PAGE compressed.
      ~half a million rows, typically filtered by date/hour/zone -> B-tree seeks.
    - Dimensions: small rowstore tables with clustered PKs.

SCD strategy:
    Type 1 (overwrite). Dimension rows are upserted, never truncated, so
    surrogate keys stay stable between runs and TRUNCATE is not blocked by
    the foreign keys. Facts are fully reloaded (truncate & insert) every run.

WARNING:
    Drops and recreates all Gold tables. Facts are dropped first because they
    reference the dimensions.
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
-- Drop in dependency order (facts first)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gold.fact_trips_hourly;
DROP TABLE IF EXISTS gold.fact_trips;
DROP TABLE IF EXISTS gold.dim_date;
DROP TABLE IF EXISTS gold.dim_time;
DROP TABLE IF EXISTS gold.dim_zone;
DROP TABLE IF EXISTS gold.dim_service;
DROP TABLE IF EXISTS gold.dim_vendor;
DROP TABLE IF EXISTS gold.dim_payment_type;
DROP TABLE IF EXISTS gold.dim_rate_code;
DROP TABLE IF EXISTS gold.dim_trip_profile;
DROP TABLE IF EXISTS gold.dim_weather;
GO

-- =============================================================================
-- DIMENSIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- dim_date: smart key yyyymmdd. A readable, sortable integer is the industry
-- convention for date keys: it needs no lookup to compute from a timestamp and
-- is still an integer for joins and partitioning.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_date (
    date_key                     INT          NOT NULL,
    full_date                    DATE         NOT NULL,
    day_of_month                 TINYINT      NOT NULL,
    day_of_week                  TINYINT      NOT NULL,  -- ISO: 1 = Monday ... 7 = Sunday
    day_name                     VARCHAR(10)  NOT NULL,
    day_name_short               CHAR(3)      NOT NULL,
    is_weekend                   BIT          NOT NULL,
    iso_week_of_year             TINYINT      NOT NULL,
    month_number                 TINYINT      NOT NULL,
    month_name                   VARCHAR(10)  NOT NULL,
    month_name_short             CHAR(3)      NOT NULL,
    quarter_number               TINYINT      NOT NULL,
    year_number                  SMALLINT     NOT NULL,
    year_month                   CHAR(7)      NOT NULL,  -- 'yyyy-mm', sorts correctly as text
    is_holiday                   BIT          NOT NULL,
    holiday_name                 VARCHAR(50)  NULL,
    is_working_day               BIT          NOT NULL,
    is_congestion_pricing_active BIT          NOT NULL,  -- MTA Congestion Relief Zone toll from 2025-01-05
    CONSTRAINT pk_dim_date PRIMARY KEY CLUSTERED (date_key),
    CONSTRAINT uq_dim_date_full_date UNIQUE (full_date),
    CONSTRAINT ck_dim_date_day_of_week CHECK (day_of_week BETWEEN 1 AND 7)
);
GO

-- -----------------------------------------------------------------------------
-- dim_time: minute grain (1,440 rows), smart key hhmm (e.g. 1745 = 17:45).
-- Kept separate from dim_date so the date dimension does not explode to
-- 1,440 rows per day.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_time (
    time_key           SMALLINT    NOT NULL,
    time_of_day        TIME(0)     NOT NULL,
    hour_24            TINYINT     NOT NULL,
    minute_of_hour     TINYINT     NOT NULL,
    hour_label         CHAR(5)     NOT NULL,  -- '17:00'
    hour_12_label      VARCHAR(5)  NOT NULL,  -- '5 PM'
    quarter_hour_label CHAR(5)     NOT NULL,  -- '17:45'
    day_part           VARCHAR(15) NOT NULL,  -- Overnight / Morning Rush / Midday / Evening Rush / Evening
    CONSTRAINT pk_dim_time PRIMARY KEY CLUSTERED (time_key),
    CONSTRAINT ck_dim_time_hour   CHECK (hour_24 BETWEEN 0 AND 23),
    CONSTRAINT ck_dim_time_minute CHECK (minute_of_hour BETWEEN 0 AND 59)
);
GO

-- -----------------------------------------------------------------------------
-- dim_zone: TLC taxi zones. Role-played in the fact as pickup and dropoff zone.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_zone (
    zone_key            SMALLINT     IDENTITY(1,1) NOT NULL,
    location_id         SMALLINT     NULL,       -- business key (TLC LocationID)
    zone_name           VARCHAR(60)  NOT NULL,
    borough             VARCHAR(20)  NOT NULL,
    service_zone        VARCHAR(20)  NOT NULL,
    is_airport          BIT          NOT NULL,
    is_yellow_zone      BIT          NOT NULL,  -- Manhattan core: green cabs may not street-hail here
    is_within_nyc       BIT          NOT NULL,
    dwh_create_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_zone_create DEFAULT SYSDATETIME(),
    dwh_update_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_zone_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_zone PRIMARY KEY CLUSTERED (zone_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_zone_location_id ON gold.dim_zone (location_id) WHERE location_id IS NOT NULL;
GO

-- -----------------------------------------------------------------------------
-- dim_service: the four TLC trip record feeds
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_service (
    service_key         TINYINT      IDENTITY(1,1) NOT NULL,
    service_code        VARCHAR(10)  NOT NULL,   -- business key: yellow / green / fhv / fhvhv
    service_name        VARCHAR(50)  NOT NULL,
    service_category    VARCHAR(20)  NOT NULL,   -- Taxi / For-Hire Vehicle
    has_fare_data       BIT          NOT NULL,   -- FHV reports no fares at all
    dwh_create_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_service_create DEFAULT SYSDATETIME(),
    dwh_update_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_service_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_service PRIMARY KEY CLUSTERED (service_key),
    CONSTRAINT uq_dim_service_code UNIQUE (service_code)
);
GO

-- -----------------------------------------------------------------------------
-- dim_vendor: who reported the record. For taxis this is the TPEP/LPEP
-- technology provider; for HVFHV it is the licensed company (Uber, Lyft).
-- Both answer "which company submitted this trip to the TLC"; vendor_type
-- keeps the two populations apart for analysis.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_vendor (
    vendor_key          SMALLINT     IDENTITY(1,1) NOT NULL,
    vendor_code         VARCHAR(10)  NULL,       -- business key: '1', '2', 'HV0003', ...
    vendor_name         VARCHAR(100) NOT NULL,
    vendor_type         VARCHAR(50)  NOT NULL,
    dwh_create_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_vendor_create DEFAULT SYSDATETIME(),
    dwh_update_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_vendor_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_vendor PRIMARY KEY CLUSTERED (vendor_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_vendor_code ON gold.dim_vendor (vendor_code) WHERE vendor_code IS NOT NULL;
GO

-- -----------------------------------------------------------------------------
-- dim_payment_type
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_payment_type (
    payment_type_key    SMALLINT     IDENTITY(1,1) NOT NULL,
    payment_type_code   TINYINT      NULL,       -- business key (TLC payment_type)
    payment_type_name   VARCHAR(50)  NOT NULL,
    payment_status      VARCHAR(20)  NOT NULL,   -- Paid / Not Paid / Unknown / Not Applicable
    dwh_create_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_payment_create DEFAULT SYSDATETIME(),
    dwh_update_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_payment_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_payment_type PRIMARY KEY CLUSTERED (payment_type_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_payment_type_code ON gold.dim_payment_type (payment_type_code) WHERE payment_type_code IS NOT NULL;
GO

-- -----------------------------------------------------------------------------
-- dim_rate_code
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_rate_code (
    rate_code_key       SMALLINT     IDENTITY(1,1) NOT NULL,
    rate_code_id        TINYINT      NULL,       -- business key (TLC RatecodeID)
    rate_code_name      VARCHAR(50)  NOT NULL,
    rate_type           VARCHAR(20)  NOT NULL,   -- Metered / Flat Rate / Negotiated / Unknown
    dwh_create_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_rate_create DEFAULT SYSDATETIME(),
    dwh_update_datetime DATETIME2(0) NOT NULL CONSTRAINT df_dim_rate_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_rate_code PRIMARY KEY CLUSTERED (rate_code_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_rate_code_id ON gold.dim_rate_code (rate_code_id) WHERE rate_code_id IS NOT NULL;
GO

-- -----------------------------------------------------------------------------
-- dim_trip_profile (JUNK DIMENSION)
-- Seven low-cardinality flags (hail type, store-and-forward, shared ride
-- requested/matched, wheelchair-accessible requested/matched, Access-A-Ride).
-- As seven separate dimensions they would add seven keys to a 25M-row fact;
-- left in the fact they would clutter it with text. A junk dimension holds
-- every valid combination (3 x 3^6 = 2,187 rows) behind ONE key.
-- The seven attributes together are its business key -> UNIQUE constraint.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_trip_profile (
    trip_profile_key      SMALLINT    IDENTITY(1,1) NOT NULL,
    hail_type             VARCHAR(15) NOT NULL,
    store_and_forward     VARCHAR(3)  NOT NULL,
    shared_ride_requested VARCHAR(3)  NOT NULL,
    shared_ride_matched   VARCHAR(3)  NOT NULL,
    wav_requested         VARCHAR(3)  NOT NULL,
    wav_matched           VARCHAR(3)  NOT NULL,
    access_a_ride         VARCHAR(3)  NOT NULL,
    CONSTRAINT pk_dim_trip_profile PRIMARY KEY CLUSTERED (trip_profile_key),
    CONSTRAINT uq_dim_trip_profile UNIQUE (hail_type, store_and_forward, shared_ride_requested,
                                           shared_ride_matched, wav_requested, wav_matched, access_a_ride),
    CONSTRAINT ck_dim_trip_profile_hail CHECK (hail_type IN ('Street-hail', 'Dispatch', 'Unknown')),
    CONSTRAINT ck_dim_trip_profile_flags CHECK (
            store_and_forward     IN ('Yes', 'No', 'N/A')
        AND shared_ride_requested IN ('Yes', 'No', 'N/A')
        AND shared_ride_matched   IN ('Yes', 'No', 'N/A')
        AND wav_requested         IN ('Yes', 'No', 'N/A')
        AND wav_matched           IN ('Yes', 'No', 'N/A')
        AND access_a_ride         IN ('Yes', 'No', 'N/A'))
);
GO

-- -----------------------------------------------------------------------------
-- dim_weather: one row per hour. Smart key yyyymmddhh, computable directly
-- from a pickup timestamp. Weather is modelled as a dimension (the context of
-- the pickup hour, used to slice trips) rather than a fact, and keeps its
-- numeric readings as attributes for banding and correlation analysis.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.dim_weather (
    weather_key             INT          NOT NULL,
    weather_datetime        DATETIME2(0) NULL,
    temperature_c           DECIMAL(4,1) NULL,
    temperature_f           DECIMAL(4,1) NULL,
    apparent_temperature_c  DECIMAL(4,1) NULL,
    temperature_band        VARCHAR(20)  NOT NULL,
    precipitation_mm        DECIMAL(5,1) NULL,
    snowfall_cm             DECIMAL(5,2) NULL,
    snow_depth_cm           DECIMAL(6,1) NULL,
    precipitation_type      VARCHAR(10)  NOT NULL,  -- None / Rain / Snow / Mixed
    precipitation_intensity VARCHAR(10)  NOT NULL,  -- None / Light / Moderate / Heavy
    is_precipitating        BIT          NOT NULL,
    weather_code            TINYINT      NULL,
    weather_condition       VARCHAR(30)  NOT NULL,
    cloud_cover_pct         TINYINT      NULL,
    wind_speed_kmh          DECIMAL(5,1) NULL,
    dwh_create_datetime     DATETIME2(0) NOT NULL CONSTRAINT df_dim_weather_create DEFAULT SYSDATETIME(),
    dwh_update_datetime     DATETIME2(0) NOT NULL CONSTRAINT df_dim_weather_update DEFAULT SYSDATETIME(),
    CONSTRAINT pk_dim_weather PRIMARY KEY CLUSTERED (weather_key)
);
GO

-- =============================================================================
-- SPECIAL MEMBERS (-1 Unknown, -2 Not Applicable)
-- Part of the table definition, so they are created with the tables.
-- =============================================================================
SET IDENTITY_INSERT gold.dim_zone ON;
INSERT INTO gold.dim_zone (zone_key, location_id, zone_name, borough, service_zone, is_airport, is_yellow_zone, is_within_nyc)
VALUES (-1, NULL, 'Unknown', 'Unknown', 'Unknown', 0, 0, 0);
SET IDENTITY_INSERT gold.dim_zone OFF;

SET IDENTITY_INSERT gold.dim_vendor ON;
INSERT INTO gold.dim_vendor (vendor_key, vendor_code, vendor_name, vendor_type)
VALUES (-1, NULL, 'Unknown', 'Unknown'),
       (-2, NULL, 'Not Applicable', 'Not Applicable');
SET IDENTITY_INSERT gold.dim_vendor OFF;

SET IDENTITY_INSERT gold.dim_payment_type ON;
INSERT INTO gold.dim_payment_type (payment_type_key, payment_type_code, payment_type_name, payment_status)
VALUES (-1, NULL, 'Unknown', 'Unknown'),
       (-2, NULL, 'Not Applicable', 'Not Applicable');
SET IDENTITY_INSERT gold.dim_payment_type OFF;

SET IDENTITY_INSERT gold.dim_rate_code ON;
INSERT INTO gold.dim_rate_code (rate_code_key, rate_code_id, rate_code_name, rate_type)
VALUES (-1, NULL, 'Unknown', 'Unknown'),
       (-2, NULL, 'Not Applicable', 'Not Applicable');
SET IDENTITY_INSERT gold.dim_rate_code OFF;

INSERT INTO gold.dim_weather (weather_key, weather_datetime, temperature_band, precipitation_type,
                              precipitation_intensity, is_precipitating, weather_condition)
VALUES (-1, NULL, 'Unknown', 'Unknown', 'Unknown', 0, 'Unknown');
GO

-- =============================================================================
-- FACTS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fact_trips
-- Grain: one row per trip record (after REJECT-severity quality rules), across
-- yellow, green, FHV and HVFHV. Measures a service does not report are NULL
-- (not 0) so that averages are not dragged down by missing data.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.fact_trips (
    -- Dimension keys
    service_key            TINYINT       NOT NULL,
    vendor_key             SMALLINT      NOT NULL,
    pickup_date_key        INT           NOT NULL,
    pickup_time_key        SMALLINT      NOT NULL,
    pickup_zone_key        SMALLINT      NOT NULL,
    dropoff_zone_key       SMALLINT      NOT NULL,
    payment_type_key       SMALLINT      NOT NULL,
    rate_code_key          SMALLINT      NOT NULL,
    trip_profile_key       SMALLINT      NOT NULL,
    weather_key            INT           NOT NULL,
    -- Degenerate dimensions (no descriptive attributes of their own)
    source_trip_id         BIGINT        NOT NULL,  -- silver trip_id; with service_key, traces back to Silver
    dispatching_base_num   CHAR(6)       NULL,      -- TLC base licence (FHV/HVFHV). No base names are
                                                    -- available, so a dim_base would only hold the key.
    pickup_datetime        DATETIME2(0)  NOT NULL,
    dropoff_datetime       DATETIME2(0)  NOT NULL,
    -- Measures
    trip_count             TINYINT       NOT NULL,  -- 1 = trip, 0 = financial adjustment (reversal/refund)
    passenger_count        TINYINT       NULL,
    trip_distance_miles    DECIMAL(9,2)  NULL,
    trip_duration_seconds  INT           NULL,
    pickup_wait_seconds    INT           NULL,      -- HVFHV only: request -> pickup
    fare_amount            DECIMAL(10,2) NULL,      -- taxi fare_amount / HVFHV base_passenger_fare
    extra_amount           DECIMAL(10,2) NULL,
    mta_tax                DECIMAL(10,2) NULL,
    improvement_surcharge  DECIMAL(10,2) NULL,
    black_car_fund_amount  DECIMAL(10,2) NULL,
    sales_tax              DECIMAL(10,2) NULL,
    tolls_amount           DECIMAL(10,2) NULL,
    congestion_surcharge   DECIMAL(10,2) NULL,
    airport_fee            DECIMAL(10,2) NULL,
    cbd_congestion_fee     DECIMAL(10,2) NULL,
    tip_amount             DECIMAL(10,2) NULL,
    total_amount           DECIMAL(10,2) NULL,      -- taxi total_amount / HVFHV passenger_total_amount
    driver_pay             DECIMAL(10,2) NULL,      -- HVFHV only
    -- Audit
    dq_flags               INT           NOT NULL,  -- WARN-level etl.dq_rule flags still present
    dwh_batch_id           INT           NOT NULL,
    dwh_load_datetime      DATETIME2(0)  NOT NULL CONSTRAINT df_fact_trips_load_dt DEFAULT SYSDATETIME(),

    CONSTRAINT ck_fact_trips_trip_count CHECK (trip_count IN (0, 1)),
    CONSTRAINT fk_fact_trips_service      FOREIGN KEY (service_key)      REFERENCES gold.dim_service (service_key),
    CONSTRAINT fk_fact_trips_vendor       FOREIGN KEY (vendor_key)       REFERENCES gold.dim_vendor (vendor_key),
    CONSTRAINT fk_fact_trips_pickup_date  FOREIGN KEY (pickup_date_key)  REFERENCES gold.dim_date (date_key),
    CONSTRAINT fk_fact_trips_pickup_time  FOREIGN KEY (pickup_time_key)  REFERENCES gold.dim_time (time_key),
    CONSTRAINT fk_fact_trips_pickup_zone  FOREIGN KEY (pickup_zone_key)  REFERENCES gold.dim_zone (zone_key),
    CONSTRAINT fk_fact_trips_dropoff_zone FOREIGN KEY (dropoff_zone_key) REFERENCES gold.dim_zone (zone_key),
    CONSTRAINT fk_fact_trips_payment_type FOREIGN KEY (payment_type_key) REFERENCES gold.dim_payment_type (payment_type_key),
    CONSTRAINT fk_fact_trips_rate_code    FOREIGN KEY (rate_code_key)    REFERENCES gold.dim_rate_code (rate_code_key),
    CONSTRAINT fk_fact_trips_trip_profile FOREIGN KEY (trip_profile_key) REFERENCES gold.dim_trip_profile (trip_profile_key),
    CONSTRAINT fk_fact_trips_weather      FOREIGN KEY (weather_key)      REFERENCES gold.dim_weather (weather_key),

    INDEX cci_fact_trips CLUSTERED COLUMNSTORE
);
GO

-- -----------------------------------------------------------------------------
-- fact_trips_hourly (AGGREGATE FACT)
-- Grain: pickup date x pickup hour x pickup zone x service.
-- Built from fact_trips (not from Silver) so both facts always agree.
-- Serves dashboards (demand heatmaps, hourly trends, weather impact) without
-- scanning the trip-level fact: ~0.5M rows instead of ~25M; at multi-year
-- scale, billions of rows collapse to millions.
-- pickup_hour_key points at the hh:00 row of dim_time, so the hour still
-- joins to the conformed time dimension.
-- Only additive measures are stored (sums and counts). Averages are derived
-- at query time (sum / count) because an average of averages is wrong.
-- -----------------------------------------------------------------------------
CREATE TABLE gold.fact_trips_hourly (
    pickup_date_key             INT           NOT NULL,
    pickup_hour_key             SMALLINT      NOT NULL,
    pickup_zone_key             SMALLINT      NOT NULL,
    service_key                 TINYINT       NOT NULL,
    weather_key                 INT           NOT NULL,
    trip_count                  INT           NOT NULL,
    adjustment_count            INT           NOT NULL,  -- reversal/refund rows (trip_count = 0)
    passenger_count_sum         INT           NULL,
    trip_distance_miles_sum     DECIMAL(14,2) NULL,
    trip_duration_seconds_sum   BIGINT        NULL,
    pickup_wait_seconds_sum     BIGINT        NULL,
    pickup_wait_trip_count      INT           NOT NULL,  -- denominator for average wait
    fare_amount_sum             DECIMAL(14,2) NULL,
    tip_amount_sum              DECIMAL(14,2) NULL,
    total_amount_sum            DECIMAL(14,2) NULL,
    driver_pay_sum              DECIMAL(14,2) NULL,
    cbd_congestion_fee_sum      DECIMAL(14,2) NULL,
    cbd_trip_count              INT           NOT NULL,  -- trips charged the Congestion Relief Zone toll
    shared_trip_count           INT           NOT NULL,
    airport_dropoff_trip_count  INT           NOT NULL,
    dwh_batch_id                INT           NOT NULL,
    dwh_load_datetime           DATETIME2(0)  NOT NULL CONSTRAINT df_fact_trips_hourly_load_dt DEFAULT SYSDATETIME(),

    CONSTRAINT pk_fact_trips_hourly PRIMARY KEY CLUSTERED (pickup_date_key, pickup_hour_key, pickup_zone_key, service_key)
        WITH (DATA_COMPRESSION = PAGE),
    CONSTRAINT fk_fact_trips_hourly_date    FOREIGN KEY (pickup_date_key) REFERENCES gold.dim_date (date_key),
    CONSTRAINT fk_fact_trips_hourly_hour    FOREIGN KEY (pickup_hour_key) REFERENCES gold.dim_time (time_key),
    CONSTRAINT fk_fact_trips_hourly_zone    FOREIGN KEY (pickup_zone_key) REFERENCES gold.dim_zone (zone_key),
    CONSTRAINT fk_fact_trips_hourly_service FOREIGN KEY (service_key)     REFERENCES gold.dim_service (service_key),
    CONSTRAINT fk_fact_trips_hourly_weather FOREIGN KEY (weather_key)     REFERENCES gold.dim_weather (weather_key),
    CONSTRAINT ck_fact_trips_hourly_hour_key CHECK (pickup_hour_key % 100 = 0)
);
GO
