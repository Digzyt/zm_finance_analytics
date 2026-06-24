{{
  config(
    materialized = 'view',
    tags = ['staging', 'dimensions']
  )
}}

-- =============================================================================
-- stg_dimension_set_entry — BC Table 480.
-- Resolves Dimension_Set_ID -> dimension code/value pairs.
-- =============================================================================

select {{ zamara_finance.dimension_set_entry_column_list('ZAAC')    }} from {{ source('bronze_source', 'dimension_set_entry_zaac')    }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('ZARIB')   }} from {{ source('bronze_source', 'dimension_set_entry_zarib')   }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('ZAMRE')   }} from {{ source('bronze_source', 'dimension_set_entry_zamre')   }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('ZHL')     }} from {{ source('bronze_source', 'dimension_set_entry_zhl')     }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('ZATL')    }} from {{ source('bronze_source', 'dimension_set_entry_zatl')    }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('C&P')     }} from {{ source('bronze_source', 'dimension_set_entry_c_p')     }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('MENA')    }} from {{ source('bronze_source', 'dimension_set_entry_mena')    }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('MALAWI')  }} from {{ source('bronze_source', 'dimension_set_entry_malawi')  }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('NIGERIA') }} from {{ source('bronze_source', 'dimension_set_entry_nigeria') }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('RWANDA')  }} from {{ source('bronze_source', 'dimension_set_entry_rwanda')  }}
union all
select {{ zamara_finance.dimension_set_entry_column_list('DRC')     }} from {{ source('bronze_source', 'dimension_set_entry_drc')     }}
