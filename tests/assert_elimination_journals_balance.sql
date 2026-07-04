-- Every elimination journal must balance: total debits = total credits.
-- Returns violating journals; test passes when empty. Severity warn.
{{ config(severity = 'warn') }}

select
    journal_id,
    period,
    sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)) as total_debits,
    sum(coalesce(cast(credit_kes as numeric(20,4)), 0)) as total_credits,
    sum(coalesce(cast(debit_kes  as numeric(20,4)), 0)
      - coalesce(cast(credit_kes as numeric(20,4)), 0)) as net
from {{ ref('elimination_journal') }}
group by journal_id, period
having abs(sum(coalesce(cast(debit_kes as numeric(20,4)),0)
          - coalesce(cast(credit_kes as numeric(20,4)),0))) > 1.0
