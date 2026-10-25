#!/usr/bin/env python3
"""Country flags for the cosmetic crates (src/shared/Data/Cosmetics.luau): assets/flags/*.svg
(OpenFront's resources/flags, CC BY-SA 4.0, see assets/flags/SOURCE.txt) rendered to fit a
FLAG_W x FLAG_H box (aspect kept), packed PER_ATLAS to an atlas image (COLS x ROWS cells of
CELL_W x CELL_H; several atlases so one moderation problem can't take every flag down), uploaded as
the group with Open Cloud (upload_audio.py's uploader, asset type Image) and written to
src/shared/Assets/Flags.luau:

  { atlases = { "rbxassetid://..", ... },
    flags = { { code = "us", name = "United States", atlas = 1, x = .., y = .., w = .., h = .. }, ... } }

(x, y, w, h: the flag's pixel rect in its atlas, for ImageRectOffset / ImageRectSize.)

Usage: .venv/bin/python tools/assets/make_flags.py --group 421623341 [--no-upload]
"""
import argparse
import hashlib
import io
import json
import os
import sys
import time

import resvg_py
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upload_audio as ua  # noqa: E402

ROOT = ua.ROOT
SRC = os.path.join(ROOT, "assets", "flags")
OUT = os.path.join(ROOT, "build", "flags")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "Flags.luau")
FORMAT = "flags-v2"
FLAG_W, FLAG_H = 116, 76
CELL_W, CELL_H = 120, 80
COLS, ROWS = 8, 8
PER_ATLAS = COLS * ROWS


def render(path):
    """The flag fit into FLAG_W x FLAG_H (RGBA). OpenFront's SVGs are square canvases with the flag
    inside (transparent margins): render big, trim to the opaque part, then fit the box."""
    svg = open(path, encoding="utf-8").read()
    png = bytes(resvg_py.svg_to_bytes(svg_string=svg, width=FLAG_W * 3))
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    box = im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if box:
        im = im.crop(box)
    im.thumbnail((FLAG_W, FLAG_H), Image.LANCZOS)
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="", help="upload as this group id")
    ap.add_argument("--no-upload", action="store_true")
    args = ap.parse_args()
    prefix = ""
    if args.group:
        ua.CREATOR = {"groupId": str(args.group)}
        prefix = f"g{args.group}:"
    names = json.load(open(os.path.join(SRC, "names.json"), encoding="utf-8"))
    # the country codes (two letters) first, then regional flags (e.g. california) — added flags go at
    # the end, so the atlases before them stay the same (no re-upload, no new moderation)
    have = [c for c in names if os.path.exists(os.path.join(SRC, c + ".svg"))]
    codes = sorted(c for c in have if len(c) == 2) + sorted(c for c in have if len(c) != 2)
    os.makedirs(OUT, exist_ok=True)
    atlases, rects = [], []
    for a in range((len(codes) + PER_ATLAS - 1) // PER_ATLAS):
        sheet = Image.new("RGBA", (COLS * CELL_W, ROWS * CELL_H), (0, 0, 0, 0))
        for k, code in enumerate(codes[a * PER_ATLAS:(a + 1) * PER_ATLAS]):
            im = render(os.path.join(SRC, code + ".svg"))
            cx, cy = (k % COLS) * CELL_W, (k // COLS) * CELL_H
            x = cx + (CELL_W - im.width) // 2
            y = cy + (CELL_H - im.height) // 2
            sheet.alpha_composite(im, (x, y))
            rects.append({"code": code, "name": names[code], "atlas": a + 1, "x": x, "y": y, "w": im.width, "h": im.height})
        # trim empty rows of the last sheet
        used = min(ROWS, (len(codes) - a * PER_ATLAS + COLS - 1) // COLS)
        sheet = sheet.crop((0, 0, COLS * CELL_W, used * CELL_H))
        p = os.path.join(OUT, f"flags_{a + 1}.png")
        sheet.save(p, optimize=True)
        atlases.append(p)
    print(f"{len(codes)} flags in {len(atlases)} atlases -> {os.path.relpath(OUT, ROOT)}")
    if args.no_upload:
        return
    cache = ua.load_cache()
    ids, failures = [], []
    for p in atlases:
        digest = hashlib.sha256(open(p, "rb").read()).hexdigest()
        ck = f"{prefix}{FORMAT}:{digest}"
        e = cache.get(ck) or {}
        aid = e.get("asset_id")
        if aid is None:
            label = "Rofront flags " + os.path.basename(p)[:-4]
            try:
                op_id = e.get("pending_op")
                if not op_id:
                    op_id = ua.upload_start(p, label, "Rofront country flags (from OpenFront, CC BY-SA 4.0)", "Image")
                    cache[ck] = {"pending_op": op_id, "name": label}
                    ua.save_cache(cache)
                aid, resp = ua.upload_wait(op_id)
            except ua.ApiError as ex:
                print(f"{p}: FAILED {ex}")
                failures.append(p)
                ids.append(None)
                continue
            mod = (resp.get("moderationResult") or {}).get("moderationState", "?")
            cache[ck] = {"asset_id": aid, "name": label, "moderation": mod, "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
            ua.save_cache(cache)
            print(f"{os.path.basename(p)}: rbxassetid://{aid} moderation={mod}")
        ids.append(aid)
    if failures:
        sys.exit(1)
    L = [
        "-- GENERATED by tools/assets/make_flags.py — do not edit by hand.",
        "-- Country flags (CC BY-SA 4.0, credited on the title screen) packed in atlases; each flag's pixel rect",
        "-- in its atlas (ImageRectOffset = x, y; ImageRectSize = w, h).",
        "return {",
        "\tatlases = {",
    ]
    for aid in ids:
        L.append(f'\t\t"rbxassetid://{aid}",')
    L += ["\t},", "\tflags = {"]
    for r in rects:
        name = r["name"].replace("\\", "\\\\").replace('"', '\\"')
        L.append(f'\t\t{{ code = "{r["code"]}", name = "{name}", atlas = {r["atlas"]}, x = {r["x"]}, y = {r["y"]}, w = {r["w"]}, h = {r["h"]} }},')
    L += ["\t},", "}"]
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print(f"manifest: {len(rects)} flags -> {os.path.relpath(MANIFEST, ROOT)}")


if __name__ == "__main__":
    main()
