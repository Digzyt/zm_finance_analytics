{{
  config(
    materialized = 'table',
    tags = ['marts', 'core', 'fct']
  )
}}

-- =============================================================================
-- fct_trial_balance — entity-grain spine fact.
--
-- Grain: company_name x statement_line_code x period.
-- This is the canonical fact for everything downstream: subsidiary reports
-- slice it by company_name; the consolidated reports aggregate across.
-- =============================================================================

with translated as (
    select * from {{ ref('int_fx_translation') }}
)

select
    company_name,
    period,
    statement_line_code,
    statement_type,
    category_l1, category_l2, category_l3,
    line_label, line_order,

    sum(amount_local_signed)            as amount_local,
    sum(amount_kes)                     as amount_kes,

    {{ dbt_utils.generate_surrogate_key([
       'company_name','period','statement_line_code'
    ]) }}                                as tb_row_key
from translated
where statement_line_code is not null
group by
    company_name, period,
    statement_line_code, statement_type,
    category_l1, category_l2, category_l3,
    line_label, line_order
