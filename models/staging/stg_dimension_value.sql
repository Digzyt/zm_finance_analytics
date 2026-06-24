{{
  config(
    materialized = 'view',
    tags = ['staging', 'dimensions']
  )
}}

-- =============================================================================
-- stg_dimension_value — BC Table 349. Dimension master per company.
-- =============================================================================

select {{ zamara_finance.dimension_value_column_list('ZAAC')    }} from {{ source('bronze_source', 'dimension_value_zaac')    }}
union all
select {{ zamara_finance.dimension_value_column_list('ZARIB')   }} from {{ source('bronze_source', 'dimension_value_zarib')   }}
union all
select {{ zamara_finance.dimension_value_column_list('ZAMRE')   }} from {{ source('bronze_source', 'dimension_value_zamre')   }}
union all
select {{ zamara_finance.dimension_value_column_list('ZHL')     }} from {{ source('bronze_source', 'dimension_value_zhl')     }}
union all
select {{ zamara_finance.dimension_value_column_list('ZATL')    }} from {{ source('bronze_source', 'dimension_value_zatl')    }}
union all
select {{ zamara_finance.dimension_value_column_list('C&P')     }} from {{ source('bronze_source', 'dimension_value_c_p')     }}
union all
select {{ zamara_finance.dimension_value_column_list('MENA')    }} from {{ source('bronze_source', 'dimension_value_mena')    }}
union all
select {{ zamara_finance.dimension_value_column_list('MALAWI')  }} from {{ source('bronze_source', 'dimension_value_malawi')  }}
union all
select {{ zamara_finance.dimension_value_column_list('NIGERIA') }} from {{ source('bronze_source', 'dimension_value_nigeria') }}
union all
select {{ zamara_finance.dimension_value_column_list('RWANDA')  }} from {{ source('bronze_source', 'dimension_value_rwanda')  }}
union all
select {{ zamara_finance.dimension_value_column_list('DRC')     }} from {{ source('bronze_source', 'dimension_value_drc')     }}
