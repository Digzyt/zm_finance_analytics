{{
  config(
    materialized = 'view',
    tags = ['staging', 'debtors']
  )
}}

-- =============================================================================
-- stg_debtor_analysis — the client's aged debtor analysis, normalised.
--
-- Reads the debtor_analysis reference seed (one row per client per reporting
-- date, in each entity's FUNCTIONAL currency) and:
--   * casts every column to a stable type,
--   * computes a derived bucket-sum so a visual can tell a row whose ageing
--     buckets tie to its stated Total from one where the client's own Total
--     exceeds the bucket sum (Uganda / MENA — see the extraction script),
--   * keeps the stated Total as authoritative and exposes `os_balance` with a
--     sensible fallback: O/S = Total - Collections where the template left it
--     blank (that identity holds on every row where both were populated).
--
-- The grain is company_name x period x client_name. It is a point-in-time
-- snapshot keyed by `period` — it does NOT accumulate on the stg_report_periods
-- spine, because each reporting pack already states the balance "as at" its
-- reporting date.
-- =============================================================================

with src as (
    select * from {{ ref('debtor_analysis') }}
),

casted as (
    select
        period,
        company_name,
        reporting_date,
        department_unit,
        division_name,
        client_name,
        client_id,
        currency,

        cast(premium_tran_bc as numeric(20, 4)) as premium_tran_bc,
        cast(premium_os_bc   as numeric(20, 4)) as premium_os_bc,

        cast(age_0_30    as numeric(20, 4)) as age_0_30,
        cast(age_31_60   as numeric(20, 4)) as age_31_60,
        cast(age_61_90   as numeric(20, 4)) as age_61_90,
        cast(age_91_120  as numeric(20, 4)) as age_91_120,
        cast(age_121_180 as numeric(20, 4)) as age_121_180,
        cast(age_181_240 as numeric(20, 4)) as age_181_240,
        cast(age_241_300 as numeric(20, 4)) as age_241_300,
        cast(age_301_365 as numeric(20, 4)) as age_301_365,
        cast(age_1_2y    as numeric(20, 4)) as age_1_2y,
        cast(age_2_3y    as numeric(20, 4)) as age_2_3y,
        cast(age_gt_3y   as numeric(20, 4)) as age_gt_3y,

        cast(total               as numeric(20, 4)) as total,
        cast(collections_1st_10th as numeric(20, 4)) as collections_1st_10th,
        cast(dp_1st_10th          as numeric(20, 4)) as dp_1st_10th,
        cast(os_balance           as numeric(20, 4)) as os_balance

    from src
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

    premium_tran_bc,
    premium_os_bc,

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

    -- the client's stated Total is authoritative and is kept as-is even where
    -- the twelve buckets do not foot to it (Uganda / MENA rows)
    total,

    -- derived diagnostic: what the twelve ageing buckets sum to
    cast(coalesce(age_0_30, 0) + coalesce(age_31_60, 0) + coalesce(age_61_90, 0)
         + coalesce(age_91_120, 0) + coalesce(age_121_180, 0) + coalesce(age_181_240, 0)
         + coalesce(age_241_300, 0) + coalesce(age_301_365, 0) + coalesce(age_1_2y, 0)
         + coalesce(age_2_3y, 0) + coalesce(age_gt_3y, 0) as numeric(20, 4)) as age_bucket_sum,

    collections_1st_10th,
    dp_1st_10th,

    -- O/S Balance: where the template left it blank, O/S = Total - Collections.
    -- The identity holds on every row where the template populated both, so the
    -- fallback only fills a gap rather than moving a reported figure.
    coalesce(
        os_balance,
        cast(coalesce(total, 0) - coalesce(collections_1st_10th, 0) as numeric(20, 4))
    ) as os_balance

from casted
