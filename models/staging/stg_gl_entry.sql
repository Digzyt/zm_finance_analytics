{{
  config(
    materialized = 'view',
    tags = ['staging', 'gl', 'core_entities']
  )
}}

-- =============================================================================
-- stg_gl_entry — unions the standard entities' G/L Entry (BC Table 17).
-- Column casts live in macros/staging_column_lists.sql so the UNION's typed
-- columns are guaranteed consistent across entities regardless of how dbt
-- inferred each seed's types.
-- =============================================================================

with unioned as (

    select {{ zamara_finance.gl_entry_column_list('ZAAC')   }} from {{ source('bronze_source', 'gl_entry_zaac')   }}
    union all
    select {{ zamara_finance.gl_entry_column_list('ZARIB')  }} from {{ source('bronze_source', 'gl_entry_zarib')  }}
    union all
    select {{ zamara_finance.gl_entry_column_list('ZAMRE')  }} from {{ source('bronze_source', 'gl_entry_zamre')  }}
    union all
    select {{ zamara_finance.gl_entry_column_list('ZHL')    }} from {{ source('bronze_source', 'gl_entry_zhl')    }}
    union all
    select {{ zamara_finance.gl_entry_column_list('ZATL')   }} from {{ source('bronze_source', 'gl_entry_zatl')   }}
    union all
    select {{ zamara_finance.gl_entry_column_list('C&P')    }} from {{ source('bronze_source', 'gl_entry_c_p')    }}
    union all
    select {{ zamara_finance.gl_entry_column_list('MALAWI') }} from {{ source('bronze_source', 'gl_entry_malawi') }}
    union all
    select {{ zamara_finance.gl_entry_column_list('RWANDA') }} from {{ source('bronze_source', 'gl_entry_rwanda') }}
    union all
    select {{ zamara_finance.gl_entry_column_list('DRC')    }} from {{ source('bronze_source', 'gl_entry_drc')    }}

)

select *
from unioned
where lower(coalesce("Reversed", 'false')) not in ('true', 't', '1')
