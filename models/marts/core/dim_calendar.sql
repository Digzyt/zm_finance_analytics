{{
  config(
    materialized = 'table',
    tags = ['marts', 'core', 'dim']
  )
}}

-- =============================================================================
-- dim_calendar — uses dbt_utils.date_spine + dbt_utils.date_part for
-- cross-DB compatibility. Generates daily granularity from 2024-01-01 to
-- 2027-12-31, then derives month / quarter / year columns.
-- =============================================================================

with spine as (
    {{ dbt_utils.date_spine(
        datepart  = "day",
        start_date = "cast('2024-01-01' as date)",
        end_date   = "cast('2028-01-01' as date)"
    ) }}
)

select
    cast(date_day as date)                                                         as calendar_date,
    {{ zamara_finance.date_part('year',    'date_day') }}                           as year,
    {{ zamara_finance.date_part('quarter', 'date_day') }}                           as quarter,
    {{ zamara_finance.date_part('month',   'date_day') }}                           as month,
    {{ dbt.date_trunc('month', 'date_day') }}                                       as month_start,
    {{ zamara_finance.year_month_string('cast(date_day as date)') }}                as period,
    {{ dbt_utils.generate_surrogate_key(['date_day']) }}                            as calendar_key
from spine
