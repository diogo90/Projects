/*
===============================================================================
Business Questions answered by the Gold layer
===============================================================================
Purpose:
    Example analytical queries showing what the star schema makes easy.
    Each query states the question, then answers it with plain joins from the
    facts to the conformed dimensions.

Notes:
    - Trip counts use SUM(trip_count), not COUNT(*): reversal/refund rows have
      trip_count = 0 so they net revenue without inflating trip volumes.
    - Averages are always SUM / SUM (weighted), never AVG of pre-aggregated
      averages.
    - Queries on fact_trips_hourly avoid scanning the 25M-row trip fact.
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- -----------------------------------------------------------------------------
-- Q1. Market share: how are trips split between taxis and app-based services
--     in each pickup borough?
-- -----------------------------------------------------------------------------
SELECT
    z.borough,
    s.service_name,
    SUM(h.trip_count)                                                              AS trips,
    CAST(100.0 * SUM(h.trip_count) / SUM(SUM(h.trip_count)) OVER (PARTITION BY z.borough) AS DECIMAL(5,1)) AS share_of_borough_pct
FROM gold.fact_trips_hourly AS h
JOIN gold.dim_zone          AS z ON z.zone_key    = h.pickup_zone_key
JOIN gold.dim_service       AS s ON s.service_key = h.service_key
GROUP BY z.borough, s.service_name
ORDER BY z.borough, trips DESC;

-- -----------------------------------------------------------------------------
-- Q2. Congestion pricing: the MTA Congestion Relief Zone toll started on
--     2025-01-05, inside this very month. How many trips were charged, and did
--     yellow-taxi and HVFHV demand shift after go-live?
-- -----------------------------------------------------------------------------
SELECT
    IIF(d.is_congestion_pricing_active = 1, 'After 5 Jan (toll live)', 'Before 5 Jan') AS period,
    s.service_name,
    COUNT(DISTINCT d.date_key)                                                        AS days,
    SUM(h.trip_count) / COUNT(DISTINCT d.date_key)                                    AS avg_trips_per_day,
    CAST(100.0 * SUM(h.cbd_trip_count) / NULLIF(SUM(h.trip_count), 0) AS DECIMAL(5,1)) AS pct_trips_charged_cbd_fee,
    CAST(SUM(h.cbd_congestion_fee_sum) AS DECIMAL(14,2))                              AS cbd_fees_collected
FROM gold.fact_trips_hourly AS h
JOIN gold.dim_date          AS d ON d.date_key    = h.pickup_date_key
JOIN gold.dim_service       AS s ON s.service_key = h.service_key
WHERE s.has_fare_data = 1
GROUP BY d.is_congestion_pricing_active, s.service_name
ORDER BY s.service_name, period DESC;

-- -----------------------------------------------------------------------------
-- Q3. Demand pattern: average trips per hour by day of week and day part.
-- -----------------------------------------------------------------------------
SELECT
    d.day_of_week,
    d.day_name,
    t.day_part,
    SUM(h.trip_count) / COUNT(DISTINCT CONCAT(h.pickup_date_key, '-', h.pickup_hour_key)) AS avg_trips_per_hour
FROM gold.fact_trips_hourly AS h
JOIN gold.dim_date          AS d ON d.date_key = h.pickup_date_key
JOIN gold.dim_time          AS t ON t.time_key = h.pickup_hour_key
GROUP BY d.day_of_week, d.day_name, t.day_part
ORDER BY d.day_of_week, MIN(t.hour_24);

-- -----------------------------------------------------------------------------
-- Q4. Weather impact: does snow or rain change demand and rideshare wait time?
--     (Uses the external weather source joined through dim_weather.)
-- -----------------------------------------------------------------------------
SELECT
    w.precipitation_type,
    w.temperature_band,
    COUNT(DISTINCT h.weather_key)                                                         AS hours_observed,
    SUM(h.trip_count) / NULLIF(COUNT(DISTINCT h.weather_key), 0)                          AS avg_trips_per_hour,
    CAST(SUM(h.pickup_wait_seconds_sum) / 60.0 / NULLIF(SUM(h.pickup_wait_trip_count), 0) AS DECIMAL(5,2)) AS avg_hvfhv_wait_minutes
FROM gold.fact_trips_hourly AS h
JOIN gold.dim_weather       AS w ON w.weather_key = h.weather_key
GROUP BY w.precipitation_type, w.temperature_band
ORDER BY w.precipitation_type, w.temperature_band;

-- -----------------------------------------------------------------------------
-- Q5. Tipping: tip rate by payment type for taxis.
--     (Cash tips are not recorded by the meter, so cash shows ~0% by design.)
-- -----------------------------------------------------------------------------
SELECT
    s.service_name,
    p.payment_type_name,
    SUM(f.trip_count)                                                                    AS trips,
    CAST(100.0 * SUM(f.tip_amount) / NULLIF(SUM(f.fare_amount), 0) AS DECIMAL(5,1))     AS tip_pct_of_fare
FROM gold.fact_trips       AS f
JOIN gold.dim_service      AS s ON s.service_key      = f.service_key
JOIN gold.dim_payment_type AS p ON p.payment_type_key = f.payment_type_key
WHERE s.service_category = 'Taxi'
  AND f.trip_count = 1
GROUP BY s.service_name, p.payment_type_name
ORDER BY s.service_name, trips DESC;

-- -----------------------------------------------------------------------------
-- Q6. Rideshare economics: what share of the rider's payment reaches the
--     driver, by company and pickup borough?
-- -----------------------------------------------------------------------------
SELECT
    v.vendor_name                                                                        AS company,
    z.borough                                                                            AS pickup_borough,
    SUM(f.trip_count)                                                                    AS trips,
    CAST(SUM(f.total_amount) / NULLIF(SUM(f.trip_count), 0) AS DECIMAL(8,2))             AS avg_rider_total,
    CAST(SUM(f.driver_pay)   / NULLIF(SUM(f.trip_count), 0) AS DECIMAL(8,2))             AS avg_driver_pay,
    CAST(100.0 * SUM(f.driver_pay) / NULLIF(SUM(f.total_amount), 0) AS DECIMAL(5,1))     AS driver_share_pct
FROM gold.fact_trips  AS f
JOIN gold.dim_vendor  AS v ON v.vendor_key = f.vendor_key
JOIN gold.dim_zone    AS z ON z.zone_key   = f.pickup_zone_key
WHERE v.vendor_type = 'High-Volume FHV Company'
GROUP BY v.vendor_name, z.borough
ORDER BY company, trips DESC;

-- -----------------------------------------------------------------------------
-- Q7. Airports: which services carry passengers FROM the airports, and what
--     does the average trip cost?
-- -----------------------------------------------------------------------------
SELECT
    z.zone_name                                                                          AS airport,
    s.service_name,
    SUM(f.trip_count)                                                                    AS trips,
    CAST(SUM(f.total_amount) / NULLIF(SUM(f.trip_count), 0) AS DECIMAL(8,2))             AS avg_total_amount,
    CAST(SUM(f.trip_distance_miles) / NULLIF(SUM(f.trip_count), 0) AS DECIMAL(6,2))      AS avg_miles
FROM gold.fact_trips  AS f
JOIN gold.dim_zone    AS z ON z.zone_key    = f.pickup_zone_key
JOIN gold.dim_service AS s ON s.service_key = f.service_key
WHERE z.is_airport = 1
GROUP BY z.zone_name, s.service_name
ORDER BY z.zone_name, trips DESC;

-- -----------------------------------------------------------------------------
-- Q8. Top 10 origin -> destination zone pairs (role-playing dim_zone).
-- -----------------------------------------------------------------------------
SELECT TOP (10)
    pz.zone_name                                                                         AS pickup_zone,
    dz.zone_name                                                                         AS dropoff_zone,
    SUM(f.trip_count)                                                                    AS trips
FROM gold.fact_trips AS f
JOIN gold.dim_zone   AS pz ON pz.zone_key = f.pickup_zone_key
JOIN gold.dim_zone   AS dz ON dz.zone_key = f.dropoff_zone_key
WHERE f.pickup_zone_key > 0 AND f.dropoff_zone_key > 0
GROUP BY pz.zone_name, dz.zone_name
ORDER BY trips DESC;
GO
