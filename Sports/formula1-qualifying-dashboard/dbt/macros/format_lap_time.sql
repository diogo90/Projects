-- Macro to format lap time to the following: MM:SS:MS
-- This is how you can call the macro: {{ format_lap_time('lap_time') }} as lap_time_formatted

{% macro format_lap_time(seconds) %}
    lpad(cast(floor({{ seconds }} / 60) as varchar), 2, '0') || ':' ||
    lpad(cast(floor({{ seconds }} % 60) as varchar), 2, '0') || ':' ||
    lpad(cast(round(({{ seconds }} - floor({{ seconds }})) * 1000) as varchar), 3, '0')
{% endmacro %}
