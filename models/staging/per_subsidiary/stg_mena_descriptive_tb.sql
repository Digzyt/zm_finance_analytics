{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'mena']
  )
}}

-- =============================================================================
-- stg_mena_descriptive_tb — MENA-specific staging.
--
-- MENA's source TB (workbook tab "MENA TB") does NOT carry BC account codes.
-- The rows are at description-line level (e.g., "Accounts Receivable",
-- "Input VAT") with no G_L_Account_No. This is unlike the other entities
-- where account codes anchor the mapping.
--
-- Approach: synthesise an account code from a stable hash of the description,
-- so MENA can flow through the same downstream account_map join. The mapping
-- table (account_map.csv) carries MENA-specific entries keyed on these
-- synthesised codes — Finance signs off the mapping by description.
--
-- When BC access lands, MENA's gl_entry will carry real account codes and
-- this model can be retired (or pass-through). The downstream models will
-- never know the difference.
-- =============================================================================

with src as (
    select
        'MENA'                                     as "Company_Name",
        "Description"                              as "Description_Source",
        "Net_Debit_Credit"                         as "Amount",          -- MENA's "Net Debit /(credit)" column
        "Amount_KES"                                                     -- pre-translated KES already on the source
    from {{ source('bronze_source', 'gl_entry_mena') }}
)

select
    "Company_Name",
    -- synthetic stable account code derived from the description string
    'MENA-' || upper(substr(md5("Description_Source"), 1, 10)) as "G_L_Account_No",
    "Description_Source"                                        as "Description",
    "Amount",
    "Amount_KES"
from src
where "Description_Source" is not null
  and trim("Description_Source") <> ''
