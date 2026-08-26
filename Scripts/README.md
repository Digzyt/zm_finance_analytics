# Scripts — loading trial balances, and reconciling the output

Six scripts, in the order a month runs through them:

| Script | Use it when |
|---|---|
| `load_tb.py` | Adding **one new month** on top of seeds that already hold every earlier month. The normal monthly routine. |
| `reseed_from_packs.py` | Rebuilding **all months from scratch** out of the `Consolidated Accounts` packs. Use after a source change or a restatement. |
| `extract_accruals.py` | Deriving the client's accrual overlay from the entity TB tabs into its own seed, so Power BI can show Amount / Accruals / Amount After Accruals separately. **Run after the reseed** — it resolves account codes through `reseed_audit.csv`. |
| `extract_budget.py` | Rebuilding `budget.csv` from the *Budget and LYTD Comparison* workbook. Run whenever Finance revises the budget. |
| `extract_debtor_analysis.py` | Rebuilding `debtor_analysis.csv` from the standardized debtor intake (`Internal/Debtors_Master_Data_Template.xlsx`). Run each month when the debtor pack is issued. |
| `extract_client_statements.py` | Pulling the client's own `SCI Detailed` / `SFP Detailed`, per entity per month, into a spreadsheet. The benchmark. |
| `compare_dbt_to_client.py` | Reconciling the dbt subsidiary SCI/SFP marts against that extract, line by line, and writing the recon workbook. |

The monthly loop, end to end:

```bash
python Scripts/load_tb.py ".../July 2026 Consolidated Accounts.xlsx" --write
python Scripts/extract_accruals.py --write      # the overlay -> tb_accrual seed
dbt seed --full-refresh && dbt build
python Scripts/extract_client_statements.py     # the client side
python Scripts/compare_dbt_to_client.py         # the recon
```

`extract_budget.py` is not part of that loop — run it only when the budget workbook changes.

`Scripts/mapping/` holds the tooling that derives `account_map` from the client's formula
chain — reach for it when the recon shows classification differences.

**`load_tb.py` cannot be used to rebuild every month.** It computes
`movement = new YTD − prior cumulative in the seed`, treating every row outside the target
period as "prior". Run it for January while February–June rows are still in the seed and
January's movement comes out as `Jan YTD − (Feb..Jun movements)`. The final period still ties
but every intermediate period is wrong. A full rebuild has to start from empty seeds and load
the months in order — that is what `reseed_from_packs.py` does.

This folder sits alongside `models/`, `seeds/`, `macros/` etc. It is **not** part of the
dbt project (dbt ignores it), so it is safe to keep here.

---

## `extract_accruals.py` — the Accruals column

```bash
python Scripts/extract_accruals.py            # dry run
python Scripts/extract_accruals.py --write    # writes seeds/reference/tb_accrual.csv
```

The client's individual TB tabs carry five columns — `A/C No`, `Description`, `Amount`,
`Accruals`, `Amount After Accruals` — and Finance wants all five in Power BI. The bronze
`gl_entry_*` seeds mirror BC's own table, so the accrual has no place in them. It travels as
its own reference seed and is joined back in `stg_tb_accrual` -> `rpt_subsidiary_tb`, leaving
every BC-shaped table and every existing model untouched.

**The bronze figure is already post-accrual**, so the decomposition is
`amount = amount_after_accruals − accruals`. Deriving the pre-accrual figure rather than
storing it means this seed cannot move a reported number, only split one.

Like `gl_entry` it holds monthly **movements**, so the period cross-join accumulates it the
same way. Two things it has to get right:

- **Releases.** An account that carried an accrual last month and carries none this month has
  been released — the client simply stops listing it. Without an explicit reversal its YTD
  would stay frozen. This happens whenever they re-code the counter-account (ZAAC's
  `Accrued Income` moves `B55130` -> `B55135` in March; ZARIB's counter-entry moves off
  `Other Staff Costs` in June).
- **Codes.** The accrual rows carry the pack's own codes, which are not the codes the seeds
  use. The script resolves them through `reseed_audit.csv`, so **run `reseed_from_packs.py`
  first**. Without this the ZARIB and C&P accruals silently fail to join.

Self-test: the client's accruals are reclassifications, not new value, so the YTD nets to zero
within an entity in every month — **14 of 14 entity-months do**.

Only ZAAC, ZARIB and C&P have the column. Everything else reads zero, so the five columns
render uniformly for all eleven entities.

### The ZARIB header trap this uncovered

ZARIB labels its accrual column **`Deffered Revenue & Accruals`** and its netted column
**`Amount After Deferred Rev`** in March and April (their spelling). Neither name was in the
header vocabulary, so the reseed read those two months from the plain `Amount` column —
pre-accrual — while every other entity-month was post-accrual. That was the KES 15,000,000
(April) and 11,250,000 (March) ZARIB gap, previously diagnosed as a consolidation-level
accrual visible only in `KES consolidated TB`. **It was on the ZARIB tab all along.** Both
names are now in `AMT_POST` / `ACCRUAL_HDRS` in `reseed_from_packs.py` and `mapping/packlib.py`.

---

## `extract_budget.py` — the Group P&L budget

```bash
python Scripts/extract_budget.py              # dry run: prints the seed + self-tests
python Scripts/extract_budget.py --write      # writes seeds/reference/budget.csv
```

Reads `Finance Templates/June Budget and LYTD Comparison - Revised (1).xlsx` — one sheet per
month, three columns per entity (`MTD Actual | MTD Budget | LYMTD Actual`) with the entity
name merged across them on row 1 — and writes 25 report lines × 6 periods.

**The budget columns are MTD, not YTD.** Every mart here is cumulative, so each period is the
sum of the month budgets up to it. Take the sheet figures at face value and June's budget comes
out roughly a sixth of what it should be.

**Jan and Feb use different line wording:** `Travel` (later `Travelling`), `Management Fees`
(`Management Expense`), `Pension Administration` (`Pension Admin Fee`). Aliased in
`LABEL_ALIASES`. Missing the first alone costs KES 3.9m on travelling — the same class of trap
as ZARIB's `Deffered Revenue & Accruals` header. **Entity column order also changes** (Jan has
NIGERIA before RWANDA), so blocks are read from row 1 rather than assumed.

Mapping mirrors `report_line_map.csv`: income is each entity's own `Total Income`; expenses are
by nature summed across ZAAC + ZARIB + C&P + ZHL; ZAMRE, MENA and Zarinet (MALAWI + RWANDA +
NIGERIA + DRC + ZATL) take a single `Total Expenses`. Taking `Total Income` rather than summing
the income sub-lines means a new income line in a later pack cannot be silently dropped.

It **refuses to write if any self-test fails**: Kenya's by-nature lines must account for the
whole of its `Total Expenses` (they tie to the cent in all six periods), every non-subtotal
label must be consumed by the mapping, and each period's YTD must equal the prior period plus
that month. `Management Expense` deliberately has no `report_line_code` — only the African
entities budget for it and they roll up as a total — and the test fails if a Kenyan entity
starts using it.

**Prior year:** `--prior-year <path>` writes the LYMTD actuals on the same parser. That is what
`rpt_group_pl.amount_prior_year_kes` needs and it would close that open item without loading
the 2025 TBs — but it is **not wired** into any model yet.

---

## `extract_client_statements.py` — the client's own SCI and SFP

```bash
python Scripts/extract_client_statements.py                  # all months
python Scripts/extract_client_statements.py --period 2026-07  # one month
```

Reads every `Consolidated Accounts` pack and flattens the `SCI Detailed` / `SFP Detailed`
tabs — one row per line, one column per entity — into
`Internal/Phase1_Client_SCI_SFP_Extract.xlsx`, plus two CSVs in `Scripts/out/`:
`client_statements_long.csv` (every cell) and `client_by_line.csv` (aggregated to
`statement_line_code`, which is the comparison grain).

**Nothing of ours is in the output.** It is the client's statement as they state it, which is
what makes it usable as the benchmark. Figures are extracted debit-positive, exactly as the
packs show them; `amount_presentation` applies `statement_line.sign_multiplier` for
comparison against the marts.

New months need no code change — the period is read from the file name.

Three things the reader has to get right, each of which corrupted an earlier attempt:

1. **The entity columns move.** `SCI Detailed` starts at column C, `SFP Detailed` at column D,
   and the order is not stable between packs. Rows 1–8 are scanned and the row with the most
   recognised entity names wins. First-seen-wins instead picks up the sheet title in A1
   ("Zamara Holdings Limited") and reads it as ZHL's data column.
2. **The SCI expense section is group headers over account-level detail rows.** Column A
   carries the client's marker (`P&L` / `Balance Sheet`) and is blank on headers and
   subtotals, so a detail row like *Emol.Pack-Salaries* inherits its group, *Personnel Costs*.
3. **`Net Profit` on the SFP is `=SUM(entire P&L range)`.** It carries the same marker as any
   other line but must never be treated as a line that owns accounts — it is compared against
   the `net_profit` our model derives in `fct_trial_balance`.

Two self-tests ship with it, and both are in the workbook:

- **Totals Check** — the client's own `Total Income` / `Total Expenses` / `Total Assets` /
  `Total Equity and Liabilities` rows against the sum of the detail rows we read.
  All 220 tie. Two layout facts are built in: their **`Total Expenses` excludes the Taxation
  line** (which sits inside the expense list but outside the total; `Management Expense` is
  inside it), and their **`Total Equity and Liabilities` includes the derived `Net Profit`**.
- **Row Cross-Foot** — the eleven entity columns against the client's own TOTAL column. Three
  exceptions, all theirs: February's depreciation subtotal formula is `=SUM(N91:N97)` and so
  **omits row 98, ZAAC `Goodwill amortisation` KES 130,054**, while their per-entity subtotal
  cells include it; the other two are group `Profit Before/After Tax` rows whose TOTAL is a
  different aggregate. We read the entity columns, so none of this moves our figures — raise
  it as a data-quality item.

**January is group-only.** That pack has no per-entity Detailed tabs — its `SCI` / `SFP` hold
the consolidated group statement in a single column. It is reported as group-only on the
Coverage tab and contributes no rows, so January cannot be reconciled per entity.

---

## `compare_dbt_to_client.py` — the recon

```bash
python Scripts/compare_dbt_to_client.py                        # marts from Postgres
python Scripts/compare_dbt_to_client.py --refresh              # re-extract the client side first
python Scripts/compare_dbt_to_client.py --marts csv --marts-dir ../Outputs
```

Compares `subsidiary.rpt_subsidiary_sci` / `_sfp` to `client_by_line.csv` per entity, per
line, per month, and writes `Internal/Phase1_SCI_SFP_Recon_dbt_vs_Client.xlsx` (Summary,
Side by Side, Differences Only, By Statement Line, Entity × Month) plus
`Scripts/out/recon_side_by_side.csv` and `recon_summary.csv`.

The marts are read from **Postgres by default**, using `~/.dbt/profiles.yml` and
`$PG_PASSWORD` — the repo's `profiles.yml` is only a template, so the real one is tried first.
`--marts csv` reads `rpt_subsidiary_*.csv` exports instead, in UTF-8, UTF-16 or with the NUL
bytes the export leaves behind, which is the route when the database is not reachable.

Both sides are compared on the **statement-presentation basis** (income and equity positive),
since that is what the marts hold. The client's own debit-positive figure travels alongside in
`client_as_stated_kes` so any row can be tied back to their pack by eye.

Every differing cell is bucketed, and the buckets are the point:

| Bucket | Means |
|---|---|
| `rounding / FX` | under 0.5% and under KES 2m — translation noise |
| `we show nothing` | they report a figure on this line and we report none — usually an unmapped or missing account |
| `client shows nothing` | we report a figure they do not |
| `classification` | both report, on different lines — a mapping decision |

Where another line in the same entity-month is out by the mirror amount, the note reads
**"offset by &lt;line&gt;"**. That distinction is what makes the list actionable: an offsetting
pair needs one mapping decision, whereas a difference with no partner means something is
genuinely absent from the seeds.

Current state: **2,383 of 2,484 line cells tie exactly (95.9%)**, total absolute difference
**KES 9.19m**. **ZARIB now ties on every line in every month** (2 shillings of rounding) after
the accrual-header fix above. The largest remaining is C&P at 7.1m.

---

## `reseed_from_packs.py` — full rebuild

```bash
python Scripts/reseed_from_packs.py                       # dry run + reports, nothing written
python Scripts/reseed_from_packs.py --write               # rebuild the seeds
dbt seed --full-refresh && dbt build
```

It reads all six `Consolidated Accounts` packs, loads the months in order, and writes
`gl_entry_*`, new `gl_account_*` rows and `fx_rate.csv`. Two report files land next to the
script: `reseed_audit.csv` (how every account's code was decided) and `reseed_recon.csv`
(seed cumulative vs each pack's YTD, per entity per period — should be zero everywhere).

**Two rule files carry every judgement call**, so nothing is decided implicitly:

- **`code_overrides.csv`** — codes the client reuses for two different accounts, and pinned
  codes for rows with a blank A/C No. ZARIB reuses 7–10 codes every month (`4000/000` is both
  *VALUE ADDS* and *Leasehold-Depreciation*); ZATL, C&P, ZAAC, DRC and ZHL each reuse one.
  Without a rule those balances silently merge.
- **`code_bridge_nigeria.csv`** — Nigeria's description → BC code bridge. The final packs give
  Nigeria no code column at all, and the `Nigeria BC Codes` companion sheet in the Raw TBs
  packs is **not** usable (it assigns `B75110` to 16 different accounts and `I25205` to 23).
  The bridge was instead built by matching YTD amounts against the Raw TBs Nigeria tab and
  name-checking every hit; 61 of Nigeria's 88 accounts bridge, the rest get synthetic codes.

Codes are resolved in this order, and the basis is recorded per account:

1. `code_overrides.csv`
2. `code_bridge_nigeria.csv` (Nigeria only)
3. source code, where it carries only one description and matches the prior seed
4. **re-alias by description** — the final packs code ZARIB / ZAMRE / ZHL / Malawi / Rwanda with
   legacy local numbers (`7380/000`, `1020/000`, `6100`) while `account_map` is keyed on BC
   codes, so the prior seed's code for the same description is used instead. Skipping this step
   orphans 437 accounts and 12.1bn KES rather than 234 and 3.0bn.
5. blank code → prior seed by description, else a readable synthetic `<ENT>-<SLUG>`

A **collision guard** then refuses to let two different accounts share an assigned code, and
suffixes the weaker-evidenced one. Same description arriving under two source codes is treated
as one account the client re-coded mid-year, and stays merged.

`--codebook-dir` points the prior-seed snapshot at a backup, for when the seeds have already
been overwritten. The script never touches `account_map.csv` or `statement_line.csv`.

**After any rebuild, `account_map` needs re-derivation** — see
`Internal/Phase1_Reseed_From_Consolidated_Accounts.xlsx` for the current gap list.

---

## `load_tb.py` — one new month

---

## What it does

1. **Reads the period from the file name** — e.g. `June 2026 Consolidated Accounts.xlsx`,
   `Consolidated TB as at June 2026.xlsx`, or `May 2026 TBs.xlsx` all resolve to the
   month-end (`2026-06-30`, `2026-05-31`).
2. **Finds each entity's TB tab** (`ZAAC TB`, `ZARIB TB`, `Zamre TB`, `ZHL`, `C & P`,
   `Rwanda`, `Nigeria`, `Malawi TB`, `MENA TB`, `DRC TB`, `ZATL`) and **auto-detects the
   header row and columns**. It handles all three pack layouts:
   - *Consolidated Accounts* (final) and *Consolidated TB* workbooks, and
   - *Raw TBs* workbooks,
   whether a tab uses **BC codes, legacy local codes, a post-accrual column, or is
   description-only** (MENA, and Nigeria in the descriptive layout).
3. **Computes the month's movement** for every account: `movement = new YTD − prior
   cumulative already in the seed`. Bronze seeds store monthly movements (that is what the
   dbt period model expects); the cumulative sum to a period is that month's TB "as at".
4. **Writes the movement rows** dated to the period month-end. Re-running for a period that
   is already loaded first **removes that period's rows**, so it is safe to re-run.
5. **Best-effort FX**: appends the period's rates from the `Rates` tab to
   `seeds/reference/fx_rate.csv` (**verify these** against CBK / Oanda).

## Usage

From the `datamodel/` folder:

```bash
# 1. Dry run — prints what it WOULD load (accounts + movements per entity, FX). No changes.
python Scripts/load_tb.py "../Finance Templates/2026 TBs/Consolidated Accounts/July 2026 Consolidated Accounts.xlsx"

# 2. Apply — writes the movements into the seeds
python Scripts/load_tb.py "../Finance Templates/2026 TBs/Consolidated Accounts/July 2026 Consolidated Accounts.xlsx" --write

# 3. Rebuild the model
dbt seed --full-refresh && dbt build
```

(Only `openpyxl` is required — already in the project venv.)

## Which file to point it at

Use the client's **final** pack — the `Consolidated Accounts` folder — as the go-forward
monthly source. The `Raw TBs` layout is also supported (e.g. for back-loading earlier
months). Point the script at **one workbook** per run.

## Important notes / limitations — read before relying on the numbers

- **It loads the raw per-entity TB tabs.** A few consolidation-level adjustments (certain
  accruals / reclassifications) exist **only** in the workbook's `KES consolidated TB` /
  `TB Local Currency` tabs, not in the per-entity source tabs — so after loading, expect
  **small residuals on a handful of adjusted accounts** vs the client's SCI/SFP Detailed.
  (`TB Local Currency` covers only 9 of the 11 entities — no ZHL/ZATL — which is why the
  per-entity tabs are used uniformly instead.)
- **Always reconcile after loading.** Run the checklist in
  `Internal/Phase1_Data_Checks_and_Finance_ICT_Issues.md`: TB foots per entity, blank codes,
  new/unmapped accounts, code-vs-description consistency, and tie dbt to the client's SCI &
  SFP Detailed.
- **Post-accrual columns are preferred** when a tab has both `Amount` and
  `Amount After Accruals` / `Net Amount`.
- **Dr/Cr layouts are handled**: if a tab splits into separate `Dr` and `Cr` columns
  (e.g. some months' `Zamre TB`), the amount is netted `Dr − Cr` (debit-positive).
- **Descriptive tabs** (MENA; Nigeria when it arrives without codes) are keyed by
  **description**: new rows are bridged to the existing seed account by description, and
  anything unmatched gets a stable synthetic code (`X-<hash>` / handled as `MENA` today) —
  **verify these new accounts and their mapping** in `account_map.csv`.
- **Blank account codes in the source** (some rows genuinely have no A/C No, e.g. Malawi
  "First Capital Current Account", Nigeria "Stonebridge") get a synthetic key — confirm and,
  if the account recurs, give it a stable code in `account_map.csv`.
- **New accounts are not auto-mapped.** After a load, any account with a balance but no
  `account_map.csv` row is dropped from the reports (the `assert_no_unmapped_accounts` test
  flags them). Map new accounts by following the client's formula chain
  (`SCI/SFP Detailed → KES consolidated TB → TB Local Currency → source tab`).
- **The script only touches `gl_entry_*` seeds and `fx_rate.csv`.** It does not change
  `account_map.csv`, `statement_line.csv`, or any model — mapping stays under review control.

## Adding an entity or fixing a tab that won't parse

- Entity tabs are configured in `ENTITIES` at the top of `load_tb.py` (tab name → seed name,
  currency, descriptive flag).
- Column detection is header-driven (`CODE_HDRS`, `DESC_HDRS`, `AMT_POST`, `AMT_PLAIN`,
  `KES_HDRS`). If a new pack uses a header word we haven't seen, add it to the relevant set.
- Section-header/total rows are skipped via `SKIP_DESC`.

---

## `extract_debtor_analysis.py` — the aged debtor analysis

```bash
python Scripts/extract_debtor_analysis.py            # dry run: prints row counts, entity totals, DQ notes
python Scripts/extract_debtor_analysis.py --write    # writes seeds/reference/debtor_analysis.csv
dbt seed --full-refresh --select debtor_analysis && dbt build --select stg_debtor_analysis+
```

Reads the standardized intake `Internal/Debtors_Master_Data_Template.xlsx` (sheet
`Debtors_Data_Entry`), one row per aged debtor line per reporting date, and writes the
`debtor_analysis` reference seed. Debtors are a designed manual input (BC is still in
progress), so this is part of the monthly pack, not a system feed.

- **Entity names are mapped to the canonical `entity.csv` codes** (Tanzania -> ZATL, Malawi
  -> MALAWI, …) so the marts join `dim_entity` / `fx_rate` cleanly.
- `period` is derived from the reporting date (`01/07/2026` -> `2026-07`) and stored ISO.
- Amounts stay in each entity's **functional currency**; nothing is translated here.
- Non-numeric cells in a numeric column are read as NULL and reported in the dry run's
  data-quality notes (the template has leaked labels like 'IPMI' and working notes like
  'whtax' into the `Collections` column on a few rows).
