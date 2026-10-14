{#- Generic test written in-house (no external packages, so the project
    deploys to Snowflake without an external access integration). -#}
{% test positive_value(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} <= 0
{% endtest %}
