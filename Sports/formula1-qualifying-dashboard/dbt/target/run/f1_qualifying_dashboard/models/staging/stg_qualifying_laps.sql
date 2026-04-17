
  
  create view "f1"."main_staging"."stg_qualifying_laps__dbt_tmp" as (
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
  );
