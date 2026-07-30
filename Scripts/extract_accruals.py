#!/usr/bin/env python3
"""Extract the client's Accruals column from the entity TB tabs into a seed.

    python Scripts/extract_accruals.py           # dry run — prints what it would write
    python Scripts/extract_accruals.py --write   # writes seeds/reference/tb_accrual.csv
    dbt seed --full-refresh && dbt build

Why a separate seed
-------------------
The client's individual TB tabs carry five columns — `A/C No`, `Description`,
`Amount`, `Accruals`, `Amount After Accruals` — and Finance wants all five in
Power BI. The bronze `gl_entry_*` seeds mirror BC's own table, so an extra
accrual column has no place in them. Instead the accrual travels as its own
reference seed and is joined back downstream (`stg_tb_accrual` ->
`rpt_subsidiary_tb`), leaving every BC-shaped table and every existing model
untouched.

**The bronze seeds already hold the POST-accrual figure** — that is what the
reseed loads and what the whole reconciliation ties to. So the derivation is:

    amount_after_accruals = gl_entry (unchanged)
    accruals              = this seed
    amount                = amount_after_accruals - accruals

Deriving the pre-accrual figure rather than storing it keeps a single source of
truth: no mart figure can move because of this seed, only be decomposed by it.

Monthly movements, not YTD
--------------------------
The packs are cumulative YTD, and `gl_entry` holds monthly movements so the
period cross-join can accumulate them. This seed follows the same convention:
`accrual_local` is the month's movement, and summing to a period gives the YTD
accrual as at that period. Months are loaded in order and each month's movement
is `this YTD - prior cumulative`.

Only three entities have the column
-----------------------------------
ZAAC, ZARIB and C&P. Everything else gets no rows, and reads as zero downstream,
so the five columns render uniformly for all eleven entities.

**ZARIB renames both columns in March and April** — `Deffered Revenue & Accruals`
and `Amount After Deferred Rev` (their spelling). Those names were not in the
header vocabulary, so the reseed read those two months from the plain `Amount`
column, i.e. pre-accrual, while every other entity-month is post-accrual. That is
the KES 15,000,000 (April) and 11,250,000 (March) ZARIB gap in the SCI/SFP recon.
Both names are now recognised in `reseed_from_packs.py` and `mapping/packlib.py`,
so a reseed puts ZARIB on the same basis as everyone else.
"""
import argparse
import collections
import csv
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mapping'))
import packlib as P                                        # noqa: E402

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
SEED = os.path.join(P.SEEDS, 'reference', 'tb_accrual.csv')

FIELDS = ['company_name', 'period', 'local_account_no', 'description',
          'accrual_local', 'client_column', 'source_tab']


def read_accruals(path, period):
    """-> [(company, account_or_None, description, ytd_overlay, column_label, tab)]

    The overlay is the RESIDUAL `Amount After Accruals - Amount`, not the value in
    the accrual column. Those are the same number on almost every row, but not all:
    the client sometimes posts an adjustment straight into the netted column and
    leaves the accrual column blank or zero. In the March 2026 pack they do exactly
    that with their tax journal —

        ZAAC  B75120   Tax Provision-Other   amt  13,204,563.90  accr 0  post  -7,806,139.06
        ZAAC  (blank)  Tax expense           amt      (blank)    accr 0  post  21,010,702.96
        ZARIB 7550/000 Tax Provision-Other   amt -143,075,062.59 accr 0  post -139,700,062.59
        ZARIB 4650/200 Tax Expense           amt  149,813,937.37 accr 0  post  146,438,937.37

    — a balanced Dr Tax expense / Cr Tax provision pair in each entity. Reading the
    accrual column missed all four, so bronze kept the pre-journal `Amount` and the
    overlay carried nothing: ZAAC's `tax_recoverable` was out by the whole 21.01m
    and ZARIB's `taxation` / `tax_recoverable` / `net_profit` by 3.375m each. (ZAAC's
    blank-code `Tax expense` row survived only via the `netted - accrual` fallback in
    reseed_from_packs.py; its credit leg did not.)

    Taking the residual makes `bronze + overlay = the client's reported figure` true
    by construction for every row, and it is self-maintaining: any future adjustment
    the client posts netted-only is picked up without a code change. Rows where the
    accrual column IS populated are unaffected — the residual equals it.

    These four rows are the only ones in the six-pack set where the two disagree, so
    the change is provably scoped. Where it fires, `client_column` is tagged
    `derived: after - amount (<stated label>)` so the TB visual and any Finance
    walkthrough can see that our figure is derived rather than lifted, and the
    Exceptions Register item can ask whether the tax journal belonged in the accrual
    column at all — the client's own tab is internally inconsistent here.
    """
    wanted = set(P.ENTITIES)
    sheets = P.sheet_rows(path, wanted=wanted)
    out = []
    for tab, rows in sheets.items():
        seed_name, _ccy = P.ENTITIES[tab]
        company = seed_name.upper().replace('_', '&') if seed_name == 'c_p' else seed_name.upper()
        hi, roles = P.find_header(rows)
        # An accrual column is what marks a tab as carrying an overlay at all.
        if hi is None or 'accrual' not in roles:
            continue
        label = str(rows[hi][roles['accrual']]).strip()
        cdesc, cacc = roles['desc'], roles['accrual']
        cplain = roles.get('amt_plain')
        ccode = roles.get('code')
        # The netted column is what the residual is measured against. On C&P's tab
        # it carries no header at all before June (see packlib.ACCRUAL_HDRS), so
        # fall back to the column immediately right of the accrual column when it
        # holds numbers. With no netted column anywhere there is nothing to take a
        # residual against and the stated accrual is all we have.
        cpost = roles.get('amt_post')
        if cpost is None:
            cand = cacc + 1
            if any(P.num(r[cand]) is not None for r in rows[hi + 1:] if cand < len(r)):
                cpost = cand
        for row in rows[hi + 1:]:
            def cell(c):
                return row[c] if c is not None and c < len(row) else None
            desc = cell(cdesc)
            nd = P.norm(desc)
            if nd in P.SKIP_DESC or nd.startswith('total') or nd.startswith('period'):
                continue
            stated = P.num(cell(cacc)) or 0.0
            post = P.num(cell(cpost))
            plain = P.num(cell(cplain)) or 0.0
            # No netted figure means the row is not reported; fall back to whatever
            # the accrual column says rather than inventing a residual from nothing.
            v = (post - plain) if post is not None else stated
            if abs(v) < 0.005:
                continue
            col = label if abs(v - stated) < 0.005 else f'derived: after - amount ({label})'
            code = None
            if ccode is not None and cell(ccode) not in (None, ''):
                code = str(cell(ccode)).strip()
            out.append((company, code, str(desc).strip(), v, col, tab))
    return out


def load_code_resolver():
    """(entity, source_code, norm description) -> the code the seed actually uses.

    The packs code the same account differently month to month, and the reseed
    resolves that — ZARIB's `6790/000 Bonus(General provision)` becomes `B80110`,
    ZAAC's `Accrued Income` is `B55130` in February and `B55135` from March, and
    several rows have no A/C No at all. `reseed_audit.csv` records every one of
    those decisions, so reusing it is what makes the accrual join to the TB. Keyed
    by description as well as by code, because the blank-code rows have nothing else.
    """
    path = os.path.join(SCRIPTS, 'reseed_audit.csv')
    if not os.path.exists(path):
        print(f'  note: {path} not found — accrual rows will keep their pack codes '
              f'and may not join to the TB. Run reseed_from_packs.py first.')
        return {}, {}
    by_code, by_desc = {}, {}
    with open(path, newline='', encoding='utf-8-sig') as f:
        for r in csv.DictReader(f):
            ent = r['entity']
            nd = P.norm(r['description'])
            by_code[(ent, r.get('source_code') or '', nd)] = r['assigned_code']
            by_desc.setdefault((ent, nd), r['assigned_code'])
    return by_code, by_desc


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--seed', default=SEED)
    a = ap.parse_args()

    by_code, by_desc = load_code_resolver()
    unresolved = set()

    def resolve(company, code, desc):
        nd = P.norm(desc)
        return (by_code.get((company, code or '', nd))
                or by_desc.get((company, nd))
                or code or '')

    cumulative = collections.defaultdict(float)     # (co, code, desc) -> loaded so far
    rows = []
    for period, pend, fname in P.MONTH_FILES:
        path = os.path.join(P.BASE, fname)
        if not os.path.exists(path):
            print(f'  {period}: pack not found, skipped')
            continue
        found = read_accruals(path, period)
        n = 0
        seen, meta = set(), {}
        for company, code, desc, ytd, label, tab in found:
            # blank A/C No is systemic in these packs; key on the description
            seed_code = resolve(company, code, desc)
            if not seed_code:
                unresolved.add((company, desc))
            key = (company, seed_code, P.norm(desc))
            seen.add(key)
            meta[key] = (seed_code, desc, label, tab)
            movement = ytd - cumulative[key]
            cumulative[key] = ytd
            if abs(movement) < 0.005:
                continue
            rows.append({'company_name': company, 'period': period,
                         'local_account_no': seed_code,
                         'description': desc,
                         'accrual_local': round(movement, 2),
                         'client_column': label, 'source_tab': tab})
            n += 1

        # An account that carried an accrual last month and carries none this month
        # has been released — the client just stops listing it. Without an explicit
        # reversal its YTD would stay frozen at last month's figure. This happens
        # whenever they re-code the counter-account: ZAAC's Accrued Income moves
        # B55130 -> B55135 in March, ZARIB's counter-entry moves off
        # '3290/000 Other Staff Costs' in June, C&P's off 'Accrued Income'.
        if found:
            for key, prior in list(cumulative.items()):
                if key in seen or abs(prior) < 0.005:
                    continue
                code, desc, label, tab = meta.get(key, (key[1], key[2], 'released', ''))
                rows.append({'company_name': key[0], 'period': period,
                             'local_account_no': key[1],
                             'description': desc,
                             'accrual_local': round(-prior, 2),
                             'client_column': 'released (no longer listed)',
                             'source_tab': tab})
                cumulative[key] = 0.0
                n += 1
        byco = collections.Counter(c for c, _, _, _, _, _ in found)
        print(f'  {period}: {n:2d} movement rows from '
              f'{dict(byco) if byco else "no accrual column on any tab"}')

    if unresolved:
        print(f'\n  {len(unresolved)} accrual rows could not be resolved to a seed code:')
        for co, d in sorted(unresolved):
            print(f'     {co} {d}')

    if not rows:
        sys.exit('no accruals found — check the header vocabulary in packlib.ACCRUAL_HDRS')

    print()
    print('%-8s %-8s %-14s %-34s %16s  %s' % ('entity', 'period', 'account',
                                              'description', 'movement', 'client column'))
    for r in rows:
        print('%-8s %-8s %-14s %-34s %16s  %s' % (
            r['company_name'], r['period'], r['local_account_no'] or '(blank)',
            r['description'][:34], format(r['accrual_local'], ',.2f'), r['client_column']))

    # The client's accruals are reclassifications, not new value: within an entity
    # the YTD column nets to zero in every month. Checking the cumulative rather than
    # the movement is the real invariant — a non-zero total means a row was missed or
    # a release was not picked up.
    print()
    bad = ytd = 0
    running = collections.defaultdict(float)
    for r in sorted(rows, key=lambda r: r['period']):
        running[(r['company_name'], r['period'])] = 0.0
    for (co, period) in sorted(running):
        v = sum(r['accrual_local'] for r in rows
                if r['company_name'] == co and r['period'] <= period)
        ytd += 1
        if abs(v) > 1.0:
            bad += 1
            print(f'  WARNING {co} {period}: YTD accruals net to {v:,.2f}, not zero')
    print(f'entity-months where the YTD accruals net to zero: {ytd - bad} of {ytd}')

    if not a.write:
        print('\ndry run — pass --write to update the seed')
        return
    os.makedirs(os.path.dirname(a.seed), exist_ok=True)
    with open(a.seed, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f'\nwrote {a.seed} ({len(rows)} rows)')
    print('now run: dbt seed --full-refresh && dbt build')


def _sums(rows):
    out = collections.defaultdict(float)
    for r in rows:
        out[(r['company_name'], r['period'])] += r['accrual_local']
    return out


if __name__ == '__main__':
    main()
