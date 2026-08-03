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
--   bad_debt_provision_kes   - from bad_debt_provision seed (Debtor Analysis); reduces revenue
--   amount_actual_net_kes    - Actual gross less bad-debt provision (matches workbook Net)
--   amount_budget_kes        - from the budget seed (Jan-Jun 2026 all loaded)
--   variance_kes / _pct      - Actual(Net) vs Budget
--   amount_prior_year_kes    - NULL; see the note at the bottom of this model
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

prov as (
    select * from {{ ref('int_bad_debt_provision') }}
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
    -- provision reduces revenue (stored negative); NULL on non-revenue lines
    case when pr.provision_kes is not null
         then -pr.provision_kes else cast(null as {{ dbt.type_numeric() }})
    end                                                    as bad_debt_provision_kes,
    coalesce(a.amount_actual_kes, 0) - coalesce(pr.provision_kes, 0) as amount_actual_net_kes,

    b.amount_budget_kes                                    as amount_budget_kes,
    (coalesce(a.amount_actual_kes,0) - coalesce(pr.provision_kes,0)) - coalesce(b.amount_budget_kes, 0) as variance_kes,
    {{ zamara_finance.safe_divide(
         '(coalesce(a.amount_actual_kes,0) - coalesce(pr.provision_kes,0)) - coalesce(b.amount_budget_kes,0)',
         'b.amount_budget_kes') }}                         as variance_pct,

    -- Prior year is deliberately NULL, and the column is kept so the mart's shape
    -- does not move under Power BI when it is populated.
    --
    -- The client's Budget and LYTD Comparison workbook does carry an LYMTD ('last
    -- year, same month') actual column, and it would populate this cheaply. It is
    -- not used, on purpose. Once a full year of our own actuals exists, prior year
    -- should be DERIVED from fct_trial_balance at period minus twelve months, so
    -- this column equals the actual we published a year earlier. Taking the
    -- client's comparative instead would give a prior year that disagrees with our
    -- own published figures — the recon has already found defects in their
    -- statements (C&P's group-TB code shifts, ZATL's rate references) — and would
    -- have to be unwound. It also needs the fiscal-year gap closed first: the
    -- period cross-join has no lower bound, so the SCI does not reset at a year
    -- boundary. See README.md and Project_Handover.md pt.16.
    cast(null as {{ dbt.type_numeric() }})                 as amount_prior_year_kes

from periods p
cross join rl
left join actual a
       on a.report_line_code = rl.report_line_code
      and a.period           = p.period
left join bud b
       on b.report_line_code = rl.report_line_code
      and b.period           = p.period
left join prov pr
       on pr.report_line_code = rl.report_line_code
      and pr.period           = p.period
order by p.period, rl.line_order
