{# =============================================================================
   test_overrides.sql

   Project-level overrides for dbt-core's generic test macros. The default
   versions reference column names without quoting, which breaks on Postgres
   when columns are case-preserved (e.g., "Company_Name"). These overrides
   wrap every column reference in `adapter.quote()` so the case survives.

   Project macros take precedence over dbt-core's defaults via dbt's
   resolution order: project > installed packages > dbt-core.

   Applies to: not_null, unique, accepted_values, relationships
   For dbt_utils.unique_combination_of_columns, add `quote_columns: true`
   to the YAML test config — the macro supports that natively.
   ============================================================================= #}


{% macro default__test_not_null(model, column_name) %}

select *
from {{ model }}
where {{ adapter.quote(column_name) }} is null

{% endmacro %}


{% macro default__test_unique(model, column_name) %}

select
    {{ adapter.quote(column_name) }} as unique_field,
    count(*) as n_records

from {{ model }}
where {{ adapter.quote(column_name) }} is not null
group by {{ adapter.quote(column_name) }}
having count(*) > 1

{% endmacro %}


{% macro default__test_accepted_values(model, column_name, values, quote=True) %}

with all_values as (

    select
        {{ adapter.quote(column_name) }} as value_field,
        count(*) as n_records

    from {{ model }}

    group by {{ adapter.quote(column_name) }}

)

select *
from all_values
where value_field not in (
    {% for value in values -%}
        {% if quote -%}
        '{{ value }}'
        {%- else -%}
        {{ value }}
        {%- endif -%}
        {%- if not loop.last -%},{%- endif %}
    {%- endfor %}
)

{% endmacro %}


{% macro default__test_relationships(model, column_name, to, field) %}

with child as (
    select {{ adapter.quote(column_name) }} as from_field
    from {{ model }}
    where {{ adapter.quote(column_name) }} is not null
),

parent as (
    select {{ adapter.quote(field) }} as to_field
    from {{ to }}
)

select
    from_field

from child
left join parent
    on child.from_field = parent.to_field

where parent.to_field is null

{% endmacro %}
