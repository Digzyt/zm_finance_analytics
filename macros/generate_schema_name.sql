{# =============================================================================
   generate_schema_name — override dbt's default schema-name resolution.

   Default behaviour: when a model/seed has `+schema: bronze_source`, dbt
   prepends the target schema, producing `dbt_dev_bronze_source`. But sources
   use the `schema:` value literally — they look for `bronze_source`. That
   creates a mismatch where seeds land in one place and sources read from
   another.

   This override makes the custom schema name LITERAL — i.e., `+schema: bronze_source`
   creates and reads from `bronze_source` directly. Same on both sides.

   See dbt docs: https://docs.getdbt.com/docs/build/custom-schemas
   ============================================================================= #}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
