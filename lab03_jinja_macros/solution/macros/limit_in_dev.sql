{% macro limit_in_dev(row_limit=1000) %}
    {% if target.name != 'prod' %}
        limit {{ row_limit }}
    {% endif %}
{% endmacro %}
