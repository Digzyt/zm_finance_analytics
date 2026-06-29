{{
  config(
    materialized = 'table',
    tags = ['marts', 'consolidation', 'report', 'management_reporting']
  )
}}

-- =============================================================================
-- rpt_group_pl — "Zamara Group Financial Report" management P&L (the "Group"
-- sheet of the monthly CEO pack). One row per report line for the reporting
-- period, with Actual / Budget / Variance and a Prior-Year placeholder.
--
-- Columns mirror the workbook:
--   amount_actual_gross_kes  - Actual before bad-debt provision (= Actual today)
--   bad_debt_provision_kes   - separate Wave 3.2 computation (NULL until built)
--   amount_actual_net_kes    - Actual after provision (= gross until 3.2 lands)
--   amount_budget_kes        - from the budget seed (2026-04 loaded; more later)
--   variance_kes / _pct      - Actual(Net) vs Budget
--   amount_prior_year_kes    - NULL until 2025 monthly TBs are loaded
--
-- Reconciliation status (as at 2026-04, see handover): Kenyan expense-by-nature
-- and ZAMRE tie to the workbook; ZARIB/ZAAC revenue (gross-vs-net definition),
-- MENA (balance-sheet-heavy provisional mapping) and Zarinet (unmapped accounts)
-- carry documented variances pending the Finance account-map review.
-- =============================================================================

with rl as (
    select * from {{ ref('report_line') }}
),

actual as (
    select * from {{ ref('int_report_pl') }}
),

bud as (
    select * from {{ ref('budget') }}
),

periods as (
    select distinct period from actual
)

select
    p.period,
    rl.report_line_code,
    rl.section,
    rl.line_order,
    rl.line_label,

    coalesce(a.amount_actual_kes, 0)                       as amount_actual_gross_kes,
    cast(null as {{ dbt.type_numeric() }})                 as bad_debt_provision_kes,
    coalesce(a.amount_actual_kes, 0)                       as amount_actual_net_kes,

    b.amount_budget_kes                                    as amount_budget_kes,
    coalesce(a.amount_actual_kes, 0) - coalesce(b.amount_budget_kes, 0) as variance_kes,
    {{ zamara_finance.safe_divide(
         'coalesce(a.amount_actual_kes,0) - coalesce(b.amount_budget_kes,0)',
         'b.amount_budget_kes') }}                         as variance_pct,

    cast(null as {{ dbt.type_numeric() }})                 as amount_prior_year_kes

from periods p
cross join rl
left join actual a
       on a.report_line_code = rl.report_line_code
      and a.period           = p.period
left join bud b
       on b.report_line_code = rl.report_line_code
      and b.period           = p.period
order by p.period, rl.line_order
