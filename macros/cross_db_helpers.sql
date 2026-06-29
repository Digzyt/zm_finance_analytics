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
   period_end_date(period)

   Pure-Jinja helper: given a reporting period 'YYYY-MM', returns the last
   calendar day of that month as a 'YYYY-MM-DD' string. Used to filter the
   cumulative G/L movement seeds to the balance "as at" the reporting period.
   Pure Jinja (no SQL) so it is identical on Postgres and Fabric.
   ----------------------------------------------------------------------------- #}
{% macro period_end_date(period) %}
  {%- set parts = period.split('-') -%}
  {%- set y = parts[0] | int -%}
  {%- set m = parts[1] | int -%}
  {%- set last = {1:31, 2:28, 3:31, 4:30, 5:31, 6:30, 7:31, 8:31, 9:30, 10:31, 11:30, 12:31} -%}
  {%- set d = last[m] -%}
  {%- if m == 2 and (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) -%}
    {%- set d = 29 -%}
  {%- endif -%}
  {{- '%04d-%02d-%02d' | format(y, m, d) -}}
{% endmacro %}


{# -----------------------------------------------------------------------------
   Dialect lint regex (for CI use). Surface accidental Postgres-isms before a PR:
       grep -RIEn '\|\||TO_CHAR\(|DATE_TRUNC\(|EXTRACT\(|::|ILIKE|JSONB' \
            datamodel/models/ datamodel/macros/ && echo "ERROR: Postgres-specific syntax found"
----------------------------------------------------------------------------- #}
