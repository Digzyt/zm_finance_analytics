{{
  config(
    materialized = 'table',
    tags = ['marts', 'core', 'dim']
  )
}}

-- =============================================================================
-- dim_entity — the entity register, hydrated from the entity.csv seed.
-- =============================================================================

select
    entity_code,
    entity_name,
    functional_ccy,
    consolidation_method,             -- 'Full' | 'Equity' | 'Sub-consolidated'
    parent_entity_code,
    is_active,
    {{ dbt_utils.generate_surrogate_key(['entity_code']) }}  as entity_key
from {{ ref('entity') }}
