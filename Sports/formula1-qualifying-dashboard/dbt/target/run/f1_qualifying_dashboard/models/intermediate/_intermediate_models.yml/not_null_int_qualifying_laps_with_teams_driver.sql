
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select driver
from "f1"."main"."int_qualifying_laps_with_teams"
where driver is null



  
  
      
    ) dbt_internal_test