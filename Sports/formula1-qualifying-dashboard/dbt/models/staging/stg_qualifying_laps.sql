-- ===============================================================
-- Model: stg_qualifying_laps
--
-- Purpose:
--   Provide a clean staging layer for qualifying lap data coming
--   directly from the raw FastF1 ingestion. This model standardises
--   the core fields (driver, session, lap_time, speed, year, round,
--   track) and exposes them without transformation so that downstream
--   intermediate models can compute fastest laps, pole deltas, and
--   other qualifying metrics.
--
-- Grain:
--   One row per recorded qualifying lap.
--
-- Upstream:
--   - f1_raw.qualifying_laps (raw ingestion from FastF1)
--
-- Downstream:
--   - int_qualifying_laps_with_teams
--   - best_laps_summary
--   - Any models requiring lap‑level qualifying data
-- ===============================================================

with qualifying_laps as (

    select
        driver,
        session,
        lap_time,
        speed,
        year,
        round,
        track
    
    from {{ source('f1_raw', 'qualifying_laps') }}

)
select * from qualifying_laps