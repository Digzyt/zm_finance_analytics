{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'fx']
  )
}}

-- =============================================================================
-- int_fx_translation
--
-- Translates local-currency amounts to KES (group reporting currency).
-- Rules (group accounting policy):
--   - SFP lines  -> closing rate at period end
--   - SCI lines  -> period average rate
--   - KES-functional entities  -> identity (rate = 1)
--
-- If the source row already carries a pre-translated amount_kes (some entities
-- such as MENA, Nigeria, Malawi, DRC, ZATL ship a KES column in the workbook),
-- prefer that value to avoid spurious rounding diffs vs the source.
-- =============================================================================

with src as (
    select * from {{ ref('int_sign_normalisation') }}
),

ent as (
    select * from {{ ref('entity') }}
),

fx as (
    select * from {{ ref('fx_rate') }}
)

select
    s.company_name,
    e.functional_ccy,
    s.period                                            as period,

    s.local_account_no,
    s.description,
    s.statement_line_code,
    s.statement_type,
    s.category_l1, s.category_l2, s.category_l3,
    s.line_label, s.line_order,

    s.amount_local_signed,

    -- Determine which rate to apply
    case
        when e.functional_ccy = '{{ var("group_currency") }}' then 1.0
        when s.statement_type = 'SFP' then fx_c.rate_to_kes
        when s.statement_type = 'SCI' then fx_a.rate_to_kes
        else 1.0
    end                                                as fx_rate_applied,

    -- Prefer pre-supplied KES if present; otherwise compute
    coalesce(
        s.amount_kes_signed_presupplied,
        s.amount_local_signed * case
            when e.functional_ccy = '{{ var("group_currency") }}' then 1.0
            when s.statement_type = 'SFP' then fx_c.rate_to_kes
            when s.statement_type = 'SCI' then fx_a.rate_to_kes
            else 1.0
        end
    )                                                  as amount_kes

from src s
left join ent e
       on e.entity_code = s.company_name
left join fx fx_c
       on fx_c.currency  = e.functional_ccy
      and fx_c.period    = s.period
      and fx_c.rate_type = 'CLOSING'
left join fx fx_a
       on fx_a.currency  = e.functional_ccy
      and fx_a.period    = s.period
      and fx_a.rate_type = 'AVERAGE'
