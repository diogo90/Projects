# Naming Conventions

Conventions used for every object in the `nyc_tlc_dwh` database.

## Table of Contents

1. [General Principles](#general-principles)
2. [Schemas](#schemas)
3. [Table Naming](#table-naming)
4. [Column Naming](#column-naming)
5. [Keys, Constraints and Indexes](#keys-constraints-and-indexes)
6. [Stored Procedures](#stored-procedures)
7. [Files](#files)

---

## General Principles

- **snake_case**, lower case, words separated by `_`.
- **English** names only.
- **No reserved words** as object names. Where a source forces one (the weather API's `time` column), Bronze keeps it in brackets (`[time]`) and Silver renames it (`weather_datetime`).
- **No abbreviations** unless the source or the business uses them universally (`cbd`, `wav`, `hvfhs`, `mta`).

## Schemas

| Schema | Purpose |
|---|---|
| `etl` | Pipeline control: batch log, landing manifest, data-quality rule catalogue, orchestration |
| `bronze` | Raw data exactly as delivered |
| `silver` | Cleansed, standardised, conformed data |
| `gold` | Business-ready star schema |

## Table Naming

### Bronze and Silver: `<source_system>_<entity>`

| Source system | Meaning | Example |
|---|---|---|
| `yellow` | Yellow taxi trip records (TPEP) | `yellow_tripdata` |
| `green` | Green taxi trip records (LPEP) | `green_tripdata` |
| `fhv` | For-Hire Vehicle trip records | `fhv_tripdata` |
| `fhvhv` | High-Volume For-Hire Vehicle trip records | `fhvhv_tripdata` |
| `tlc` | TLC reference data (zones, data-dictionary code values) | `tlc_taxi_zone_lookup` |
| `openmeteo` | Open-Meteo weather API | `openmeteo_weather_hourly` |

The entity keeps the name of the source file (`*_tripdata`), so a table can always be traced to its file.

### Gold: `<category>_<entity>`

| Prefix | Meaning | Example |
|---|---|---|
| `dim_` | Dimension table | `dim_zone`, `dim_date` |
| `fact_` | Fact table | `fact_trips`, `fact_trips_hourly` |

Entities are business terms, not source terms (`dim_vendor`, not `dim_vendorid`).

## Column Naming

### Bronze
Columns keep the **exact source name and order** (`VendorID`, `PULocationID`, `dropOff_datetime`), so every column maps one-to-one to the TLC data dictionaries.

### Silver: conformed names
The same concept has the same name in every source:

| Concept | Source names | Silver name |
|---|---|---|
| Pickup timestamp | `tpep_pickup_datetime`, `lpep_pickup_datetime`, `pickup_datetime` | `pickup_datetime` |
| Pickup zone | `PULocationID`, `PUlocationID` | `pickup_location_id` |
| Distance | `trip_distance`, `trip_miles` | `trip_distance_miles` |
| Duration | *(derived)*, `trip_time` | `trip_duration_seconds` |
| Tips | `tip_amount`, `tips` | `tip_amount` |
| Tolls | `tolls_amount`, `tolls` | `tolls_amount` |

Rules:
- **Units in the name** when a column is a measurement: `_miles`, `_seconds`, `_mm`, `_cm`, `_c` (Celsius), `_kmh`, `_pct`.
- **Money** columns end in `_amount`, `_fee`, `_tax`, `_surcharge` or `_pay`.
- **Booleans** start with `is_` (`is_shared_ride`, `is_wav_request`).
- **Identifiers from a source** end in `_id` (`vendor_id`, `rate_code_id`) or `_num` for licence numbers (`dispatching_base_num`).

### Gold: surrogate keys
- Dimension primary keys: **`<dimension>_key`** (`zone_key`, `vendor_key`).
- Role-playing keys add the role as a prefix: `pickup_zone_key`, `dropoff_zone_key`.
- Smart keys keep the same suffix: `date_key` (yyyymmdd), `time_key` (hhmm), `weather_key` (yyyymmddhh).
- Aggregated measures end in `_sum` or `_count` (`total_amount_sum`, `cbd_trip_count`).

### Technical columns: `dwh_` prefix

| Column | Meaning |
|---|---|
| `dwh_batch_id` | Pipeline run that loaded the row (`etl.seq_batch_id`) |
| `dwh_load_datetime` | When the row was loaded (facts, Silver) |
| `dwh_create_datetime` / `dwh_update_datetime` | When a dimension row was created / last overwritten (SCD Type 1) |
| `dq_flags` | Bitmask of the `etl.dq_rule` rules the row breaks |

## Keys, Constraints and Indexes

| Object | Pattern | Example |
|---|---|---|
| Primary key | `pk_<table>` | `pk_dim_zone` |
| Foreign key | `fk_<table>_<role>` | `fk_fact_trips_pickup_zone` |
| Unique constraint | `uq_<table>_<column(s)>` | `uq_dim_date_full_date` |
| Unique index | `ux_<table>_<column>` | `ux_dim_zone_location_id` |
| Check constraint | `ck_<table>_<rule>` | `ck_fact_trips_trip_count` |
| Default constraint | `df_<table>_<column>` | `df_fact_trips_load_dt` |
| Clustered columnstore | `cci_<table>` | `cci_fact_trips` |

## Stored Procedures

| Pattern | Purpose | Example |
|---|---|---|
| `<layer>.load_<layer>` | Load one layer | `bronze.load_bronze`, `gold.load_gold` |
| `<layer>.load_<object>` | Reusable load step | `bronze.load_file` |
| `etl.<verb>_<noun>` | Pipeline utilities | `etl.run_pipeline`, `etl.write_load_log` |

## Files

| Pattern | Example |
|---|---|
| `ddl_<layer>.sql` | `scripts/silver/ddl_silver.sql` |
| `proc_<procedure>.sql` | `scripts/silver/proc_load_silver.sql` |
| `quality_checks_<layer>.sql` | `tests/quality_checks_silver.sql` |
| Landing files: `<source_system>_<entity>.csv` | `fhvhv_tripdata.csv` |
