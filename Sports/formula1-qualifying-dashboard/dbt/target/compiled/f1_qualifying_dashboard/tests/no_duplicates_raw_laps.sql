-- tests/no_duplicate_raw_laps.sql
-- Fail = 0 rows returned
-- Warn = >0 rows returned




select
    driver,
    session,
    lap_time,
    speed,
    year,
    round,
    track,
    count(*) as row_count
from "f1"."main"."qualifying_laps"
group by 1,2,3,4,5,6,7
having count(*) > 1