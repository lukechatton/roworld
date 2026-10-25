#!/usr/bin/env python3
"""sim-parity: first divergence between two lockstep traces (tools/parity/lockstep.gd / .luau).

usage: tools/parity/diff.py orig.txt port.txt
Fields per tick: tick rng_state claimed live_attacks tile_checksum troops_sum nukes structs roads units delta_hash.
"""
import sys

NAMES = ["tick", "rng", "claimed", "attacks", "tile_ck", "troops", "nukes", "structs", "roads", "units", "dhash"]


def main():
    a = open(sys.argv[1]).read().split("\n")
    b = open(sys.argv[2]).read().split("\n")
    n = min(len(a), len(b))
    first = {}
    for i in range(n):
        if a[i] == b[i]:
            continue
        fa, fb = a[i].split(), b[i].split()
        for k, name in enumerate(NAMES):
            if k < len(fa) and k < len(fb) and fa[k] != fb[k] and name not in first:
                first[name] = (i, a[i], b[i])
        if len(first) >= 3 and i > min(v[0] for v in first.values()) + 3:
            break
    if not first:
        print("IDENTICAL over %d lines" % n)
        return
    for name, (i, la, lb) in sorted(first.items(), key=lambda kv: kv[1][0]):
        print("first %-8s diff at line %d\n  orig: %s\n  port: %s" % (name, i, la, lb))


main()
