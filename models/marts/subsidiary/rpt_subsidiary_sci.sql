{{
  config(
    materialized = 'table',
    tags = ['marts', 'subsidiary', 'report']
  )
}}

-- =============================================================================
-- rpt_subsidiary_sci — per-entity Statement of Comprehensive Income,
-- with budget and prior year alongside the actual.
--
-- ONE model serves all subsidiaries. Power BI slices by company_name to
-- produce ZAAC's SCI, ZARIB's SCI, etc. — no duplicated logic per entity.
--
-- Budget
-- ------
-- From `budget_subsidiary`, keyed on (company_name, statement_line_code, period)
-- — the same grain as this mart, so it is a straight join with no allocation.
-- rpt_group_pl cannot show this: its taxonomy pools the four Kenyan entities
-- into by-nature expense lines and the five African entities into a single
-- Zarinet total, so ZAAC's personnel budget is not separable there. The source
-- workbook is at entity x line grain and all 22 of its labels map 1:1 onto our
-- SCI lines, so nothing had to be apportioned to get here. The subsidiary seed
-- is self-tested to roll up to the group seed exactly.
--
-- SIGN — read before building a variance visual. Everything in this mart is on
-- the presentation basis: sign_multiplier has been applied, so income AND
-- expenses are both POSITIVE. The budget is stored on the same basis for that
-- reason — a budget column that did not match the sign of the actual beside it
-- would be useless. Consequently:
--
--     variance_kes = actual - budget
--     income   line: positive variance = ahead of budget   (good)
--     expense  line: positive variance = spent above budget (bad)
--
-- This differs from rpt_group_pl, where expenses are stored NEGATIVE and a
-- positive variance therefore means underspend. Do not carry a variance measure
-- between the two models without re-checking the direction.
--
-- Coverage: `taxation` has no budget — the client's workbook stops at profit
-- before tax — and Uganda is absent because it is equity-accounted and does not
-- appear in the budget pack. Both come through as NULL rather than zero, so a
-- visual can tell "no budget set" apart from "budgeted at nil".
--
-- No prior year. The budget workbook carries an LYMTD column, but importing it
-- would be a stopgap that has to be unwound: once a full year of our own actuals
-- exists, prior year should be DERIVED from fct_trial_balance at period minus
-- twelve months, so the comparative equals the actual we published a year
-- earlier instead of coming from the client's figures. That also needs the
-- fiscal-year gap closed first — see README.md and Project_Handover.md pt.16.
-- =============================================================================

with actual as (
    select * from {{ ref('fct_trial_balance') }}
    where statement_type = 'SCI'
),

plan as (
    select
        company_name,
        statement_line_code,
        period,
        cast(amount_budget_kes as {{ dbt.type_numeric() }})  as amount_budget_kes
    from {{ ref('budget_subsidiary') }}
)

select
    t.company_name,
    t.region,
    t.period,
    t.statement_line_code,
    sl.line_order,
    sl.category_l1,
    sl.category_l2,
    sl.category_l3,
    sl.tb_category,
    sl.line_label,

    t.amount_local,
    t.amount_kes,

    b.amount_budget_kes,
    t.amount_kes - b.amount_budget_kes                          as variance_kes,
    {{ zamara_finance.safe_divide('t.amount_kes - b.amount_budget_kes',
                                  'b.amount_budget_kes') }}     as variance_pct

from actual t
join {{ ref('dim_statement_line') }} sl
  on sl.statement_line_code = t.statement_line_code
left join plan b
       on b.company_name        = t.company_name
      and b.statement_line_code = t.statement_line_code
      and b.period              = t.period
order by t.company_name, sl.line_order
