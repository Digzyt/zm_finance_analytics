{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'accruals']
  )
}}

-- =============================================================================
-- int_tb_accrual_mapped — the client's accrual overlay, mapped and signed so it
-- can be added back to the trial balance.
--
-- The bronze gl_entry_* seeds hold the PRE-accrual figure, because that is what
-- BC itself would hold: the accrual is an adjustment the client applies in the
-- workbook on top of the ledger, not a posted entry. Keeping the two apart is
-- what lets Power BI show the five columns of the client's own TB tabs, and it
-- means bronze stays a faithful mirror when BC access lands and these seeds are
-- replaced by real extracts.
--
-- The reported statements are still POST-accrual, so the overlay has to come
-- back before the SCI/SFP are struck. This model shapes it exactly like
-- int_fx_translation's output and fct_trial_balance unions it in, which keeps
-- every reported figure identical to before the split.
--
-- Mapping mirrors int_account_mapping deliberately, including the effective
-- dating: the client re-classifies some accounts mid-year, so a mapping is only
-- valid for the span it was written for.
--
-- FX: every entity that has an accrual column (ZAAC, ZARIB, C&P) is
-- KES-functional, so the rate is 1 in practice. The join is written out anyway
-- so this does not quietly break if the client starts accruing in Malawi.
-- =============================================================================

with accrual as (
    select * from {{ ref('stg_tb_accrual') }}
),

periods as (
    select * from {{ ref('stg_report_periods') }}
),

amap as (
    select * from {{ ref('account_map') }}
),

sl as (
    select * from {{ ref('statement_line') }}
),

ent as (
    select * from {{ ref('entity') }}
),

fx as (
    select * from {{ ref('fx_rate') }}
),

mapped as (
    select
        a.company_name,
        a.period,
        a.local_account_no,
        a.description,
        m.statement_line_code,
        sum(a.accrual_local) as accrual_local
    from accrual a
    join periods p
      on p.period = a.period
    left join amap m
      on m.company_name     = a.company_name
     and m.local_account_no = a.local_account_no
     and p.period_end between cast(m.effective_from as date) and cast(m.effective_to as date)
    group by 1, 2, 3, 4, 5
)

select
    m.company_name,
    e.functional_ccy,
    m.period,

    m.local_account_no,
    m.description,
    m.statement_line_code,
    s.statement_type,
    s.category_l1, s.category_l2, s.category_l3,
    s.line_label,
    s.line_order,

    cast(m.accrual_local * s.sign_multiplier as numeric(20, 4))  as amount_local_signed,

    cast(
        m.accrual_local * s.sign_multiplier * case
            when e.functional_ccy = '{{ var("group_currency") }}' then 1.0
            when s.statement_type = 'SFP' then coalesce(fx_c.rate_to_kes, 1.0)
            when s.statement_type = 'SCI' then coalesce(fx_a.rate_to_kes, 1.0)
            else 1.0
        end
    as numeric(20, 4))                                           as amount_kes

from mapped m
join sl s
  on s.statement_line_code = m.statement_line_code
left join ent e
       on e.entity_code = m.company_name
left join fx fx_c
       on fx_c.currency  = e.functional_ccy
      and fx_c.period    = m.period
      and fx_c.rate_type = 'CLOSING'
left join fx fx_a
       on fx_a.currency  = e.functional_ccy
      and fx_a.period    = m.period
      and fx_a.rate_type = 'AVERAGE'
where m.statement_line_code is not null
