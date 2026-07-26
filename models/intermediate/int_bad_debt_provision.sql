{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'management_reporting', 'bad_debt']
  )
}}

-- =============================================================================
-- int_bad_debt_provision — bad-debt provision by report line & period.
--
-- The Group report's "Bad debt Provision" column is a separate provisioning
-- analysis (Debtor Analysis), NOT in the trial balance. Finance supplies it in
-- the bad_debt_provision seed at (period, entity, statement_line, days_past_due,
-- amount). Here we aggregate it to the entity's revenue report line so the Group
-- P&L can show revenue net of provision. Amounts are provision magnitudes
-- (positive); rpt_group_pl applies them as a reduction to revenue.
-- =============================================================================

with prov as (
    select * from {{ ref('bad_debt_provision') }}
),

mapped as (
    select
        period,
        case company_name
            when 'ZAAC'    then 'zaac_revenue'
            when 'ZARIB'   then 'zarib_revenue'
            when 'C&P'     then 'cp_revenue'
            when 'ZHL'     then 'zhl_interest'
            when 'ZAMRE'   then 'zamre_revenue'
            when 'MENA'    then 'mena_revenue'
            when 'ZATL'    then 'zarinet_revenue'
            when 'MALAWI'  then 'zarinet_revenue'
            when 'DRC'     then 'zarinet_revenue'
            when 'RWANDA'  then 'zarinet_revenue'
            when 'NIGERIA' then 'zarinet_revenue'
        end                                          as report_line_code,
        cast(amount_kes as numeric(20, 4))           as amount_kes
    from prov
)

select
    period,
    report_line_code,
    sum(amount_kes) as provision_kes
from mapped
where report_line_code is not null
group by period, report_line_code
