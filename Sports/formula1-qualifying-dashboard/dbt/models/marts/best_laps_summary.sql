-- ===============================================================
-- Model: best_laps_summary
--
-- Purpose:
--   Produce a clean, analysis‑ready table containing each driver's
--   fastest qualifying lap for a given year and Grand Prix, along
--   with the delta to pole position and a formatted lap‑time string.
--   This model is used for visualisations such as Speed vs Lap Time
--   scatterplots, where each driver must appear exactly once.
--
-- Logic:
--   1. From the lap‑level dataset, identify the fastest lap per
--      driver for each (year, track) combination.
--   2. Determine the overall fastest lap ("pole time") for each
--      qualifying session.
--   3. Join back to the lap‑level table to retrieve attributes
--      from the actual fastest lap (speed, session, etc.).
--   4. Compute the lap delta as:
--         fastest_lap_time - pole_time
--      so the pole sitter has delta = 0.000 and all others have
--      small positive values.
--   5. Format the lap time into FIA‑style M:SS.mmm using the
--      format_lap_time macro.
--
-- Grain:
--   One row per driver per year per track (fastest qualifying lap).
--
-- Upstream:
--   - int_qualifying_laps_with_teams (one row per lap, including
--     driver, team, lap_time, speed, session, year, track)
--
-- Downstream:
--   - Tableau dashboards comparing qualifying performance
--   - Any analysis requiring fastest‑lap deltas or speed‑vs‑time
-- ===============================================================

with best_laps as (

    select
        driver,
        year,
        track,
        min(lap_time) as best_lap_time

    from {{ ref('int_qualifying_laps_with_teams') }}
    group by 1,2,3
)

, min_fastest_lap as (

    select
        year,
        track,
        min(best_lap_time) as pole_time
    from best_laps
    group by 1,2

)

, best_lap_details as (

    select
        q.driver,
        q.team,
        q.year,
        q.track,
        q.lap_time as fastest_lap_time,
        {{ format_lap_time('q.lap_time') }} as fastest_lap_time_formatted,
        q.speed as speed_on_fastest_lap,
        q.session
        
    from {{ ref('int_qualifying_laps_with_teams') }} q
    inner join best_laps b
        on q.driver = b.driver
       and q.year = b.year
       and q.track = b.track
       and q.lap_time = b.best_lap_time
)

, final as (

    select
        b.*,
        b.fastest_lap_time - m.pole_time as lap_delta
    
    from best_lap_details b
    
    join min_fastest_lap m
      on b.year = m.year
     and b.track = m.track

)
select * from final