#!/usr/bin/env python3
"""sim-parity: align two RNG call logs (orig vs port, same format) and show the first mismatch
with context. usage: tools/parity/rngdiff.py orig_rng.txt port_rng.txt [context]"""
import sys

ALL = "--all" in sys.argv
if ALL:
    sys.argv.remove("--all")
# By default only RNG call lines ("... @ site") are aligned; --all also aligns diagnostic lines.
a = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip() and (ALL or " @ " in l)]
b = [l.rstrip("\n") for l in open(sys.argv[2]) if l.strip() and (ALL or " @ " in l)]
ctx = int(sys.argv[3]) if len(sys.argv) > 3 else 8


def key(l):
    # tick + method + value (sites differ between languages)
    return l.split(" @ ")[0]


n = min(len(a), len(b))
for i in range(n):
    if key(a[i]) != key(b[i]):
        print("first mismatch at call #%d (orig %d calls, port %d calls)" % (i, len(a), len(b)))
        for j in range(max(0, i - ctx), min(n, i + ctx)):
            mark = ">>" if j == i else "  "
            print("%s O %s\n%s P %s" % (mark, a[j], mark, b[j]))
        sys.exit(0)
print("no mismatch in first %d calls (orig %d, port %d)" % (n, len(a), len(b)))
if len(a) != len(b):
    for j in range(n, max(len(a), len(b))):
        print("  O %s" % (a[j] if j < len(a) else "-"))
        print("  P %s" % (b[j] if j < len(b) else "-"))
        if j > n + ctx:
            break
