{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'nigeria']
  )
}}

-- =============================================================================
-- stg_nigeria_descriptive_tb — Nigeria-specific staging.
--
-- Nigeria's source carries Account_Name and Category but no BC code; we
-- synthesise a stable code from the name. Seed carries monthly movements with
-- Posting_Date; cross-join the period spine to make period a real dimension.
-- =============================================================================

with src as (
    select
        'NIGERIA'                                  as "Company_Name",
        "Account_Name",
        "Category",
        "Amount",
        "Amount_KES",
        cast("Posting_Date" as date)              as posting_date
    from {{ source('bronze_source', 'gl_entry_nigeria') }}
),

periods as (
    select * from {{ ref('stg_report_periods') }}
)

select
    src."Company_Name",
    'NGA-' || upper(substr(md5(src."Account_Name"), 1, 10)) as "G_L_Account_No",
    src."Account_Name"                                       as "Description",
    src."Category"                                           as "Source_Category",
    src."Amount",
    src."Amount_KES",
    p.period
from src
cross join periods p
where src."Account_Name" is not null
  and trim(src."Account_Name") <> ''
  and src.posting_date <= p.period_end
