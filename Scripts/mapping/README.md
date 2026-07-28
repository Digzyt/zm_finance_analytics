# mapping — deriving `account_map` from the client's own formula chain

These scripts rebuild `seeds/reference/account_map.csv` from the client's monthly
Consolidated Accounts packs, and reconcile the resulting marts against the client's
own SCI Detailed and SFP Detailed, line by line, for every month.

The mapping is **not** inferred from account names. Every figure the client reports is a
formula that terminates in a specific cell on an entity's TB tab:

```
SCI / SFP Detailed  ->  KES consolidated TB  ->  TB Local Currency  ->  entity TB tab
```

Parsing that chain means each account's statement line is the client's own assignment.
943 of the 951 rows come straight from it; the rest fall back to the client's `Categories`
column on `KES consolidated TB`.

## Running it

```bash
cd datamodel
python Scripts/mapping/derive_map.py          # writes account_map_derived.csv + map_unresolved.csv
# review, then copy the five standard columns into seeds/reference/account_map.csv
dbt seed --select account_map --full-refresh && dbt build
python Scripts/mapping/compare.py             # writes recon_summary.csv + recon_detail.csv
```

`derive_map.py` writes an extra `basis`, `description`, `source_code` and `note` column
beyond the five `account_map` columns — keep those for review, strip them for the seed.

## Files

| File | Purpose |
|---|---|
| `packlib.py` | Fast pack reader. Materialises each sheet once with `iter_rows`; `ws.cell()` random access on a read-only sheet is O(n²) (~35s a pack vs ~0.2s). |
| `chain.py` | Resolves the formula chain. |
| `derive_map.py` | Turns the chain into `account_map` rows, recording the basis for each. |
| `compare.py` | Compares the marts to the client's statements per entity, line and month. |

## Four things the chain resolver has to get right

Each of these silently corrupted an earlier attempt:

1. **`KES consolidated TB` and `TB Local Currency` are not row-aligned**, and the offset
   differs per entity. The row link is taken from the formula itself — including resolving
   VLOOKUPs by their lookup key. Matching rows by account name instead produced offsets of
   13–14 rows and mapped accounts to the wrong lines.
2. **`TB Local Currency` covers only 9 of the 11 entities.** ZHL and ZATL have no column
   there; their `KES consolidated TB` cells point straight at `ZHL!C39`, `ZATL!D6`.
3. **Range sums must be expanded.** Much of the SFP is written as
   `SUM('KES consolidated TB'!D14:D28)`; dropping ranges loses most of the balance sheet.
   Only single-column ranges are expanded, capped at 130 rows — the SFP `Net Profit` row
   sums the entire P&L range and would otherwise map every P&L account into equity.
4. **The SCI expense section is group headers over account-level detail rows.** Column A
   carries the client's marker (`P&L` on the SCI, `Balance Sheet` on the SFP) and is blank
   on group headers and subtotals, so detail rows inherit their group. Matching the marker
   text literally is brittle — the SFP marker is `Balance Sheet`, not `Balance`.

**Where two lines both reach an account, the narrower line wins.** The client writes broad
subtotals that sweep in a row and then subtract the dedicated line again — ZARIB's
`Trade and other payables` is `SUM(...F135...)-F46` where F46 is `Premium payable`. Parsing
that arithmetic in general is fragile; preferring the more specific line gets it right
without doing so, and fixed a KES 10.6bn mis-split on its own.

Where an account is reached from both an SCI and an SFP line, the client's `Categories`
label decides — a trial-balance account can only sit on one statement.

## Known limits

- **January cannot be reconciled at line level.** That pack's `SCI` and `SFP` tabs are the
  consolidated group statements, not the per-entity Detailed tabs the other five months
  carry. January still contributes accounts and Categories labels to the mapping.
- **MENA has no account codes.** `stg_mena_descriptive_tb` derives one as
  `'MENA-' || md5(Description)`, so the raw description string must be carried through
  byte-for-byte — it is not in the reseed audit and needs the hash computed directly.
- **Consolidation-level accruals are invisible here.** They exist only in
  `KES consolidated TB`, not on the entity tabs the seeds are built from. ZARIB is short
  exactly KES 15,000,000 of expense and payable in April and May for this reason.
- Current state: **2,340 of 2,484 line cells tie exactly (94.2%)**; see
  `Internal/Phase1_SCI_SFP_Reconciliation_Jan_Jun.xlsx`.
- **`map_overrides.csv`** holds reviewed decisions the chain cannot reach or gets wrong, each
  with its justification. Keep it small and keep the reasons — an override with no reason is
  indistinguishable from a mistake. Today it holds three C&P rows.
- **`account_map`'s `effective_from` / `effective_to` columns are not honoured** —
  `int_account_mapping` joins on company and account only. The client does re-classify
  accounts mid-year (C&P's Withholding IncomeTax moves from Other receivables to Tax
  recoverable in June), so making the model date-aware is the next structural fix.
