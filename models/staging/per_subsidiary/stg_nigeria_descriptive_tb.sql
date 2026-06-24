{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'nigeria']
  )
}}

-- =============================================================================
-- stg_nigeria_descriptive_tb — Nigeria-specific staging.
--
-- Nigeria's source TB carries an Account_Name and Category column but no
-- BC account code. We synthesise a stable code from the description so the
-- downstream account_map join works uniformly. Category is preserved as it
-- gives a coarser SCI / SFP classification that's useful as a sanity check.
-- =============================================================================

with src as (
    select
        'NIGERIA'                                  as "Company_Name",
        "Account_Name",
        "Category",
        "Amount",
        "Amount_KES"
    from {{ source('bronze_source', 'gl_entry_nigeria') }}
)

select
    "Company_Name",
    'NGA-' || upper(substr(md5("Account_Name"), 1, 10)) as "G_L_Account_No",
    "Account_Name"                                       as "Description",
    "Category"                                           as "Source_Category",
    "Amount",
    "Amount_KES"
from src
where "Account_Name" is not null
  and trim("Account_Name") <> ''
