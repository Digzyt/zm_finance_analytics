{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'eliminations']
  )
}}

-- =============================================================================
-- int_eliminations
--
-- Consolidation elimination & adjustment journals. These do NOT come from BC —
-- they are manual consolidation entries (cancel investment-in-subsidiary vs
-- subsidiary equity, intercompany balances, goodwill, translation reserve, NCI,
-- etc.). Finance supplies them each period in the elimination_journal seed
-- using plain double-entry (debit_kes / credit_kes) against a report line.
--
-- Convention bridge: the seed is in natural debit-positive/credit book form.
-- We multiply (debit - credit) by the statement line's sign_multiplier so the
-- result lands in the same sign-normalised space as subsidiary_sum_kes; then
-- fct_consolidated_tb adds them:
--     consolidated = subsidiary_sum + eliminations + equity_pickup
--
-- Each journal must balance (sum debit = sum credit) — see
-- tests/assert_elimination_journals_balance.sql.
-- =============================================================================

with elims as (
    select * from {{ ref('elimination_journal') }}
),

sl as (
    select statement_line_code, statement_type, sign_multiplier
    from {{ ref('statement_line') }}
)

select
    e.entity_scope                                   as company_name,
    cast(e.period as text)                           as period,
    e.statement_line_code,
    e.statement_type,
    e.journal_id,
    e.journal_description,
    e.elimination_type,
    cast(
        (coalesce(cast(e.debit_kes  as numeric(20,4)), 0)
       - coalesce(cast(e.credit_kes as numeric(20,4)), 0))
        * coalesce(sl.sign_multiplier, 1)
    as numeric(20, 4))                               as amount_kes
from elims e
left join sl
       on sl.statement_line_code = e.statement_line_code
where upper(coalesce(cast(e.posted as text), 'Y')) in ('Y','YES','TRUE','T','1')
