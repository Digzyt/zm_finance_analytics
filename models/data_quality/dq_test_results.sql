{{
  config(
    materialized = 'table',
    tags = ['data_quality', 'dq']
  )
}}

-- =============================================================================
-- dq_test_results — the SUMMARY table the Power BI Data Quality page shows:
-- one row per control per period, with records tested / passed / failed, a
-- pass rate and a status. This is the "table of tests" Finance reads.
--
-- Two sources are unioned so all 26 controls appear:
--   1. Automated in-warehouse controls — aggregated from dq_test_evaluations,
--      recomputed on every dbt build (run_basis = 'SQL (dbt)').
--   2. Controls verified outside the warehouse (reseed / recon scripts, or a
--      manual attestation) — carried in the dq_external_results seed.
--
-- Every row is joined to dq_test_catalog for the control's title, block,
-- severity, tolerance, owners and evidence. The page drills from a row here
-- into dq_test_failures on test_id (+ period).
-- =============================================================================

-- One row per control: the automated tests are summarised at their LATEST
-- available period, so every control appears once with an `as_of` date showing
-- how current its evidence is (full per-period history lives in
-- dq_test_evaluations for trend reporting).
with sql_latest as (
    select test_id, max(period) as period
    from {{ ref('dq_test_evaluations') }}
    group by test_id
),

sql_agg as (
    select
        e.test_id,
        e.period,
        count(*)                                          as records_tested,
        sum(case when e.passed then 1 else 0 end)         as records_passed,
        sum(case when e.passed then 0 else 1 end)         as records_failed
    from {{ ref('dq_test_evaluations') }} e
    join sql_latest l on l.test_id = e.test_id and l.period = e.period
    group by e.test_id, e.period
),

sql_rows as (
    select
        test_id,
        period,
        cast(records_tested as integer)                   as records_tested,
        cast(records_passed as integer)                   as records_passed,
        cast(records_failed as integer)                   as records_failed,
        cast(case when records_failed > 0 then 'FAIL' else 'PASS' end
             as {{ dbt.type_string() }})                  as status,
        cast('SQL (dbt)' as {{ dbt.type_string() }})      as run_basis,
        period                                            as as_of,
        cast(null as {{ dbt.type_string() }})             as note
    from sql_agg
),

ext_rows as (
    select
        test_id,
        period,
        cast(nullif(cast(records_tested as {{ dbt.type_string() }}), '') as integer) as records_tested,
        cast(nullif(cast(records_passed as {{ dbt.type_string() }}), '') as integer) as records_passed,
        cast(nullif(cast(records_failed as {{ dbt.type_string() }}), '') as integer) as records_failed,
        cast(status   as {{ dbt.type_string() }})         as status,
        cast(run_basis as {{ dbt.type_string() }})        as run_basis,
        cast(as_of    as {{ dbt.type_string() }})         as as_of,
        cast(note     as {{ dbt.type_string() }})         as note
    from {{ ref('dq_external_results') }}
),

unioned as (
    select * from sql_rows
    union all
    select * from ext_rows
)

select
    u.test_id,
    u.test_id                                             as control_id,
    c.block,
    c.title,
    c.category,
    u.period,
    u.records_tested,
    u.records_passed,
    u.records_failed,
    case when coalesce(u.records_tested, 0) > 0
         then cast(round(100.0 * u.records_passed / u.records_tested, 1) as numeric(6,1))
         else null end                                    as pass_rate_pct,
    u.status,
    c.severity,
    c.automation,
    u.run_basis,
    u.as_of,
    c.tolerance,
    c.exception_codes,
    u.note,
    c.method,
    c.evidence,
    c.owner_preparer,
    c.owner_reviewer
from unioned u
left join {{ ref('dq_test_catalog') }} c on c.test_id = u.test_id
