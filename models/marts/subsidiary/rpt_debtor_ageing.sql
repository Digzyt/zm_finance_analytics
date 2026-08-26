{{
  config(
    materialized = 'table',
    tags = ['marts', 'subsidiary', 'debtors', 'report']
  )
}}

-- =============================================================================
-- rpt_debtor_ageing — the aged debtor exposure in BAND form, final for Power BI.
--
-- One row per (company, period, ageing_band) (and, rolled where requested, at
-- department/division grain). This is the counterpart of rpt_debtor_analysis:
-- that mart is one row per client (drill-down to a specific debtor); this one
-- is the ageing profile — totals by band, by entity, by department, and the
-- current / overdue split — so a visual can show the aged-balance waterfall
-- without re-bucketing.
--
-- Amounts are functional currency, per rpt_debtor_analysis. Both marts read
-- the same long source (int_debtor_ageing) so they reconcile by construction:
-- summing rpt_debtor_ageing over the bands of a client equals that client's
-- age_bucket_sum in rpt_debtor_analysis.
-- =============================================================================

with src as (
    select * from {{ ref('int_debtor_ageing') }}
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

grouped as (
    select
        period,
        company_name,
        entity_name,
        region,
        functional_ccy,
        department_unit,
        division_name,
        ageing_band,
        band_label,
        band_order,
        is_current,
        is_overdue,
        period_class,
        cast(sum(amount_local) as numeric(20, 4)) as amount_local
    from joined
    group by period, company_name, entity_name, region, functional_ccy,
             department_unit, division_name, ageing_band, band_label,
             band_order, is_current, is_overdue, period_class
)

select
    period,
    company_name,
    entity_name,
    region,
    functional_ccy,
    department_unit,
    division_name,

    ageing_band,
    band_label,
    band_order,
    is_current,
    is_overdue,
    period_class,

    amount_local,
    -- share of this band within its (company, period) exposure, for profile bars
    cast(amount_local
         / nullif(sum(amount_local) over (
               partition by period, company_name, department_unit, division_name),
               0) as numeric(10, 4)) as band_share

from grouped
