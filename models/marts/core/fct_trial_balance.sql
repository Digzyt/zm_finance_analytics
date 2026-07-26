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
--
-- net_profit: the client's SFP presents current-year earnings as a separate
-- equity line ("Net Profit"), distinct from brought-forward Retained earnings.
-- The current-year result lives in the P&L (SCI) accounts, not in a balance-
-- sheet account, so we synthesise it here: per (company, period),
--   net_profit = SUM(SCI income) - SUM(SCI expenses)   [after tax]
-- posted as an SFP / Equity line. This makes the SFP self-balance
-- (Assets = Equity & Liabilities + Net Profit) for every fully-mapped entity;
-- any residual then equals that entity's net unmapped amount.
-- =============================================================================

with translated as (
    select * from {{ ref('int_fx_translation') }}
),

base as (
    select
        company_name,
        period,
        statement_line_code,
        statement_type,
        category_l1, category_l2, category_l3,
        line_label, line_order,

        sum(amount_local_signed)            as amount_local,
        sum(amount_kes)                     as amount_kes
    from translated
    where statement_line_code is not null
    group by
        company_name, period,
        statement_line_code, statement_type,
        category_l1, category_l2, category_l3,
        line_label, line_order
),

net_profit as (
    -- current-year result carried to equity on the SFP (after tax)
    select
        company_name,
        period,
        cast('net_profit'             as text)  as statement_line_code,
        cast('SFP'                    as text)  as statement_type,
        cast('EQUITY AND LIABILITIES' as text)  as category_l1,
        cast('Equity'                 as text)  as category_l2,
        cast(''                       as text)  as category_l3,
        cast('Net Profit'             as text)  as line_label,
        5040                                    as line_order,

        sum(case when statement_type = 'SCI' and category_l1 = 'INCOME'   then amount_local
                 when statement_type = 'SCI' and category_l1 = 'EXPENSES' then -amount_local
                 else 0 end)                     as amount_local,
        sum(case when statement_type = 'SCI' and category_l1 = 'INCOME'   then amount_kes
                 when statement_type = 'SCI' and category_l1 = 'EXPENSES' then -amount_kes
                 else 0 end)                     as amount_kes
    from base
    group by company_name, period
),

combined as (
    select * from base
    union all
    select * from net_profit
)

select
    company_name,
    period,
    statement_line_code,
    statement_type,
    category_l1, category_l2, category_l3,
    line_label, line_order,
    amount_local,
    amount_kes,

    {{ dbt_utils.generate_surrogate_key([
       'company_name','period','statement_line_code'
    ]) }}                                as tb_row_key
from combined
