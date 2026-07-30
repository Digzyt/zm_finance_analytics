{{
  config(
    materialized = 'table',
    tags = ['marts', 'core', 'dim']
  )
}}

-- =============================================================================
-- dim_statement_line — the canonical SCI / SFP line catalogue from the
-- statement_line.csv seed.
--
-- tb_category is the client's own grouping: column A of the `KES consolidated TB`
-- tab, the 24-category template. Our 51 statement lines collapse onto it many-to-
-- one, so it is a column on the seed rather than a separate mapping table, and it
-- is exposed here so Power BI can group the TB and the statements exactly the way
-- Finance's workbook does. Derived by joining the client's `No.` column to
-- account_map across all six packs; see the 30 July note in Project_Handover.md
-- for the two judgement calls Finance still needs to confirm.
-- =============================================================================

select
    statement_line_code,
    statement_type,           -- 'SCI' | 'SFP'
    sign_multiplier,
    line_order,
    category_l1,              -- ASSETS | EQUITY AND LIABILITIES | INCOME | EXPENSES
    category_l2,
    category_l3,
    tb_category,              -- the client's column-A grouping (24 categories)
    line_label,
    {{ dbt_utils.generate_surrogate_key(['statement_line_code']) }}  as statement_line_key
from {{ ref('statement_line') }}
