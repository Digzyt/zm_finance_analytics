# Zamara Finance — dbt Project

> dbt project for the Phase 1 Finance Reporting Modernization. Built today against PostgreSQL with the Consolidated TB workbook's per-entity tabs landed as seeds. Designed to switch cleanly to Microsoft Fabric Warehouse the moment BC access lands — see the **"How this switches to Fabric"** section below.

---

## What this project does today

Twelve subsidiary trial balances (lifted from the *Finance Templates → Consolidated TB as at April 2026.xlsx* hidden tabs) flow through a layered dbt pipeline:

```
seeds/bronze/*.csv         (real workbook data, 807 rows total)
    │
    ▼
bronze_source.*            (per-company landing tables — mirrors BC's schema)
    │
    ▼
staging.stg_*              (unioned with Company_Name added; BC PascalCase preserved)
    │
    ▼
intermediate.int_*         (account mapping, sign normalisation, FX → KES, eliminations, ZAAC sub-consol)
    │
    ▼
core.fct_trial_balance     (entity × period × statement_line spine fact)
    │
    ├──▶  subsidiary.rpt_subsidiary_sci   (filter by Company_Name in Power BI)
    ├──▶  subsidiary.rpt_subsidiary_sfp
    ├──▶  consolidation.rpt_consolidated_sci
    └──▶  consolidation.rpt_consolidated_sfp
```

The four `rpt_*` tables are what Power BI connects to.

**The seeds contain real workbook values, not random data.** They were extracted directly from the hidden TB tabs (`ZAAC TB`, `ZARIB TB`, `Zamre TB`, etc.) of the Consolidated TB workbook on April-end 2026. Each subsidiary's row count matches what's in the workbook (ZAAC: 162 rows; ZARIB: 129; etc.). Uganda Associate is two rows representing the equity-pickup amounts. So the Power BI dashboards produced from this build will show the *actual* Zamara financials — not synthetic — which is the point: we can demonstrate the end-to-end flow to Finance with numbers they recognise.

---

## How this switches to Fabric when ready

The whole point of this project is that **when BC access lands, the model code does not change.** Only three things change at switch time:

1. **The profile target** — add `prod_fabric` to `profiles.yml` (template in `profiles.yml.example`); run `dbt build --target prod_fabric`.
2. **The source definitions** — edit `models/staging/_sources.yml` so the per-company source tables point at the Fabric Lakehouse raw extracts instead of the seeded Postgres tables.
3. **The seeds (mostly) retire** — bronze seeds get replaced by real BC extracts; reference seeds (`entity`, `statement_line`, `account_map`, `fx_rate`, `elimination_journal`) stay.

Everything else — staging models, intermediate models, marts, tests, macros — is unchanged.

This is achieved through five disciplines we've baked into the project from day one. **Read `DISCIPLINES.md` before adding any model**, but the headline summary:

| Discipline | Why |
|---|---|
| Sources declared from day one, never `ref()` on seeds | Source YAML is the single point of change at switch time |
| No PostgreSQL-specific SQL in models — use `dbt.date_trunc`, dbt-utils, or `adapter.dispatch` macros | T-SQL doesn't recognise `TO_CHAR`, `\|\|`, `JSONB`, etc. |
| Warehouse-specific quirks absorbed in staging only | Marts stay dialect-neutral |
| Target Fabric **Warehouse** (writable T-SQL), not Lakehouse (read-only) | Only the Warehouse supports dbt materialisations |
| Run parity tests against both adapters from day one of Fabric availability | Dialect drift is silent — catch early |

The macros in `macros/cross_db_helpers.sql` already include `adapter.dispatch` implementations for `date_part`, `year_month_string`, and `safe_string_md5` — Postgres versions today, Fabric versions ready for when access lands. Adding a new dialect-specific macro means writing a `postgres__foo` and `fabric__foo` next to a `default__foo`.

The `macros/staging_column_lists.sql` macros are the other portability hinge — every BC column is cast to an explicit type in the staging union, so it doesn't matter whether the underlying data came from a seed CSV (inferred types) or a Fabric Lakehouse Delta table (typed via the BC connector). The contract is the same.

---

## Project layout

```
datamodel/
├── README.md                       # this file
├── DISCIPLINES.md                  # the 5 rules for Postgres → Fabric portability — READ FIRST
├── dbt_project.yml
├── packages.yml
├── profiles.yml.example            # template; copy to ~/.dbt/profiles.yml
│
├── models/
│   ├── staging/
│   │   ├── _sources.yml            # 46 per-company bronze tables declared
│   │   ├── _models.yml             # column docs + tests
│   │   ├── stg_gl_entry.sql        # unions standard entities, adds Company_Name
│   │   ├── stg_gl_account.sql
│   │   ├── stg_dimension_set_entry.sql
│   │   ├── stg_dimension_value.sql
│   │   └── per_subsidiary/         # MENA, Nigeria, Uganda — genuinely different source shapes
│   │
│   ├── intermediate/
│   │   ├── int_account_mapping.sql
│   │   ├── int_sign_normalisation.sql
│   │   ├── int_fx_translation.sql
│   │   ├── int_zaac_subconsolidation.sql
│   │   └── int_eliminations.sql
│   │
│   └── marts/
│       ├── core/                   # dim_entity, dim_statement_line, dim_calendar, fct_trial_balance
│       ├── subsidiary/             # ONE rpt_subsidiary_sci, ONE rpt_subsidiary_sfp — slice in BI
│       └── consolidation/          # fct_consolidated_tb + rpt_consolidated_sci/sfp
│
├── seeds/
│   ├── bronze/                     # 45 CSVs — real workbook data + per-entity templates
│   └── reference/                  # entity, statement_line, account_map, fx_rate, elimination_journal
│
├── macros/
│   ├── generate_schema_name.sql    # override — use schema names literally (no dbt_dev_ prefix)
│   ├── cross_db_helpers.sql        # adapter dispatch: date_part, year_month_string, safe_string_md5
│   ├── staging_column_lists.sql    # column-list + cast macros used by the union staging models
│   └── test_overrides.sql          # override generic tests to quote column refs (Postgres case-sensitivity)
│
└── tests/                          # singular tests
    ├── assert_tb_balances_per_entity.sql
    └── assert_no_unmapped_accounts.sql
```

---

## Quick start

```powershell
# from the datamodel/ folder
python -m venv .venv
.\.venv\Scripts\Activate.ps1

python -m pip install --upgrade pip
python -m pip install "dbt-core>=1.7,<2.0" "dbt-postgres>=1.7,<2.0"

# copy the profile template and fill in your Postgres creds
cp profiles.yml.example $env:USERPROFILE\.dbt\profiles.yml

# set the password (one-time, persists)
[System.Environment]::SetEnvironmentVariable("PG_PASSWORD", "your-actual-password", "User")
# close & reopen PowerShell for the env var to be visible

# build
dbt deps
dbt seed --full-refresh
dbt build
```

If you hit `dbt-fusion 2.0.0-preview...` instead of dbt-core, the Fusion engine is taking precedence on PATH. The venv's `dbt` should override it — confirm with `Get-Command dbt | Select-Object Source`.

Then point Power BI at the four report tables in your Postgres database — see the BI engineer section below.

---

## What the Data Engineer owns

You're operating and extending the pipeline. The high-leverage things to focus on, roughly in priority order:

**1. `seeds/reference/account_map.csv` — populated (provisional, pending Finance confirmation).**

The seed now carries **775 auto-mapped accounts across the 11 standard entities** (98.7% coverage of the 793 unique accounts in the bronze TBs). The mappings were derived by pattern-matching each account's description against the 38 statement lines — see `Zamara/Internal/Phase1_Account_Map_For_Finance_Review.xlsx` for the full mapping with proposed line per row, ready for Finance to confirm or correct.

Status of the mapping today:
- 775 accounts mapped automatically with high confidence (descriptive patterns covering Zamara conventions like `Emol.Pack-*`, `Trav.*`, `Due to/from *`, `MV-*` etc., plus correct disambiguation between asset-side `MV-Cost`/`Furn-Cost` and expense-side `MV-Leasing Costs`/`Furn-Depreciation`).
- 10 accounts still unmapped — genuinely ambiguous (staff debtor names in ZARIB, the ESOP intercompany line, etc.). Listed in the review xlsx with empty proposed-line for Finance to classify.

The provisional mappings will need walkthrough with Finance in Module A. Once Finance returns the confirmed review xlsx, the data engineer converts it back to `account_map.csv` (drop the review-only columns, keep `company_name`, `local_account_no`, `statement_line_code`, `effective_from`, `effective_to`).

Schema: `(company_name, local_account_no, statement_line_code, effective_from, effective_to)`.

Run `dbt build --select int_account_mapping+` to rebuild downstream models when this seed changes. The `assert_no_unmapped_accounts` test now reports approximately 10 unmapped accounts (down from ~750 before this pass) — use it as the remaining worklist.

**2. Extend `seeds/reference/statement_line.csv` if needed.**

The 38 lines today are illustrative based on insurance-industry conventions. The Module A diagnostic should confirm the canonical SCI / SFP line list and labels. When Finance confirms, update this seed and re-run.

**3. When BC access lands — the Fabric switch.**

Follow the checklist at the bottom of `DISCIPLINES.md`. The mechanics:
- Add `prod_fabric` block to `profiles.yml` (template already in `profiles.yml.example`).
- Update `models/staging/_sources.yml`: change `schema: bronze_source` to wherever the BC ingestion landed the raw tables, or use a Jinja conditional on `target.type`.
- `dbt-postgres` keeps working for dev / parity testing; `dbt-fabric` becomes the prod target.
- The staging `column_list` macros (`macros/staging_column_lists.sql`) absorb any column-type changes from real BC data — they explicitly cast everything to canonical types.

**4. Populate `elimination_journal.csv` as IC pairs are identified.**

Today empty. The structure is `(journal_id, period, journal_description, company_name, statement_line_code, statement_type, elimination_amount_kes, posted)`. Look for `IC_Partner_Code` populated in real BC GL entries — those are your intercompany pairs.

**5. Documentation tasks.**

- `dbt docs generate && dbt docs serve --port 8080` — gives Finance an interactive view of the lineage. Worth showing them in Module A.
- The YAML descriptions in `_sources.yml` and `_models.yml` carry the BC field mapping ("BC field: G/L Account No.", etc.) — keep them updated as you learn more.

**Things to avoid:**

- Don't use Postgres-specific syntax in models (see `DISCIPLINES.md` for the table of what to replace). If you must, write an `adapter.dispatch` macro in `cross_db_helpers.sql` with a `postgres__foo` and `fabric__foo`.
- Don't add `column_types:` per-seed in `dbt_project.yml`. We tried — it causes type mismatches in the UNION when only some seeds have explicit types. The staging `column_list` macros do the casting instead.
- Don't enable `persist_docs: columns: true`. On Postgres it generates COMMENT statements that case-fold our `"Company_Name"` columns to lowercase and fails.

---

## What the Power BI Engineer owns

Once `dbt build` succeeds, four tables are ready to consume. Connect Power BI directly to the Postgres database (DirectQuery or Import — Import is faster for the volumes we're working with today).

### Connection

- **Get Data → PostgreSQL database**
- Host / port / database from your `profiles.yml`
- Schemas to import: `consolidation`, `subsidiary`, `core`, `ref`

### Tables / views to connect

| Schema | Table | Use |
|---|---|---|
| `consolidation` | `rpt_consolidated_sci` | Group Statement of Comprehensive Income |
| `consolidation` | `rpt_consolidated_sfp` | Group Statement of Financial Position |
| `subsidiary` | `rpt_subsidiary_sci` | Per-entity SCI — slice by `company_name` |
| `subsidiary` | `rpt_subsidiary_sfp` | Per-entity SFP — slice by `company_name` |
| `core` | `dim_entity` | Entity register for slicers / lookups |
| `core` | `dim_statement_line` | Statement-line hierarchy (4 levels) for row drilldown |
| `core` | `dim_calendar` | Date dimension |
| `core` | `fct_trial_balance` | Underlying spine fact — use for any custom views |

### Recommended semantic model

- **Relationships:**
  - `fct_trial_balance.company_name` → `dim_entity.entity_code`
  - `fct_trial_balance.statement_line_code` → `dim_statement_line.statement_line_code`
  - `fct_trial_balance.period` → `dim_calendar.period` (or build a period mapping if calendar uses YYYY-MM-DD)

- **For the group reports**, the consolidated tables carry the same `statement_line_code` + `dim_statement_line` lineage — use `dim_statement_line` for sorting/grouping/hierarchy on rows.

- **For per-entity views**, add `company_name` as a slicer/filter on the subsidiary report visuals. ONE model serves all entities — the BI slicer is what produces the per-subsidiary view.

### Recommended visuals

For the SCI/SFP demo to Finance, the simplest compelling layout is a matrix visual:

- Rows: `category_l1 → category_l2 → category_l3 → line_label` (the 4-level hierarchy from `dim_statement_line`)
- Values: `consolidated_kes` (for the group report) or `amount_kes` (for subsidiary)
- For the consolidated reports, also show the three component columns side-by-side: `subsidiary_sum_kes`, `elimination_kes`, `equity_pickup_kes` → this is what makes the consolidation auditable. Finance will appreciate seeing where Uganda's equity pickup lands separately from the subsidiary sum.

### Branding / theming

Match the existing Zamara Group dashboard requirements doc (in the parent `Zamara/` folder) for colour palette and logo placement once we get those from the client.

### Things to be aware of

- **The data is real and the mapping is now ~99% populated (provisional).** 775 accounts auto-mapped via pattern matching pending Finance confirmation. Expect the SCI/SFP totals to look meaningful in the first pass — but the green rows in the review xlsx need Finance walkthrough before we treat the numbers as truth.
- **`assert_tb_balances_per_entity` warns**, meaning some entities' debits and credits don't perfectly match. This is because the workbook source has off-system adjustments (`Accruals` columns) that we don't yet fully wire in. The TB-correctness conversation is a Finance discussion, not a Power BI one.
- **Reload mechanics.** When the data engineer updates a seed (e.g., adds mappings) and runs `dbt build`, the mart tables refresh in Postgres. Power BI then needs a manual or scheduled refresh to pick up the new data. We can set up a scheduled refresh once we're past the demo.

---

## Status of tests on the current build

| Test | Status | Meaning |
|---|---|---|
| All YAML generic tests (`not_null`, `unique`, `accepted_values`, `unique_combination_of_columns`) | ✅ PASS | Schema-level integrity OK |
| `assert_tb_balances_per_entity` | ⚠️ WARN (4 entities unbalanced) | Workbook source has off-system adjustments — Finance discussion |
| `assert_no_unmapped_accounts` | ⚠️ WARN (~10 rows) | The 10 accounts in the review xlsx that need Finance to classify. |

Both warnings are diagnostic by design and don't block downstream models.

---

## Open items / what's not built yet

- **`account_map.csv` confirmation by Finance.** Seed carries 775 auto-mapped accounts (provisional). Walkthrough with Finance via `Internal/Phase1_Account_Map_For_Finance_Review.xlsx` — they confirm green rows and fill in the 10 still-unmapped ones, then the confirmed file replaces the auto-generated seed.
- `elimination_journal.csv` entries (today: empty header; needed: IC pairs from BC `IC_Partner_Code`)
- `dimension_set_entry_*` and `dimension_value_*` seeds (today: empty headers; needed: when real BC data lands)
- Module G — Executive support workstream (not in the data pipeline; it's the steering / governance cadence)
- The other three Phase 1 reports beyond SCI/SFP (Debtor Analysis, Commission Sharing, Cash Position) — out of scope for this demo; will come as separate marts when AR sub-ledger / Beyontec-named system / bank statement data are wired in

---

## Reference documents (in the parent `Zamara/` folder)

- **`Project_Handover.md`** — full engagement context, history, design decisions
- **`Phase1_Roadmap_Notion.md`** — 12-week project plan
- **`Internal/Phase1_Initial_Review_Note.docx`** — what we found in the Finance Templates pack
- **`Internal/Phase1_Report_Data_Requirements.docx`** — data needs per report
- **`Internal/Phase1_KPI_Dictionary.xlsx`** — 59 KPIs with definitions
- **`Internal/Phase1_Mapping_Documents.xlsx`** — mapping templates
- **`Internal/Delivery Scope - Finance AI Foundation.pdf`** — the SOW (Schedule 1 has the canonical wave/phase/module names)
