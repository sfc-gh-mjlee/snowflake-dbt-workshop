{% macro format_currency(column_name, scale=2) %}
    round({{ column_name }}, {{ scale }})
{% endmacro %}
