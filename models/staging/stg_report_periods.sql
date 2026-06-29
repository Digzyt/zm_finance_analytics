{{
  config(
    materialized = 'view',
    tags = ['staging', 'periods']
  )
}}

-- =============================================================================
-- stg_report_periods — the reporting-period spine.
--
-- The bronze gl_entry seeds carry monthly G/L *movements*, each dated to its
-- month-end. The distinct month-ends are the reporting periods. Downstream
-- staging models cross-join this spine so a movement contributes to EVERY
-- period >= its own month, giving the cumulative trial-balance "as at" each
-- period. period is the 'YYYY-MM' label; period_end is the month-end date.
--
-- Sourced from gl_entry_zaac + gl_entry_mena (which between them carry every
-- month present in the pack) so it does not depend on stg_gl_entry (avoids a
-- staging cycle) and covers both the standard and descriptive seed shapes.
-- =============================================================================

with raw_dates as (
    select cast("Posting_Date" as date) as period_end from {{ source('bronze_source', 'gl_entry_zaac') }}
    union
    select cast("Posting_Date" as date) as period_end from {{ source('bronze_source', 'gl_entry_mena') }}
)

select distinct
    period_end,
    {{ zamara_finance.year_month_string('period_end') }} as period
from raw_dates
where period_end is not null
