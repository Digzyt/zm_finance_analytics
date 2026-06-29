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
)

select
    tb.period,
    rl.report_line_code,
    rl.section,
    rl.line_order,
    rl.line_label,
    sum(tb.amount_kes * cast(rl.presentation_sign as int)) as amount_actual_kes
from tb
join map
  on map.company_name     = tb.company_name
 and map.local_account_no = tb.local_account_no
join rl
  on rl.report_line_code  = map.report_line_code
group by
    tb.period, rl.report_line_code, rl.section, rl.line_order, rl.line_label
