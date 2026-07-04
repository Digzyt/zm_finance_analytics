# Zamara Finance — dbt Project

> dbt project for the Phase 1 Finance Reporting Modernization. Built today against PostgreSQL with the Zamara monthly Trial Balance pack landed as seeds. Designed to switch cleanly to Microsoft Fabric Warehouse the moment BC access lands — see the **"How this switches to Fabric"** section below.

---

## What this project does today

The 2026 monthly Trial Balance pack (Jan–May, *Finance Templates → 2026 TBs*) is landed as **monthly G/L movement seeds** and flows through a layered dbt pipeline. `period` is a first-class dimension: every reporting mart carries one row per period, so you get the full month-by-month history, not a single snapshot.

```
seeds/bronze/*.csv          monthly G/L MOVEMENTS per entity (each row = that month's delta)
    │
    ▼
bronze_source.*             per-company landing tables — mirrors BC's schema
    │
    ▼
staging.stg_report_periods  the period spine (distinct month-ends: 2026-01 … 2026-05)
staging.stg_*               unioned + Company_Name; CROSS JOINED to the spine so each
                            movement contributes to every period >= its own month
    │                       (cumulative sum to a period = the TB "as at" that month)
    ▼
intermediate.int_*          account mapping → sign normalisation → FX→KES (per period)
                            → eliminations, ZAAC sub-consol
    │
    ▼
core.fct_trial_balance      company × PERIOD × statement_line spine fact
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
```

**Every `rpt_*` table has a `period` column** valued `2026-01` … `2026-05`. Each period is the **cumulative year-to-date position as at that month-end**, translated at that month's FX rate. `select * from consolidation.rpt_consolidated_sci` returns all five months; filter `where period = '2026-03'` for one month.

**The seeds contain real workbook values, not random data.** They are the per-entity TB tabs from the monthly pack, differenced into monthly movements so the bronze layer behaves like BC's G/L Entry table (transactions that accumulate to a balance). Cumulative movements reconcile to each month's source closing balance to within rounding.

---

## Period model — read this first

- Bronze `gl_entry_*` seeds hold **movements**, not balances. `gl_entry_zaac` row for `2026-03-31` is *March's change*, not the March balance.
- `stg_report_periods` lists the distinct month-ends. Staging cross-joins it: a movement dated `2026-02-28` appears under periods `2026-02`, `2026-03`, `2026-04`, `2026-05` (every period on/after its month).
- Downstream `group by (company, period, statement_line)` therefore yields the **cumulative balance as at each period** = the trial balance "as at" that month. This is standard YTD reporting.
- `reporting_period` in `dbt_project.yml` is **no longer used to filter** — period selection is a `WHERE period = …` in your query / BI slicer. (The var is retained only as harmless metadata.)
- Adding June: drop the June movement rows into the `gl_entry_*` seeds (dated `2026-06-30`) and add June's rates to `fx_rate.csv`. The spine and every mart pick the new period up automatically — no model changes.

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
│   │   ├── stg_gl_account.sql
│   │   ├── stg_dimension_set_entry.sql
│   │   ├── stg_dimension_value.sql
│   │   └── per_subsidiary/         # MENA, Nigeria (descriptive), Uganda (equity)
│   │
│   ├── intermediate/
│   │   ├── int_account_mapping.sql
│   │   ├── int_sign_normalisation.sql
│   │   ├── int_fx_translation.sql
│   │   ├── int_zaac_subconsolidation.sql
│   │   ├── int_eliminations.sql
│   │   └── int_report_pl.sql       # management P&L layer (feeds rpt_group_pl)
│   │
│   └── marts/
│       ├── core/                   # dim_entity, dim_statement_line, dim_calendar, fct_trial_balance
│       ├── subsidiary/             # rpt_subsidiary_sci / _sfp  (slice by company_name)
│       └── consolidation/          # fct_consolidated_tb, rpt_consolidated_sci/_sfp, rpt_group_pl
│
├── seeds/
│   ├── bronze/                     # per-entity monthly MOVEMENT seeds (gl_entry_*, gl_account_*, …)
│   └── reference/                  # entity, statement_line, account_map, fx_rate, elimination_journal,
│                                   #   report_line, report_line_map, budget
│
├── macros/
│   ├── generate_schema_name.sql
│   ├── cross_db_helpers.sql        # adapter dispatch + period_end_date
│   ├── staging_column_lists.sql
│   └── test_overrides.sql
│
└── tests/
    ├── assert_tb_balances_per_entity.sql        # per (entity, period)
    ├── assert_no_unmapped_accounts.sql
    └── assert_elimination_journals_balance.sql  # each journal nets Dr = Cr
```

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

Once `dbt build` succeeds, connect Power BI to the Postgres database (Import is fine at these volumes). Import schemas `consolidation`, `subsidiary`, `core`, `ref`.

### The golden rule: filter on `period`

Every reporting table has a `period` column (`'2026-01'` … `'2026-05'`). Each row is the **cumulative YTD position as at that month-end**. Put a **`period` slicer** on every page. `dim_calendar` (in `core`) is the period dimension to anchor it.

### Which table for which report

| Report | Table(s) | Notes |
|---|---|---|
| **Zamara Group Financial Report — "Group" P&L** (the monthly CEO pack) | `consolidation.rpt_group_pl` + `ref.report_line` | The management P&L. See dedicated section below. |
| Group Statement of Comprehensive Income (IFRS) | `consolidation.rpt_consolidated_sci` | |
| Group Statement of Financial Position (IFRS) | `consolidation.rpt_consolidated_sfp` | |
| Subsidiary P&L (per entity) | `subsidiary.rpt_subsidiary_sci` | Slice by `company_name` + `period` |
| Subsidiary Balance Sheet (per entity) | `subsidiary.rpt_subsidiary_sfp` | Slice by `company_name` + `period` |
| Entity register / slicers | `core.dim_entity` | |
| Statement-line hierarchy (rows) | `core.dim_statement_line` | 4-level: `category_l1 → l2 → l3 → line_label` |
| Date / period dimension | `core.dim_calendar` | |
| Custom views / drill-through | `core.fct_trial_balance` | company × period × statement_line spine |

### Building the "Zamara Group Financial Report" (Group P&L)

This is the centrepiece of the monthly pack. Use **`consolidation.rpt_group_pl`**, joined to **`ref.report_line`** for ordering and section labels. One row per `report_line_code` per `period`.

Columns:

| Column | Meaning |
|---|---|
| `period` | `'2026-01'` … `'2026-05'` — slice on this |
| `report_line_code` / `line_label` | the management line (e.g. `zaac_revenue`, `personnel_costs`) |
| `section` | `INCOME` or `EXPENSE` — drives subtotals |
| `line_order` | display order (use to sort rows) |
| `amount_actual_gross_kes` | Actual before bad-debt provision |
| `bad_debt_provision_kes` | NULL today — separate Wave 3.2 computation |
| `amount_actual_net_kes` | Actual after provision (= gross until Wave 3.2 lands) |
| `amount_budget_kes` | Budget (2026-04 loaded today; other months as the budget seed is extended) |
| `variance_kes` / `variance_pct` | Actual(Net) vs Budget |
| `amount_prior_year_kes` | NULL today — needs 2025 monthly TBs |

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

## What the Data Engineer owns

**1. `seeds/reference/account_map.csv` — populated (provisional, pending Finance confirmation).**

Carries **838 mappings** keyed on `(company_name, local_account_no)`. The 2026 pack re-codes several entities to BC account numbers (ZARIB, Zamre, ZHL, Malawi, Rwanda, Nigeria); mappings were carried across by description / canonical-BC code / the in-workbook BC-Codes sheets. Remaining unmapped and open classification items are tracked in `Zamara/Internal/Phase1_Exceptions_Register.xlsx`, and the full mapping is presented for Finance sign-off in `Zamara/Internal/Phase1_Group_Mapping_Tables.xlsx`. When Finance confirms, fold corrections back into this seed (keep `company_name, local_account_no, statement_line_code, effective_from, effective_to`).

Schema: `(company_name, local_account_no, statement_line_code, effective_from, effective_to)`. Rebuild downstream with `dbt build --select int_account_mapping+`.

**2. Management-reporting seeds (for the Group P&L).**

- `report_line.csv` — the management P&L taxonomy: `report_line_code, section, presentation_sign, line_order, line_label`.
- `report_line_map.csv` — `(company_name, local_account_no, report_line_code)`, 363 rows (regenerated from the current `account_map`, incl. Nigeria on BC codes). Revenue at entity grain; expenses classified to nature by description; P&L restricted to `I`-codes. Add the ZARIB/ZAAC revenue-stream split here once Finance provides the department allocation (see `Phase1_Revenue_Stream_Mapping_Plan.docx`).
- `budget.csv` — `(report_line_code, period, amount_budget_kes)`. 2026-04 loaded from the workbook Group sheet; extend with monthly budgets from the `2026_Income_Budget` / `2026_Expense_Budget` tabs.

**3. `seeds/reference/fx_rate.csv`** — `(currency, period, rate_type, rate_to_kes, rate_source)`, monthly closing/average per currency, 2026-01…05. Implied from each pack's KES column (Rates-tab fallback). Add new months here.

**4. `elimination_journal.csv` — populated (double-entry standard).**

Holds the manual consolidation journals (these are NOT in BC): investment-in-subsidiary cancellations, intercompany balances, goodwill, translation reserve and NCI. Schema `(journal_id, period, journal_description, elimination_type, entity_scope, statement_line_code, statement_type, debit_kes, credit_kes, posted, notes)`. `int_eliminations` converts Dr/Cr to presentation sign via `statement_line.sign_multiplier`, feeding `fct_consolidated_tb`:

`consolidated = subsidiary_sum + eliminations + equity_pickup`

April is loaded (16 journals, 52 lines) from the consolidation workbook and cancels ~1.32bn of investment-in-subsidiary. Four SFP lines were added for these entries — `goodwill, translation_reserve, non_controlling_interests, deferred_tax` (statement_line is now 42 lines). Finance maintains this monthly via `Internal/Phase1_Elimination_Journal_Template.xlsx` (standard: `Phase1_Elimination_Journal_Standard.docx`). `assert_elimination_journals_balance` verifies each journal nets to zero.

**5. Adding a new month.** Difference the new month's TB into movements, append to `gl_entry_*` (dated month-end), add the month's `fx_rate` rows, `dbt seed --full-refresh && dbt build`. Every mart gains the new period with no model change.

**Things to avoid:**
- No Postgres-specific syntax in models (see `DISCIPLINES.md`). Use an `adapter.dispatch` macro with `postgres__foo` / `fabric__foo`.
- No per-seed `column_types:` — it breaks the cross-entity UNION; the `column_list` macros cast instead.
- Don't enable `persist_docs: columns: true` (Postgres case-folds quoted `"Company_Name"`).

---

## Status of tests on the current build

| Test | Status | Meaning |
|---|---|---|
| YAML generic tests (`not_null`, `unique`, `accepted_values`, `unique_combination_of_columns`) | PASS | Schema-level integrity OK |
| `assert_tb_balances_per_entity` | WARN | Per (entity, period): workbook off-system accrual adjustments mean some entities don't net to zero — a Finance discussion |
| `assert_no_unmapped_accounts` | WARN | ~15 material accounts awaiting Finance classification (see Exceptions Register) |
| `assert_elimination_journals_balance` | PASS | All 16 April journals balance Dr = Cr |

Both warnings are diagnostic by design and don't block downstream models.

---

## Open items / what's not built yet

- **`account_map.csv` confirmation by Finance** — 838 provisional mappings; open items in `Internal/Phase1_Exceptions_Register.xlsx`, full set for sign-off in `Internal/Phase1_Group_Mapping_Tables.xlsx`.
- **Subsidiary-sum SFP mapping gap** — consolidated SFP is ~2.2bn below the workbook pre-elimination total: balance-sheet accounts still unmapped (deposits, placements, premium-receivable split, accrued income). Biggest remaining reconciliation item (see the Module C pack).
- **Tax expense** — tax accounts largely unmapped (consolidated tax ~12m vs ~235m); map before use.
- **Group P&L revenue-stream split** (Actuarial / Multicarrier / Grouplife / Medical / Special Projects …) — needs BC department dimensions or a Finance allocation; revenue is at entity grain until then.
- **Bad-debt provision** in `rpt_group_pl` — NULL today; Wave 3.2 (Bad Debt Provisioning) computation.
- **Prior-Year columns** — need the 2025 monthly TBs loaded as movement seeds.
- **Eliminations** — April loaded; Finance to supply subsequent months via the template. Once BC carries `IC_Partner_Code`, the intercompany journals can be generated automatically.
- `dimension_set_entry_*` / `dimension_value_*` seeds (when real BC data lands).
- The other Phase 1 reports beyond the P&L / balance sheet (Debtor Analysis, Commission Sharing, Cash Position) — separate marts when AR sub-ledger / bank statement data are wired in.

---

## Reference documents (in the parent `Zamara/` folder)

- **`Project_Handover.md`** — full engagement context, history, design decisions (see the changelog for the multi-month + Group P&L + multi-period work).
- **`Phase1_Roadmap_Notion.md`** — 12-week project plan.
- **`Internal/Phase1_ModuleC_TB_to_Report_Reconciliation_Apr2026.xlsx`** — the TB-to-report reconciliation + Reconciliation Control Matrix (Module C).
- **`Internal/Phase1_Group_Mapping_Tables.xlsx`** — all mappings in one workbook for Finance sign-off (Module B).
- **`Internal/Phase1_Exceptions_Register.xlsx`** — open mapping/classification/standardisation items needing a client decision.
- **`Internal/Phase1_KPI_Dictionary.xlsx`** — metric definitions, source basis, owners, sign-off points.
- **`Internal/Phase1_Elimination_Journal_Standard.docx`** + **`Phase1_Elimination_Journal_Template.xlsx`** — consolidation-eliminations standard & monthly submission template.
- **`Internal/Phase1_Revenue_Stream_Mapping_Plan.docx`** + **`Phase1_Revenue_Stream_Allocation_Template.xlsx`** — revenue product/BU split standard & template.
- **`Internal/Delivery Scope - Finance AI Foundation.pdf`** — the SOW (Schedule 1 has the canonical wave/phase/module names).
