-- The same budget is held at two grains: `budget` at Group P&L management-line
-- grain, and `budget_subsidiary` at company x statement_line grain. They are one
-- aggregation apart, so they must agree. If they drift, two reports show two
-- different budgets for the same month and neither can be trusted — worse than
-- not having the subsidiary grain at all.
--
-- Scripts/extract_budget.py already refuses to write when this fails, but the
-- seeds can also be edited by hand, so the assertion lives here too.
--
-- Only the income lines are checked, because those are the ones where the group
-- taxonomy is entity-specific and the comparison is unambiguous. Expenses pool
-- ZAAC + ZARIB + C&P + ZHL into by-nature lines and the five African entities
-- into one Zarinet total, so a like-for-like check there means re-encoding the
-- whole mapping in SQL; the script covers it, including the expense side.
--
-- Note the sign flip: `budget` keeps the workbook's income-positive /
-- expense-negative basis, `budget_subsidiary` is on the marts' presentation
-- basis where both are positive. Income lines are positive in both, which is
-- why they compare directly.

{{ config(severity = 'error') }}

with group_income as (
    select
        period,
        report_line_code,
        sum(cast(amount_budget_kes as {{ dbt.type_numeric() }}))  as group_kes
    from {{ ref('budget') }}
    where report_line_code in ('zaac_revenue', 'cp_revenue', 'zarib_revenue',
                               'zhl_interest', 'zamre_revenue', 'mena_revenue')
    group by period, report_line_code
),

-- report_line_code -> the entity whose income it is
entity_of as (
    select cast('zaac_revenue'  as {{ dbt.type_string() }}) as report_line_code,
           cast('ZAAC'          as {{ dbt.type_string() }}) as company_name
    union all select 'cp_revenue',    'C&P'
    union all select 'zarib_revenue', 'ZARIB'
    union all select 'zhl_interest',  'ZHL'
    union all select 'zamre_revenue', 'ZAMRE'
    union all select 'mena_revenue',  'MENA'
),

sub_income as (
    select
        b.period,
        e.report_line_code,
        sum(cast(b.amount_budget_kes as {{ dbt.type_numeric() }}))  as sub_kes
    from {{ ref('budget_subsidiary') }} b
    join {{ ref('statement_line') }} sl
      on sl.statement_line_code = b.statement_line_code
    join entity_of e
      on e.company_name = b.company_name
    where sl.category_l1 = 'INCOME'
    group by b.period, e.report_line_code
)

select
    g.period,
    g.report_line_code,
    g.group_kes,
    coalesce(s.sub_kes, 0)              as sub_kes,
    g.group_kes - coalesce(s.sub_kes, 0) as difference
from group_income g
left join sub_income s
       on s.period           = g.period
      and s.report_line_code = g.report_line_code
where abs(g.group_kes - coalesce(s.sub_kes, 0)) > 1.0
