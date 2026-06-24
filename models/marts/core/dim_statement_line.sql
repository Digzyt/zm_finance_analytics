{{
  config(
    materialized = 'table',
    tags = ['marts', 'core', 'dim']
  )
}}

-- =============================================================================
-- dim_statement_line — the canonical SCI / SFP line catalogue from the
-- statement_line.csv seed.
-- =============================================================================

select
    statement_line_code,
    statement_type,           -- 'SCI' | 'SFP'
    sign_multiplier,
    line_order,
    category_l1,              -- ASSETS | EQUITY AND LIABILITIES | INCOME | EXPENSES
    category_l2,
    category_l3,
    line_label,
    {{ dbt_utils.generate_surrogate_key(['statement_line_code']) }}  as statement_line_key
from {{ ref('statement_line') }}
