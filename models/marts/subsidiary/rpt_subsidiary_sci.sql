{{
  config(
    materialized = 'table',
    tags = ['marts', 'subsidiary', 'report']
  )
}}

-- =============================================================================
-- rpt_subsidiary_sci — per-entity Statement of Comprehensive Income.
--
-- ONE model serves all subsidiaries. Power BI slices by company_name to
-- produce ZAAC's SCI, ZARIB's SCI, etc. — no duplicated logic per entity.
-- =============================================================================

select
    t.company_name,
    t.period,
    t.statement_line_code,
    sl.line_order,
    sl.category_l1,
    sl.category_l2,
    sl.category_l3,
    sl.line_label,
    t.amount_local,
    t.amount_kes
from {{ ref('fct_trial_balance') }} t
join {{ ref('dim_statement_line') }} sl
  on sl.statement_line_code = t.statement_line_code
where t.statement_type = 'SCI'
order by t.company_name, sl.line_order
