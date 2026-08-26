{{
  config(
    materialized = 'table',
    tags = ['marts', 'subsidiary', 'debtors', 'report']
  )
}}

-- =============================================================================
-- rpt_debtor_analysis — the client-grain debtor analysis, final for Power BI.
--
-- One row per (company, period, client). This is the table Power BI imports to
-- drive the Debtor Analysis report: the aged exposure per client and the
-- derived analytics (overdue share, collection rate) on top of the functional-
-- currency figures captured from the client's pack. Join dim_entity for the
-- entity name / region, filter and slice on period (2026-07 at present).
--
-- Basis: functional currency, exactly as the client's pack states it. Nobody
-- translates the aged balances to the group currency until the FX basis for
-- debtor balances is agreed with Finance.
--
-- Companion mart: rpt_debtor_ageing (the same balances in LONG/band form for
-- ageing-profile visuals). These two reconcile by construction — both read
-- stg_debtor_analysis, and the band sums in rpt_debtor_ageing tie to the
-- column-and-row totals here.
-- =============================================================================

with src as (
    select * from {{ ref('stg_debtor_analysis') }}
),

joined as (
    select
        s.*,
        e.entity_name,
        e.region,
        e.functional_ccy
    from src s
    left join {{ ref('dim_entity') }} e
           on e.entity_code = s.company_name
),

derived as (
    select
        *,
        -- overdue exposure = everything beyond the current (0-30) band, per the
        -- template's own banding
        cast(coalesce(age_31_60, 0) + coalesce(age_61_90, 0) + coalesce(age_91_120, 0)
             + coalesce(age_121_180, 0) + coalesce(age_181_240, 0) + coalesce(age_241_300, 0)
             + coalesce(age_301_365, 0) + coalesce(age_1_2y, 0) + coalesce(age_2_3y, 0)
             + coalesce(age_gt_3y, 0) as numeric(20, 4)) as overdue_amount
    from joined
)

select
    period,
    company_name,
    entity_name,
    region,
    functional_ccy,
    reporting_date,

    department_unit,
    division_name,
    client_name,
    client_id,
    currency,

    -- premium (BC) exposure
    premium_tran_bc,
    premium_os_bc,

    -- the twelve ageing buckets, functional currency
    age_0_30,
    age_31_60,
    age_61_90,
    age_91_120,
    age_121_180,
    age_181_240,
    age_241_300,
    age_301_365,
    age_1_2y,
    age_2_3y,
    age_gt_3y,

    -- reported total and derived bucket diagnostic
    total,
    age_bucket_sum,

    -- collections to the 10th and the stated/derived outstanding balance
    collections_1st_10th,
    dp_1st_10th,
    os_balance,

    -- ---- derived analytics -------------------------------------------------
    overdue_amount,

    -- share of the stated total that is overdue (0..1; NULL where no exposure)
    case when coalesce(total, 0) = 0 then null
         else cast(overdue_amount / nullif(total, 0) as numeric(10, 4))
    end as overdue_share,

    -- current share of the stated total (0..1)
    case when coalesce(total, 0) = 0 then null
         else cast(coalesce(age_0_30, 0) / nullif(total, 0) as numeric(10, 4))
    end as current_share,

    -- collection rate: collected-to-date against the stated total (0..1)
    case when coalesce(total, 0) = 0 then null
         else cast(coalesce(collections_1st_10th, 0) / nullif(total, 0) as numeric(10, 4))
    end as collection_rate,

    case when overdue_amount > 0 then true else false end as has_overdue

from derived
