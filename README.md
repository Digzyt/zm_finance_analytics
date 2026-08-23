# Zamara Finance — dbt Project

> dbt project for the Phase 1 Finance Reporting Modernization. Built today against PostgreSQL with the Zamara monthly Trial Balance pack landed as seeds. Designed to switch cleanly to Microsoft Fabric Warehouse the moment BC access lands — see the **"How this switches to Fabric"** section below.

---

## Update — 30 July 2026 (accrual overlay, computed tax, translation plug, TB mart)

Major changes since the initial build. Read this before working in the model.

**Reconciliation status: 2,402 of 2,484 SCI/SFP line cells tie exactly to the client's own statements (96.7%), total absolute difference KES 8,424,090** — down from KES 91,316,170. ZAMRE, ZHL, Malawi and ZARIB tie on every line of both statements. **93.8% of what remains sits outside our models** (C&P 7,122,719 and ZATL 779,966, both traced to specific cells in the client's packs — see *Where the remaining variance comes from* below). Start from `Internal/Phase1_SCI_SFP_Recon_dbt_vs_Client.xlsx`.

- **Data covers Jan–Jun 2026.** Every mart carries periods `2026-01 … 2026-06`.
- **Statement-line taxonomy mirrors the client's own SCI/SFP structure** — 51 lines in `seeds/reference/statement_line.csv`, with `category_l1/l2/l3` following their statement hierarchy (ASSETS → Non-Current/Current Assets). Our marts therefore reconcile line-for-line with `SCI Detailed` / `SFP Detailed`.
- **`tb_category` on `statement_line`** — the client's own column-A grouping from `KES consolidated TB`, the 24-category template. Our 51 lines collapse onto it many-to-one. Exposed on `dim_statement_line` and every reporting mart so Power BI can group the TB and the statements exactly as Finance's workbook does.
- **Mapping is derived from the client's own formula chain**, not guessed: `SCI/SFP Detailed → KES consolidated TB → TB Local Currency → source '<Entity> TB'`. To resolve any mapping question, read the client's formula for the line and follow it to the source account. This is authoritative.
- **Bronze is PRE-accrual (the BC basis).** The entity TB tabs carry `Amount | Accruals | Amount After Accruals`. Bronze holds `Amount` — what BC itself would hold — and the client's accrual overlay travels separately in `seeds/reference/tb_accrual.csv`, rejoining the chain in `int_tb_accrual_mapped` → `int_tb_with_accruals`. **The overlay is the residual `Amount After Accruals − Amount`, not the accrual column**, because the client sometimes posts an adjustment straight into the netted column and leaves the accrual column at zero (their March tax journal does exactly that). Taking the residual makes *bronze + overlay = the reported figure* true by construction for every row — verified at 1,754 rows across six packs, zero exceptions.
- **The overlay must rejoin before `int_computed_tax`.** Tax is struck as a percentage of profit before tax, so adding the accrual later computes tax on the wrong profit. That mistake alone was worth KES 48m.
- **Computed tax is modelled** (`int_computed_tax` + `seeds/reference/tax_rate.csv`). Several entities carry no taxation account at all and the client posts a flat percentage of PBT as a journal (Dr Taxation / Cr Tax recoverable). Rows exist in `tax_rate.csv` **only** for the entity-periods where the client computes; everywhere else the charge comes from a real account.
- **The IAS 21 translation difference is modelled** (`int_translation_reserve_plug`). SFP translates at closing and SCI at average, so the translated TB no longer foots; the residual goes to translation reserve. The client carries it explicitly on `KES consolidated TB` as *"forex difference (p & l translated at average and not closing)"*, each cell being `=-'<Entity> TB'!<total>`, i.e. minus the sum of that entity's whole KES column. Was worth KES 1,017,003 across 29 entity-months.
- **New mart `subsidiary.rpt_subsidiary_tb`** — the trial balance at **account** grain, debit-positive so it foots to zero, reproducing the five columns of the client's own entity tabs. This is the table for the individual-TB visuals. See the Power BI section.
- **`region` on `entity.csv`** — Kenya / MENA / Africa, flowing through `dim_entity`, `fct_trial_balance` and all three subsidiary marts, so every visual can slice on it.
- **MENA** is descriptive-only (no codes in the packs): a synthetic `MENA-<md5(description)>` is generated in `stg_mena_descriptive_tb`. Nigeria was upgraded to real BC codes; `stg_nigeria_descriptive_tb` is a deprecated no-op.
- **The reconciliation is two re-runnable scripts** (`Scripts/extract_client_statements.py` then `Scripts/compare_dbt_to_client.py`). Next month's pack needs no code change — drop it in the folder and re-run.
- **Monthly intake:** run the checklist in `Internal/Phase1_Data_Checks_and_Finance_ICT_Issues.md` on every new TB pack (TB foots, blank codes, new/unmapped accounts, code-vs-description consistency, reconcile to the client Detailed, SFP self-balances, FX).

---

## Where the remaining variance comes from

Not a to-do list for the model — this is the diagnosis, so nobody re-investigates it. Full detail with cell references is in `Email_ReconVariances_to_Team_DRAFT.md` and the `Project_Handover.md` changelog (pt.10–pt.13).

| KES | Cause | Ours? |
|---|---|---|
| 7,122,719 | **C&P** — three accounts sit against a different code in `KES consolidated TB` than on the `C & P` tab: `B65180` Debtors Prepaid other → `B65160` Placements (Feb–Apr, corrected by the client themselves in June), `I25193` Conference Attended by Us → `I25192` Conference Given By Us (Jun), `I10121` Interest Income → `1020/080` Commission (Mar–Apr). Our mapping follows the C&P tab, which is also the bronze basis. **Do not "fix" `account_map`** — it would map Debtors Prepaid to cash and Interest Income to commission. | No |
| 779,966 | **ZATL** — two rate references on the ZATL tab. April's SFP uses `Rates!$F$10` (31 March closing) instead of `$F$11` (30 April); May's SCI uses `Rates!$F$12` (closing) instead of the `Average` row. Every affected cell is out by the *same* ratio to nine decimal places, which is the signature of a rate rather than a mapping. **`fx_rate.csv` is correct** — it takes closing from `Rates` rows 8–12 and each month's average from that pack's own `Average` row. | No |
| 521,391 | Nigeria 419,987 · MENA 75,753 · Rwanda 24,810 · ZAAC 720 · DRC 121. **MENA's SCI is the most likely place to find something genuinely ours** — it is the one entity still mapped on description alone. | Partly |

---

## What this project does today

The 2026 monthly Trial Balance pack (Jan–Jun, *Finance Templates → 2026 TBs*) is landed as **monthly G/L movement seeds** and flows through a layered dbt pipeline. `period` is a first-class dimension: every reporting mart carries one row per period, so you get the full month-by-month history, not a single snapshot.

```
seeds/bronze/*.csv          monthly G/L MOVEMENTS per entity, PRE-accrual (each row = that month's delta)
seeds/reference/tb_accrual   the client's accrual overlay, also as monthly movements
    │
    ▼
bronze_source.*             per-company landing tables — mirrors BC's schema
    │
    ▼
staging.stg_report_periods  the period spine (distinct month-ends: 2026-01 … 2026-06)
staging.stg_gl_entry        unioned + Company_Name; CROSS JOINED to the spine so each
staging.stg_tb_accrual      movement contributes to every period >= its own month
    │                       (cumulative sum to a period = the TB "as at" that month)
    ▼
int_account_mapping         account → statement_line (effective-dated)
int_sign_normalisation      apply statement_line.sign_multiplier
int_fx_translation          → KES: SFP at closing, SCI at average, per period
int_tb_accrual_mapped       the accrual overlay, mapped and signed the same way
    │
    ▼
int_tb_with_accruals        ledger + overlay = the REPORTED basis.
    │                       Everything downstream reads this, and it must come
    │                       BEFORE int_computed_tax.
    ├──▶ int_computed_tax             flat-% tax for entities with no tax account
    ├──▶ int_translation_reserve_plug the SFP-closing vs SCI-average residual
    │
    ▼
core.fct_trial_balance      company × PERIOD × statement_line spine fact
                            = base + computed tax + translation plug + derived net_profit
    │
    ├──▶  subsidiary.rpt_subsidiary_sci        per-entity SCI  (slice by company_name, period)
    ├──▶  subsidiary.rpt_subsidiary_sfp        per-entity SFP
    ├──▶  consolidation.rpt_consolidated_sci   Group SCI (IFRS)
    ├──▶  consolidation.rpt_consolidated_sfp   Group SFP (IFRS)
    │
    └──▶  intermediate.int_report_pl ──▶ consolidation.rpt_group_pl
                            the management P&L behind the monthly "Zamara Group
                            Financial Report" (Group sheet): Actual / Budget /
                            Variance / Prior-Year, revenue at entity grain +
                            expense-by-nature.

subsidiary.rpt_subsidiary_tb  ACCOUNT-grain TB, off int_sign_normalisation +
                              stg_tb_accrual directly (not fct_trial_balance) —
                              debit-positive, foots to zero, five client columns
```

**Every `rpt_*` table has a `period` column** valued `2026-01` … `2026-06`. Each period is the **cumulative year-to-date position as at that month-end**, translated at that month's FX rate. `select * from consolidation.rpt_consolidated_sci` returns all six months; filter `where period = '2026-03'` for one month.

**Three things are unioned onto the mapped base in `fct_trial_balance`**, all of them the client's own constructions and all SFP-side, so none disturbs `net_profit` (which sums SCI rows only): the computed tax charge, the translation-reserve plug, and the derived `net_profit` equity line itself.

**The seeds contain real workbook values, not random data.** They are the per-entity TB tabs from the monthly pack, differenced into monthly movements so the bronze layer behaves like BC's G/L Entry table (transactions that accumulate to a balance). Cumulative movements reconcile to each month's source closing balance to within rounding.

---

## Period model — read this first

- Bronze `gl_entry_*` seeds hold **movements**, not balances. `gl_entry_zaac` row for `2026-03-31` is *March's change*, not the March balance.
- `tb_accrual.csv` follows the same convention — monthly movements, not YTD — so it accumulates on the same spine. An account that carried an accrual last month and carries none this month has been **released** and needs an explicit reversal row, or its YTD would freeze at last month's figure. `Scripts/extract_accruals.py` generates those reversals; it self-tests that the YTD accruals net to zero within each entity-month (currently 15 of 15).
- `stg_report_periods` lists the distinct month-ends. Staging cross-joins it: a movement dated `2026-02-28` appears under periods `2026-02` … `2026-06` (every period on/after its month).
- Downstream `group by (company, period, statement_line)` therefore yields the **cumulative balance as at each period** = the trial balance "as at" that month. This is standard YTD reporting.
- `reporting_period` in `dbt_project.yml` is **no longer used to filter** — period selection is a `WHERE period = …` in your query / BI slicer. (The var is retained only as harmless metadata.)
- Adding July: re-run `Scripts/reseed_from_packs.py --write` then `Scripts/extract_accruals.py --write` with the July pack in the folder, add July's rates to `fx_rate.csv`, and add any `tax_rate` rows for entity-periods where the client computes tax. The spine and every mart pick the new period up automatically — no model changes.

---

## How this switches to Fabric when ready

The whole point of this project is that **when BC access lands, the model code does not change.** Only three things change at switch time:

1. **The profile target** — add `prod_fabric` to `profiles.yml` (template in `profiles.yml.example`); run `dbt build --target prod_fabric`.
2. **The source definitions** — edit `models/staging/_sources.yml` so the per-company source tables point at the Fabric Lakehouse raw extracts instead of the seeded Postgres tables.
3. **The seeds (mostly) retire** — bronze seeds get replaced by real BC extracts; reference seeds (`entity`, `statement_line`, `account_map`, `report_line`, `report_line_map`, `budget`, `fx_rate`, `elimination_journal`) stay.

Everything else — staging, intermediate, marts, tests, macros — is unchanged. See `DISCIPLINES.md` before adding any model. Headline rules:

| Discipline | Why |
|---|---|
| Sources declared from day one, never `ref()` on seeds | Source YAML is the single point of change at switch time |
| No PostgreSQL-specific SQL in models — use `dbt.*`, dbt-utils, or `adapter.dispatch` macros | T-SQL doesn't recognise `TO_CHAR`, `\|\|`, `JSONB`, etc. |
| Warehouse-specific quirks absorbed in staging only | Marts stay dialect-neutral |
| Target Fabric **Warehouse** (writable T-SQL), not Lakehouse (read-only) | Only the Warehouse supports dbt materialisations |
| Run parity tests against both adapters from day one of Fabric availability | Dialect drift is silent — catch early |

`macros/cross_db_helpers.sql` carries `adapter.dispatch` implementations for `date_part`, `year_month_string`, `safe_string_md5`, `safe_divide`, plus the pure-Jinja `period_end_date`. `macros/staging_column_lists.sql` casts every BC column explicitly so seed-inferred types and Fabric Delta types meet the same contract.

---

## Project layout

```
datamodel/
├── README.md                       # this file
├── DISCIPLINES.md                  # the 5 portability rules — READ FIRST
├── dbt_project.yml
├── profiles.yml.example
│
├── models/
│   ├── staging/
│   │   ├── _sources.yml
│   │   ├── _models.yml
│   │   ├── stg_report_periods.sql  # the period spine (distinct month-ends)
│   │   ├── stg_gl_entry.sql        # unions standard entities, cross-joins the spine
│   │   ├── stg_tb_accrual.sql      # the client's accrual overlay, onto the same spine
│   │   ├── stg_gl_account.sql
│   │   ├── stg_dimension_set_entry.sql
│   │   ├── stg_dimension_value.sql
│   │   └── per_subsidiary/         # MENA (descriptive), Nigeria (no-op), Uganda (equity)
│   │
│   ├── intermediate/
│   │   ├── int_account_mapping.sql
│   │   ├── int_sign_normalisation.sql
│   │   ├── int_fx_translation.sql
│   │   ├── int_tb_accrual_mapped.sql       # overlay mapped + signed like the ledger
│   │   ├── int_tb_with_accruals.sql        # ledger + overlay = the REPORTED basis
│   │   ├── int_computed_tax.sql            # flat-% tax where there is no tax account
│   │   ├── int_translation_reserve_plug.sql # IAS 21 closing-vs-average residual
│   │   ├── int_bad_debt_provision.sql
│   │   ├── int_zaac_subconsolidation.sql
│   │   ├── int_eliminations.sql
│   │   └── int_report_pl.sql       # management P&L layer (feeds rpt_group_pl)
│   │
│   └── marts/
│       ├── core/                   # dim_entity, dim_statement_line, dim_calendar, fct_trial_balance
│       ├── subsidiary/             # rpt_subsidiary_sci / _sfp / _tb  (slice by company_name)
│       └── consolidation/          # fct_consolidated_tb, rpt_consolidated_sci/_sfp, rpt_group_pl
│
├── seeds/
│   ├── bronze/                     # per-entity monthly MOVEMENT seeds, PRE-accrual
│   └── reference/                  # entity, statement_line, account_map, fx_rate, tax_rate,
│                                   #   tb_accrual, elimination_journal, bad_debt_provision,
│                                   #   manual_accruals, manual_pl_adjustments,
│                                   #   report_line, report_line_map, budget,
│                                   #   budget_subsidiary
│
├── macros/
│   ├── generate_schema_name.sql
│   ├── cross_db_helpers.sql        # adapter dispatch + period_end_date
│   ├── staging_column_lists.sql
│   └── test_overrides.sql
│
├── Scripts/                        # one-off + monthly Python, NOT part of dbt runs
│   ├── README.md                   # what each script does and the order to run them
│   ├── reseed_from_packs.py        # packs  -> bronze seeds  (run FIRST)
│   ├── extract_accruals.py         # packs  -> tb_accrual.csv (needs reseed_audit.csv)
│   ├── extract_budget.py           # budget workbook -> budget.csv (MTD -> YTD)
│   ├── extract_client_statements.py # packs -> the client-side benchmark
│   ├── compare_dbt_to_client.py    # marts vs benchmark -> the recon workbook
│   ├── code_overrides.csv          # pinned codes for duplicate / blank-code rows
│   ├── reseed_audit.csv            # every code decision the reseed made
│   └── out/                        # intermediate CSVs from the two recon scripts
│
└── tests/
    ├── assert_tb_balances_per_entity.sql        # per (entity, period)
    ├── assert_no_unmapped_accounts.sql
    ├── assert_account_map_no_overlaps.sql       # effective-dated spans must not intersect
    ├── assert_elimination_journals_balance.sql  # each journal nets Dr = Cr
    └── assert_translation_plug_not_masking_unmapped.sql
```

### The monthly script order matters

`extract_accruals.py` resolves the accrual rows' account codes through `reseed_audit.csv`, which `reseed_from_packs.py` writes. **Run the reseed first**, or the accrual rows keep the pack's own codes and silently fail to join to the TB.

```powershell
python Scripts/reseed_from_packs.py --write        # 1. bronze seeds + reseed_audit.csv
python Scripts/extract_accruals.py --write        # 2. tb_accrual.csv
dbt seed --full-refresh; dbt build                # 3. rebuild
python Scripts/extract_client_statements.py       # 4. client-side benchmark
python Scripts/compare_dbt_to_client.py           # 5. the recon workbook
```

Both extract scripts take the period from the pack filename, so a new month needs no code change.

---

## Quick start

```powershell
# from the datamodel/ folder
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install "dbt-core>=1.7,<2.0" "dbt-postgres>=1.7,<2.0"

cp profiles.yml.example $env:USERPROFILE\.dbt\profiles.yml
[System.Environment]::SetEnvironmentVariable("PG_PASSWORD", "your-actual-password", "User")
# close & reopen PowerShell for the env var to be visible

dbt deps
dbt seed --full-refresh     # required: seed schemas changed (movements, new ref seeds)
dbt build
```

`dbt seed --full-refresh` is needed because seed *schemas* changed (MENA/Nigeria gained `Posting_Date`; `gl_account_*` for re-coded entities regenerated; new `report_line` / `report_line_map` / `budget` seeds). After the first full-refresh, model-only changes need just `dbt build`.

To rebuild only the management P&L after editing its inputs: `dbt build --select int_report_pl+ rpt_group_pl`.

---

## What the Power BI Engineer owns

Once `dbt build` succeeds, connect Power BI to the Postgres database (Import is fine at these volumes). Import schemas `consolidation`, `subsidiary`, `core`, `ref`, and `data_quality` (the new Data Quality page — see its own section below).

### The golden rule: filter on `period`

Every reporting table has a `period` column (`'2026-01'` … `'2026-06'`). Each row is the **cumulative YTD position as at that month-end**. Put a **`period` slicer** on every page. `dim_calendar` (in `core`) is the period dimension to anchor it.

### Which table for which report

| Report | Table(s) | Notes |
|---|---|---|
| **Zamara Group Financial Report — "Group" P&L** (the monthly CEO pack) | `consolidation.rpt_group_pl` + `ref.report_line` | The management P&L. See dedicated section below. |
| Group Statement of Comprehensive Income (IFRS) | `consolidation.rpt_consolidated_sci` | |
| Group Statement of Financial Position (IFRS) | `consolidation.rpt_consolidated_sfp` | |
| Subsidiary P&L (per entity) | `subsidiary.rpt_subsidiary_sci` | Slice by `company_name` + `period` |
| **Budget vs actual, per subsidiary** | **`subsidiary.rpt_subsidiary_sci`** | **Carries `amount_budget_kes`, `variance_kes`, `variance_pct`. Check the sign note below.** |
| Subsidiary Balance Sheet (per entity) | `subsidiary.rpt_subsidiary_sfp` | Slice by `company_name` + `period` |
| **Individual Trial Balance (per entity)** | **`subsidiary.rpt_subsidiary_tb`** | **Account grain. See below.** |
| **KES Consolidated TB** | **`subsidiary.rpt_subsidiary_tb`** | A matrix: `company_name` on columns, `amount_after_accruals_kes` as the value. No new model needed. |
| Entity register / slicers | `core.dim_entity` | Includes `region` (Kenya / MENA / Africa) |
| Statement-line hierarchy (rows) | `core.dim_statement_line` | `category_l1 → l2 → l3 → line_label`, plus `tb_category` |
| Date / period dimension | `core.dim_calendar` | |
| Custom views / drill-through | `core.fct_trial_balance` | company × period × statement_line spine |

### Budget on the subsidiary P&L

`rpt_subsidiary_sci` carries budget and variance alongside the actual, from the
`budget_subsidiary` seed at the same `(company_name, statement_line_code, period)` grain — a
straight join, no allocation.

| Column | Meaning |
|---|---|
| `amount_kes` | actual, cumulative YTD |
| `amount_budget_kes` | budget, cumulative YTD |
| `variance_kes` / `variance_pct` | `actual − budget` |

**No prior year** — on either this mart or `rpt_group_pl`. See Open items for why.

**Mind the sign.** Everything in this mart is on the presentation basis — `sign_multiplier` has
been applied, so income *and* expenses are both **positive**, and the budget is stored the same
way so the two columns are comparable. So on an **expense** line a *positive* variance means
**overspend**. This is the opposite of `rpt_group_pl`, where expenses are stored negative.
**Do not copy a variance measure between the two models without re-checking the direction.**

Why this is not available from `rpt_group_pl`: its taxonomy pools ZAAC + ZARIB + C&P + ZHL into
by-nature expense lines and the five African entities into a single Zarinet total, so ZAAC's
personnel budget is not separable there. Use `rpt_group_pl` for the CEO pack and
`rpt_subsidiary_sci` for anything per entity. The two reconcile — the subsidiary seed is
self-tested to roll up to the group seed exactly, and `assert_budget_subsidiary_ties_to_group`
asserts it on every build.

`taxation` has no budget (the client's workbook stops at profit before tax) and Uganda is absent
(equity-accounted, not in the budget pack). Both arrive as NULL rather than zero, so a visual can
tell *"no budget set"* from *"budgeted at nil"* — use `COALESCE` in measures accordingly.

### `rpt_subsidiary_tb` — the individual trial balance

Account grain (`company_name × period × local_account_no`), ~5,000 rows, 11 entities, 6 periods. Reproduces the five columns of the client's own entity tabs:

| Column | Meaning |
|---|---|
| `local_account_no` / `description` | as the client's `A/C No` / `Description` |
| `amount_local` | the **pre-accrual** ledger figure — what BC would hold |
| `accruals_local` | the client's overlay; zero for the eight entities that have no such column |
| `amount_after_accruals_local` | `amount + accruals` — **the reported figure** |
| `amount_kes` / `accruals_kes` / `amount_after_accruals_kes` | the same three, translated |
| `fx_rate_applied` | the rate used — SFP at closing, SCI at average |
| `statement_line_code` / `line_label` / `tb_category` | so the TB cross-filters against the SCI and SFP visuals |
| `sign_multiplier` | to flip to the presentation basis if a visual wants it |
| `region`, `has_client_accrual`, `accrual_column_label` | slicers and provenance |

Two things to know:

- **It is debit-positive, so it foots to zero.** Deliberately *not* the presentation basis used by `rpt_subsidiary_sci` / `_sfp`, where `sign_multiplier` flips income and equity positive. A trial balance that does not show credits as negative is not a trial balance.
- **It is the only place unmapped accounts are visible.** Excluding them it ties to `rpt_subsidiary_sci` / `_sfp` in all 66 entity-periods; the unmapped rows appear here and nowhere else, which makes this the one table where you can see what is *not* reaching the statements.

Note `accrual_column_label` may read `derived: after - amount (…)`. That flags a row where the client's netted column moved but their accrual column did not, so our decomposition is derived rather than lifted — the reported figure is still theirs.

### Grouping rows the way Finance does

`tb_category` (on `dim_statement_line` and every mart) is the client's own column-A grouping from `KES consolidated TB` — 24 categories, e.g. *Cash and cash equivalents*, *Other receivables - Related parties*, *Income Statement-Expenses*. Use it when a visual needs to match their workbook line-for-line; use `category_l1/l2/l3` for the IFRS statement hierarchy. Two mappings are provisional pending Finance: `accrued_income` → *Other receivables*, and `net_profit` → *Retained earnings*.

### Building the "Zamara Group Financial Report" (Group P&L)

This is the centrepiece of the monthly pack. Use **`consolidation.rpt_group_pl`**, joined to **`ref.report_line`** for ordering and section labels. One row per `report_line_code` per `period`.

Columns:

| Column | Meaning |
|---|---|
| `period` | `'2026-01'` … `'2026-06'` — slice on this |
| `report_line_code` / `line_label` | the management line (e.g. `zaac_revenue`, `personnel_costs`) |
| `section` | `INCOME` or `EXPENSE` — drives subtotals |
| `line_order` | display order (use to sort rows) |
| `amount_actual_gross_kes` | Actual before bad-debt provision |
| `bad_debt_provision_kes` | NULL today — separate Wave 3.2 computation |
| `amount_actual_net_kes` | Actual after provision (= gross until Wave 3.2 lands) |
| `amount_budget_kes` | Budget, **all six periods loaded** (Jan–Jun 2026), cumulative YTD |
| `variance_kes` / `variance_pct` | Actual(Net) vs Budget |
| `amount_prior_year_kes` | NULL today — see the prior-year note in Open items |

Suggested visual — a **matrix**:
- Rows: `report_line.section` then `report_line.line_label`, sorted by `line_order`.
- Values: `amount_actual_net_kes`, `amount_budget_kes`, `variance_kes`, `variance_pct`.
- **Subtotals** (`Total Income`, `Total Expenses`, `PBT`) are not stored — let the matrix subtotal by `section`, and compute `PBT = sum(amount_actual_net_kes)` across all lines (income is positive, expenses negative, so a straight sum gives PBT).
- Period slicer drives the "as at" month.

Reconciliation status to be transparent about with Finance (as at 2026-04 vs the workbook):
- **Ties:** the Kenyan expense-by-nature block (Personnel, Premises, Communications, Printing, Insurance, Professional Fees, Motor Vehicle exact; others within a few %), plus ZAMRE and ZHL.
- **Known variances — all from the provisional `account_map`, not the report logic:** MENA P&L (its descriptive mapping is mostly balance-sheet), Zarinet/African subs (unmapped accounts from the Finance review list), ZARIB/ZAAC revenue (management gross-vs-net + intercompany HOFF definition), and bad-debt (= 0; Wave 3.2). These improve as the account map is confirmed.
- Revenue is at **entity grain** today. The finer revenue-stream split (Actuarial / Multicarrier / Grouplife / Medical / Special Projects …) needs BC department dimensions or a Finance allocation table — tracked as a backlog item.

### Recommended semantic model

- Relationships:
  - `fct_trial_balance.company_name` → `dim_entity.entity_code`
  - `fct_trial_balance.statement_line_code` → `dim_statement_line.statement_line_code`
  - `*.period` → `dim_calendar.period`
  - `rpt_group_pl.report_line_code` → `report_line.report_line_code`
- For the IFRS group/subsidiary statements, use `dim_statement_line` for row hierarchy and sorting (`line_order`).
- For the consolidated reports, the three component columns `subsidiary_sum_kes`, `elimination_kes`, `equity_pickup_kes` make the consolidation auditable — show them side by side so Finance sees where the Uganda equity pickup and eliminations land.
- ONE subsidiary model serves all entities — the `company_name` slicer produces the per-subsidiary view.

### Things to be aware of

- **Cumulative, not monthly-movement, in the marts.** A period row is YTD-to-that-month. To show a single month's movement in BI, subtract the prior period (or add a measure that does).
- **The mapping is provisional (~99% by value for the standard entities).** Treat numbers as demonstrably-shaped, not signed-off, until Finance confirms the account map.
- **Reload mechanics.** After the data engineer runs `dbt build`, Power BI needs a refresh to pick up new data. Schedule once past the demo.

---

## Data quality control board — the Data Quality Power BI page

A page that shows every reconciliation control, tested on each build, with the records
that failed one click away. It maps 1:1 to the 26-control Reconciliation Control Matrix
(governance pack sheet 11, `C-01`…`C-26`), so the page *is* the control matrix, live.

**Bring in two tables from the `data_quality` schema. No new modelling on your side.**

| Table | What it is |
|---|---|
| **`data_quality.dq_test_results`** | The **summary** — one row per control: `records_tested`, `records_passed`, `records_failed`, `pass_rate_pct`, `status`. This is the table behind the main visual. |
| **`data_quality.dq_test_failures`** | The **detail** — one row per failing record, with the control's title/block/severity attached. This is the drill-through target. |

(There is also `data_quality.dq_test_evaluations` — the atomic pass/fail rows behind the
SQL controls, all periods; keep it only if you want a trend visual. The page needs the two above.)

Relationship: `dq_test_results[test_id]` → `dq_test_failures[test_id]` (one-to-many, single direction).

### `dq_test_results` — the columns you'll use

| Column | Meaning |
|---|---|
| `test_id` (= `control_id`) | control id, e.g. `C-20` |
| `block` | `A. TB intake` · `B. Manual overlays` · `C. Translation & mapping` · `D. Output & release` — group rows on this |
| `title`, `category` | control name and short category |
| `records_tested` / `records_passed` / `records_failed` | the counts (null for a manual control) |
| `pass_rate_pct` | passed ÷ tested, one decimal — put a data bar on it |
| `status` | `PASS` · `FAIL` · `WARN` · `REVIEW` · `BLOCKED` · `MANUAL` · `NOT_LIVE` · `NOT_OPERATING` |
| `severity` | High / Medium / Low / Gate |
| `automation` | `SQL (dbt)` (recomputes every build) · `Script` · `Manual` · `Blocked` |
| `as_of` | the period the evidence covers — a control reading an earlier month than the current close is stale on purpose, not a bug |
| `tolerance`, `exception_codes`, `note`, `method`, `evidence`, `owner_preparer`, `owner_reviewer` | context, from the catalog seed |

`dq_test_failures` columns: `test_id · block · title · severity · period · entity · unit_type · unit_key · description · metric_value · threshold · fail_reason · exception_codes`. `metric_value` is the number that failed; `fail_reason` is the plain-English why.

### Building the page

1. **KPI cards** over `dq_test_results`:
   - `Controls = DISTINCTCOUNT(dq_test_results[test_id])`
   - `Failing = CALCULATE(DISTINCTCOUNT(dq_test_results[test_id]), dq_test_results[status]="FAIL")`
   - `Passing = CALCULATE(DISTINCTCOUNT(dq_test_results[test_id]), dq_test_results[status]="PASS")`
   - `Need attention = CALCULATE(DISTINCTCOUNT(dq_test_results[test_id]), dq_test_results[status] IN {"WARN","REVIEW","BLOCKED"})`
2. **Summary table / matrix** over `dq_test_results`, grouped by `block`, columns `test_id, title, records_tested, records_passed, records_failed, pass_rate_pct, status, automation, as_of`.
   - Conditional-format the `status` cell background by rule: PASS → green, FAIL → red, WARN/REVIEW/BLOCKED → amber, MANUAL/NOT_LIVE/NOT_OPERATING → grey.
   - Data bar on `pass_rate_pct`. Sort by `test_id`.
3. **Drill-through to the records.** Add a page "Failure detail", put `dq_test_failures[test_id]` in its Drillthrough well, and a table over `dq_test_failures` (`period, entity, unit_key, description, metric_value, fail_reason`). Right-click a control row → Drill through → Failure detail lands filtered to that control. Sort detail by `ABS(metric_value)` desc so material items lead.
4. **Slicers:** `block` and `status`; add `period` if you want to view a prior close.

The visual reference is **`Internal/DataQuality_PowerBI_Mockup.html`** — the intended layout and drill-through on the real July numbers. Full step-by-step in **`Internal/DataQuality_PowerBI_BuildGuide.md`**.

### What it looked like at first build (July 2026)

26 controls — **9 passing · 5 failing · 7 review/blocked**, the rest manual. Failing: `C-05` entity TB balancing (Malawi and ZATL July don't foot — the client's new "Profit" plug lines), `C-20` mapping coverage (22 unmapped accounts carrying a balance in July), `C-22` those unmapped foreign balances masking in the translation reserve, `C-25` report-line-map orphans (73/363), `C-11` three April elimination journals out by sub-shilling.

### Two things to know

- **10 controls are live SQL** (recompute on every `dbt build`): C-05, C-08, C-11, C-12, C-17, C-18, C-20, C-21, C-22, C-25. The other 16 are verified by the reseed/recon scripts or a manual attestation and carried in the `dq_external_results` seed with an `as_of` date — refresh them from that period's script outputs before you refresh the dataset (see the build guide, §5).
- **Overlay-dependent controls read an earlier `as_of`** until their seeds are extended for the new month — `C-08` (accruals), `C-11` (eliminations), `C-12` (budget). The page shows this rather than hiding it.

---

## What the Data Engineer owns

**1. `seeds/reference/account_map.csv` — populated (provisional, pending Finance confirmation).**

Carries **966 mappings** keyed on `(company_name, local_account_no)`, **effective-dated** because the client re-classifies some accounts mid-year. Derived from the client's own formula chain (see above). Remaining unmapped and open classification items are tracked in `Zamara/Internal/Phase1_Exceptions_Register.xlsx`, and the full mapping is presented for Finance sign-off in `Zamara/Internal/Phase1_Group_Mapping_Tables.xlsx`. When Finance confirms, fold corrections back into this seed.

Schema: `(company_name, local_account_no, statement_line_code, effective_from, effective_to)`. Rebuild downstream with `dbt build --select int_account_mapping+`. `assert_account_map_no_overlaps` fails if two rows for the same account have intersecting date spans — that would fan the fact table out and double-count.

**Do not re-map the three C&P accounts or the ZATL rates** to close the recon — see *Where the remaining variance comes from*. Both are client-side and are with Finance.

**1b. `seeds/reference/tb_accrual.csv` — the client's accrual overlay.**

81 rows, `(company_name, period, local_account_no, description, accrual_local, client_column, source_tab)`, monthly movements. Generated by `Scripts/extract_accruals.py`; **never hand-edit it** — it is derived, and the generator enforces the invariant that bronze + overlay equals the client's reported figure. Only ZAAC, ZARIB and C&P have an accrual column in the packs; everything else reads zero so the five TB columns render uniformly for all eleven entities.

**1c. `seeds/reference/tax_rate.csv` — where the client computes tax.**

`(company_name, period, tax_rate, basis, source, notes)`. Rows exist **only** for the entity-periods where the trial balance carries no taxation account and the client posts a flat percentage of PBT (ZATL, C&P, Rwanda, Nigeria, and ZAMRE/ZARIB in January). Everywhere else the charge comes from a real account via `account_map` and `int_computed_tax` must not fire. It is a **top-up**, not a guard: the charge posted is the client's computed figure less whatever the mapped accounts already give, which lands the taxation line on their number either way. One open item — Rwanda's March formula reads `*0.28`, not `*0.3`; flagged for Finance.

**2. Management-reporting seeds (for the Group P&L).**

- `report_line.csv` — the management P&L taxonomy: `report_line_code, section, presentation_sign, line_order, line_label`.
- `report_line_map.csv` — `(company_name, local_account_no, report_line_code)`, 363 rows (regenerated from the current `account_map`, incl. Nigeria on BC codes). Revenue at entity grain; expenses classified to nature by description; P&L restricted to `I`-codes. Add the ZARIB/ZAAC revenue-stream split here once Finance provides the department allocation (see `Phase1_Revenue_Stream_Mapping_Plan.docx`).
- `budget.csv` — `(report_line_code, period, amount_budget_kes)`. **150 rows: 25 report lines × Jan–Jun 2026**, generated by `Scripts/extract_budget.py` from `Finance Templates/June Budget and LYTD Comparison - Revised (1).xlsx`. Do not hand-edit — re-run the script when Finance revises the budget.

  Two things that script gets right and a manual load would not. **The workbook's budget columns are MTD, not YTD**, so each period is the cumulative sum of the month budgets up to it — the marts are all cumulative. And **Jan and Feb use different line wording**: `Travel` (later `Travelling`), `Management Fees` (`Management Expense`), `Pension Administration` (`Pension Admin Fee`); missing the first of those alone costs KES 3.9m on travelling. Entity column order also differs between packs (Jan has NIGERIA before RWANDA), so blocks are located from row 1 rather than assumed.

  It self-tests before writing and refuses to write if any check fails: Kenya's by-nature expense lines must account for the whole of its `Total Expenses` (they tie to the cent in all six periods), every non-subtotal label must be consumed by the mapping, and each period's YTD must equal the prior period plus that month. As a further check, **15 of the 25 lines reproduce the previously-loaded 2026-04 figures exactly**; the 10 that moved are the revision itself (ZARIB +40.8m, ZAAC +27.2m, C&P +17.8m — C&P had no budget at all before — Zarinet revenue −15.3m and expense +12.2m, and five smaller expense lines).

  **Prior year is deliberately not loaded**, though the same workbook carries LYMTD actuals in the third column of each entity block. See Open items.

**3. `seeds/reference/fx_rate.csv`** — `(currency, period, rate_type, rate_to_kes, rate_source)`, 2026-01…06, one `CLOSING` and one `AVERAGE` row per currency-period.

Lifted from each pack's own **`Rates`** tab: `RATES_TAB_CLOSING` from the dated month-end rows, `RATES_TAB_AVERAGE` from that pack's `Average` row (which is a period-to-date average, recomputed each month — hence a different value per period). `CBK` marks rates taken directly from the Central Bank of Kenya. **The rule is SFP at closing, SCI at average**, applied in `int_fx_translation`, and the residual goes to translation reserve via `int_translation_reserve_plug`.

Two cautions. The `Rates` tab's row numbers **move between packs** (the `Average` row is 23 in the April pack and 15 in May), so read it by label, not position. And the packs sometimes reference the wrong cell — ZATL's April SFP uses the March closing rate — so when a whole statement-month is out by a constant ratio, check the rate reference before suspecting the mapping.

**4. `elimination_journal.csv` — populated (double-entry standard).**

Holds the manual consolidation journals (these are NOT in BC): investment-in-subsidiary cancellations, intercompany balances, goodwill, translation reserve and NCI. Schema `(journal_id, period, journal_description, elimination_type, entity_scope, statement_line_code, statement_type, debit_kes, credit_kes, posted, notes)`. `int_eliminations` converts Dr/Cr to presentation sign via `statement_line.sign_multiplier`, feeding `fct_consolidated_tb`:

`consolidated = subsidiary_sum + eliminations + equity_pickup`

April is loaded (16 journals, 52 lines) from the consolidation workbook and cancels ~1.32bn of investment-in-subsidiary. Four SFP lines were added for these entries — `goodwill, translation_reserve, non_controlling_interests, deferred_tax` (statement_line is now 51 lines). Finance maintains this monthly via `Internal/Phase1_Elimination_Journal_Template.xlsx` (standard: `Phase1_Elimination_Journal_Standard.docx`). `assert_elimination_journals_balance` verifies each journal nets to zero.

**5. Adding a new month.** Drop the pack into `Finance Templates/2026 TBs/Consolidated Accounts/` and run the five steps in *The monthly script order matters* above. Add the month's `fx_rate` rows from the pack's `Rates` tab, and a `tax_rate` row for any entity-period where the client computes the charge. Every mart gains the new period with no model change.

**Things to avoid:**
- No Postgres-specific syntax in models (see `DISCIPLINES.md`). Use an `adapter.dispatch` macro with `postgres__foo` / `fabric__foo`.
- No per-seed `column_types:` — it breaks the cross-entity UNION; the `column_list` macros cast instead.
- Don't enable `persist_docs: columns: true` (Postgres case-folds quoted `"Company_Name"`).

---

## Status of tests on the current build

| Test | Status | Meaning |
|---|---|---|
| YAML generic tests (`not_null`, `unique`, `accepted_values`, `unique_combination_of_columns`) | PASS | Schema-level integrity OK |
| `assert_account_map_no_overlaps` | PASS | No effective-dated span intersects another for the same account |
| `assert_elimination_journals_balance` | PASS | All 16 April journals balance Dr = Cr |
| `assert_translation_plug_not_masking_unmapped` | PASS | No unmapped balance is being absorbed into translation reserve |
| `assert_budget_subsidiary_ties_to_group` | PASS | The subsidiary budget rolls up to the group budget (income lines) |
| `assert_tb_balances_per_entity` | WARN | Per (entity, period): some entities don't net to zero — a Finance discussion |
| `assert_no_unmapped_accounts` | WARN | 13 accounts awaiting Finance classification (see Exceptions Register) |

The two warnings are diagnostic by design and don't block downstream models.

**Why `assert_translation_plug_not_masking_unmapped` exists.** The translation plug is the residual that makes an entity's translated TB foot to zero, summed over its **whole** tab — unmapped accounts included, because that is the basis the client's own formula uses. The hazard is that an account falling out of `account_map` would land in translation reserve, keep the SFP balancing, and hide the mapping gap. The test compares the unmapped portion of each entity-period residual against the plug and warns above KES 1. Every unmapped account in a foreign entity currently carries a nil balance, so it is silent — but it will not stay silent if that changes.

---

## Open items / what's not built yet

- **`account_map.csv` confirmation by Finance** — 966 provisional mappings; open items in `Internal/Phase1_Exceptions_Register.xlsx`, full set for sign-off in `Internal/Phase1_Group_Mapping_Tables.xlsx`.
- **`rpt_group_pl` is not reliable yet** — `report_line_map.csv` must be regenerated from the current `account_map` before the management P&L can be trusted. The SCI/SFP marts are unaffected.
- **MENA's SCI** — 10 cells / KES 75,753 out. MENA is the one entity whose accounts carry no BC codes in the packs, so it is mapped on description alone via a synthetic `MENA-<md5>` code. The most likely place to find a genuine mapping error on our side.
- **Nigeria** — KES 419,987 across 6 cells, including a 322,570 `other_income` balance the pack's own `SCI Detailed` shows as nil. Not yet diagnosed.
- **`tb_category`** — two mappings need Finance sign-off: `accrued_income` → *Other receivables*, `net_profit` → *Retained earnings*.
- **A "client posting error" reason bucket in `compare_dbt_to_client.py`** — 93.8% of the residual variance is outside our models, but the recon files it under *classification* / *client shows nothing*, which reads as our error. Separating the two would make the tie rate honest.
- **The group tax journal's own translation difference** — the client debits an SCI line at average and credits an SFP line at closing, which generates a small residual neither they nor we recognise. Flagged for Finance rather than silently modelled.
- **Group P&L revenue-stream split** (Actuarial / Multicarrier / Grouplife / Medical / Special Projects …) — needs BC department dimensions or a Finance allocation; revenue is at entity grain until then.
- **Bad-debt provision** in `rpt_group_pl` — NULL today; Wave 3.2 (Bad Debt Provisioning) computation.
- **NO FISCAL-YEAR CONCEPT — read before loading 2025 comparatives or 2027 data.** The period cross-join in `stg_gl_entry` is `Posting_Date <= period_end` with no lower bound, so accumulation is **inception-to-date, not year-to-date**. Correct for the SFP, wrong for the SCI across a year boundary: at `2027-01` the SCI would sum thirteen months. `net_profit` is derived from those SCI rows and posted to SFP equity, so the prior year's profit would be counted twice and **the SFP would stop balancing**. Separately, `load_tb.py` and `extract_accruals.py` compute `movement = new YTD − prior cumulative`, and the client's YTD resets for P&L accounts at their year end, so the first month of a new year yields a large negative artefact. **Loading the 2025 TBs — the next prior-year step below — triggers both.** Fix needs EXC-18 (fiscal year start) confirmed first. See `Project_Handover.md` pt.16.
- **Prior year is NOT loaded, by decision.** `rpt_group_pl.amount_prior_year_kes` is `cast(null)` and the column is kept only so the mart's shape does not move under Power BI later; `rpt_subsidiary_sci` has no such column. The budget workbook's LYMTD column would populate it cheaply and was deliberately left out: once a full year of our own actuals exists, prior year should be **derived** from `fct_trial_balance` at period − 12 months so the comparative equals the actual we published a year earlier. Taking the client's comparative instead would disagree with our own published figures — the recon has already found defects in their statements — and would have to be unwound. **Do the fiscal-year fix above first**; a prior-year comparative is exactly the thing that breaks without it.
- Note for whenever a second year does arrive: `extract_budget.py` hardcodes 2026 periods against sheet names `Jan`…`June`, and a 2027 workbook will have **identical** sheet names, so re-running would silently drop the 2026 rows. It needs a year parameter and merge rather than replace semantics.
- **Eliminations** — April loaded; Finance to supply subsequent months via the template. Once BC carries `IC_Partner_Code`, the intercompany journals can be generated automatically.
- `dimension_set_entry_*` / `dimension_value_*` seeds (when real BC data lands).
- The other Phase 1 reports beyond the P&L / balance sheet (Debtor Analysis, Commission Sharing, Cash Position) — separate marts when AR sub-ledger / bank statement data are wired in.

---

## Reference documents (in the parent `Zamara/` folder)

- **`Project_Handover.md`** — full engagement context, history, design decisions. **The changelog is the authoritative record of why the model is shaped the way it is** — pt.10 (the accrual residual), pt.11 (C&P), pt.12 (the translation plug) and pt.13 (ZATL's rates) explain every remaining variance.
- **`Internal/Phase1_SCI_SFP_Recon_dbt_vs_Client.xlsx`** — **the reconciliation. Start here.** Summary, Side by Side, Differences Only, By Statement Line, Entity × Month. Every differing cell is bucketed and, where another line in the same entity-month is out by the mirror amount, annotated *"offset by &lt;line&gt;"* — an offsetting pair is one mapping decision, a difference with no partner means something is genuinely missing.
- **`Internal/Phase1_Client_SCI_SFP_Extract.xlsx`** — the client-side benchmark, read straight from the packs with nothing of ours in it.
- **`Internal/Phase1_Reseed_From_Consolidated_Accounts.xlsx`** — the seed rebuild audit.
- **`Email_ReconVariances_to_Team_DRAFT.md`** — the variance causes written up with cell references, for the team and Finance.
- **`Phase1_Roadmap_Notion.md`** — 12-week project plan.
- **`Internal/Phase1_ModuleC_TB_to_Report_Reconciliation_Apr2026.xlsx`** — the TB-to-report reconciliation + Reconciliation Control Matrix (Module C).
- **`Internal/Phase1_Group_Mapping_Tables.xlsx`** — all mappings in one workbook for Finance sign-off (Module B).
- **`Internal/Phase1_Exceptions_Register.xlsx`** — open mapping/classification/standardisation items needing a client decision.
- **`Internal/Phase1_KPI_Dictionary.xlsx`** — metric definitions, source basis, owners, sign-off points.
- **`Internal/Phase1_Elimination_Journal_Standard.docx`** + **`Phase1_Elimination_Journal_Template.xlsx`** — consolidation-eliminations standard & monthly submission template.
- **`Internal/Phase1_Revenue_Stream_Mapping_Plan.docx`** + **`Phase1_Revenue_Stream_Allocation_Template.xlsx`** — revenue product/BU split standard & template.
- **`Internal/Delivery Scope - Finance AI Foundation.pdf`** — the SOW (Schedule 1 has the canonical wave/phase/module names).
