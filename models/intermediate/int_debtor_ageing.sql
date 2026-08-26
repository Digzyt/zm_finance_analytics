{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'debtors']
  )
}}

-- =============================================================================
-- int_debtor_ageing — the aged debtor balances in LONG form.
--
-- stg_debtor_analysis is wide (one row per client with the twelve ageing
-- buckets in columns). Power BI wants to slice by ageing band, so here the
-- twelve buckets are unpivoted into one row per (company, period, client,
-- ageing_band). Each row carries the amount in that band plus band metadata
-- (label, ordering, whether it is current / overdue, and a coarser period
-- classification) so visuals can bucket consistently without re-implementing
-- the band rules.
--
-- The unpivot is written as an explicit UNION of twelve selects, one per
-- bucket, deliberately not a CROSS JOIN LATERAL / UNPIVOT, to stay portable
-- between Postgres and the Fabric Warehouse (DISCIPLINES.md).
--
-- A row whose band amount is NULL/zero is still emitted (amount 0) so every
-- client appears in all bands and a matrix can pivot the bands to a complete
-- grid; filter `total > 0` for exposure-only views.
-- =============================================================================

with src as (
    select * from {{ ref('stg_debtor_analysis') }}
)

select
    period,
    company_name,
    reporting_date,
    department_unit,
    division_name,
    client_name,
    client_id,
    currency,

    total,
    os_balance,
    collections_1st_10th,

    ageing_band,
    band_label,
    band_order,
    is_current,
    is_overdue,
    period_class,
    cast(amount_local as numeric(20, 4)) as amount_local

from (
    -- 0-30 days (Current)
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_0_30' as ageing_band, '0-30 days' as band_label, 1 as band_order,
           true as is_current, false as is_overdue, 'Current' as period_class,
           age_0_30 as amount_local from src
    union all
    -- 31-60 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_31_60' as ageing_band, '31-60 days' as band_label, 2 as band_order,
           false as is_current, true as is_overdue, 'Overdue 30-90' as period_class,
           age_31_60 as amount_local from src
    union all
    -- 61-90 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_61_90' as ageing_band, '61-90 days' as band_label, 3 as band_order,
           false as is_current, true as is_overdue, 'Overdue 30-90' as period_class,
           age_61_90 as amount_local from src
    union all
    -- 91-120 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_91_120' as ageing_band, '91-120 days' as band_label, 4 as band_order,
           false as is_current, true as is_overdue, 'Overdue 91-180' as period_class,
           age_91_120 as amount_local from src
    union all
    -- 121-180 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_121_180' as ageing_band, '121-180 days' as band_label, 5 as band_order,
           false as is_current, true as is_overdue, 'Overdue 91-180' as period_class,
           age_121_180 as amount_local from src
    union all
    -- 181-240 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_181_240' as ageing_band, '181-240 days' as band_label, 6 as band_order,
           false as is_current, true as is_overdue, 'Overdue 181-365' as period_class,
           age_181_240 as amount_local from src
    union all
    -- 241-300 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_241_300' as ageing_band, '241-300 days' as band_label, 7 as band_order,
           false as is_current, true as is_overdue, 'Overdue 181-365' as period_class,
           age_241_300 as amount_local from src
    union all
    -- 301-365 days
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_301_365' as ageing_band, '301-365 days' as band_label, 8 as band_order,
           false as is_current, true as is_overdue, 'Overdue 181-365' as period_class,
           age_301_365 as amount_local from src
    union all
    -- 1-2 years
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_1_2y' as ageing_band, '1-2 years' as band_label, 9 as band_order,
           false as is_current, true as is_overdue, 'Overdue 1-2y' as period_class,
           age_1_2y as amount_local from src
    union all
    -- 2-3 years
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_2_3y' as ageing_band, '2-3 years' as band_label, 10 as band_order,
           false as is_current, true as is_overdue, 'Overdue >2y' as period_class,
           age_2_3y as amount_local from src
    -- >3 years
    union all
    select period, company_name, reporting_date, department_unit, division_name,
           client_name, client_id, currency, total, os_balance, collections_1st_10th,
           'age_gt_3y' as ageing_band, '>3 years' as band_label, 11 as band_order,
           false as is_current, true as is_overdue, 'Overdue >2y' as period_class,
           age_gt_3y as amount_local from src
) unpivoted
