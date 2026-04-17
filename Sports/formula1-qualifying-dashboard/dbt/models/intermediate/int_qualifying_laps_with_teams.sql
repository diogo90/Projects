-- Model: int_qualifying_laps_with_teams
-- Purpose:
--   Enrich qualifying lap data with constructor (team) information
--   by mapping each driver/year combination to the correct team.
--
-- Data Sources:
--   - main_staging.stg_qualifying_laps
--   - main.int_dim_driver_team
--       • Official F1 team lineups for seasons 2019–2023 & 2026
--
-- Key Notes:
--   • This model assumes FIA-standard 3‑letter driver codes.
--   • Team mappings are season‑specific and historically accurate.
--   • Only years present in the source dataset are included.
--   • 2026 mappings follow the custom future lineup provided.
--   • All driver/year combinations in the staging model are covered.


with qualifying_laps_with_teams as (

    select
        q.driver,
        q.session,
        q.lap_time,
        q.speed,
        q.year,
        q.round,
        q.track,
        d.team
    from {{ ref('stg_qualifying_laps') }} q
    left join {{ ref('int_dim_driver_team') }} d
        on q.driver = d.driver
        and q.year = d.year

)
select * from qualifying_laps_with_teams