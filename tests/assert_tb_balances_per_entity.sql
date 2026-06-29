-- A trial balance must balance: total debits = total credits within an entity.
-- Tolerance of 1.00 in the entity's local currency to absorb rounding from the
-- workbook source.
--
-- Returns rows that VIOLATE the assertion. Test passes when this query is empty.

with totals as (
    select
        "Company_Name"                                                                                  as company_name,
        period                                                                                          as period,
        sum(coalesce(cast("Debit_Amount"  as numeric(20,4)), 0))                                        as total_debits,
        sum(coalesce(cast("Credit_Amount" as numeric(20,4)), 0))                                        as total_credits,
        sum(coalesce(cast("Debit_Amount"  as numeric(20,4)), 0)
            - coalesce(cast("Credit_Amount" as numeric(20,4)), 0))                                       as net
    from {{ ref('stg_gl_entry') }}
    group by "Company_Name", period
)

select *
from totals
where abs(net) > 1.0
