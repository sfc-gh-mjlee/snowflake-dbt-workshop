{% macro safe_divide(numerator, denominator) %}
    iff(
        {{ denominator }} = 0 or {{ denominator }} is null,
        null,
        {{ numerator }} / nullif({{ denominator }}, 0)
    )
{% endmacro %}
