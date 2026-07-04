{{
  config(
    materialized = 'view',
    tags = ['staging', 'per_subsidiary', 'deprecated']
  )
}}

-- =============================================================================
-- DEPRECATED — Nigeria now uses BC codes via the standard stg_gl_entry union.
--
-- The multi-month TB workbooks in Finance Templates/2026 TBs/ include a
-- "BC Codes" column on the Nigeria tab, so we no longer need to synthesise
-- account codes from MD5-hashed descriptions. Nigeria flows through
-- stg_gl_entry.sql alongside ZAAC, ZARIB, Rwanda, DRC, etc.
--
-- This model is kept as an empty no-op to avoid breaking any historical refs.
-- Safe to remove once all downstream references are audited.
-- =============================================================================

select
    cast(null as text)                as "Company_Name",
    cast(null as text)                as "G_L_Account_No",
    cast(null as text)                as "Description",
    cast(null as numeric(20, 4))      as "Amount",
    cast(null as numeric(20, 4))      as "Amount_KES",
    cast(null as text)                as period
where false
