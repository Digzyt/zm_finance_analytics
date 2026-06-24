{{
  config(
    materialized = 'view',
    tags = ['staging', 'gl', 'core_entities']
  )
}}

-- =============================================================================
-- stg_gl_account — unions all entities' G/L Account (BC Table 15) tables.
-- Casts live in macros/staging_column_lists.sql for cross-entity consistency.
-- =============================================================================

with unioned as (

    select {{ zamara_finance.gl_account_column_list('ZAAC')    }} from {{ source('bronze_source', 'gl_account_zaac')          }}
    union all
    select {{ zamara_finance.gl_account_column_list('ZARIB')   }} from {{ source('bronze_source', 'gl_account_zarib')         }}
    union all
    select {{ zamara_finance.gl_account_column_list('ZAMRE')   }} from {{ source('bronze_source', 'gl_account_zamre')         }}
    union all
    select {{ zamara_finance.gl_account_column_list('ZHL')     }} from {{ source('bronze_source', 'gl_account_zhl')           }}
    union all
    select {{ zamara_finance.gl_account_column_list('ZATL')    }} from {{ source('bronze_source', 'gl_account_zatl')          }}
    union all
    select {{ zamara_finance.gl_account_column_list('C&P')     }} from {{ source('bronze_source', 'gl_account_c_p')           }}
    union all
    select {{ zamara_finance.gl_account_column_list('MENA')    }} from {{ source('bronze_source', 'gl_account_mena')          }}
    union all
    select {{ zamara_finance.gl_account_column_list('MALAWI')  }} from {{ source('bronze_source', 'gl_account_malawi')        }}
    union all
    select {{ zamara_finance.gl_account_column_list('NIGERIA') }} from {{ source('bronze_source', 'gl_account_nigeria')       }}
    union all
    select {{ zamara_finance.gl_account_column_list('RWANDA')  }} from {{ source('bronze_source', 'gl_account_rwanda')        }}
    union all
    select {{ zamara_finance.gl_account_column_list('DRC')     }} from {{ source('bronze_source', 'gl_account_drc')           }}
    union all
    select {{ zamara_finance.gl_account_column_list('UGANDA')  }} from {{ source('bronze_source', 'gl_account_uganda_assoc') }}

)

select * from unioned
