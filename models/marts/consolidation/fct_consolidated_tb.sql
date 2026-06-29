{{
  config(
    materialized = 'table',
    tags = ['marts', 'consolidation', 'fct']
  )
}}

-- =============================================================================
-- fct_consolidated_tb — group-grain consolidated trial balance.
--
-- Identity:
--   Consolidated  =  Σ(fully-consolidated subsidiaries)
--                 +  Eliminations (intercompany, investment in subsidiary)
--                 +  Uganda equity pick-up
--
-- For the demo with the seeded workbook data the "mostly a union" piece
-- dominates because eliminations and Uganda lines are empty/minimal. The
-- structure is in place so that when real data arrives, only the seeds change.
-- =============================================================================

with subs as (
    -- Fully-consolidated entities
    select
        period,
        statement_line_code,
        statement_type,
        sum(amount_kes) as amount_kes
    from {{ ref('fct_trial_balance') }}
    where company_name in (
        select entity_code
        from {{ ref('dim_entity') }}
        where consolidation_method = 'Full'
    )
    group by period, statement_line_code, statement_type
),

elims as (
    select
        period,
        statement_line_code,
        statement_type,
        sum(amount_kes) as amount_kes
    from {{ ref('int_eliminations') }}
    group by period, statement_line_code, statement_type
),

uganda as (
    -- Equity pickup: maps the Uganda associate lines into the SCI / SFP lines
    -- via the equity_treatment_code carried on the staging row.
    select
        p.period                                         as period,
        case u."Equity_Treatment_Code"
            when 'SCI_SHARE_OF_PROFIT'            then 'share_of_assoc_profit'
            when 'SFP_INVESTMENT_IN_ASSOCIATE'    then 'investment_in_associate'
        end                                              as statement_line_code,
        case u."Equity_Treatment_Code"
            when 'SCI_SHARE_OF_PROFIT'            then 'SCI'
            when 'SFP_INVESTMENT_IN_ASSOCIATE'    then 'SFP'
        end                                              as statement_type,
        sum(u."Amount_KES")                              as amount_kes
    from {{ ref('stg_uganda_associate') }} u
    cross join {{ ref('stg_report_periods') }} p
    where cast(u."Posting_Date" as date) <= p.period_end
    group by p.period, u."Equity_Treatment_Code"
),

combined as (
    select
        cast(period              as text)            as period,
        cast(statement_line_code as text)            as statement_line_code,
        cast(statement_type      as text)            as statement_type,
        cast(amount_kes          as numeric(20, 4))  as amount_kes,
        cast('subsidiary_sum'    as text)            as component
    from subs

    union all

    select
        cast(period              as text)            as period,
        cast(statement_line_code as text)            as statement_line_code,
        cast(statement_type      as text)            as statement_type,
        cast(amount_kes          as numeric(20, 4))  as amount_kes,
        cast('elimination'       as text)            as component
    from elims

    union all

    select
        cast(period              as text)            as period,
        cast(statement_line_code as text)            as statement_line_code,
        cast(statement_type      as text)            as statement_type,
        cast(amount_kes          as numeric(20, 4))  as amount_kes,
        cast('equity_pickup'     as text)            as component
    from uganda
)

select
    period,
    statement_line_code,
    statement_type,
    sum(case when component = 'subsidiary_sum' then amount_kes else 0 end) as subsidiary_sum_kes,
    sum(case when component = 'elimination'    then amount_kes else 0 end) as elimination_kes,
    sum(case when component = 'equity_pickup'  then amount_kes else 0 end) as equity_pickup_kes,
    sum(amount_kes)                                                         as consolidated_kes
from combined
where statement_line_code is not null
group by period, statement_line_code, statement_type
