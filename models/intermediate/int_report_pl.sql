{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'management_reporting']
  )
}}

-- =============================================================================
-- int_report_pl — management P&L layer for the "Zamara Group Financial Report".
--
-- Re-pivots the SCI side of int_fx_translation from IFRS statement lines into
-- the management taxonomy used by the monthly Group/CEO pack: revenue at entity
-- grain (Kenyan entities as single revenue lines; ZAMRE / Zarinet / MENA as
-- single net lines) and expenses by NATURE (Personnel, Travelling, Premises...).
--
-- The (company, account) -> report_line mapping lives in the report_line_map
-- seed; the line taxonomy + presentation sign live in the report_line seed.
-- This is additive: it does not touch the IFRS rpt_consolidated_* marts.
--
-- amount_kes from int_fx_translation is sign-normalised (income & expense both
-- positive). presentation_sign flips expenses negative for P&L presentation.
-- period flows from stg_* (now a real dimension): every period appears in the mart.
-- =============================================================================

with tb as (
    select * from {{ ref('int_fx_translation') }}
    where statement_type = 'SCI'
),

map as (
    select * from {{ ref('report_line_map') }}
),

rl as (
    select * from {{ ref('report_line') }}
),

-- TB-derived report-line amounts (presentation-signed)
tb_lines as (
    select
        tb.period,
        map.report_line_code,
        sum(tb.amount_kes * cast(rl.presentation_sign as int)) as amount_kes
    from tb
    join map
      on map.company_name     = tb.company_name
     and map.local_account_no = tb.local_account_no
    join rl
      on rl.report_line_code  = map.report_line_code
    group by tb.period, map.report_line_code
),

-- Manual P&L adjustments NOT in the TB (e.g. Exceptional Items). Amounts are
-- already in report presentation terms (positive = increases profit).
manual as (
    select
        period,
        report_line_code,
        sum(cast(amount_kes as numeric(20,4))) as amount_kes
    from {{ ref('manual_pl_adjustments') }}
    group by period, report_line_code
),

combined as (
    select period, report_line_code, amount_kes from tb_lines
    union all
    select period, report_line_code, amount_kes from manual
)

select
    c.period,
    c.report_line_code,
    rl.section,
    rl.line_order,
    rl.line_label,
    sum(c.amount_kes) as amount_actual_kes
from combined c
join rl on rl.report_line_code = c.report_line_code
group by c.period, c.report_line_code, rl.section, rl.line_order, rl.line_label
