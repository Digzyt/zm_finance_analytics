#!/usr/bin/env python3
"""Which rate does the client actually apply, cell by cell?

Every per-entity column on `KES consolidated TB` translates the local-currency
figure by multiplying by a cell on the `Rates` tab. That tab holds one row per
month plus an 'Average' row, so the reference tells us whether the client used
that month's closing rate or the period average — and they are not consistent.
"""
import csv, collections, datetime, re
import packlib as P
import chain as CH

OUT = P.OUTDIR
RATES_REF = re.compile(r"Rates!\$?([A-Z]{1,2})\$?(\d+)")


def rates_index(pack):
    """(col, row) -> (currency, label, value); label is 'YYYY-MM' or 'AVERAGE'."""
    ws = pack.wbV['Rates']
    cur_by_col = {}
    for r in range(1, min(ws.max_row, 12) + 1):
        hit = {c: P.RATE_CURR[P.norm(ws.cell(r, c).value)]
               for c in range(1, ws.max_column + 1)
               if P.norm(ws.cell(r, c).value) in P.RATE_CURR}
        if len(hit) >= 3:
            cur_by_col = hit
            break
    idx = {}
    for r in range(1, ws.max_row + 1):
        a = ws.cell(r, 1).value
        if isinstance(a, datetime.datetime):
            label = f'{a.year:04d}-{a.month:02d}'
        elif isinstance(a, str) and 'average' in a.lower():
            label = 'AVERAGE'
        else:
            continue
        for c, cur in cur_by_col.items():
            v = P.num(ws.cell(r, c).value)
            if v:
                idx[(c, r)] = (cur, label, v)
    return idx, cur_by_col


rows = []
for period, pend, fname in P.MONTH_FILES:
    pk = CH.load(P.BASE + '/' + fname, period)
    ridx, cur_by_col = rates_index(pk)
    ecols = pk.ecols.get(CH.KES_TAB, {})
    ws = pk.wbV[CH.KES_TAB]
    for r in range(1, ws.max_row + 1):
        no = ws.cell(r, 2).value
        nm = ws.cell(r, 3).value
        cat = ws.cell(r, 1).value
        if no is None and nm is None:
            continue
        for co, c in ecols.items():
            f = pk.f(CH.KES_TAB, r, c)
            if not isinstance(f, str):
                continue
            for m in RATES_REF.finditer(f):
                col, rr = P.norm(m.group(1)).upper(), int(m.group(2))
                ci = 0
                for ch in col:
                    ci = ci * 26 + (ord(ch) - 64)
                hit = ridx.get((ci, rr))
                rows.append({
                    'period': period, 'entity': co, 'kes_row': r,
                    'account_no': str(no).strip() if no is not None else '',
                    'account_name': str(nm).strip() if nm is not None else '',
                    'client_category': str(cat).strip() if isinstance(cat, str) else '',
                    'rates_cell': f'{m.group(1)}{rr}',
                    'currency': hit[0] if hit else '?',
                    'rate_label': hit[1] if hit else '?',
                    'rate_value': hit[2] if hit else '',
                })
    pk.close()
    print('read', period, flush=True)

with open(f'{OUT}/fx_refs.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)

print()
print('rate references found: %d' % len(rows))
print()
print('=== which rate row, by entity (all months) ===')
tab = collections.defaultdict(collections.Counter)
for r in rows:
    kind = 'AVERAGE' if r['rate_label'] == 'AVERAGE' else (
        'THIS MONTH' if r['rate_label'] == r['period'] else
        ('OTHER MONTH: ' + r['rate_label']) if r['rate_label'] != '?' else 'UNRESOLVED')
    tab[r['entity']][kind] += 1
for co in sorted(tab):
    tot = sum(tab[co].values())
    parts = ', '.join(f'{k} {v} ({100*v/tot:.0f}%)' for k, v in tab[co].most_common())
    print('  %-8s %4d refs | %s' % (co, tot, parts))

print()
print('=== accounts using THIS MONTH where their entity mostly uses AVERAGE ===')
dom = {co: tab[co].most_common(1)[0][0] for co in tab}
odd = collections.Counter()
for r in rows:
    kind = 'AVERAGE' if r['rate_label'] == 'AVERAGE' else (
        'THIS MONTH' if r['rate_label'] == r['period'] else 'OTHER')
    if dom.get(r['entity'], '').startswith('AVERAGE') and kind != 'AVERAGE':
        odd[(r['entity'], r['account_no'], r['account_name'], kind)] += 1
for (co, no, nm, kind), n in odd.most_common(30):
    print('  %-8s %-12s %-38s %-12s x%d months' % (co, no, nm[:38], kind, n))
print('  (%d such account/entity combinations)' % len(odd))
