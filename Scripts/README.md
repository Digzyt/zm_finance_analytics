# Scripts — adding a monthly TB to the seeds

`load_tb.py` loads a monthly Trial Balance workbook into the dbt **bronze seeds**
(`seeds/bronze/gl_entry_*.csv`), so a new month can be added without hand-editing CSVs.

This folder sits alongside `models/`, `seeds/`, `macros/` etc. It is **not** part of the
dbt project (dbt ignores it), so it is safe to keep here.

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
