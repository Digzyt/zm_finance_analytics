{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'uganda', 'equity_accounted']
  )
}}

-- =============================================================================
-- stg_uganda_associate — Uganda Associate, equity-accounted.
--
-- Uganda is NOT consolidated line-by-line. Per IFRS equity accounting:
--   - SFP: a single line "Investment in Associate" valued at our share of
--     net assets, plus retained share of profits.
--   - SCI: a single line "Share of profit from associate" (post-tax).
--
-- The source workbook ("Uganda associate" tab) is a small formatted statement
-- rather than a true TB. We extract two values:
--   1. Profit-for-the-year (KES)  -> flows into SCI as Share of Profit
--   2. Investment carrying value (KES) -> flows into SFP as Investment in Associate
--
-- These are NOT unioned with the main stg_gl_entry. The intermediate layer
-- adds them at the group level only.
-- =============================================================================

select
    'UGANDA'                                  as "Company_Name",
    "Posting_Date",
    "Line_Item",                                   -- e.g. 'Share of profit', 'Investment in Associate'
    "Amount_UGX",
    "Amount_KES",
    "Equity_Treatment_Code"                        -- 'SCI_SHARE_OF_PROFIT' | 'SFP_INVESTMENT_IN_ASSOCIATE'
from {{ source('bronze_source', 'gl_entry_uganda_assoc') }}

-- NOTE: gl_entry_uganda_assoc is a different shape from the standard gl_entry
-- source (see seeds/bronze/gl_entry_uganda_assoc.csv). It is intentionally
-- declared in the same source schema for consistency but is consumed only here.
