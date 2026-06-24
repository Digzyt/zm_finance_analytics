{{
  config(
    materialized = 'table',
    tags = ['marts', 'consolidation', 'report']
  )
}}

-- =============================================================================
-- rpt_consolidated_sci — Group Statement of Comprehensive Income.
-- Power BI connects here.
-- =============================================================================

select
    c.period,
    c.statement_line_code,
    sl.line_order,
    sl.category_l1,
    sl.category_l2,
    sl.category_l3,
    sl.line_label,
    c.subsidiary_sum_kes,
    c.elimination_kes,
    c.equity_pickup_kes,
    c.consolidated_kes
from {{ ref('fct_consolidated_tb') }} c
join {{ ref('dim_statement_line') }} sl
  on sl.statement_line_code = c.statement_line_code
where c.statement_type = 'SCI'
order by sl.line_order
