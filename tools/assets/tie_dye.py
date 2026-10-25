#!/usr/bin/env python3
"""The Tie Dye exclusive skin (2026-10-18): a custom territory background for one player, @ilyannna,
modelled on a reference clip of a Tie Dye territory pattern. The pattern lives in
assets/skins/tie_dye.json ({scale, alpha, colors: ["#RRGGBB"], mask: [rows]}: '.' is the owner's own fill,
'1'..'9' then 'a'..'z' are colors[1..]); this writes it into src/shared/Data/Cosmetics.luau between the
TIE_DYE_BEGIN / TIE_DYE_END markers, with its owner (Roblox user id 58387889, ilyannna).

Usage: .venv/bin/python tools/assets/tie_dye.py [pattern.json]
Then: .venv/bin/python tools/assets/make_skin_previews.py --group 421623341 (the Locker card's preview).
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "assets", "skins", "tie_dye.json")
LUAU = os.path.join(ROOT, "src", "shared", "Data", "Cosmetics.luau")
OWNERS = [(58387889, "ilyannna")]
KEYS = "123456789abcdefghijklmnopqrstuvwxyz"


def check(p):
    rows = p["mask"]
    w = len(rows[0])
    assert 1 <= len(rows) <= 64 and 1 <= w <= 64, "mask size"
    assert all(len(r) == w for r in rows), "every row the same width"
    keys = set(KEYS[: len(p["colors"])]) | {"."}
    bad = {c for r in rows for c in r} - keys
    assert not bad, f"mask keys without a colour: {sorted(bad)}"
    assert 1 <= len(p["colors"]) <= len(KEYS)
    assert 0 <= int(p["alpha"]) <= 255 and int(p["scale"]) in (0, 1, 2, 3)


def entry(p):
    cols = ", ".join("0x" + c.lstrip("#").upper() for c in p["colors"])
    owners = "".join(f"{uid}, " for uid, _ in OWNERS).rstrip(", ")
    names = ", ".join(n for _, n in OWNERS)
    L = [
        "\t-- TIE_DYE_BEGIN (tools/assets/tie_dye.py writes this entry)",
        "\t{",
        '\t\tid = "tie_dye",',
        '\t\tname = "Tie Dye",',
        f"\t\towners = {{ {owners} }}, -- {names}",
        f"\t\tscale = {int(p['scale'])},",
        f"\t\talpha = {int(p['alpha'])},",
        f"\t\tcolors = {{ {cols} }},",
        "\t\tmask = {",
    ]
    L += [f'\t\t\t"{r}",' for r in p["mask"]]
    L += ["\t\t},", "\t},", "\t-- TIE_DYE_END"]
    return "\n".join(L)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else SRC
    p = json.load(open(src))
    check(p)
    s = open(LUAU, encoding="utf-8").read()
    pat = re.compile(r"\t-- TIE_DYE_BEGIN.*?-- TIE_DYE_END", re.S)
    assert pat.search(s), "markers missing in Cosmetics.luau"
    s = pat.sub(lambda _: entry(p), s, count=1)
    open(LUAU, "w", encoding="utf-8").write(s)
    if os.path.abspath(src) != SRC:
        os.makedirs(os.path.dirname(SRC), exist_ok=True)
        json.dump(p, open(SRC, "w"), indent=1)
    print(f"tie_dye {len(p['mask'][0])}x{len(p['mask'])} scale {p['scale']} alpha {p['alpha']}, "
          f"{len(p['colors'])} colours -> {os.path.relpath(LUAU, ROOT)}")


if __name__ == "__main__":
    main()
