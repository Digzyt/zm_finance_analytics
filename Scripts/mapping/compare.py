#!/usr/bin/env python3
"""Compare our marts to the client's own SCI/SFP Detailed, per entity per line
per month. Writes recon_summary.csv and recon_detail.csv."""
import csv, json, collections, os
import psycopg2
import packlib as P
from derive_map import load_statement_lines, label_to_code

OUT = P.OUTDIR
TOL = 1.0          # KES; anything inside this is a rounding tie

by_label, sl = load_statement_lines()

# ---- client side -------------------------------------------------------------
# client_reported.json is already resolved to statement_line codes, one figure
# per client row (see derive_map)
raw = json.load(open(f'{OUT}/client_reported.json'))
client = collections.defaultdict(float)
for k, v in raw.items():
    co, which, code, period = k.split('|')
    client[(co, period, code)] += float(v)

# ---- our side ---------------------------------------------------------------
# Superseded for reconciliation by Scripts/compare_dbt_to_client.py, which reads
# profiles.yml (or CSV exports) rather than assuming a local socket.
c = psycopg2.connect(os.environ.get('PGDSN')) if os.environ.get('PGDSN') else \
    psycopg2.connect(host='/tmp/pgdata', user='postgres', dbname='postgres')
cur = c.cursor()
ours = collections.defaultdict(float)
for tab in ('subsidiary.rpt_subsidiary_sci', 'subsidiary.rpt_subsidiary_sfp'):
    cur.execute(f'select company_name, period, statement_line_code, sum(amount_kes) '
                f'from {tab} group by 1,2,3')
    for co, period, code, amt in cur.fetchall():
        ours[(co, period, code)] += float(amt)

# ---- sign orientation -------------------------------------------------------
# The client's Detailed tabs inherit the debit-positive convention of the KES
# consolidated TB; our marts apply statement_line.sign_multiplier for
# presentation. Compare on the presentation basis by applying the same
# multiplier to the client figure.
sign = {code: float(r['sign_multiplier']) for code, r in sl.items()}

summary, detail = [], []
periods = sorted({k[1] for k in client})   # January has no per-entity Detailed tabs
entities = sorted({k[0] for k in ours} | {k[0] for k in client})
for co in entities:
    for period in periods:
        codes = {k[2] for k in ours if k[0] == co and k[1] == period} | \
                {k[2] for k in client if k[0] == co and k[1] == period}
        if not codes:
            continue
        ties = offs = 0
        worst = 0.0
        for code in sorted(codes):
            o = ours.get((co, period, code), 0.0)
            cl = client.get((co, period, code), 0.0) * sign.get(code, 1.0)
            d = o - cl
            if abs(d) <= TOL:
                ties += 1
            else:
                offs += 1
                worst = max(worst, abs(d))
                detail.append({'entity': co, 'period': period, 'statement_line_code': code,
                               'statement_type': sl.get(code, {}).get('statement_type', ''),
                               'line_label': sl.get(code, {}).get('line_label', ''),
                               'ours_kes': round(o, 2), 'client_kes': round(cl, 2),
                               'difference': round(d, 2)})
        def tot(which, l1s):
            return sum(ours.get((co, period, k), 0.0) for k, r in sl.items()
                       if r['statement_type'] == which and r['category_l1'] in l1s)
        summary.append({'entity': co, 'period': period, 'lines_compared': len(codes),
                        'lines_tying': ties, 'lines_off': offs,
                        'largest_difference': round(worst, 2),
                        'sci_income_ours': round(sum(ours.get((co, period, k), 0.0) for k, r in sl.items()
                                                     if r['statement_type'] == 'SCI' and float(r['sign_multiplier']) < 0), 2),
                        'sci_income_client': round(sum(client.get((co, period, k), 0.0) * sign.get(k, 1)
                                                       for k, r in sl.items()
                                                       if r['statement_type'] == 'SCI' and float(r['sign_multiplier']) < 0), 2),
                        'sci_expense_ours': round(sum(ours.get((co, period, k), 0.0) for k, r in sl.items()
                                                      if r['statement_type'] == 'SCI' and float(r['sign_multiplier']) > 0), 2),
                        'sci_expense_client': round(sum(client.get((co, period, k), 0.0) * sign.get(k, 1)
                                                        for k, r in sl.items()
                                                        if r['statement_type'] == 'SCI' and float(r['sign_multiplier']) > 0), 2),
                        'sfp_assets_ours': round(sum(ours.get((co, period, k), 0.0) for k, r in sl.items()
                                                     if r['statement_type'] == 'SFP' and float(r['sign_multiplier']) > 0), 2),
                        'sfp_assets_client': round(sum(client.get((co, period, k), 0.0) * sign.get(k, 1)
                                                       for k, r in sl.items()
                                                       if r['statement_type'] == 'SFP' and float(r['sign_multiplier']) > 0), 2),
                        'sfp_eandl_ours': round(sum(ours.get((co, period, k), 0.0) for k, r in sl.items()
                                                    if r['statement_type'] == 'SFP' and float(r['sign_multiplier']) < 0), 2),
                        'sfp_eandl_client': round(sum(client.get((co, period, k), 0.0) * sign.get(k, 1)
                                                      for k, r in sl.items()
                                                      if r['statement_type'] == 'SFP' and float(r['sign_multiplier']) < 0), 2)})

for name, rows in (('recon_summary', summary), ('recon_detail', detail)):
    with open(f'{OUT}/{name}.csv', 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)

tl = sum(s['lines_tying'] for s in summary); tc = sum(s['lines_compared'] for s in summary)
print('line cells compared: %d | tying: %d (%.1f%%) | off: %d' % (tc, tl, 100 * tl / tc, tc - tl))
print()
print('%-8s %-8s %6s %6s %18s' % ('entity', 'period', 'lines', 'tying', 'largest diff'))
for s in summary:
    print('%-8s %-8s %6d %6d %18s' % (s['entity'], s['period'], s['lines_compared'],
          s['lines_tying'], format(s['largest_difference'], ',.2f')))
