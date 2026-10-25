#!/usr/bin/env python3
"""Contact sheet + verification for the UI icons (compares Roblox against the original SVGs).

Inputs:
  --studio  PNG capture of the AssetsIcons dev harness in Play mode (studio.py shot)
  --console text of the Studio console after the harness ran (studio.py console), which holds
            "[AssetsIcons] readback {json}" — per uploaded image: size + RGBA channel sums
Output:
  build/assets_contact_sheet.png  per icon: original SVG rendered at the on-screen px | the Roblox
                                  ImageLabel cropped from the capture | 24 px amber + 14 px cyan tints;
                                  with mean abs difference (0..255) between the first two.
  stdout: readback check (uploaded image bytes == local PNG) and the per-icon difference table.

Usage:
  .venv/bin/python tools/assets/contact_sheet.py --studio build/assets_icons_studio.png \
      --console <console.txt> [--out build/assets_contact_sheet.png]
Layout constants must match src/client/Dev/AssetsIcons.luau.
"""
import argparse
import io
import json
import os
import re
import sys

import numpy as np
import resvg_py
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_ui_icons as icons  # noqa: E402

ORIGIN, CELL_W, CELL_H, COLS = 16, 104, 92, 9
CELL_BG = (26, 33, 61)
PAGE_BG = (13, 19, 38)
AMBER = (255, 181, 71)
CYAN = (79, 209, 255)


def font(sz):
    for p in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(p):
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def svg_on(path, px, bg, tint=None):
    svg = open(path, encoding="utf-8").read()
    im = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg, width=px, height=px)))).convert("RGBA")
    if tint:
        a = np.asarray(im).copy()
        a[..., :3] = tint
        im = Image.fromarray(a, "RGBA")
    base = Image.new("RGBA", (px, px), bg + (255,))
    base.alpha_composite(im)
    return base.convert("RGB")


def scale_of(cap):
    a = np.asarray(cap.convert("RGB")).astype(int)
    m = (np.abs(a - np.array(CELL_BG)).sum(axis=2) <= 8)
    ys, xs = np.nonzero(m)
    if len(xs) == 0:
        raise SystemExit("no harness cells found in the capture")
    y0 = ys.min()
    x0 = xs[ys == y0].min()
    # starts of the cell runs along the first cell row's top edge (skips icon/label pixels)
    line = m[y0 + 3]
    starts = [x for x in range(1, len(line)) if line[x] and not line[x - 1]]
    if line[0]:
        starts.insert(0, 0)
    starts = [x for x in starts if x >= x0][:COLS]
    if len(starts) < COLS:
        raise SystemExit(f"found {len(starts)} cells in the first row, expected {COLS}")
    s = (starts[-1] - starts[0]) / ((COLS - 1) * CELL_W)
    return s, x0, y0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--studio", required=True)
    ap.add_argument("--console", required=True)
    ap.add_argument("--out", default=os.path.join(icons.ROOT, "build", "assets_contact_sheet.png"))
    args = ap.parse_args()

    srcs = {k: (p, colour) for k, p, colour in icons.sources()}
    keys = sorted(k for k in srcs if k != "app_icon")

    # 1) byte-level readback check
    txt = open(args.console, encoding="utf-8", errors="replace").read()
    m = re.search(r"\[AssetsIcons\] readback (\{.*\})", txt)
    rb = json.loads(m.group(1)) if m else {}
    bad = []
    for k in keys + ["app_icon"]:
        local = np.asarray(Image.open(os.path.join(icons.OUT, k + ".png")).convert("RGBA")).astype(np.int64)
        want = [int(local[..., c].sum()) for c in range(4)]
        got = rb.get(k)
        if not got or "sums" not in got:
            bad.append((k, "no readback: " + str(got)))
        elif got["sums"] != want or got["w"] != local.shape[1] or got["h"] != local.shape[0]:
            bad.append((k, f"differs: roblox {got} local {want}"))
    print(f"readback: {len(keys) + 1 - len(bad)}/{len(keys) + 1} uploaded images byte-identical to assets/ui_icons")
    for k, why in bad:
        print("  MISMATCH", k, why)

    # 2) visual comparison
    cap = Image.open(args.studio).convert("RGB")
    s, x0, y0 = scale_of(cap)
    ox, oy = x0 - ORIGIN * s, y0 - ORIGIN * s     # capture px of GUI offset (0,0)
    N = int(round(48 * s))

    def grab(gx, gy, px, ref):
        """Crop the ImageLabel at GUI offset (gx, gy) of px GUI size; best ±2 capture-px alignment."""
        n = ref.size[0]
        bx, by = int(round(ox + gx * s)), int(round(oy + gy * s))
        best = None
        r = np.asarray(ref, float)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                c = cap.crop((bx + dx, by + dy, bx + dx + n, by + dy + n))
                dv = float(np.abs(r - np.asarray(c, float)).mean())
                if best is None or dv < best[0]:
                    best = (dv, c)
        return best

    cw, ch = 2 * N + 6 + int(round(24 * s)) + 34, N + 30
    cols = 8
    rows = (len(keys) + cols) // cols
    sheet = Image.new("RGB", (cols * cw + 12, 64 + rows * ch + int(round(128 * s)) + 16), PAGE_BG)
    d = ImageDraw.Draw(sheet)
    f12, f16 = font(12), font(18)
    d.text((12, 10), f"AIRFRONT UI icons: original SVG (left) vs Roblox ImageLabel captured in Play mode (right) at 48 GUI px; "
                     f"Roblox tints at 24 / 14 GUI px (capture scale {s:.3f})", fill=(240, 244, 255), font=f16)
    d.text((12, 36), f"readback: {len(keys) + 1 - len(bad)}/{len(keys) + 1} uploaded images byte-identical to "
                     f"the generated PNGs; diff = mean |delta| (0..255) of the 48 px box after <=2 px alignment",
           fill=(174, 186, 219), font=f12)
    rows_out = []
    for i, k in enumerate(keys):
        col, row = i % cols, i // cols
        X, Y = 12 + col * cw, 64 + row * ch
        ci = keys.index(k)
        gx = ORIGIN + (ci % COLS) * CELL_W
        gy = ORIGIN + (ci // COLS) * CELL_H
        ref = svg_on(srcs[k][0], N, CELL_BG)
        diff, crop = grab(gx + 8, gy + 8, 48, ref)
        rows_out.append((k, diff))
        sheet.paste(ref, (X, Y))
        sheet.paste(crop, (X + N + 6, Y))
        t24 = svg_on(srcs[k][0], int(round(24 * s)), CELL_BG, AMBER)
        _, c24 = grab(gx + 64, gy + 8, 24, t24)
        t14 = svg_on(srcs[k][0], int(round(14 * s)), CELL_BG, CYAN)
        _, c14 = grab(gx + 64, gy + 40, 14, t14)
        sheet.paste(c24, (X + 2 * N + 12, Y))
        sheet.paste(c14, (X + 2 * N + 12, Y + c24.size[1] + 6))
        d.text((X, Y + N + 3), f"{k}  {diff:.1f}", fill=(174, 186, 219), font=f12)
    # app icon / logo mark at 128 GUI px
    n = int(round(128 * s))
    Y = 64 + rows * ch
    ref = svg_on(srcs["app_icon"][0], n, PAGE_BG)
    diff, crop = grab(ORIGIN + COLS * CELL_W + 16, ORIGIN, 128, ref)
    rows_out.append(("app_icon", diff))
    sheet.paste(ref, (12, Y))
    sheet.paste(crop, (12 + n + 8, Y))
    d.text((12 + 2 * n + 24, Y + 8), f"app_icon / logo_mark at 128 GUI px: SVG (left) vs Roblox (right)  diff {diff:.1f}",
           fill=(174, 186, 219), font=f12)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    sheet.save(args.out)
    print("contact sheet ->", os.path.relpath(args.out, icons.ROOT), f"(capture scale {s:.4f})")
    worst = sorted(rows_out, key=lambda r: -r[1])[:6]
    print("largest SVG-vs-Roblox differences:", ", ".join(f"{k} {v:.1f}" for k, v in worst))
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
