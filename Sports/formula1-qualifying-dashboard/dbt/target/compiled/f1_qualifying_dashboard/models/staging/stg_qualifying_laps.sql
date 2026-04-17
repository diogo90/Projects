with qualifying_laps as (

    select
        driver,
        session,
        lap_time,
        speed,
        year,
        round,
        track
    
    from "f1"."main"."qualifying_laps"

)
select * from qualifying_laps