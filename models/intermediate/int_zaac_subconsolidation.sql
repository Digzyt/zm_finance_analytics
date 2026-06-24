{{
  config(
    materialized = 'view',
    tags = ['intermediate']
  )
}}

-- =============================================================================
-- int_zaac_subconsolidation
--
-- The workbook has a "ZAAC Consolidated" hidden tab that combines ZAAC and
-- C&P balances. This represents a sub-consolidation: C&P is a subsidiary of
-- ZAAC, and the management view sometimes presents them combined.
--
-- For the group view we do NOT use this sub-consolidation — we treat C&P as
-- a sibling entity in the union. This view exists only to support optional
-- "ZAAC consolidated" subsidiary reports if Finance asks for them.
-- =============================================================================

with translated as (
    select * from {{ ref('int_fx_translation') }}
)

select
    'ZAAC_CONSOL'                         as company_name,
    functional_ccy,
    period,
    statement_line_code,
    statement_type,
    category_l1, category_l2, category_l3,
    line_label, line_order,
    sum(amount_local_signed)              as amount_local_signed,
    sum(amount_kes)                        as amount_kes
from translated
where company_name in ('ZAAC','C&P')
group by functional_ccy, period, statement_line_code, statement_type,
         category_l1, category_l2, category_l3, line_label, line_order
