-- account_map is now effective-dated: an account may appear more than once, each
-- row valid for a span of periods, because the client re-classifies some accounts
-- mid-year. int_account_mapping left-joins on the span, so two rows whose spans
-- overlap would fan the fact table out and double-count that account.
--
-- Fails if any (company, account) has two rows whose effective ranges intersect.

with m as (
    select
        company_name,
        local_account_no,
        statement_line_code,
        cast(effective_from as date) as valid_from,
        cast(effective_to   as date) as valid_to
    from {{ ref('account_map') }}
)

select
    a.company_name,
    a.local_account_no,
    a.statement_line_code   as line_a,
    b.statement_line_code   as line_b,
    a.valid_from            as from_a,
    a.valid_to              as to_a,
    b.valid_from            as from_b,
    b.valid_to              as to_b
from m a
join m b
  on b.company_name      = a.company_name
 and b.local_account_no  = a.local_account_no
 and (b.valid_from > a.valid_from
      or (b.valid_from = a.valid_from and b.statement_line_code > a.statement_line_code))
where b.valid_from <= a.valid_to
  and a.valid_from <= b.valid_to
