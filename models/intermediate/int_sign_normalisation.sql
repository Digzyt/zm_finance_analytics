{{
  config(
    materialized = 'view',
    tags = ['intermediate']
  )
}}

-- =============================================================================
-- int_sign_normalisation
--
-- BC convention: Amount is debit-positive / credit-negative in LCY.
-- Reporting convention (SCI/SFP positive presentation): apply sign_multiplier
-- from statement_line. e.g. Revenue lines have sign_multiplier = -1 in BC, so
-- multiplying flips the natural credit into a positive Revenue figure on the
-- SCI; share_capital has -1 to show Equity as positive on the SFP.
-- =============================================================================

with mapped as (
    select * from {{ ref('int_account_mapping') }}
)

select
    company_name,
    local_account_no,
    description,
    account_name,
    account_type,
    income_balance,
    account_category,

    statement_line_code,
    statement_type,
    category_l1,
    category_l2,
    category_l3,
    line_label,
    line_order,

    amount_local,
    amount_kes_presupplied,

    coalesce(sign_multiplier, 1)                             as sign_multiplier,
    amount_local * coalesce(sign_multiplier, 1)              as amount_local_signed,
    amount_kes_presupplied * coalesce(sign_multiplier, 1)    as amount_kes_signed_presupplied

from mapped
