#!/usr/bin/env python3
"""Re-derive account_map from the client's own formula chain.

Primary evidence is the chain: the SCI/SFP Detailed line whose formula reaches an
account IS that account's statement line, per the client. Where the chain is
silent, the client's 'Categories' column on KES consolidated TB is used as a
second source, and only then a description rule. Every row records which.
"""
import csv, collections, json, os, hashlib
import packlib as P
import chain as CH

# Lines whose figure we want for the reconciliation but which must never become a
# mapping. The SFP 'Net Profit' row is =SUM(entire P&L range); our model derives
# it in fct_trial_balance, so mapping from it would push every P&L account into
# equity — but we still want to compare our derived figure to theirs.
COMPARE_ONLY = {'net profit': 'Net Profit (derived)'}

SEEDS = P.SEEDS
OUT = P.OUTDIR
os.makedirs(OUT, exist_ok=True)

# Client SFP labels that name one of our lines differently (incl. their typo).
LABEL_ALIAS = {
    'office cash': 'Cash - Office Cash',
    'client cash': 'Cash - Client Cash',
    'deposits': 'Cash - Deposits',
    'placements': 'Cash - Placements',
    'intangible assets - computer software': 'Intangible - computer software',
    'intangible assets - goodwill': 'Intangible - goodwill',
    'transalation reserve': 'Translation reserve',
    'translation reserve': 'Translation reserve',
    'taxation expense': 'Taxation',
    'finance costs': 'Finance cost',
}
# Subtotal / derived rows that must never become a mapping. 'Net Profit' on the
# SFP is =SUM(entire P&L range) — our model derives it in fct_trial_balance, so
# taking it from the chain would map every P&L account to equity.
LABEL_SKIP = {
    'profit before tax', 'profit after tax', 'variance', 'profit as per management accounts',
    'equity attributable to equity holders of the parent', 'total', 'net assets',
    'total equity and liabilities', 'total assets', 'gross profit', 'operating profit',
    'net profit', 'total income', 'total expenses', 'total equity', 'income', 'expenses',
}

# The client's 'Categories' vocabulary -> our statement_line_code. Second-line
# evidence, used only where the chain does not reach an account.
CATEGORY_MAP = {
    'share capital': 'share_capital',
    'translation reserve': 'translation_reserve',
    'retained earnings': 'retained_earnings',
    'non-controlling interests': 'non_controlling_interests',
    'proposed dividend': 'proposed_dividend',
    'property, plant and equipment': 'ppe',
    'intangible assets': 'computer_software',
    'intangible assets - computer software': 'computer_software',
    'goodwill': 'goodwill',
    'investment in associate': 'investment_in_associate',
    'investment in unquoted equity securities': 'investment_unquoted_equity',
    'investment in subsidiary': 'investment_in_subsidiary',
    'deposit for investment in subsidiary': 'deposit_for_investment_in_subsidiary',
    'deferred tax': 'deferred_tax',
    'trade receivables': 'trade_receivables',
    'premium receivables': 'premium_receivables',
    'other receivables': 'other_receivables',
    'due from/to related parties': 'due_from_to_related_parties',
    'accrued income': 'accrued_income',
    'tax recoverable': 'tax_recoverable',
    'office cash': 'office_cash',
    'client cash': 'client_cash',
    'deposits': 'deposits',
    'placements': 'placements',
    'cash and cash equivalents': 'office_cash',
    'trade and other payables': 'trade_and_other_payables',
    'premium payable': 'premium_payable',
    'deferred revenue': 'deferred_revenue',
    'borrowings': 'borrowings',
    'revenue': 'other_income',
    'other income': 'other_income',
    'personnel costs': 'personnel_costs',
    'travelling': 'travelling',
    'entertainment': 'entertainment',
    'it costs': 'it_costs',
    'communications': 'communications',
    'printing & stationery': 'printing_stationery',
    'premises': 'premises',
    'advertising & pr': 'advertising_pr',
    'insurance': 'insurance',
    'professional fees': 'professional_fees',
    'depreciation': 'depreciation',
    'motor vehicle expenses': 'motor_vehicle_expenses',
    'general expenses': 'general_expenses',
    'management expense': 'management_expense',
    'finance costs': 'finance_costs',
    'finance cost': 'finance_costs',
    'taxation': 'taxation',
    'taxation expense': 'taxation',
}


def load_statement_lines():
    by_label = {}
    codes = {}
    for r in csv.DictReader(open(f'{SEEDS}/reference/statement_line.csv')):
        by_label[P.norm(r['line_label'])] = r['statement_line_code']
        codes[r['statement_line_code']] = r
    return by_label, codes


def label_to_code(which, label, by_label, for_compare=False):
    n = P.norm(label)
    if n in LABEL_SKIP:
        if not (for_compare and n in COMPARE_ONLY):
            return None
        return by_label.get(P.norm(COMPARE_ONLY[n]))
    n = P.norm(LABEL_ALIAS.get(n, label))
    return by_label.get(n)


def load_overrides():
    """Reviewed, reasoned mapping decisions that the chain cannot reach or gets
    wrong. Kept in a file rather than in code so every one is visible to Finance
    with its justification."""
    out = {}
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'map_overrides.csv')
    if not os.path.exists(p):
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'map_overrides.csv')
    if os.path.exists(p):
        for r in csv.DictReader(open(p, newline='')):
            out[(r['company_name'].strip(), r['local_account_no'].strip())] = \
                (r['statement_line_code'].strip(), r['reason'])
    return out


def main():
    by_label, sl = load_statement_lines()
    overrides = load_overrides()

    # assigned code per (company, source_code, norm_description) from the reseed
    assigned = {}
    audit = os.environ.get('RESEED_AUDIT',
                           os.path.join(P.SCRIPTS, 'reseed_audit.csv'))
    for r in csv.DictReader(open(audit)):
        assigned[(r['entity'], r['source_code'] or '', P.norm(r['description']))] = r['assigned_code']

    # acct -> period -> code, so a mapping that changes mid-year becomes two
    # effective-dated rows rather than one arbitrary winner
    chain_by_period = collections.defaultdict(dict)
    chain_votes = collections.defaultdict(collections.Counter)   # acct -> code -> months
    # How many accounts the claiming line reaches. When two lines both reach an
    # account, the narrower line is the intended home: the client writes broad
    # subtotal formulas that sweep in a row and then subtract the dedicated line
    # again (ZARIB's 'Trade and other payables' is SUM(...F135...)-F46, where F46
    # is 'Premium payable'). Parsing that arithmetic in general is fragile;
    # preferring the more specific line gets it right without doing so.
    chain_breadth = collections.defaultdict(dict)                # acct -> code -> min breadth
    cat_votes = collections.defaultdict(collections.Counter)     # acct -> category -> months
    reported = {}                                                # (co,which,label,period) -> value
    unresolved_labels = collections.Counter()

    raws = {}
    for period, pend, fname in P.MONTH_FILES:
        pk = CH.load(P.BASE + '/' + fname, period)
        la, cats, rep, raw_desc = pk.build()
        raws.update(raw_desc)
        for (co, which, label), accts in la.items():
            code = label_to_code(which, label, by_label)
            if not code:
                if P.norm(label) not in LABEL_SKIP:
                    unresolved_labels[(which, label)] += 1
                continue
            breadth = len(set(accts))
            for sc, nd in accts:
                k = (co, sc, nd)
                # narrowest claiming line wins within a single month too
                prev = chain_by_period[k].get(period)
                if prev is None or breadth < chain_by_period[k].get('_b_' + period, 9999):
                    chain_by_period[k][period] = code
                    chain_by_period[k]['_b_' + period] = breadth
                chain_votes[k][code] += 1
                prev = chain_breadth[(co, sc, nd)].get(code)
                if prev is None or breadth < prev:
                    chain_breadth[(co, sc, nd)][code] = breadth
        for (co, sc, nd), cat in cats.items():
            cat_votes[(co, sc, nd)][cat] += 1
        # one figure per client row: its own label if that names a statement
        # line, otherwise the group it sits under
        for (co, which, label, group), v in rep.items():
            code = label_to_code(which, label, by_label, for_compare=True) or \
                   (label_to_code(which, group, by_label, for_compare=True) if group else None)
            if not code:
                continue
            k = (co, which, code, period)
            reported[k] = reported.get(k, 0.0) + v
        pk.close()
        print('chain read', period, flush=True)

    PERIODS = [p for p, _, _ in P.MONTH_FILES]
    PERIOD_START = {p: f'{p}-01' for p in PERIODS}
    PERIOD_END = {p: e for p, e, _ in P.MONTH_FILES}

    def spans(key):
        """Contiguous runs of months sharing one code -> [(code, first, last)].
        Months where the chain is silent inherit the previous code, so a gap in
        the client's own referencing does not read as a re-classification."""
        seq = []
        last_code = None
        for p in PERIODS:
            code = chain_by_period[key].get(p) or last_code
            if code is None:
                continue
            if seq and seq[-1][0] == code:
                seq[-1][2] = p
            else:
                seq.append([code, p, p])
            last_code = code
        return seq

    rows, unresolved, changes = [], [], []
    keys = set(chain_votes) | set(cat_votes)
    for key in sorted(keys):
        co, sc, nd = key
        if co == 'MENA':
            # MENA is not in the reseed audit: it has no account codes, so
            # stg_mena_descriptive_tb synthesises one from the description.
            raw = raws.get(key)
            acode = 'MENA-' + hashlib.md5(raw.encode('utf-8')).hexdigest()[:10].upper() if raw else None
        else:
            acode = assigned.get(key)
        if not acode:
            continue
        cv = chain_votes.get(key)
        basis = note = ''
        code = None
        ov = overrides.get((co, acode))
        if ov:
            rows.append({'company_name': co, 'local_account_no': acode,
                         'statement_line_code': ov[0], 'effective_from': '1900-01-01',
                         'effective_to': '9999-12-31', 'basis': 'REVIEWED_OVERRIDE',
                         'description': nd, 'source_code': sc, 'note': ov[1]})
            continue
        if cv:
            bd = chain_breadth[key]
            # narrowest claiming line first, then most months, then stable name
            ranked = sorted(cv.items(), key=lambda kv: (bd.get(kv[0], 9999), -kv[1], kv[0]))
            code = ranked[0][0]
            basis = 'CHAIN'
            if len(ranked) > 1:
                cat = (cat_votes[key].most_common(1) or [(None, 0)])[0][0]
                cat_code = CATEGORY_MAP.get(P.norm(cat)) if cat else None
                if cat_code in dict(ranked):
                    # The client's Categories column on KES consolidated TB is their
                    # own account-level classification, so where it names one of the
                    # competing lines it beats any structural heuristic. This matters
                    # because statement rows shift between packs: C&P's 'Debtors
                    # Prepaid other' was picked up by the one-account 'Placements'
                    # line in a month where the row indices had moved, and the
                    # breadth rule then preferred it over 'Other receivables' —
                    # which is what the Categories column actually says.
                    code = cat_code
                    basis = 'CHAIN_CATEGORY_TIEBREAK'
                    note = f'more than one line reaches this account; the client Categories ' \
                           f'column says {cat!r} -> {cat_code}. Lines claiming it: ' + \
                           ', '.join(f'{c} (x{n})' for c, n in ranked)
                else:
                    basis = 'CHAIN_SPECIFIC' if bd.get(ranked[0][0], 9999) < bd.get(ranked[1][0], 9999) \
                            else 'CHAIN_MAJORITY'
                    note = 'chain reaches this account from more than one line: ' + \
                           ', '.join(f'{c} (x{n} months, line spans {bd.get(c, "?")} accounts)'
                                     for c, n in ranked)
        else:
            cat = (cat_votes[key].most_common(1) or [(None, 0)])[0][0]
            code = CATEGORY_MAP.get(P.norm(cat)) if cat else None
            if code:
                basis = 'CLIENT_CATEGORY'
                note = f'chain silent; client Categories column says {cat!r}'
            else:
                unresolved.append({'entity': co, 'source_code': sc, 'description': nd,
                                   'assigned_code': acode,
                                   'client_category': cat or '',
                                   'reason': 'no chain reference and no category mapping'})
                continue
        # Emit one effective-dated row per contiguous run of months on the same
        # line. Most accounts give a single run covering everything; the ones that
        # give more are the client re-classifying mid-year, and each becomes an
        # entry in the change register for them to explain.
        sp = spans(key) if cv else []
        if len(sp) <= 1:
            rows.append({'company_name': co, 'local_account_no': acode,
                         'statement_line_code': code, 'effective_from': '1900-01-01',
                         'effective_to': '9999-12-31', 'basis': basis, 'description': nd,
                         'source_code': sc, 'note': note})
        else:
            for i, (c2, first, last) in enumerate(sp):
                rows.append({'company_name': co, 'local_account_no': acode,
                             'statement_line_code': c2,
                             'effective_from': '1900-01-01' if i == 0 else PERIOD_START[first],
                             'effective_to': '9999-12-31' if i == len(sp) - 1 else PERIOD_END[last],
                             'basis': 'CHAIN_EFFECTIVE_DATED',
                             'description': nd, 'source_code': sc,
                             'note': f'client reports this account on {c2} for {first}..{last}'})
                if i:
                    changes.append({'entity': co, 'account_code': acode, 'source_code': sc,
                                    'description': nd, 'changed_from': sp[i - 1][0],
                                    'changed_to': c2, 'changed_in': first,
                                    'from_months': f'{sp[i-1][1]}..{sp[i-1][2]}',
                                    'to_months': f'{first}..{last}'})

    # Overrides for accounts the chain never reaches at all (so they never enter
    # the loop above) — e.g. C&P Entertainment, which the client's Detailed sheet
    # leaves blank while their consolidated TB carries the amount.
    have = {(r['company_name'], r['local_account_no']) for r in rows}
    for (co, acct), (code, reason) in overrides.items():
        if (co, acct) in have:
            continue
        rows.append({'company_name': co, 'local_account_no': acct,
                     'statement_line_code': code, 'effective_from': '1900-01-01',
                     'effective_to': '9999-12-31', 'basis': 'REVIEWED_OVERRIDE',
                     'description': '', 'source_code': '', 'note': reason})
        unresolved = [u for u in unresolved if not (u['entity'] == co and u['assigned_code'] == acct)]

    # one row per (company, account, effective span)
    seen = {}
    for r in rows:
        k = (r['company_name'], r['local_account_no'], r['effective_from'], r['effective_to'])
        if k in seen and seen[k]['basis'].startswith('CHAIN') and not r['basis'].startswith('CHAIN'):
            continue
        seen[k] = r
    rows = list(seen.values())
    # An override replaces every span for that account, otherwise it would
    # overlap the chain-derived rows and fan the fact table out.
    ov_accts = {(co, a) for (co, a) in overrides}
    rows = [r for r in rows
            if (r['company_name'], r['local_account_no']) not in ov_accts
            or r['basis'] == 'REVIEWED_OVERRIDE']
    changes = [c for c in changes if (c['entity'], c['account_code']) not in ov_accts]

    with open(f'{OUT}/mapping_changes.csv', 'w', newline='') as f:
        fn = ['entity', 'account_code', 'source_code', 'description', 'changed_from',
              'changed_to', 'changed_in', 'from_months', 'to_months']
        w = csv.DictWriter(f, fieldnames=fn); w.writeheader(); w.writerows(changes)

    with open(f'{OUT}/account_map_derived.csv', 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['company_name', 'local_account_no',
            'statement_line_code', 'effective_from', 'effective_to', 'basis',
            'description', 'source_code', 'note'])
        w.writeheader(); w.writerows(sorted(rows, key=lambda r: (r['company_name'], r['local_account_no'])))
    with open(f'{OUT}/map_unresolved.csv', 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=['entity', 'source_code', 'description',
                                          'assigned_code', 'client_category', 'reason'])
        w.writeheader(); w.writerows(unresolved)
    json.dump({f'{co}|{w}|{code}|{p}': v for (co, w, code, p), v in reported.items()},
              open(f'{OUT}/client_reported.json', 'w'))

    print()
    print('derived account_map rows: %d (effective-dated: %d)' % (len(rows), sum(1 for r in rows if r['basis']=='CHAIN_EFFECTIVE_DATED')))
    print('mapping changes over time: %d' % len(changes))
    print('  by basis :', dict(collections.Counter(r['basis'] for r in rows).most_common()))
    print('  by entity:', dict(collections.Counter(r['company_name'] for r in rows).most_common()))
    print('unresolved accounts: %d' % len(unresolved))
    print('  by entity:', dict(collections.Counter(u['entity'] for u in unresolved).most_common()))
    print()
    print('client labels that reach accounts but match no statement_line (top 15):')
    for (w, lab), n in unresolved_labels.most_common(15):
        print('   %-4s %-50s x%d' % (w, lab[:50], n))


if __name__ == '__main__':
    main()
