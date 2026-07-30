{{
  config(
    materialized = 'view',
    tags = ['intermediate', 'fx', 'translation']
  )
}}

-- =============================================================================
-- int_translation_reserve_plug — the IAS 21 translation difference that arises
-- because the SFP is translated at closing rate and the SCI at period average.
--
-- A trial balance foots to zero in its functional currency. Translate the SFP
-- rows at closing and the SCI rows at average and it no longer does: the residual
-- is a genuine translation difference, and it has to go somewhere or the SFP will
-- not balance. The client posts it to translation reserve, on the row of their
-- `KES consolidated TB` labelled
--     "forex difference (p & l translated at average and not closing)"
-- (row 286 in the Feb-June 2026 packs, Category = 'Translation reserve'). Each
-- entity's cell there is a single reference back to that entity's own TB tab —
-- e.g. Malawi is `=-'Malawi TB'!D90`, and D90 is `=SUM(D5:D89)`, the sum of the
-- whole KES column. Their local-currency column on the same row sums to ~1e-06,
-- which is the proof that the residual is purely a translation artefact.
--
-- So the plug is, exactly: MINUS the sum of the entity's debit-positive KES
-- across every account. We were missing it, and it was the whole of the
-- `translation_reserve` difference in the SCI/SFP recon for 29 of 30
-- entity-periods, to the cent (KES 1,017,003 in total). The one exception is
-- ZATL 2026-04, where the recon is out by 137,797.63 against a plug of 448.00 —
-- ZATL April has a separate FX problem, visible as 17 SFP cells off with
-- retained_earnings / share_capital / trade_receivables all adrift.
--
-- Sign derivation, spelled out because it is easy to get backwards:
--   * upstream `amount_kes` is the PRESENTATION figure — sign_multiplier from
--     statement_line has already been applied by int_sign_normalisation
--   * so debit-positive KES  = amount_kes * sign_multiplier   (it is +/-1)
--   * the plug, debit-positive = -SUM(amount_kes * sign_multiplier)
--   * translation_reserve has sign_multiplier = -1, so converting the plug back
--     to the presentation basis multiplies by -1 again, and the two negatives
--     cancel: plug_presentation = SUM(amount_kes * sign_multiplier)
-- Checked against Malawi 2026-03: their plug is -130,701.83, we showed
-- translation_reserve 30,078,625.51 vs their 30,209,327.33, and adding
-- +130,701.83 lands on 30,209,327.34.
--
-- Basis: `int_tb_with_accruals`, i.e. bronze plus the client's accrual overlay
-- and NOTHING ELSE. That is deliberately the same basis as their entity tab,
-- which is what their formula sums. In particular the computed tax from
-- int_computed_tax is excluded, because it is posted at group level on their
-- `KES consolidated TB` and is not on the entity tab — including it here would
-- add a residual they do not carry. (Their group-level tax journal does debit an
-- SCI line at average and credit an SFP line at closing, so it introduces a
-- small translation difference of its own that neither they nor we recognise.
-- Flagged for Finance rather than silently modelled.)
--
-- amount_local is 0 by construction, not by omission: a translation difference
-- does not exist in the functional currency. The local column of the client's own
-- row is likewise empty.
-- =============================================================================

with tb as (
    select * from {{ ref('int_tb_with_accruals') }}
),

sl as (
    select * from {{ ref('statement_line') }}
),

-- The entity's translated trial balance, back on a debit-positive footing.
--
-- Unmapped accounts are INCLUDED, deliberately: the client's formula sums their
-- whole tab, so excluding them would put us on a different basis and the plug
-- would not tie. The risk is that a genuinely unmapped balance gets quietly
-- absorbed into translation reserve instead of showing up as a missing statement
-- line, so the unmapped portion is carried out separately as a diagnostic and
-- asserted on by tests/assert_translation_plug_not_masking_unmapped.sql. Today
-- every unmapped account in a foreign entity (DRC 3, ZATL 1) has a nil balance,
-- so the distinction costs nothing and buys an early warning.
residual as (
    select
        t.company_name,
        t.period,
        sum(t.amount_kes * coalesce(s.sign_multiplier, 1))  as debit_positive_kes,
        sum(case when t.statement_line_code is null
                 then t.amount_kes else 0 end)              as unmapped_kes
    from tb t
    left join sl s
           on s.statement_line_code = t.statement_line_code
    group by t.company_name, t.period
),

line as (
    select * from sl where statement_line_code = 'translation_reserve'
)

select
    r.company_name,
    r.period,

    l.statement_line_code,
    l.statement_type,
    l.category_l1,
    l.category_l2,
    l.category_l3,
    l.line_label,
    l.line_order,

    -- see the sign derivation above: the two negatives cancel
    cast(0                        as numeric(20, 4))  as amount_local,
    cast(r.debit_positive_kes     as numeric(20, 4))  as amount_kes,

    -- kept for diagnostics: this is the figure on the client's row, and the two
    -- should be equal and opposite
    cast(-r.debit_positive_kes    as numeric(20, 4))  as client_basis_plug_kes,

    -- how much of the plug is really an unmapped account rather than a genuine
    -- translation difference. Should stay at zero; see the residual CTE.
    cast(r.unmapped_kes           as numeric(20, 4))  as unmapped_kes

from residual r
cross join line l
-- KES-functional entities translate at 1.0, so their residual is zero by
-- construction. Dropping them keeps the fact table free of no-op rows.
where abs(r.debit_positive_kes) > 0.005
