{{
  config(
    materialized = 'table',
    tags = ['marts', 'subsidiary', 'report', 'tb']
  )
}}

-- =============================================================================
-- rpt_subsidiary_tb — the trial balance at ACCOUNT grain, as Finance sees it.
--
-- This is the table Power BI imports to show the individual TB. It reproduces
-- the five columns of the client's own entity tabs —
--     A/C No | Description | Amount | Accruals | Amount After Accruals
-- — for every entity and every period, and carries the statement line each
-- account maps to so the TB cross-filters against the SCI and SFP visuals in
-- one model.
--
-- Grain: company_name x period x local_account_no. One row per account per
-- period, cumulative ("as at"), which is how the client's own TB tabs read.
--
-- Sign: DEBIT-POSITIVE throughout, exactly as their TB tab shows it. This is
-- deliberately NOT the presentation basis used by rpt_subsidiary_sci/_sfp
-- (where sign_multiplier flips income and equity positive) — a trial balance
-- that does not show credits as negative is not a trial balance, and it must
-- foot to zero. `sign_multiplier` is carried so a visual can flip to the
-- presentation basis if wanted.
--
-- Where the three amount columns come from:
--     amount                = the bronze figure, which is PRE-accrual (BC would
--                             hold exactly this; the accrual is a workbook overlay)
--     accruals              = stg_tb_accrual, zero where the client has none
--     amount_after_accruals = amount + accruals
-- `amount_after_accruals` is the reported figure, so it agrees with what
-- rpt_subsidiary_sci/_sfp aggregate — those add the same overlay back through
-- int_tb_accrual_mapped in fct_trial_balance.
--
-- Only ZAAC, ZARIB and C&P have an accruals column in the packs. Everything
-- else reads zero, so the five columns render uniformly for all eleven
-- entities and stay correct if the client adds the column elsewhere later.
-- =============================================================================

with tb as (
    -- account grain, cumulative to each period, with the mapped statement line
    select
        company_name,
        period,
        local_account_no,
        max(description)                              as description,
        max(statement_line_code)                      as statement_line_code,
        max(statement_type)                           as statement_type,
        max(line_label)                               as line_label,
        max(line_order)                               as line_order,
        max(category_l1)                              as category_l1,
        max(category_l2)                              as category_l2,
        max(sign_multiplier)                          as sign_multiplier,
        sum(amount_local)                             as amount_local,
        sum(amount_kes_presupplied)                   as amount_kes_presupplied
    from {{ ref('int_sign_normalisation') }}
    group by company_name, period, local_account_no
),

accrual as (
    select
        company_name,
        period,
        local_account_no,
        max(client_column)      as accrual_column_label,
        sum(accrual_local)      as accrual_local
    from {{ ref('stg_tb_accrual') }}
    group by company_name, period, local_account_no
),

ent as (
    select * from {{ ref('entity') }}
),

fx as (
    select * from {{ ref('fx_rate') }}
),

joined as (
    select
        t.company_name,
        e.region,
        e.functional_ccy,
        t.period,
        t.local_account_no,
        t.description,
        t.statement_line_code,
        t.statement_type,
        t.line_label,
        t.line_order,
        t.category_l1,
        t.category_l2,
        t.sign_multiplier,
        a.accrual_column_label,

        cast(coalesce(a.accrual_local, 0) as numeric(20, 4))    as accruals_local,
        cast(t.amount_local as numeric(20, 4))                  as amount_local,
        cast(t.amount_local
             + coalesce(a.accrual_local, 0) as numeric(20, 4))  as amount_after_accruals_local,

        -- Same rule as int_fx_translation: SFP at the closing rate, SCI at the
        -- period average, KES-functional entities at 1. Applied here rather than
        -- reused because that model works on sign-normalised amounts and a trial
        -- balance has to stay debit-positive.
        case
            when e.functional_ccy = '{{ var("group_currency") }}' then 1.0
            when t.statement_type = 'SFP' then fx_c.rate_to_kes
            when t.statement_type = 'SCI' then fx_a.rate_to_kes
            else 1.0
        end                                                     as fx_rate_applied,
        t.amount_kes_presupplied

    from tb t
    left join accrual a
           on a.company_name      = t.company_name
          and a.period            = t.period
          and a.local_account_no  = t.local_account_no
    left join ent e
           on e.entity_code = t.company_name
    left join fx fx_c
           on fx_c.currency  = e.functional_ccy
          and fx_c.period    = t.period
          and fx_c.rate_type = 'CLOSING'
    left join fx fx_a
           on fx_a.currency  = e.functional_ccy
          and fx_a.period    = t.period
          and fx_a.rate_type = 'AVERAGE'
)

select
    company_name,
    region,
    functional_ccy,
    period,

    local_account_no,
    description,

    -- the client's five columns, in their currency
    amount_local,
    accruals_local,
    amount_after_accruals_local,

    -- and translated to the group currency
    cast(amount_local          * coalesce(fx_rate_applied, 1) as numeric(20, 4)) as amount_kes,
    cast(accruals_local        * coalesce(fx_rate_applied, 1) as numeric(20, 4)) as accruals_kes,
    -- pre-supplied KES is preferred for the reported figure so this column ties
    -- to rpt_subsidiary_sci/_sfp to the shilling, exactly as int_fx_translation does
    coalesce(
        amount_kes_presupplied,
        cast(amount_after_accruals_local * coalesce(fx_rate_applied, 1) as numeric(20, 4))
    )                                                                            as amount_after_accruals_kes,

    fx_rate_applied,
    case when accrual_column_label is null then false else true end as has_client_accrual,
    accrual_column_label,

    j.statement_line_code,
    j.statement_type,
    j.line_label,
    j.line_order,
    j.category_l1,
    j.category_l2,
    -- the client's column-A grouping from their `KES consolidated TB`, so a matrix
    -- over this table can be grouped the way their own tab is. Taken from the
    -- dimension rather than threaded up the intermediate chain — one join here is
    -- cheaper than adding a column to six models.
    sl.tb_category,
    j.sign_multiplier

from joined j
left join {{ ref('dim_statement_line') }} sl
       on sl.statement_line_code = j.statement_line_code
