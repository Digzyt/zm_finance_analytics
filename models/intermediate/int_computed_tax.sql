{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'tax']
  )
}}

-- =============================================================================
-- int_computed_tax — the tax charge for entities that have no tax account.
--
-- Several entities carry no taxation account in their trial balance at all. For
-- those, the client computes the charge as a flat percentage of profit before
-- tax and posts it as a journal: their formula is literally
--   KES consolidated TB 'Taxation expense' = -SUM(<the P&L range>) * 0.3
-- ZATL and C&P do this at KES consolidated TB level; Rwanda and Nigeria one
-- level down in TB Local Currency. Either way there is no source account, so
-- nothing in the bronze seeds can produce it and the SCI, net profit and SFP
-- equity all understate until it is modelled.
--
-- The double entry is the client's own: Dr Taxation (SCI), Cr Tax recoverable
-- (SFP) — visible in their sheet as
--   'Tax Provision-Other' = +ZATL!D22+ZATL!D27-L285
-- where L285 is the computed charge.
--
-- The rate lives in the tax_rate seed rather than in this model so Finance owns
-- it and can see it. Only the (company, period) combinations where the client
-- computes are seeded; everywhere else the charge comes from a real account via
-- account_map and this model must not fire.
--
-- Base is profit before tax, so the taxation line itself is excluded — matching
-- the client's SUM range, which stops one row short of the tax row.
-- =============================================================================

with sci as (
    select
        company_name,
        period,
        sum(case when category_l1 = 'INCOME'   then amount_local_signed
                 when category_l1 = 'EXPENSES' then -amount_local_signed
                 else 0 end)                                as pbt_local,
        sum(case when category_l1 = 'INCOME'   then amount_kes
                 when category_l1 = 'EXPENSES' then -amount_kes
                 else 0 end)                                as pbt_kes
    from {{ ref('int_tb_with_accruals') }}
    where statement_type = 'SCI'
      and statement_line_code <> 'taxation'
    group by company_name, period
),

-- What the trial balance already contributes to the taxation line. C&P is the
-- awkward case: it has a real 'Tax expense' account from February AND the client
-- switches to the computed basis from March, ignoring that account. So this is
-- not a guard but a top-up — the charge we post is the difference between the
-- client's computed figure and whatever the mapped accounts already give, which
-- lands the taxation line exactly on their number either way. Where nothing is
-- mapped (ZATL, Rwanda, Nigeria) the difference is the whole charge.
already_taxed as (
    select
        company_name,
        period,
        sum(amount_local_signed)  as mapped_tax_local,
        sum(amount_kes)           as mapped_tax_kes
    from {{ ref('int_tb_with_accruals') }}
    where statement_line_code = 'taxation'
    group by company_name, period
),

rate as (
    select
        company_name,
        period,
        cast(tax_rate as numeric(9, 6))  as tax_rate,
        basis,
        source,
        notes
    from {{ ref('tax_rate') }}
)

select
    r.company_name,
    r.period,
    r.tax_rate,
    r.basis,
    r.source,
    r.notes,

    s.pbt_local,
    s.pbt_kes,

    -- the client's total charge for the period
    cast(s.pbt_local * r.tax_rate as numeric(20, 4))   as tax_charge_local,
    cast(s.pbt_kes   * r.tax_rate as numeric(20, 4))   as tax_charge_kes,

    coalesce(t.mapped_tax_local, 0)                    as mapped_tax_local,
    coalesce(t.mapped_tax_kes, 0)                      as mapped_tax_kes,

    -- what has to be posted on top of the mapped accounts
    cast(s.pbt_local * r.tax_rate - coalesce(t.mapped_tax_local, 0)
         as numeric(20, 4))                            as tax_adjustment_local,
    cast(s.pbt_kes   * r.tax_rate - coalesce(t.mapped_tax_kes, 0)
         as numeric(20, 4))                            as tax_adjustment_kes

from rate r
join sci s
  on s.company_name = r.company_name
 and s.period       = r.period
left join already_taxed t
       on t.company_name = r.company_name
      and t.period       = r.period
where s.pbt_local is not null
