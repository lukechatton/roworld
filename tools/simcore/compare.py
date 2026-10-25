#!/usr/bin/env python3
"""sim-core: compare sim_bench logs of the original (Godot/Airship) with the Luau port.

usage: tools/simcore_compare.py --orig /private/tmp/af_bench_h{H}_s{S}.log --luau DIR/bench_h{H}_s{S}.log
       [--human 0|1] [--seeds 1,2,3] [--minutes 1,3,8,15]
Prints mean (min..max over seeds) of every per-minute metric for both, side by side.
"""
import argparse
import re
import statistics


def num(s):
    s = s.strip()
    mult = 1.0
    if s.endswith("K"):
        mult, s = 1e3, s[:-1]
    elif s.endswith("M"):
        mult, s = 1e6, s[:-1]
    return float(s) * mult


def parse(path):
    minutes = {}
    cur = None
    extra = {"landgrab": {}}
    with open(path, errors="replace") as f:
        for line in f:
            m = re.search(r"=== minute (\d+) \(tick \d+\) === step avg ([\d.]+) ms p95 ([\d.]+) max ([\d.]+) \| delta ([\d.]+) KB/s .* tiles/tick (\d+) ev/tick ([\d.]+)", line)
            if m:
                cur = {"step_avg": float(m[2]), "step_p95": float(m[3]), "delta_kbs": float(m[5]), "tiles_tick": float(m[6]), "ev_tick": float(m[7])}
                minutes[int(m[1])] = cur
                continue
            m = re.search(r"LANDGRAB t=\s*(\d+) s claimed ([\d.]+)%", line)
            if m:
                extra["landgrab"][int(m[1])] = float(m[2])
                continue
            m = re.search(r"BENCH TOTAL ticks=(\d+) avg=([\d.]+) ms p95=([\d.]+) ms p99=([\d.]+) max=([\d.]+)", line)
            if m:
                extra["total"] = dict(ticks=int(m[1]), avg=float(m[2]), p95=float(m[3]), p99=float(m[4]), max=float(m[5]))
                continue
            m = re.search(r"GAME OVER at tick (\d+): winner \d+ \((.*)\) reason (\d+)", line)
            if m:
                extra["over"] = (int(m[1]), m[2], int(m[3]))
                continue
            if cur is None:
                continue
            m = re.search(r"alive: nations (\d+) tribes (\d+) humans (\d+) \| claimed ([\d.]+)% \| attacks (\d+) \| alliances (\d+)", line)
            if m:
                cur.update(nations=int(m[1]), tribes=int(m[2]), humans=int(m[3]), claimed=float(m[4]), attacks=int(m[5]), alliances=int(m[6]))
                continue
            m = re.search(r"structs: city (\d+) port (\d+) factory (\d+) defense (\d+) sam (\d+) silo (\d+) \| roads (\d+) \| units: transport (\d+) trade (\d+) warship (\d+) truck (\d+) \| nukes launched (\d+)", line)
            if m:
                for k, v in zip(["city", "port", "factory", "defense", "sam", "silo", "roads", "transport", "trade", "warship", "truck", "nukes"], m.groups()):
                    cur[k] = int(v)
                continue
            m = re.search(r"colour re-tints so far: (\d+)", line)
            if m:
                cur["retints"] = int(m[1])
                continue
            m = re.search(r"nations avg: income (\S+)/s cap (\S+) troops (\S+) gold (\S+)", line)
            if m:
                cur.update(n_income=num(m[1]), n_cap=num(m[2]), n_troops=num(m[3]), n_gold=num(m[4]))
                continue
            m = re.search(r"top: (.*)$", line)
            if m:
                shares = [float(x) for x in re.findall(r" ([\d.]+)% \(", " " + m[1])]
                cur["top1"] = shares[0] if shares else 0
                cur["top3"] = sum(shares[:3])
                cur["top10"] = sum(shares[:10])
                cur["leader"] = m[1].split(" ")[0]
                continue
            m = re.search(r"human: alive (\d) tiles (\d+) \(([\d.]+)%\) troops (\S+) / (\S+) gold (\S+) income (\d+)/s cities (\d+) ports (\d+) factories (\d+)", line)
            if m:
                cur.update(h_alive=int(m[1]), h_share=float(m[3]), h_troops=num(m[4]), h_cap=num(m[5]), h_gold=num(m[6]), h_income=int(m[7]),
                           h_cities=int(m[8]), h_ports=int(m[9]), h_factories=int(m[10]))
                continue
    return minutes, extra


def fmt(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "-"
    mean = statistics.mean(vals)
    lo, hi = min(vals), max(vals)
    def f(x):
        if abs(x) >= 1e6:
            return "%.2fM" % (x / 1e6)
        if abs(x) >= 1e4:
            return "%.0fK" % (x / 1e3)
        if abs(x) >= 100:
            return "%.0f" % x
        return "%.1f" % x
    return "%s (%s..%s)" % (f(mean), f(lo), f(hi))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orig", default="/private/tmp/af_bench_h{H}_s{S}.log")
    ap.add_argument("--luau", required=True)
    ap.add_argument("--human", default="0")
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--minutes", default="1,3,8,15")
    a = ap.parse_args()
    seeds = a.seeds.split(",")
    mins = [int(x) for x in a.minutes.split(",")]
    runs = {"orig": [], "luau": []}
    for s in seeds:
        runs["orig"].append(parse(a.orig.replace("{H}", a.human).replace("{S}", s)))
        runs["luau"].append(parse(a.luau.replace("{H}", a.human).replace("{S}", s)))
    keys = ["claimed", "nations", "tribes", "humans", "attacks", "alliances", "top1", "top3", "top10", "city", "port", "factory", "defense",
            "sam", "silo", "roads", "transport", "trade", "warship", "truck", "nukes", "retints", "n_income", "n_cap", "n_troops", "n_gold",
            "h_share", "h_troops", "h_cap", "h_gold", "h_income", "h_cities", "h_ports", "h_factories", "step_avg", "step_p95", "tiles_tick", "ev_tick"]
    print("human=%s seeds=%s  (mean (min..max) over seeds)" % (a.human, a.seeds))
    lg_o = [r[1]["landgrab"] for r in runs["orig"]]
    lg_l = [r[1]["landgrab"] for r in runs["luau"]]
    for t in (15, 30, 45, 60, 120, 180):
        print("  landgrab %3d s: orig %-22s luau %s" % (t, fmt([x.get(t) for x in lg_o]), fmt([x.get(t) for x in lg_l])))
    for m in mins:
        print("--- minute %d" % m)
        for k in keys:
            o = [r[0].get(m, {}).get(k) for r in runs["orig"]]
            l = [r[0].get(m, {}).get(k) for r in runs["luau"]]
            if all(v is None for v in o + l):
                continue
            print("  %-11s orig %-26s luau %s" % (k, fmt(o), fmt(l)))
        lo = [r[0].get(m, {}).get("leader") for r in runs["orig"]]
        ll = [r[0].get(m, {}).get("leader") for r in runs["luau"]]
        print("  %-11s orig %-26s luau %s" % ("leader", ",".join(str(x) for x in lo), ",".join(str(x) for x in ll)))
    for name in ("orig", "luau"):
        for i, r in enumerate(runs[name]):
            tot = r[1].get("total")
            print("%s seed %s: total %s over %s" % (name, seeds[i], tot, r[1].get("over")))


if __name__ == "__main__":
    main()
