#!/usr/bin/env python3
"""Map-picker thumbnails rendered from each map's own terrain data (re-runnable).

Every map in the registry (src/shared/Data/MapList.luau) is decoded from its data module
(src/server/MapData/<Module>.luau, or src/shared/Data/Maps/<Module>.luau for the replicated default
map: terrain = base64(zstd(width * height tile bytes)), the byte format of Core/WorldMap.luau) and
drawn in the in-game terrain palette (Map/MapSurface.luau terrain_pixel: water darkening with the
distance from the coast, the lighter shoreline water and sand coast, plains / highland / mountain
ramps). Two departures, both for reading at card size:
  * open water keeps darkening a little past the game's cap (DEEP_RAMP), so coasts and islands
    stand out;
  * impassable terrain is transparent: the game draws it in the map's background colour, so on a
    card the card itself is that background and the playable area keeps its real outline.
The full-resolution picture is averaged down in linear light (premultiplied by coverage) to fit
within 512 px (aspect kept) and its corners are rounded. Shown at the picker's card size
(~152 x 86 px) and on the title screen's 58 x 40 match card.

Outputs:
  build/map_thumbs/<id>.png          one per map
  src/shared/Assets/MapThumbs.luau   GENERATED { <map id> = "rbxassetid://..." } (UIMaps joins on
                                     its normalised id)

Usage:
  STUDIO_MATCH=mapart.rbxl .venv/bin/python tools/assets/make_map_thumbs.py [--no-upload]
      [--only world,europe] [--sheet <contact_sheet.png>]
Uploads go through tools/upload.py (content-hash cached: unchanged renders are not re-uploaded).
"""
import argparse
import base64
import os
import re
import sys

import numpy as np
import zstandard
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MAPLIST = os.path.join(ROOT, "src", "shared", "Data", "MapList.luau")
DATA_DIRS = [os.path.join(ROOT, "src", "server", "MapData"), os.path.join(ROOT, "src", "shared", "Data", "Maps")]
OUT = os.path.join(ROOT, "build", "map_thumbs")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "MapThumbs.luau")

MAX_PX = 512
IMPASSABLE = 0x9F
CORNER = 0.035  # corner radius as a fraction of the long side
DEEP_RAMP = 0.6  # extra darkening per water-distance step past the game's 10 (open water up to -22.6)

# Map/MapSurface.luau terrain colours
OCEAN = (0x47, 0x85, 0xB5)
SAND = (0xCC, 0xCB, 0x9E)
PLAINS = (0xBE, 0xDC, 0x8A)
HIGHLAND = (0xDC, 0xCB, 0x9E)
MOUNTAIN = (0xE6, 0xE6, 0xE6)
BACKGROUND = (0x3C, 0x3C, 0x3C)


def terrain_rgb(tb):
    """RGB of terrain byte `tb`, as MapSurface.terrain_pixel draws it."""
    land, shore, mag = tb >= 128, (tb & 64) != 0, tb & 31
    if land and mag == 31:
        c = BACKGROUND
    elif land and shore:
        c = SAND
    elif land:
        if mag < 10:
            c = (PLAINS[0], PLAINS[1] - 2 * mag, PLAINS[2])
        elif mag < 20:
            m = mag - 10
            c = (HIGHLAND[0] + 2 * m, HIGHLAND[1] + 2 * m, HIGHLAND[2] + 2 * m)
        else:
            m = mag // 2
            c = (MOUNTAIN[0] + m, MOUNTAIN[1] + m, MOUNTAIN[2] + m)
    elif shore:
        c = tuple(0.7 * v + 76.5 for v in OCEAN)
    else:
        # the game's ramp to 10, then DEEP_RAMP more per step: the shelf reads at card size
        m = min(mag, 10) + DEEP_RAMP * max(0, mag - 10)
        c = (OCEAN[0] - m, OCEAN[1] - m, OCEAN[2] - m)
    return tuple(min(255, max(0, int(v + 0.5))) for v in c)


LUT = np.array([terrain_rgb(b) for b in range(256)], dtype=np.uint8)


def read_registry():
    """[{id, name, module}] in registry order."""
    src = open(MAPLIST, encoding="utf-8").read()
    body = src[src.index("MapList.maps = {"):]
    rows = []
    for m in re.finditer(r'\{ id = "([^"]+)", name = "((?:[^"\\]|\\.)*)", module = "([^"]+)",', body):
        name = re.sub(r"\\(.)", r"\1", m.group(2))
        rows.append({"id": m.group(1), "name": name, "module": m.group(3)})
    if not rows:
        raise SystemExit("no maps found in " + MAPLIST)
    return rows


def read_terrain(module):
    """(width, height, uint8 array [h, w]) of a map data module."""
    for d in DATA_DIRS:
        p = os.path.join(d, module + ".luau")
        if os.path.exists(p):
            break
    else:
        raise FileNotFoundError("no data module for " + module)
    src = open(p, encoding="utf-8").read()
    w = int(re.search(r"^\twidth = (\d+),", src, re.M).group(1))
    h = int(re.search(r"^\theight = (\d+),", src, re.M).group(1))
    b64 = re.search(r'^\tterrain = "([^"]*)",', src, re.M).group(1)
    raw = zstandard.ZstdDecompressor().decompress(base64.b64decode(b64), max_output_size=w * h)
    if len(raw) != w * h:
        raise ValueError("%s: %d tile bytes, expected %d x %d" % (module, len(raw), w, h))
    return w, h, np.frombuffer(raw, dtype=np.uint8).reshape(h, w)


def _to_linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255.0


def render(tiles):
    """RGBA thumbnail of a terrain grid: palette at full resolution, area-averaged in linear light
    to fit MAX_PX (impassable tiles transparent), rounded corners."""
    h, w = tiles.shape
    s = min(MAX_PX / w, MAX_PX / h)
    tw, th = max(1, round(w * s)), max(1, round(h * s))

    def shrink(a):
        return np.asarray(Image.fromarray(a, mode="F").resize((tw, th), Image.Resampling.BOX))

    cover = (tiles != IMPASSABLE).astype(np.float32)
    lin = _to_linear(LUT[tiles].astype(np.float32)) * cover[:, :, None]
    alpha = shrink(cover)
    rgb = np.stack([shrink(np.ascontiguousarray(lin[:, :, k])) for k in range(3)], axis=2)
    rgb = _to_srgb(rgb / np.maximum(alpha, 1e-6)[:, :, None])
    # rounded corners, antialiased (drawn 4x and averaged down)
    r = min(CORNER * max(tw, th), min(tw, th) * 0.3)
    corner = np.ones((th, tw), dtype=np.float32)
    if r >= 1:
        k = 4
        mask = Image.new("L", (tw * k, th * k), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, tw * k - 1, th * k - 1), radius=r * k, fill=255)
        corner = np.asarray(mask.resize((tw, th), Image.Resampling.BOX), dtype=np.float32) / 255.0
    a = np.clip(alpha, 0.0, 1.0) * corner * 255.0
    rgba = np.concatenate([np.round(rgb), np.round(a)[:, :, None]], axis=2)
    rgba[rgba[:, :, 3] == 0, :3] = 0
    return Image.fromarray(rgba.astype(np.uint8), "RGBA")


def write_manifest(rows, uris):
    lines = [
        "-- GENERATED by tools/assets/make_map_thumbs.py. Do not edit.",
        "-- Map thumbnails rendered from each map's own terrain data (its data module, in the in-game",
        "-- terrain palette), fit within 512 px. Keys = the registry's map ids.",
        "return {",
    ]
    for r in sorted(rows, key=lambda r: r["id"]):
        key = r["id"] if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", r["id"]) else '["%s"]' % r["id"]
        lines.append('\t%s = "%s",' % (key, uris[r["id"]]))
    lines += ["}", ""]
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def contact_sheet(rows, paths, out_path, cell=(220, 170), cols=8):
    """All thumbnails on a dark page (the picker's card colours) with their names."""
    cw, ch = cell
    n = len(rows)
    page = Image.new("RGB", (cols * cw + 16, ((n + cols - 1) // cols) * ch + 16), (13, 19, 38))
    draw = ImageDraw.Draw(page)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 13)
    except OSError:
        font = ImageFont.load_default()
    for i, r in enumerate(rows):
        x0, y0 = 8 + (i % cols) * cw, 8 + (i // cols) * ch
        draw.rounded_rectangle((x0 + 4, y0 + 4, x0 + cw - 4, y0 + ch - 4), radius=10, fill=(26, 33, 61))
        im = Image.open(paths[r["id"]])
        box_w, box_h = cw - 24, ch - 44
        s = min(box_w / im.width, box_h / im.height)
        im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.Resampling.LANCZOS)
        page.paste(im, (x0 + 12 + (box_w - im.width) // 2, y0 + 12 + (box_h - im.height) // 2), im)
        draw.text((x0 + 12, y0 + ch - 28), r["name"], fill=(255, 255, 255), font=font)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    page.save(out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-upload", action="store_true", help="render only (MapThumbs.luau unchanged)")
    ap.add_argument("--only", help="comma-separated map ids to render (implies --no-upload)")
    ap.add_argument("--sheet", help="also write a contact sheet of the renders to this path")
    args = ap.parse_args()

    rows = read_registry()
    if args.only:
        want = set(args.only.split(","))
        rows = [r for r in rows if r["id"] in want]
    os.makedirs(OUT, exist_ok=True)
    paths, failed = {}, []
    for r in rows:
        try:
            w, h, tiles = read_terrain(r["module"])
            im = render(tiles)
        except Exception as e:  # noqa: BLE001 - report every map that fails, then stop
            failed.append(r["id"])
            print("FAILED %-22s %s" % (r["id"], e))
            continue
        p = os.path.join(OUT, r["id"] + ".png")
        im.save(p, optimize=True)
        paths[r["id"]] = p
        print("%-22s %5d x %-5d -> %3d x %-3d" % (r["id"], w, h, im.width, im.height))
    print("rendered %d / %d maps into %s" % (len(paths), len(rows), os.path.relpath(OUT, ROOT)))
    if args.sheet:
        contact_sheet([r for r in rows if r["id"] in paths], paths, args.sheet)
        print("contact sheet:", args.sheet)
    if failed:
        raise SystemExit("not rendered: " + ", ".join(failed))
    if args.no_upload or args.only:
        return

    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import upload  # noqa: E402,PLC0415
    res = upload.upload_images([paths[r["id"]] for r in rows])
    uris = {r["id"]: res[os.path.abspath(paths[r["id"]])] for r in rows}
    write_manifest(rows, uris)
    print("wrote %s (%d thumbnails)" % (os.path.relpath(MANIFEST, ROOT), len(uris)))


if __name__ == "__main__":
    main()
