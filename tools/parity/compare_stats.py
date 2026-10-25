#!/usr/bin/env python3
"""sim-parity: compare tools/parity/stats.luau outputs of two groups (e.g. rng=port vs rng=godot,
or before/after a change). usage: compare_stats.py DIR [groupA groupB]
Files: DIR/<group>_<seed>.json. Prints mean, sd, n and Welch t for each metric."""
import json
import math
import os
import sys

d = sys.argv[1]
ga = sys.argv[2] if len(sys.argv) > 2 else "port"
gb = sys.argv[3] if len(sys.argv) > 3 else "godot"


def load(g):
    out = {}
    for f in os.listdir(d):
        if f.startswith(g + "_") and f.endswith(".json"):
            try:
                j = json.loads(open(os.path.join(d, f)).read().strip().split("\n")[-1])
            except Exception:
                continue
            out[j["seed"]] = j
    return out


A, B = load(ga), load(gb)


def metric(js, fn):
    vals = []
    for j in js.values():
        try:
            vals.append(float(fn(j)))
        except (KeyError, TypeError):
            pass
    return vals


def stat(v):
    n = len(v)
    if n == 0:
        return 0, 0, 0
    m = sum(v) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in v) / (n - 1)) if n > 1 else 0
    return m, sd, n


def p_two_sided(t, df):
    if df > 60:
        return math.erfc(abs(t) / math.sqrt(2.0))
    # Student t survival via regularized incomplete beta (continued fraction)
    x = df / (df + t * t)
    a, b = df / 2.0, 0.5

    def betacf(a, b, x):
        qab, qap, qam = a + b, a + 1, a - 1
        c, dd = 1.0, 1 - qab * x / qap
        dd = 1 / (dd if abs(dd) > 1e-30 else 1e-30)
        h = dd
        for m in range(1, 200):
            m2 = 2 * m
            aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            dd = 1 + aa * dd
            dd = 1 / (dd if abs(dd) > 1e-30 else 1e-30)
            c = 1 + aa / c
            h *= dd * c
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            dd = 1 + aa * dd
            dd = 1 / (dd if abs(dd) > 1e-30 else 1e-30)
            c = 1 + aa / c
            h *= dd * c
        return h

    bt = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log(1 - x))
    return bt * betacf(a, b, x) / a


rows = []
for s in ["15", "30", "45", "60", "90", "120"]:
    rows.append(("landgrab %ss" % s, lambda j, s=s: j["landgrab"][s]))
for m in ["1", "2", "3", "5", "8", "10", "12", "15"]:
    for k in ["nukes", "structs", "roads", "units", "alliances", "nations", "tribes", "attacks"]:
        rows.append(("min%-2s %s" % (m, k), lambda j, m=m, k=k: j["minute"][m][k]))
rows.append(("step_ms", lambda j: j["step_ms"]))
print("%-22s %22s %22s %8s %6s" % ("metric", ga + " mean±sd (n)", gb + " mean±sd (n)", "t", "p"))
for name, fn in rows:
    va, vb = metric(A, fn), metric(B, fn)
    (ma, sa, na), (mb, sb, nb) = stat(va), stat(vb)
    if na < 2 or nb < 2:
        continue
    se = math.sqrt(sa * sa / na + sb * sb / nb)
    t = (ma - mb) / se if se > 0 else 0
    df = (sa * sa / na + sb * sb / nb) ** 2 / ((sa ** 4) / (na * na * (na - 1)) + (sb ** 4) / (nb * nb * (nb - 1))) if se > 0 else 1
    p = p_two_sided(t, df) if se > 0 else 1
    flag = " *" if p < 0.05 else ""
    print("%-22s %13.2f±%-6.2f(%d) %13.2f±%-6.2f(%d) %8.2f %6.3f%s" % (name, ma, sa, na, mb, sb, nb, t, p, flag))
