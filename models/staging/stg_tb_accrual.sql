{{
  config(
    materialized = 'view',
    tags = ['staging', 'accruals']
  )
}}

-- =============================================================================
-- stg_tb_accrual — the client's `Accruals` column, per account per period.
--
-- The individual TB tabs carry five columns: A/C No, Description, Amount,
-- Accruals, Amount After Accruals. Finance wants all five in Power BI. The
-- bronze gl_entry_* seeds mirror BC's own table, so the accrual has no place in
-- them; it arrives as its own reference seed (Scripts/extract_accruals.py) and
-- is joined back in rpt_subsidiary_tb.
--
-- The bronze seeds already hold the POST-accrual figure — that is what the
-- reseed loads and what the whole reconciliation ties to — so downstream:
--     amount_after_accruals = gl_entry            (unchanged)
--     accruals              = this model
--     amount                = after - accruals    (derived)
-- Nothing here can move a mart figure; it can only decompose one.
--
-- Like the gl_entry seeds this holds monthly MOVEMENTS, so it cross-joins the
-- same period spine: a row contributes to every period at or after its own
-- month, and summing by (company, account, period) gives the YTD accrual as at
-- that period. Only ZAAC, ZARIB and C&P have the column; every other entity
-- reads as zero, which is what keeps the five columns uniform across all eleven.
-- =============================================================================

with accrual as (
    select * from {{ ref('tb_accrual') }}
),

periods as (
    select * from {{ ref('stg_report_periods') }}
)

select
    a.company_name,
    p.period,
    a.local_account_no,
    a.description,
    cast(a.accrual_local as numeric(20, 4))   as accrual_local,
    a.client_column,
    cast(a.period as varchar(7))              as movement_period

from accrual a
cross join periods p
where p.period_end >= cast(a.period || '-01' as date)
