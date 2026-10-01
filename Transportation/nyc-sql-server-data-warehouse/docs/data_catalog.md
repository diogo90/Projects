# Data Catalog

Business and technical description of every table and column in the warehouse. Field descriptions for trip data are based on the official TLC data dictionaries (March 2025 revision) in `data_dictionaries/`.

## Contents

1. [Gold layer (business-facing)](#gold-layer)
   - Facts: [fact_trips](#goldfact_trips) · [fact_trips_hourly](#goldfact_trips_hourly)
   - Dimensions: [dim_date](#golddim_date) · [dim_time](#golddim_time) · [dim_zone](#golddim_zone) · [dim_service](#golddim_service) · [dim_vendor](#golddim_vendor) · [dim_payment_type](#golddim_payment_type) · [dim_rate_code](#golddim_rate_code) · [dim_trip_profile](#golddim_trip_profile) · [dim_weather](#golddim_weather)
2. [Silver layer](#silver-layer)
3. [Source-to-Silver column mapping](#source-to-silver-column-mapping)
4. [Data-quality rules (`etl.dq_rule`)](#data-quality-rules)
5. [ETL control tables (`etl` schema)](#etl-control-tables)

**Conventions used in this catalog**

- **Key**: `PK` primary key · `FK` foreign key · `UK` unique business key · `DD` degenerate dimension.
- **Special members**: `-1` = Unknown (value missing or not in reference data), `-2` = Not Applicable (the service never reports it).
- **NULL measures**: a measure the service does not report is `NULL`, not `0`, so averages are not dragged down by missing data.
- **Services**: *Yellow* = yellow taxi, *Green* = green taxi, *FHV* = for-hire vehicle (livery, black car, limousine), *HVFHV* = high-volume for-hire vehicle (Uber, Lyft).

---

## Gold Layer

### gold.fact_trips

**Purpose:** one row per trip record across all four services. It is the main fact table for trip-level analysis: fares, tips, durations, market share, congestion pricing.<br>
**Grain:** one trip record that passed the REJECT-severity quality rules.<br>
**Rows (Jan 2025):** about 25.8M · **Storage:** clustered columnstore.

| Column | Data Type | Key | Description |
|---|---|---|---|
| service_key | TINYINT | FK | Service that performed the trip → `dim_service`. |
| vendor_key | SMALLINT | FK | Company that reported the record → `dim_vendor`. `-2` for FHV. |
| pickup_date_key | INT | FK | Pickup date (yyyymmdd) → `dim_date`. |
| pickup_time_key | SMALLINT | FK | Pickup time to the minute (hhmm) → `dim_time`. |
| pickup_zone_key | SMALLINT | FK | TLC zone where the trip began → `dim_zone` (role: pickup). |
| dropoff_zone_key | SMALLINT | FK | TLC zone where the trip ended → `dim_zone` (role: dropoff). |
| payment_type_key | SMALLINT | FK | How the passenger paid → `dim_payment_type`. `-2` for FHV/HVFHV. |
| rate_code_key | SMALLINT | FK | Final rate code at the end of the trip → `dim_rate_code`. `-2` for FHV/HVFHV. |
| trip_profile_key | SMALLINT | FK | Combination of trip flags (hail type, shared ride, wheelchair-accessible, ...) → `dim_trip_profile`. |
| weather_key | INT | FK | Weather in the pickup hour (yyyymmddhh) → `dim_weather`. |
| source_trip_id | BIGINT | DD | `trip_id` of the Silver row. With `service_key`, it traces a fact row back to Silver. |
| dispatching_base_num | CHAR(6) | DD | TLC licence number of the base that dispatched the trip (FHV/HVFHV only). |
| pickup_datetime | DATETIME2(0) | DD | Exact pickup timestamp (meter engaged, or passenger picked up). |
| dropoff_datetime | DATETIME2(0) | DD | Exact dropoff timestamp. |
| trip_count | TINYINT | | `1` for a trip, `0` for a financial adjustment (a reversal, refund or dispute row with a negative amount). **Count trips with `SUM(trip_count)`, not `COUNT(*)`.** |
| passenger_count | TINYINT | | Driver-entered number of passengers (taxis only). `NULL` when not recorded or recorded as 0. |
| trip_distance_miles | DECIMAL(9,2) | | Trip distance in miles: the taximeter for taxis, `trip_miles` for HVFHV. `NULL` for FHV. |
| trip_duration_seconds | INT | | Trip time in seconds (dropoff minus pickup; the source `trip_time` for HVFHV). |
| pickup_wait_seconds | INT | | HVFHV only: seconds from the passenger's request to pickup. `NULL` if the pickup is logged before the request. |
| fare_amount | DECIMAL(10,2) | | Time-and-distance fare (taxi `fare_amount`) or base passenger fare before tolls, tips, taxes and fees (HVFHV). |
| extra_amount | DECIMAL(10,2) | | Taxi miscellaneous extras and surcharges (e.g. rush hour, overnight). |
| mta_tax | DECIMAL(10,2) | | Taxi MTA tax, triggered automatically by the metered rate. |
| improvement_surcharge | DECIMAL(10,2) | | Taxi improvement surcharge assessed at flag drop. |
| black_car_fund_amount | DECIMAL(10,2) | | HVFHV Black Car Fund contribution. |
| sales_tax | DECIMAL(10,2) | | HVFHV New York State sales tax. |
| tolls_amount | DECIMAL(10,2) | | Total tolls paid in the trip. |
| congestion_surcharge | DECIMAL(10,2) | | New York State congestion surcharge. |
| airport_fee | DECIMAL(10,2) | | Airport fee: yellow pickups at LaGuardia/JFK, or HVFHV pickups and dropoffs at LGA/EWR/JFK. |
| cbd_congestion_fee | DECIMAL(10,2) | | MTA Congestion Relief Zone toll, charged from 2025-01-05. |
| tip_amount | DECIMAL(10,2) | | Tip. For taxis, only card tips are recorded (cash tips are not). |
| total_amount | DECIMAL(10,2) | | Total charged to the passenger: taxi `total_amount` (excludes cash tips), or for HVFHV the sum of fare, tolls, BCF, sales tax, surcharges, fees and tips. |
| driver_pay | DECIMAL(10,2) | | HVFHV only: total driver pay, net of commission, surcharges and taxes, excluding tolls and tips. |
| dq_flags | INT | | WARN-level quality flags still present on the row (bitmask of `etl.dq_rule`). |
| dwh_batch_id | INT | | Pipeline run that loaded the row. |
| dwh_load_datetime | DATETIME2(0) | | When the row was loaded. |

### gold.fact_trips_hourly

**Purpose:** pre-aggregated demand and revenue by hour, pickup zone and service. It is used for dashboards, heatmaps and weather analysis without scanning the trip-level fact.<br>
**Grain:** pickup date × pickup hour × pickup zone × service.<br>
**Rows (Jan 2025):** about 0.5M · **Storage:** rowstore, clustered PK on the grain, PAGE compressed.<br>
Every measure is additive. Derive averages at query time as `SUM(x_sum) / SUM(trip_count)`.

| Column | Data Type | Key | Description |
|---|---|---|---|
| pickup_date_key | INT | PK, FK | Pickup date → `dim_date`. |
| pickup_hour_key | SMALLINT | PK, FK | Pickup hour, stored as the `hh00` key of `dim_time` (e.g. 1700 = 17:00-17:59). |
| pickup_zone_key | SMALLINT | PK, FK | Pickup zone → `dim_zone`. |
| service_key | TINYINT | PK, FK | Service → `dim_service`. |
| weather_key | INT | FK | Weather in that hour → `dim_weather`. |
| trip_count | INT | | Number of trips (adjustment rows excluded). |
| adjustment_count | INT | | Number of reversal/refund rows (`trip_count = 0` in the fact). |
| passenger_count_sum | INT | | Sum of recorded passengers (taxis). |
| trip_distance_miles_sum | DECIMAL(14,2) | | Total miles. |
| trip_duration_seconds_sum | BIGINT | | Total trip seconds. |
| pickup_wait_seconds_sum | BIGINT | | Total HVFHV wait seconds. |
| pickup_wait_trip_count | INT | | Trips with a valid wait time (the denominator for average wait). |
| fare_amount_sum | DECIMAL(14,2) | | Total fare / base passenger fare. |
| tip_amount_sum | DECIMAL(14,2) | | Total tips. |
| total_amount_sum | DECIMAL(14,2) | | Total charged to passengers. |
| driver_pay_sum | DECIMAL(14,2) | | Total HVFHV driver pay. |
| cbd_congestion_fee_sum | DECIMAL(14,2) | | Total Congestion Relief Zone tolls. |
| cbd_trip_count | INT | | Trips charged the Congestion Relief Zone toll. |
| shared_trip_count | INT | | Trips that were matched as shared rides. |
| airport_dropoff_trip_count | INT | | Trips ending at an airport zone. |
| dwh_batch_id | INT | | Pipeline run that loaded the row. |
| dwh_load_datetime | DATETIME2(0) | | When the row was loaded. |

### gold.dim_date

**Purpose:** calendar attributes for analysing trips by day, week, month, holiday and congestion-pricing period. It is generated by the pipeline, not sourced; the calendar spans the reporting year ±1.

| Column | Data Type | Key | Description |
|---|---|---|---|
| date_key | INT | PK | Smart key yyyymmdd (e.g. 20250120). |
| full_date | DATE | UK | Calendar date. |
| day_of_month | TINYINT | | 1-31. |
| day_of_week | TINYINT | | ISO day of week: 1 = Monday … 7 = Sunday (independent of `DATEFIRST`). |
| day_name | VARCHAR(10) | | Monday … Sunday. |
| day_name_short | CHAR(3) | | Mon … Sun. |
| is_weekend | BIT | | 1 on Saturday and Sunday. |
| iso_week_of_year | TINYINT | | ISO 8601 week number. |
| month_number | TINYINT | | 1-12. |
| month_name | VARCHAR(10) | | January … December. |
| month_name_short | CHAR(3) | | Jan … Dec. |
| quarter_number | TINYINT | | 1-4. |
| year_number | SMALLINT | | Calendar year. |
| year_month | CHAR(7) | | 'yyyy-mm', sortable as text. |
| is_holiday | BIT | | 1 on a US federal holiday. |
| holiday_name | VARCHAR(50) | | Holiday name, computed by rule (e.g. MLK Day = 3rd Monday of January). NULL otherwise. |
| is_working_day | BIT | | 0 on weekends and holidays. |
| is_congestion_pricing_active | BIT | | 1 from 2025-01-05, when the MTA Congestion Relief Zone toll started. |

### gold.dim_time

**Purpose:** time-of-day attributes at minute grain (1,440 rows), generated by the pipeline.

| Column | Data Type | Key | Description |
|---|---|---|---|
| time_key | SMALLINT | PK | Smart key hhmm (e.g. 1745 = 17:45). |
| time_of_day | TIME(0) | | Clock time. |
| hour_24 | TINYINT | | 0-23. |
| minute_of_hour | TINYINT | | 0-59. |
| hour_label | CHAR(5) | | Hour bucket, e.g. '17:00'. |
| hour_12_label | VARCHAR(5) | | 12-hour label, e.g. '5 PM'. |
| quarter_hour_label | CHAR(5) | | 15-minute bucket, e.g. '17:45'. |
| day_part | VARCHAR(15) | | Overnight (0-5), Morning Rush (6-9), Midday (10-15), Evening Rush (16-19), Evening (20-23). |

### gold.dim_zone

**Purpose:** the 265 TLC taxi zones (roughly neighbourhoods). Role-played as pickup and dropoff zone.<br>
Source: `taxi_zone_lookup.csv`. The matching shapefile is in `lookup_tables/taxi_zones.zip` for map visuals.

| Column | Data Type | Key | Description |
|---|---|---|---|
| zone_key | SMALLINT | PK | Surrogate key. `-1` = Unknown. |
| location_id | SMALLINT | UK | TLC LocationID used in the trip records (1-265). |
| zone_name | VARCHAR(60) | | Zone name, e.g. 'JFK Airport'. **Not unique**: TLC reuses some names (e.g. two 'Corona' zones). |
| borough | VARCHAR(20) | | Manhattan, Brooklyn, Queens, Bronx, Staten Island, EWR, Outside NYC, Unknown. |
| service_zone | VARCHAR(20) | | TLC service area: Yellow Zone, Boro Zone, Airports, EWR, Unknown. |
| is_airport | BIT | | 1 for JFK, LaGuardia and Newark (EWR). |
| is_yellow_zone | BIT | | 1 in the Manhattan core, where green taxis may not pick up street hails. |
| is_within_nyc | BIT | | 1 for the five boroughs. |
| dwh_create_datetime | DATETIME2(0) | | When the member was first inserted. |
| dwh_update_datetime | DATETIME2(0) | | When its attributes were last overwritten (SCD Type 1). |

### gold.dim_service

**Purpose:** the four TLC trip record feeds.

| Column | Data Type | Key | Description |
|---|---|---|---|
| service_key | TINYINT | PK | Surrogate key. |
| service_code | VARCHAR(10) | UK | yellow, green, fhv, fhvhv. |
| service_name | VARCHAR(50) | | Yellow Taxi, Green Taxi (Street Hail Livery), For-Hire Vehicle, High-Volume For-Hire Vehicle. |
| service_category | VARCHAR(20) | | Taxi or For-Hire Vehicle. |
| has_fare_data | BIT | | 0 for FHV, which reports no fare information. |
| dwh_create_datetime / dwh_update_datetime | DATETIME2(0) | | Audit columns (SCD Type 1). |

### gold.dim_vendor

**Purpose:** the company that submitted the trip record to the TLC. For taxis this is the TPEP/LPEP technology provider; for HVFHV it is the licensed app company.

| Column | Data Type | Key | Description |
|---|---|---|---|
| vendor_key | SMALLINT | PK | Surrogate key. `-1` Unknown, `-2` Not Applicable (FHV). |
| vendor_code | VARCHAR(10) | UK | Taxi `VendorID` (1, 2, 6, 7) or HVFHS licence number (HV0002 … HV0005). |
| vendor_name | VARCHAR(100) | | E.g. Creative Mobile Technologies, Curb Mobility, Uber, Lyft. |
| vendor_type | VARCHAR(50) | | Taxi Technology Provider or High-Volume FHV Company. |
| dwh_create_datetime / dwh_update_datetime | DATETIME2(0) | | Audit columns (SCD Type 1). |

### gold.dim_payment_type

**Purpose:** how a taxi passenger paid.

| Column | Data Type | Key | Description |
|---|---|---|---|
| payment_type_key | SMALLINT | PK | Surrogate key. `-1` Unknown, `-2` Not Applicable (FHV/HVFHV). |
| payment_type_code | TINYINT | UK | TLC code: 0 Flex Fare trip, 1 Credit card, 2 Cash, 3 No charge, 4 Dispute, 5 Unknown, 6 Voided trip. |
| payment_type_name | VARCHAR(50) | | Description of the code. |
| payment_status | VARCHAR(20) | | Grouping: Paid (0, 1, 2), Not Paid (3, 4, 6), Unknown (5). |
| dwh_create_datetime / dwh_update_datetime | DATETIME2(0) | | Audit columns (SCD Type 1). |

### gold.dim_rate_code

**Purpose:** the final rate code in effect at the end of a taxi trip.

| Column | Data Type | Key | Description |
|---|---|---|---|
| rate_code_key | SMALLINT | PK | Surrogate key. `-1` Unknown, `-2` Not Applicable (FHV/HVFHV). |
| rate_code_id | TINYINT | UK | TLC code: 1 Standard, 2 JFK, 3 Newark, 4 Nassau or Westchester, 5 Negotiated fare, 6 Group ride, 99 Null/unknown. |
| rate_code_name | VARCHAR(50) | | Description of the code. |
| rate_type | VARCHAR(20) | | Grouping: Metered, Flat Rate (JFK), Negotiated, Unknown. |
| dwh_create_datetime / dwh_update_datetime | DATETIME2(0) | | Audit columns (SCD Type 1). |

### gold.dim_trip_profile

**Purpose:** a junk dimension that bundles seven low-cardinality trip flags behind one key. It holds every combination (3 × 3⁶ = 2,187 rows). Values are 'Yes', 'No' or 'N/A' (not reported by that service).

| Column | Data Type | Key | Description |
|---|---|---|---|
| trip_profile_key | SMALLINT | PK | Surrogate key. |
| hail_type | VARCHAR(15) | UK* | Street-hail, Dispatch or Unknown. Green trips report it; FHV/HVFHV are always Dispatch (they may not accept street hails); yellow does not report it. |
| store_and_forward | VARCHAR(3) | UK* | The taxi held the record in memory before sending it (no connection). |
| shared_ride_requested | VARCHAR(3) | UK* | HVFHV: the passenger agreed to a shared/pooled ride. |
| shared_ride_matched | VARCHAR(3) | UK* | The passenger actually shared the vehicle (HVFHV `shared_match_flag`, FHV `SR_Flag`). |
| wav_requested | VARCHAR(3) | UK* | HVFHV: a wheelchair-accessible vehicle was requested. |
| wav_matched | VARCHAR(3) | UK* | HVFHV: the trip happened in a wheelchair-accessible vehicle. |
| access_a_ride | VARCHAR(3) | UK* | HVFHV: the trip was administered on behalf of the MTA (Access-A-Ride). |

\* The seven columns together form the unique business key.

### gold.dim_weather

**Purpose:** hourly weather at Central Park, from an **external source** (Open-Meteo Historical Weather API, CC BY 4.0). Used to slice demand, fares and wait times by weather.

| Column | Data Type | Key | Description |
|---|---|---|---|
| weather_key | INT | PK | Smart key yyyymmddhh (NYC local time). `-1` = Unknown. |
| weather_datetime | DATETIME2(0) | | Start of the hour. |
| temperature_c / temperature_f | DECIMAL(4,1) | | Air temperature at 2 m, in °C / °F. |
| apparent_temperature_c | DECIMAL(4,1) | | "Feels like" temperature (wind chill). |
| temperature_band | VARCHAR(20) | | Severe Cold (< -5 °C), Freezing (< 0), Cold (< 10), Mild (< 20), Warm. |
| precipitation_mm | DECIMAL(5,1) | | Total precipitation in the hour (rain + snow water equivalent). |
| snowfall_cm | DECIMAL(5,2) | | Snowfall in the hour. |
| snow_depth_cm | DECIMAL(6,1) | | Snow on the ground. |
| precipitation_type | VARCHAR(10) | | None, Rain, Snow or Mixed. |
| precipitation_intensity | VARCHAR(10) | | None, Light (< 2.5 mm/h), Moderate (< 7.6 mm/h), Heavy. |
| is_precipitating | BIT | | 1 when any precipitation fell. |
| weather_code | TINYINT | | WMO weather interpretation code. |
| weather_condition | VARCHAR(30) | | Readable condition decoded from the WMO code (Clear, Overcast, Snow, ...). |
| cloud_cover_pct | TINYINT | | Cloud cover, 0-100 %. |
| wind_speed_kmh | DECIMAL(5,1) | | Wind speed at 10 m. |
| dwh_create_datetime / dwh_update_datetime | DATETIME2(0) | | Audit columns (SCD Type 1). |

---

## Silver Layer

Every Silver trip table also carries `trip_id` (surrogate identity, used for lineage), `dq_flags` (bitmask of broken [quality rules](#data-quality-rules)), `dwh_batch_id` and `dwh_load_datetime`.

### silver.yellow_tripdata / silver.green_tripdata

| Column | Data Type | Description |
|---|---|---|
| vendor_id | TINYINT | TPEP/LPEP provider code (see `tlc_code_values`, code_type 'vendor'). |
| pickup_datetime / dropoff_datetime | DATETIME2(0) | When the meter was engaged / disengaged. |
| pickup_location_id / dropoff_location_id | SMALLINT | TLC zone where the meter was engaged / disengaged. |
| passenger_count | TINYINT | Driver-entered passenger count; 0 or out-of-range values become NULL. |
| trip_distance_miles | DECIMAL(9,2) | Distance reported by the taximeter. |
| trip_duration_seconds | INT | Derived: dropoff minus pickup. NULL if it overflows INT (sentinel dates). |
| rate_code_id | TINYINT | Final rate code. NULL is mapped to 99 (Null/unknown), per the dictionary. |
| payment_type_id | TINYINT | Payment code. NULL is mapped to 5 (Unknown), per the dictionary. |
| trip_type_id | TINYINT | Green only: 1 Street-hail, 2 Dispatch. |
| is_store_and_forward | BIT | Y → 1, N → 0. |
| fare_amount, extra_amount, mta_tax, tip_amount, tolls_amount, improvement_surcharge, congestion_surcharge, airport_fee (yellow), cbd_congestion_fee, total_amount | DECIMAL(10,2) | Monetary fields as defined in the dictionary, converted from FLOAT to exact DECIMAL. |

### silver.fhv_tripdata

| Column | Data Type | Description |
|---|---|---|
| dispatching_base_num | CHAR(6) | TLC base licence that dispatched the trip. Upper-cased and validated against the format `B#####`. |
| affiliated_base_num | CHAR(6) | Base the vehicle is affiliated with. Free-text values ('United Cars', '1UBER', 'B3404', ...) fail validation and become NULL. |
| pickup_datetime / dropoff_datetime | DATETIME2(0) | Pickup / dropoff time. |
| pickup_location_id / dropoff_location_id | SMALLINT | TLC zones (pickup is missing on ~83% of FHV trips). |
| trip_duration_seconds | INT | Derived: dropoff minus pickup. |
| is_shared_ride | BIT | `SR_Flag` = 1 → 1; NULL (not shared) → 0. |

### silver.fhvhv_tripdata

| Column | Data Type | Description |
|---|---|---|
| hvfhs_license_num | CHAR(6) | HVFHS licence: HV0003 Uber, HV0005 Lyft (HV0002 Juno and HV0004 Via are no longer active). |
| dispatching_base_num / originating_base_num | CHAR(6) | Base that dispatched the trip / received the original request. |
| request_datetime | DATETIME2(0) | When the passenger requested the ride. |
| on_scene_datetime | DATETIME2(0) | When the driver arrived (reported for accessible-vehicle trips only). |
| pickup_datetime / dropoff_datetime | DATETIME2(0) | Pickup / dropoff time. |
| pickup_location_id / dropoff_location_id | SMALLINT | TLC zones. |
| trip_distance_miles | DECIMAL(9,2) | Source `trip_miles`. |
| trip_duration_seconds | INT | Source `trip_time`. |
| pickup_wait_seconds | INT | Derived: request to pickup. NULL when the pickup precedes the request. |
| base_passenger_fare | DECIMAL(10,2) | Fare before tolls, tips, taxes and fees. |
| tolls_amount, black_car_fund_amount, sales_tax, congestion_surcharge, airport_fee, cbd_congestion_fee, tip_amount | DECIMAL(10,2) | Source `tolls`, `bcf`, `sales_tax`, `congestion_surcharge`, `airport_fee`, `cbd_congestion_fee`, `tips`. |
| passenger_total_amount | DECIMAL(10,2) | Derived: everything the rider paid (fare + tolls + BCF + tax + surcharges + fees + tips). |
| driver_pay | DECIMAL(10,2) | Driver pay, net of commission, surcharges and taxes. |
| is_shared_request, is_shared_match, is_access_a_ride, is_wav_request, is_wav_match | BIT | Y/N flags converted to 1/0. |

### silver.tlc_taxi_zone_lookup

| Column | Data Type | Description |
|---|---|---|
| location_id | SMALLINT (PK) | TLC LocationID. |
| borough | VARCHAR(20) | 'N/A' → 'Unknown'; zone 265 → 'Outside NYC'. |
| zone_name | VARCHAR(60) | 'N/A' → 'Unknown'. |
| service_zone | VARCHAR(20) | 'N/A' → 'Unknown'. |

### silver.tlc_code_values

| Column | Data Type | Description |
|---|---|---|
| code_type | VARCHAR(20) (PK) | service_type, vendor, rate_code, payment_type, trip_type (CHECK constraint). |
| code | VARCHAR(10) (PK) | The code value as it appears in the trip records. |
| code_description | VARCHAR(100) | Meaning, from the data dictionary. |
| code_group | VARCHAR(50) | Grouping used by Gold (vendor type, payment status, rate type, service category). |
| source_document | VARCHAR(100) | Dictionary file the code was transcribed from. |

### silver.openmeteo_weather_hourly

| Column | Data Type | Description |
|---|---|---|
| weather_datetime | DATETIME2(0) (PK) | Hour start, NYC local time. |
| temperature_c, apparent_temperature_c | DECIMAL(4,1) | °C. |
| precipitation_mm, rain_mm | DECIMAL(5,1) | mm in the hour. |
| snowfall_cm | DECIMAL(5,2) | cm in the hour. |
| snow_depth_cm | DECIMAL(6,1) | Source metres × 100. |
| weather_code | TINYINT | WMO code. |
| weather_condition | VARCHAR(30) | Derived, readable WMO description. |
| cloud_cover_pct | TINYINT | 0-100 (CHECK constraint). |
| wind_speed_kmh | DECIMAL(5,1) | km/h. |

---

## Source-to-Silver Column Mapping

Bronze keeps the source column names exactly; Silver conforms them.

| Concept | Yellow (Bronze) | Green (Bronze) | FHV (Bronze) | HVFHV (Bronze) | Silver |
|---|---|---|---|---|---|
| Reporting company | VendorID | VendorID | – | hvfhs_license_num | vendor_id / hvfhs_license_num |
| Pickup time | tpep_pickup_datetime | lpep_pickup_datetime | pickup_datetime | pickup_datetime | pickup_datetime |
| Dropoff time | tpep_dropoff_datetime | lpep_dropoff_datetime | dropOff_datetime | dropoff_datetime | dropoff_datetime |
| Pickup zone | PULocationID | PULocationID | PUlocationID | PULocationID | pickup_location_id |
| Dropoff zone | DOLocationID | DOLocationID | DOlocationID | DOLocationID | dropoff_location_id |
| Distance | trip_distance | trip_distance | – | trip_miles | trip_distance_miles |
| Duration | *(derived)* | *(derived)* | *(derived)* | trip_time | trip_duration_seconds |
| Rate code | RatecodeID | RatecodeID | – | – | rate_code_id |
| Payment | payment_type | payment_type | – | – | payment_type_id |
| Fare | fare_amount | fare_amount | – | base_passenger_fare | fare_amount / base_passenger_fare |
| Tips | tip_amount | tip_amount | – | tips | tip_amount |
| Tolls | tolls_amount | tolls_amount | – | tolls | tolls_amount |
| Black Car Fund | – | – | – | bcf | black_car_fund_amount |
| Airport fee | Airport_fee | – | – | airport_fee | airport_fee |
| Total | total_amount | total_amount | – | *(derived)* | total_amount / passenger_total_amount |
| Store & forward | store_and_fwd_flag | store_and_fwd_flag | – | – | is_store_and_forward |
| Shared ride | – | – | SR_Flag | shared_request_flag, shared_match_flag | is_shared_ride / is_shared_request, is_shared_match |
| Dispatching base | – | – | dispatching_base_num | dispatching_base_num | dispatching_base_num |
| E-hail fee | – | ehail_fee | – | – | *(dropped: always NULL)* |

---

## Data-Quality Rules

`etl.dq_rule`: each Silver trip row carries `dq_flags`, the sum of the bits of the rules it breaks. Test with `dq_flags & rule_bit <> 0`.

| Bit | Rule | Severity | Meaning | Jan 2025 examples |
|---|---|---|---|---|
| 1 | OUT_OF_PERIOD | REJECT | Pickup outside the reporting month of the file | 22 yellow, 43 green |
| 2 | NEGATIVE_DURATION | REJECT | Dropoff before pickup | 124 yellow; 46 FHV (incl. a dropoff dated 1900-01-01) |
| 4 | EXCESSIVE_DURATION | REJECT | Trip longer than 24 hours | FHV dropoff dated 2029 |
| 8 | IMPLAUSIBLE_VALUE | REJECT | Distance > 250 miles or amount > $5,000 | Yellow trip of 276,424 miles; $863K fare |
| 16 | ZERO_DURATION | WARN | Pickup and dropoff timestamps identical | ~2K yellow |
| 32 | NEGATIVE_AMOUNT | WARN | Negative total (taxi) or base fare (HVFHV): a reversal or refund. Counted as `trip_count = 0` | ~63K yellow |
| 64 | MISSING_LOCATION | WARN | Pickup or dropoff zone not recorded | ~1.58M FHV |
| 128 | AMOUNT_NOT_RECONCILED | WARN | Taxi fare components do not sum to `total_amount` (known vendor behaviour, e.g. congestion surcharge also in `extra`) | ~1.1M yellow |

**REJECT** rows stay in Silver for audit but are excluded from Gold. **WARN** rows flow to Gold with the flag kept.

---

## ETL Control Tables

| Table | Description |
|---|---|
| `etl.load_log` | One row per table loaded per run: `batch_id`, layer, object, status, rows affected, start/end time, computed duration and, on failure, the error number, line, procedure and message captured in `TRY...CATCH`. |
| `etl.file_manifest` | The landing manifest: file, source system, reporting month, row count, file size and extraction time. Bronze reconciles its row counts against it. |
| `etl.dq_rule` | Catalogue of the data-quality rules above. |
| `etl.seq_batch_id` | Sequence that issues one batch id per pipeline run. |
