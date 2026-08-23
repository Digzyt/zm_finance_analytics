{{
  config(
    materialized = 'table',
    tags = ['data_quality', 'dq']
  )
}}

-- =============================================================================
-- dq_test_evaluations — the atomic pass/fail rows for every AUTOMATED (in-warehouse)
-- data-quality control, one row per evaluated unit.
--
-- This is the base table behind the Power BI Data Quality page. It is aggregated
-- into dq_test_results (the summary the page shows: tests, records tested, passed,
-- failed) and filtered into dq_test_failures (the drill-through detail).
--
-- test_id maps 1:1 to the Reconciliation Control Matrix (governance pack sheet 11),
-- so a row here is "control C-nn, evaluated for this unit, in this period".
-- Controls whose evidence is produced outside the warehouse (the reseed / recon
-- scripts, or a manual attestation) are NOT here — they are carried in the
-- dq_external_results seed and unioned in dq_test_results.
--
-- Uniform schema every CTE conforms to:
--   test_id · period · unit_type · unit_key · entity · description
--   · metric_value · threshold · passed (bool) · fail_reason
--
-- Portability note (DISCIPLINES): this model uses `||` and `round(...)` for
-- readability. At the Fabric switch these become dbt.concat / explicit casts,
-- exactly as the staging layer already handles adapter differences.
-- =============================================================================

with

-- ---- C-05  Entity trial balance foots in functional currency ----------------
c05 as (
    select
        cast('C-05' as {{ dbt.type_string() }})                                    as test_id,
        period,
        cast('entity-period' as {{ dbt.type_string() }})                           as unit_type,
        cast("Company_Name" || ' ' || period as {{ dbt.type_string() }})           as unit_key,
        cast("Company_Name" as {{ dbt.type_string() }})                            as entity,
        cast('Trial balance foots (debit = credit)' as {{ dbt.type_string() }})    as description,
        cast(round(sum(coalesce(cast("Debit_Amount"  as numeric(20,4)), 0)
                     - coalesce(cast("Credit_Amount" as numeric(20,4)), 0)), 4)
             as numeric(20,4))                                                      as metric_value,
        cast(1.0 as numeric(20,4))                                                 as threshold,
        abs(sum(coalesce(cast("Debit_Amount"  as numeric(20,4)), 0)
              - coalesce(cast("Credit_Amount" as numeric(20,4)), 0))) <= 1.0        as passed,
        case when abs(sum(coalesce(cast("Debit_Amount" as numeric(20,4)), 0)
                       - coalesce(cast("Credit_Amount" as numeric(20,4)), 0))) > 1.0
             then 'Trial balance does not foot: net '
                  || round(sum(coalesce(cast("Debit_Amount"  as numeric(20,4)), 0)
                             - coalesce(cast("Credit_Amount" as numeric(20,4)), 0)), 2)
                  || ' in functional currency'
             else null end                                                         as fail_reason
    from {{ ref('stg_gl_entry') }}
    group by "Company_Name", period
),

-- ---- (shared) latest reporting period -----------------------------------------
latest_period as (select max(period) as p from {{ ref('rpt_subsidiary_tb') }}),

-- ---- C-08  Accrual overlay nets to nil within an entity-period ---------------
c08 as (
    select
        cast('C-08' as {{ dbt.type_string() }})                                    as test_id,
        period,
        cast('entity-period' as {{ dbt.type_string() }})                           as unit_type,
        cast(company_name || ' ' || period as {{ dbt.type_string() }})             as unit_key,
        cast(company_name as {{ dbt.type_string() }})                              as entity,
        cast('Accrual overlay nets to nil' as {{ dbt.type_string() }})             as description,
        cast(round(sum(cast(accrual_local as numeric(20,4))), 4) as numeric(20,4))                        as metric_value,
        cast(1.0 as numeric(20,4))                                                 as threshold,
        abs(sum(cast(accrual_local as numeric(20,4)))) <= 1.0                                             as passed,
        case when abs(sum(cast(accrual_local as numeric(20,4)))) > 1.0
             then 'Accrual overlay does not net to nil: ' || round(sum(cast(accrual_local as numeric(20,4))), 2)
             else null end                                                         as fail_reason
    from {{ ref('tb_accrual') }}
    group by company_name, period
),

-- ---- C-11  Elimination journals balance (debit = credit) --------------------
c11 as (
    select
        cast('C-11' as {{ dbt.type_string() }})                                    as test_id,
        period,
        cast('journal' as {{ dbt.type_string() }})                                 as unit_type,
        cast(journal_id || '|' || period as {{ dbt.type_string() }})               as unit_key,
        cast(max(entity_scope) as {{ dbt.type_string() }})                         as entity,
        cast(max(journal_description) as {{ dbt.type_string() }})                  as description,
        cast(round(sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)
                     - coalesce(cast(credit_kes as numeric(20,4)), 0)), 4)
             as numeric(20,4))                                                      as metric_value,
        cast(0.005 as numeric(20,4))                                               as threshold,
        abs(sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)
              - coalesce(cast(credit_kes as numeric(20,4)), 0))) <= 0.005          as passed,
        case when abs(sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)
                       - coalesce(cast(credit_kes as numeric(20,4)), 0))) > 0.005
             then 'Journal out of balance by KES '
                  || round(sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)
                             - coalesce(cast(credit_kes as numeric(20,4)), 0)), 2)
             else null end                                                         as fail_reason
    from {{ ref('elimination_journal') }}
    group by journal_id, period
),

-- ---- C-12  Budget: subsidiary grain rolls up to group grain (income lines) ---
group_income as (
    select period, report_line_code,
           sum(cast(amount_budget_kes as numeric(20,4))) as group_kes
    from {{ ref('budget') }}
    where report_line_code in ('zaac_revenue','cp_revenue','zarib_revenue',
                               'zhl_interest','zamre_revenue','mena_revenue')
    group by period, report_line_code
),
entity_of as (
    select cast('zaac_revenue'  as {{ dbt.type_string() }}) as report_line_code,
           cast('ZAAC'          as {{ dbt.type_string() }}) as company_name
    union all select 'cp_revenue',    'C&P'
    union all select 'zarib_revenue', 'ZARIB'
    union all select 'zhl_interest',  'ZHL'
    union all select 'zamre_revenue', 'ZAMRE'
    union all select 'mena_revenue',  'MENA'
),
sub_income as (
    select b.period, e.report_line_code,
           sum(cast(b.amount_budget_kes as numeric(20,4))) as sub_kes
    from {{ ref('budget_subsidiary') }} b
    join {{ ref('statement_line') }} sl on sl.statement_line_code = b.statement_line_code
    join entity_of e on e.company_name = b.company_name
    where sl.category_l1 = 'INCOME'
    group by b.period, e.report_line_code
),
c12 as (
    select
        cast('C-12' as {{ dbt.type_string() }})                                    as test_id,
        g.period,
        cast('report-line-period' as {{ dbt.type_string() }})                      as unit_type,
        cast(g.report_line_code || '|' || g.period as {{ dbt.type_string() }})     as unit_key,
        cast(g.report_line_code as {{ dbt.type_string() }})                        as entity,
        cast('Subsidiary budget rolls up to group budget' as {{ dbt.type_string() }}) as description,
        cast(round(g.group_kes - coalesce(s.sub_kes, 0), 4) as numeric(20,4))      as metric_value,
        cast(1.0 as numeric(20,4))                                                 as threshold,
        abs(g.group_kes - coalesce(s.sub_kes, 0)) <= 1.0                           as passed,
        case when abs(g.group_kes - coalesce(s.sub_kes, 0)) > 1.0
             then 'Budget roll-up breaks by KES ' || round(g.group_kes - coalesce(s.sub_kes, 0), 2)
             else null end                                                         as fail_reason
    from group_income g
    left join sub_income s on s.period = g.period and s.report_line_code = g.report_line_code
),

-- ---- C-17  Uganda equity pickup excluded from the TB union -------------------
tb_periods as (select distinct period from {{ ref('rpt_subsidiary_tb') }}),
c17 as (
    select
        cast('C-17' as {{ dbt.type_string() }})                                    as test_id,
        p.period,
        cast('period' as {{ dbt.type_string() }})                                  as unit_type,
        cast('UGANDA|' || p.period as {{ dbt.type_string() }})                     as unit_key,
        cast('UGANDA' as {{ dbt.type_string() }})                                  as entity,
        cast('Uganda associate excluded from the TB union' as {{ dbt.type_string() }}) as description,
        cast((select count(*) from {{ ref('rpt_subsidiary_tb') }} t
              where upper(t.company_name) = 'UGANDA' and t.period = p.period)
             as numeric(20,4))                                                      as metric_value,
        cast(0 as numeric(20,4))                                                   as threshold,
        (select count(*) from {{ ref('rpt_subsidiary_tb') }} t
              where upper(t.company_name) = 'UGANDA' and t.period = p.period) = 0   as passed,
        case when (select count(*) from {{ ref('rpt_subsidiary_tb') }} t
                   where upper(t.company_name) = 'UGANDA' and t.period = p.period) > 0
             then 'Uganda appears in the TB union — it must be equity-accounted only'
             else null end                                                         as fail_reason
    from tb_periods p
),

-- ---- C-18  FX rate present, per used currency-period-type --------------------
fx_need as (
    select distinct t.functional_ccy as ccy, t.period, rt.rt
    from {{ ref('rpt_subsidiary_tb') }} t
    cross join (select cast('CLOSING' as {{ dbt.type_string() }}) as rt
                union all select cast('AVERAGE' as {{ dbt.type_string() }})) rt
    where t.functional_ccy <> 'KES'
),
c18 as (
    select
        cast('C-18' as {{ dbt.type_string() }})                                    as test_id,
        n.period,
        cast('currency-period-type' as {{ dbt.type_string() }})                    as unit_type,
        cast(n.ccy || '|' || n.period || '|' || n.rt as {{ dbt.type_string() }})   as unit_key,
        cast(n.ccy as {{ dbt.type_string() }})                                     as entity,
        cast('FX rate present (' || n.rt || ')' as {{ dbt.type_string() }})        as description,
        cast(case when f.currency is null then 0 else 1 end as numeric(20,4))      as metric_value,
        cast(1 as numeric(20,4))                                                   as threshold,
        (f.currency is not null)                                                   as passed,
        case when f.currency is null
             then 'Missing ' || n.rt || ' rate for ' || n.ccy || ' ' || n.period
             else null end                                                         as fail_reason
    from fx_need n
    left join {{ ref('fx_rate') }} f
           on f.currency = n.ccy and f.period = n.period and f.rate_type = n.rt
),

-- ---- C-20  Every account with a balance reaches a statement line ------------
c20 as (
    select
        cast('C-20' as {{ dbt.type_string() }})                                    as test_id,
        period,
        cast('company-period-account' as {{ dbt.type_string() }})                  as unit_type,
        cast(company_name || '|' || period || '|' || local_account_no
             as {{ dbt.type_string() }})                                           as unit_key,
        cast(company_name as {{ dbt.type_string() }})                              as entity,
        cast(description as {{ dbt.type_string() }})                               as description,
        cast(round(amount_after_accruals_local, 4) as numeric(20,4))               as metric_value,
        cast(0.005 as numeric(20,4))                                               as threshold,
        not (statement_line_code is null and abs(amount_after_accruals_local) > 0.005) as passed,
        case when statement_line_code is null and abs(amount_after_accruals_local) > 0.005
             then 'Unmapped account carrying a balance — needs an account_map row'
             else null end                                                         as fail_reason
    from {{ ref('rpt_subsidiary_tb') }}
),

-- ---- C-21  Effective-dated mapping spans do not overlap ----------------------
am as (
    select company_name, local_account_no, statement_line_code,
           cast(effective_from as date) as vf, cast(effective_to as date) as vt
    from {{ ref('account_map') }}
),
am_overlap as (
    select distinct a.company_name, a.local_account_no
    from am a
    join am b
      on b.company_name     = a.company_name
     and b.local_account_no = a.local_account_no
     and (b.vf > a.vf or (b.vf = a.vf and b.statement_line_code > a.statement_line_code))
    where b.vf <= a.vt and a.vf <= b.vt
),
am_group as (
    select company_name, local_account_no, count(*) as spans
    from am group by company_name, local_account_no
),
c21 as (
    select
        cast('C-21' as {{ dbt.type_string() }})                                    as test_id,
        (select p from latest_period)                                              as period,
        cast('company-account' as {{ dbt.type_string() }})                         as unit_type,
        cast(g.company_name || '|' || g.local_account_no as {{ dbt.type_string() }}) as unit_key,
        cast(g.company_name as {{ dbt.type_string() }})                            as entity,
        cast('Mapping spans do not overlap' as {{ dbt.type_string() }})            as description,
        cast(g.spans as numeric(20,4))                                             as metric_value,
        cast(1 as numeric(20,4))                                                   as threshold,
        (o.company_name is null)                                                   as passed,
        case when o.company_name is not null
             then 'Overlapping effective-dated mapping spans — would double-count'
             else null end                                                         as fail_reason
    from am_group g
    left join am_overlap o
           on o.company_name = g.company_name and o.local_account_no = g.local_account_no
),

-- ---- C-22  KES TB foots beyond the translation plug (plug not masking unmapped)
c22 as (
    select
        cast('C-22' as {{ dbt.type_string() }})                                    as test_id,
        period,
        cast('entity-period' as {{ dbt.type_string() }})                           as unit_type,
        cast(company_name || ' ' || period as {{ dbt.type_string() }})             as unit_key,
        cast(company_name as {{ dbt.type_string() }})                              as entity,
        cast('Translation plug is not masking unmapped balance' as {{ dbt.type_string() }}) as description,
        cast(round(unmapped_kes, 4) as numeric(20,4))                              as metric_value,
        cast(1.0 as numeric(20,4))                                                 as threshold,
        abs(unmapped_kes) <= 1.0                                                   as passed,
        case when abs(unmapped_kes) > 1.0
             then 'Unmapped balance KES ' || round(unmapped_kes, 2)
                  || ' hiding in the translation reserve'
             else null end                                                         as fail_reason
    from {{ ref('int_translation_reserve_plug') }}
),

-- ---- C-25  report_line_map derived from account_map (no orphans) -------------
am_keys as (select distinct company_name, local_account_no from {{ ref('account_map') }}),
c25 as (
    select
        cast('C-25' as {{ dbt.type_string() }})                                    as test_id,
        (select p from latest_period)                                              as period,
        cast('report-line-row' as {{ dbt.type_string() }})                         as unit_type,
        cast(r.company_name || '|' || r.local_account_no || '|' || r.report_line_code
             as {{ dbt.type_string() }})                                           as unit_key,
        cast(r.company_name as {{ dbt.type_string() }})                            as entity,
        cast(r.report_line_code || ' <- ' || r.local_account_no
             as {{ dbt.type_string() }})                                           as description,
        cast(0 as numeric(20,4))                                                   as metric_value,
        cast(0 as numeric(20,4))                                                   as threshold,
        (k.local_account_no is not null)                                           as passed,
        case when k.local_account_no is null
             then 'report_line_map row has no live account_map row (orphan)'
             else null end                                                         as fail_reason
    from {{ ref('report_line_map') }} r
    left join am_keys k
           on k.company_name = r.company_name and k.local_account_no = r.local_account_no
)

select * from c05
union all select * from c08
union all select * from c11
union all select * from c12
union all select * from c17
union all select * from c18
union all select * from c20
union all select * from c21
union all select * from c22
union all select * from c25
