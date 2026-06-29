{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'eliminations']
  )
}}

-- =============================================================================
-- int_eliminations
--
-- Scaffold for consolidation eliminations. The elimination_journal seed
-- carries IC pairs and adjustment entries — empty today, populated as the
-- Module A diagnostic identifies them.
--
-- Output is at the same grain as int_fx_translation (period x statement_line
-- x company), with amount_kes representing the elimination adjustment to
-- apply against the unionised group totals.
--
-- Example entries we expect to be added:
--   1. Investment in Subsidiary (ZHL) <-> Share Capital (operating sub)
--   2. Intercompany Receivable/Payable (Head Office Receivable Account)
--   3. Intercompany Revenue <-> Intercompany Expense pairs
-- =============================================================================

with elims as (
    select * from {{ ref('elimination_journal') }}
)

select
    company_name,
    cast(period as text)                             as period,
    statement_line_code,
    statement_type,
    journal_id,
    journal_description,
    cast(elimination_amount_kes as numeric(20, 4))  as amount_kes
from elims
where coalesce(cast(posted as text), 'true') in ('true','TRUE','t','1')
