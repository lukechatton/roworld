#!/usr/bin/env python3
"""ui-kit: Rubik advance widths (per weight, em/1000) for the kit's layout metrics.

Godot laid the original UI out with the Rubik variable font's true advances (HarfBuzz, no
hinting) and tabular digits for number templates; Roblox measures hinted advances at small sizes.
This writes the exact advances of printable ASCII + a few UI symbols at weights 400..900 (and the
tabular-figure width) into the GENERATED block of src/client/UI/UITheme.luau.

Usage: .venv/bin/python tools/uikit/make_metrics.py [path/to/Rubik-VariableFont_wght.ttf]
"""
import os
import re
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/godot/airship-app/__builtin/theme/Rubik-VariableFont_wght.ttf")
THEME = os.path.join(ROOT, "src", "client", "UI", "UITheme.luau")
EXTRA = "·×…−±✓’“”—–•"

base = TTFont(FONT)
cmap = base.getBestCmap()
subs = {}
for fr in base["GSUB"].table.FeatureList.FeatureRecord:
    if fr.FeatureTag == "tnum":
        for li in fr.Feature.LookupListIndex:
            for st in base["GSUB"].table.LookupList.Lookup[li].SubTable:
                if hasattr(st, "mapping"):
                    subs.update(st.mapping)
chars = [chr(c) for c in range(32, 127)] + list(EXTRA)
lines = ["-- BEGIN GENERATED METRICS (tools/uikit/make_metrics.py) --",
         "-- Rubik advances in em/1000: ADV[weight] = {codepoint -> advance}; TNUM[weight] = tabular digit.",
         "local ADV: { [number]: { [number]: number } } = {}",
         "local TNUM: { [number]: number } = {}"]
for w in (400, 500, 600, 700, 800, 900):
    inst = instantiateVariableFont(TTFont(FONT), {"wght": w}, inplace=False)
    hm = inst["hmtx"].metrics
    pairs = []
    for c in chars:
        g = cmap.get(ord(c))
        if g is None:
            continue
        pairs.append(f"[{ord(c)}]={hm[g][0]}")
    tn = hm[subs[cmap[ord('0')]]][0]
    lines.append(f"ADV[{w}] = {{ {', '.join(pairs)} }}")
    lines.append(f"TNUM[{w}] = {tn}")
lines.append("-- END GENERATED METRICS --")
block = "\n".join(lines)
src = open(THEME).read()
pat = re.compile(r"-- BEGIN GENERATED METRICS.*?-- END GENERATED METRICS --", re.S)
if pat.search(src):
    src = pat.sub(lambda m: block, src)
else:
    raise SystemExit("marker block not found in UITheme.luau")
open(THEME, "w").write(src)
print("updated", THEME)
