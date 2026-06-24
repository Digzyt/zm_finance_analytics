{# =============================================================================
   cross_db_helpers.sql

   Adapter-dispatched macros for SQL that genuinely differs between
   PostgreSQL and Microsoft Fabric (T-SQL).

   General rule (from DISCIPLINES.md):
     1. Try dbt-built-in (`dbt.date_trunc`, `dbt.concat`, `dbt.type_string`, ...)
     2. Try dbt-utils
     3. Only then write a custom dispatch macro here.

   Usage in models:
     {{ zamara_finance.safe_string_md5('Description') }}
     {{ zamara_finance.year_month_string('Posting_Date') }}
   ============================================================================= #}


{# -----------------------------------------------------------------------------
   safe_string_md5 — MD5 of a string column, returned as lowercase hex.
   Used by per_subsidiary models (MENA / Nigeria) to synthesise stable account
   codes from descriptions.
----------------------------------------------------------------------------- #}

{% macro safe_string_md5(col) -%}
    {{ adapter.dispatch('safe_string_md5', 'zamara_finance')(col) }}
{%- endmacro %}

{% macro default__safe_string_md5(col) -%}
    md5({{ col }})
{%- endmacro %}

{% macro postgres__safe_string_md5(col) -%}
    md5({{ col }})
{%- endmacro %}

{% macro fabric__safe_string_md5(col) -%}
    convert(varchar(32), hashbytes('MD5', cast({{ col }} as varchar(max))), 2)
{%- endmacro %}


{# -----------------------------------------------------------------------------
   year_month_string — format a date column as 'YYYY-MM' string. Used for the
   period column. Postgres uses TO_CHAR; Fabric uses FORMAT.
----------------------------------------------------------------------------- #}

{% macro year_month_string(col) -%}
    {{ adapter.dispatch('year_month_string', 'zamara_finance')(col) }}
{%- endmacro %}

{% macro postgres__year_month_string(col) -%}
    to_char({{ col }}, 'YYYY-MM')
{%- endmacro %}

{% macro fabric__year_month_string(col) -%}
    format({{ col }}, 'yyyy-MM')
{%- endmacro %}


{# -----------------------------------------------------------------------------
   date_part — extract a date part from a date/timestamp.
   `dbt.date_part` doesn't exist in dbt-core; `dbt_utils.date_part` was removed
   in dbt-utils 1.0. So we own this one.
----------------------------------------------------------------------------- #}

{% macro date_part(datepart, expression) -%}
    {{ adapter.dispatch('date_part', 'zamara_finance')(datepart, expression) }}
{%- endmacro %}

{% macro default__date_part(datepart, expression) -%}
    extract({{ datepart }} from {{ expression }})
{%- endmacro %}

{% macro postgres__date_part(datepart, expression) -%}
    extract({{ datepart }} from {{ expression }})
{%- endmacro %}

{% macro fabric__date_part(datepart, expression) -%}
    datepart({{ datepart }}, {{ expression }})
{%- endmacro %}


{# -----------------------------------------------------------------------------
   safe_divide — avoids #DIV/0 on both dialects. Use this in mart models for
   percentage calculations rather than raw `a / b`.
----------------------------------------------------------------------------- #}

{% macro safe_divide(numerator, denominator) -%}
    case
        when coalesce({{ denominator }}, 0) = 0 then null
        else ({{ numerator }} * 1.0) / {{ denominator }}
    end
{%- endmacro %}


{# -----------------------------------------------------------------------------
   Dialect lint regex (for CI use).
   Run this against the models/ tree before each PR to surface accidental
   Postgres-isms that would break on Fabric.

   Example (bash):
       grep -RIEn '\\|\\||TO_CHAR\\(|DATE_TRUNC\\(|EXTRACT\\(|::|ILIKE|JSONB|GENERATE_SERIES\\(' \\
            datamodel/models/ datamodel/macros/ \\
            && echo "ERROR: Postgres-specific syntax found"
----------------------------------------------------------------------------- #}
