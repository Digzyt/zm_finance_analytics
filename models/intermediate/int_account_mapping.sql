{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'mapping']
  )
}}

-- =============================================================================
-- int_account_mapping
--
-- Joins the unioned GL Entries to the local CoA and to the account_map seed
-- (which maps (Company_Name, G_L_Account_No) -> statement_line_code).
--
-- Output renames BC PascalCase columns to lowercase snake_case business names.
-- From this point downstream, BC field naming disappears.
-- =============================================================================

with gl as (
    select * from {{ ref('stg_gl_entry') }}
),

mena as (
    select
        "Company_Name",
        "G_L_Account_No",
        "Description",
        cast("Amount"     as numeric(20, 4)) as "Amount",
        cast("Amount_KES" as numeric(20, 4)) as "Amount_KES",
        period
    from {{ ref('stg_mena_descriptive_tb') }}
),

-- Nigeria now flows through stg_gl_entry with real BC codes (as of the
-- multi-month TB workbooks). The old stg_nigeria_descriptive_tb model is
-- retired — no longer referenced.

-- Bring the standard-entity GL into the same minimal shape as MENA
gl_minimal as (
    select
        "Company_Name",
        "G_L_Account_No",
        "Description",
        cast("Amount" as numeric(20, 4))    as "Amount",
        cast(null     as numeric(20, 4))    as "Amount_KES",  -- standard entities aren't pre-translated
        period
    from gl
),

all_lines as (
    select * from gl_minimal
    union all select * from mena
),

coa as (
    select * from {{ ref('stg_gl_account') }}
),

account_map as (
    select * from {{ ref('account_map') }}
),

statement_line as (
    select * from {{ ref('statement_line') }}
)

select
    l."Company_Name"                              as company_name,
    l."G_L_Account_No"                            as local_account_no,
    l."Description"                               as description,
    l.period                                      as period,

    coa."Name"                                    as account_name,
    coa."Account_Type"                            as account_type,
    coa."Income_Balance"                          as income_balance,
    coa."Account_Category"                        as account_category,

    am.statement_line_code                         as statement_line_code,
    sl.statement_type                              as statement_type,    -- 'SCI' | 'SFP'
    sl.sign_multiplier                             as sign_multiplier,
    sl.category_l1                                 as category_l1,
    sl.category_l2                                 as category_l2,
    sl.category_l3                                 as category_l3,
    sl.line_label                                  as line_label,
    sl.line_order                                  as line_order,

    cast(l."Amount"     as numeric(20, 4))        as amount_local,
    cast(l."Amount_KES" as numeric(20, 4))        as amount_kes_presupplied

from all_lines l
left join coa
       on coa."Company_Name"    = l."Company_Name"
      and coa."G_L_Account_No"  = l."G_L_Account_No"
left join account_map am
       on am.company_name       = l."Company_Name"
      and am.local_account_no   = l."G_L_Account_No"
left join statement_line sl
       on sl.statement_line_code = am.statement_line_code
