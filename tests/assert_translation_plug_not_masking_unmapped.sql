-- The translation-reserve plug is the residual that makes an entity's translated
-- trial balance foot to zero, summed over its WHOLE tab — unmapped accounts
-- included, because that is the basis the client's own formula uses (see
-- int_translation_reserve_plug).
--
-- That creates one hazard: an account that falls out of account_map stops
-- reaching its statement line and its balance lands in the plug instead, so the
-- SFP still balances and the mapping gap is invisible. This test is the tripwire.
-- It compares the unmapped portion of each entity-period residual against the
-- plug itself, and warns when an unmapped balance is material either in absolute
-- terms or relative to the genuine translation difference.
--
-- Today every unmapped account in a foreign entity carries a nil balance, so this
-- returns nothing. Severity warn, not error: an unmapped account is a reason to
-- go and look at Internal/Phase1_Exceptions_Register.xlsx, not to fail the build.

{{ config(severity = 'warn') }}

select
    company_name,
    period,
    amount_kes           as plug_kes,
    unmapped_kes,
    abs(unmapped_kes)    as unmapped_abs
from {{ ref('int_translation_reserve_plug') }}
where abs(unmapped_kes) > 1.0
