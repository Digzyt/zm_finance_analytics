{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'mena']
  )
}}

-- =============================================================================
-- stg_mena_descriptive_tb — MENA-specific staging.
--
-- MENA's source TB is at description-line level with no BC account code, so we
-- synthesise a stable account code from the description (Finance signs off the
-- mapping by description). The seed carries monthly movements with Posting_Date;
-- we cross-join the period spine so each movement contributes to the cumulative
-- balance of every period >= its month (period is a real dimension downstream).
-- =============================================================================

with src as (
    select
        'MENA'                                     as "Company_Name",
        "Description"                              as "Description_Source",
        "Net_Debit_Credit"                         as "Amount",          -- MENA's "Net Debit /(credit)" column
        "Amount_KES",                                                    -- pre-translated KES already on the source
        cast("Posting_Date" as date)              as posting_date
    from {{ source('bronze_source', 'gl_entry_mena') }}
),

periods as (
    select * from {{ ref('stg_report_periods') }}
)

select
    src."Company_Name",
    -- synthetic stable account code derived from the description string
    'MENA-' || upper(substr(md5(src."Description_Source"), 1, 10)) as "G_L_Account_No",
    src."Description_Source"                                       as "Description",
    src."Amount",
    src."Amount_KES",
    p.period
from src
cross join periods p
where src."Description_Source" is not null
  and trim(src."Description_Source") <> ''
  and src.posting_date <= p.period_end
