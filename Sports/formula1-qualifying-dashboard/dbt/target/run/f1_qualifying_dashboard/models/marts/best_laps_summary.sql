
  
  create view "f1"."main"."best_laps_summary__dbt_tmp" as (
    -- ===============================================================
-- Model: best_laps_summary
-- Purpose:
--   Extract the fastest qualifying lap per driver, per year, per track.
--   This is the correct grain for scatterplots comparing drivers
--   (e.g., Speed vs Lap Time) because each driver appears once.
--
-- Logic:
--   1. Identify each driver's fastest lap for a given year + track.
--   2. Join back to the lap-level table to retrieve the speed
--      and any other attributes from that specific lap.
--
-- Grain:
--   One row per driver per year per track (fastest lap only).
--
-- Upstream:
--   - int_qualifying_laps_with_teams (one row per lap)
-- ===============================================================

with best_laps as (

    select
        driver,
        year,
        track,
        min(lap_time) as best_lap_time

    from "f1"."main"."int_qualifying_laps_with_teams"
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
        
    lpad(cast(floor(q.lap_time / 60) as varchar), 2, '0') || ':' ||
    lpad(cast(floor(q.lap_time % 60) as varchar), 2, '0') || ':' ||
    lpad(cast(round((q.lap_time - floor(q.lap_time)) * 1000) as varchar), 3, '0')
 as fastest_lap_time_formatted,
        q.speed as speed_on_fastest_lap,
        q.session
        
    from "f1"."main"."int_qualifying_laps_with_teams" q
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
  );
