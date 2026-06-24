-- Every GL entry should have a corresponding entry in account_map. Unmapped
-- accounts get dropped from the SCI/SFP rollups, which produces incorrect
-- totals. Surface them as a test failure (severity warn so this is visible
-- but doesn't block CI while the mapping is being completed).
--
-- Returns rows that VIOLATE the assertion. Test passes when this query is empty.

{{ config(severity = 'warn') }}

with mapped as (
    select * from {{ ref('int_account_mapping') }}
)

select
    company_name,
    local_account_no,
    description,
    sum(amount_local) as unmapped_amount_local
from mapped
where statement_line_code is null
group by company_name, local_account_no, description
having abs(sum(amount_local)) > 0
order by abs(sum(amount_local)) desc
