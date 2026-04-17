
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select speed
from "f1"."main"."qualifying_laps"
where speed is null



  
  
      
    ) dbt_internal_test