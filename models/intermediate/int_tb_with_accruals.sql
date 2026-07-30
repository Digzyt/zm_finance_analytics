{{ config(materialized='view', tags=['intermediate','accruals']) }}

-- =============================================================================
-- int_tb_with_accruals — the translated trial balance PLUS the client's accrual
-- overlay, which is the basis every reported figure is struck from.
--
-- Bronze holds the PRE-accrual figure (what BC itself would hold); the client's
-- statements are post-accrual. The overlay therefore has to rejoin the chain
-- BEFORE anything reads the P&L — int_computed_tax strikes tax as a percentage
-- of profit before tax, so adding the accrual any later gives those entities a
-- tax charge computed on the wrong profit. That is exactly what happened when
-- this union lived in fct_trial_balance: C&P and ZAAC were out by their own tax.
-- =============================================================================

select company_name, functional_ccy, period, local_account_no, description,
       statement_line_code, statement_type, category_l1, category_l2, category_l3,
       line_label, line_order, amount_local_signed, amount_kes
from {{ ref('int_fx_translation') }}

union all

select company_name, functional_ccy, period, local_account_no, description,
       statement_line_code, statement_type, category_l1, category_l2, category_l3,
       line_label, line_order, amount_local_signed, amount_kes
from {{ ref('int_tb_accrual_mapped') }}
