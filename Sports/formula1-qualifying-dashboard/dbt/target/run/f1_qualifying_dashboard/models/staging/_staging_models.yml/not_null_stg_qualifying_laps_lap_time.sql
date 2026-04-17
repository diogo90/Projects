
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select lap_time
from "f1"."main_staging"."stg_qualifying_laps"
where lap_time is null



  
  
      
    ) dbt_internal_test