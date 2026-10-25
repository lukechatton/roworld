#!/usr/bin/env python3
"""The Arsenal previews' ground: a piece of a real map, drawn like a match, in place of solid background
colours (2026-10-24).

Each scene is a window of one of our maps (src/shared/Data/Maps, src/server/MapData), drawn the
way the game draws a match (Map/MapSurface): the terrain's colours, one pixel per tile, then the player's
land left of a border and a nation's right of it, each owner's colour blended over the land at 150/255
(saturation 0.85) with its border tiles opaque (HSL lightness - 0.125), water never owned and a coast a
border. The border is a column that wanders (smooth noise per row, the same in every frame of a scene).
Reinforcements has frames of its border advancing (`frames`), the client stepping through them.

The scenes are packed in one atlas (cells of CELL_W x CELL_H tiles, a 2-px gutter repeating each cell's
edge so a pixelated rect never samples its neighbour) and uploaded as the group (Open Cloud, the shop
flags' helpers), and src/shared/Assets/ArsenalMaps.luau points the game at it once Roblox's moderation
approved it (an image in review is blank for players).

The client (UI/ArsenalDemo) shows a rect of a cell with the scene's aspect: the whole cell's height (or
width, for a scene wider than the cell), placed so the border column lands at the scene's `split`.

Usage: .venv/bin/python tools/assets/make_arsenal_maps.py [--sheet] [--upload --group 421623341]
  --sheet   build/arsenal_maps_sheet.png: every scene at desktop and phone shape, 3x, with its marks
"""
import argparse
import base64
import math
import os
import random
import re
import sys

import numpy as np
import zstandard
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD = os.path.join(REPO, "build", "arsenal_maps")
MANIFEST = os.path.join(REPO, "src", "shared", "Assets", "ArsenalMaps.luau")

CELL_W, CELL_H = 192, 88
GUTTER = 2

# the player's colour and the nations' (owner colours, before the blend)
PLAYER = (150, 92, 226)
RED = (220, 68, 60)
ORANGE = (238, 132, 44)
TEAL = (40, 170, 170)

# key: map module, window (x, y), mirrored, the border's split of the scene, the nation's colour, where its
# land ends (`far`, of the cell; past it nobody's land or a `third` nation's), and the points of the
# scene the demo draws on (only for the sheet's marks: land under them, not water)
SCENES = {
    "mega": dict(map="Italia", at=(960, 638), flip=True, split=0.40, enemy=RED, far=0.84,
                 marks=[(0.15, 0.7), (0.72, 0.74), (0.72, 0.2)]),
    "scatter": dict(map="Balkans", at=(792, 814), flip=False, split=0.38, enemy=ORANGE, far=0.86,
                    third=TEAL,
                    marks=[(0.14, 0.7), (0.7, 0.62), (0.7, 0.2)]),
    "reinforce": dict(map="Italia", at=(96, 132), flip=False, split=0.44, enemy=RED, advance=22, frames=9,
                      marks=[(0.13, 0.8), (0.25, 0.8), (0.37, 0.8), (0.82, 0.66), (0.78, 0.2)]),
    "artillery": dict(map="Italia", at=(576, 352), flip=True, split=0.44, enemy=ORANGE, far=0.93, third=TEAL,
                      marks=[(0.3, 0.55), (0.86, 0.66), (0.6, 0.52), (0.7, 0.78), (0.74, 0.2)]),
    "airfield": dict(map="Europe", at=(816, 572), flip=False, split=0.40, enemy=RED, far=0.94,
                     marks=[(0.12, 0.72), (0.88, 0.7), (0.78, 0.2)]),
    "railgun": dict(map="Italia", at=(48, 220), flip=False, split=0.30, enemy=TEAL,
                    marks=[(0.11, 0.6), (0.66, 0.64), (0.62, 0.2)]),
    "reload2x": dict(map="Balkans", at=(96, 242), flip=False, split=0.68, enemy=RED,
                     marks=[(0.3, 0.35), (0.3, 0.7), (0.86, 0.35), (0.86, 0.7)]),
    # (the payout: the player's land only, darkened by the client)
    "stars2x": dict(map="Europe", at=(840, 990), flip=False, split=None, enemy=None, marks=[]),
}

# Map/MapSurface terrain colours
OCEAN = (0x47, 0x85, 0xB5)
SAND = (0xCC, 0xCB, 0x9E)
PLAINS = (0xBE, 0xDC, 0x8A)
HIGHLAND = (0xDC, 0xCB, 0x9E)
MOUNTAIN = (0xE6, 0xE6, 0xE6)
BACKGROUND = (0x3C, 0x3C, 0x3C)
ALPHA = 150 / 255
SATURATION = 0.85
BORDER_DARKEN = 0.125

_maps = {}


def load(mod):
    if mod in _maps:
        return _maps[mod]
    for d in ("src/shared/Data/Maps", "src/server/MapData"):
        p = os.path.join(REPO, d, mod + ".luau")
        if os.path.exists(p):
            s = open(p).read()
            w = int(re.search(r"\bwidth = (\d+)", s).group(1))
            h = int(re.search(r"\bheight = (\d+)", s).group(1))
            raw = zstandard.ZstdDecompressor().decompress(base64.b64decode(re.search(r'terrain = "([^"]+)"', s).group(1)))
            _maps[mod] = np.frombuffer(raw, np.uint8).reshape(h, w)
            return _maps[mod]
    sys.exit("no map " + mod)


def terrain(tb):
    """MapSurface.terrain_pixel for every tile: (h, w, 3) floats."""
    tb = tb.astype(np.int32)
    land, shore, mag = tb >= 128, (tb & 64) != 0, tb & 31
    out = np.zeros(tb.shape + (3,))
    m = np.minimum(mag, 10)
    for c in range(3):
        v = OCEAN[c] - m
        v = np.where(~land & shore, 0.7 * OCEAN[c] + 76.5, v)
        v = np.where(land & (mag < 10), PLAINS[c] - (2 * mag if c == 1 else 0), v)
        v = np.where(land & (mag >= 10) & (mag < 20), HIGHLAND[c] + 2 * (mag - 10), v)
        v = np.where(land & (mag >= 20) & (mag < 31), MOUNTAIN[c] + mag // 2, v)
        v = np.where(land & shore & (mag < 31), SAND[c], v)
        v = np.where(land & (mag == 31), BACKGROUND[c], v)
        out[..., c] = v
    return np.clip(np.floor(out + 0.5), 0, 255)


def hsl_darken(rgb, amount):
    import colorsys
    r, g, b = (x / 255 for x in rgb)
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    r, g, b = colorsys.hls_to_rgb(h, max(0.0, l - amount), s)
    return (r * 255, g * 255, b * 255)


def fill_of(rgb):
    r, g, b = (x / 255 for x in rgb)
    luma = r * 0.299 + g * 0.587 + b * 0.114
    return tuple((luma + (x - luma) * SATURATION) * 255 for x in (r, g, b))


def border_cols(key, base_x, rows):
    """The border's column for each row: base_x plus smooth noise (a few tiles), the same shape for every
    frame of the scene."""
    rnd = random.Random(key)
    waves = [(rnd.uniform(0.035, 0.06), rnd.uniform(0, 6.28), rnd.uniform(5.0, 7.0)),
             (rnd.uniform(0.1, 0.16), rnd.uniform(0, 6.28), rnd.uniform(2.0, 3.0)),
             (rnd.uniform(0.3, 0.45), rnd.uniform(0, 6.28), rnd.uniform(0.8, 1.2))]
    # (and a walk of single tiles, the ragged edge a front leaves)
    walk, out = 0.0, []
    for y in range(rows):
        walk = max(-2.0, min(2.0, walk + rnd.choice((-1, 0, 0, 1))))
        v = sum(a * math.sin(f * y + p) for f, p, a in waves) + walk
        out.append(int(round(base_x + v)))
    return out


def owners(key, sc, land, base_x):
    """Owner per tile of the window (with its 1-tile margin): 1 the player, 2 the nation, 0 nobody."""
    h, w = land.shape
    own = np.zeros((h, w), np.int8)
    if sc["split"] is None:
        own[land] = 1
        return own
    xs = np.arange(w)[None, :]
    mine = xs < np.array(border_cols(key, base_x, h))[:, None]
    own[land & mine] = 1
    own[land & ~mine] = 2
    if sc.get("far") is not None:
        # the nation's land ends at a second border, the land past it nobody's or a third nation's
        far = xs >= np.array(border_cols(key + "far", sc["far"] * CELL_W + 1, h))[:, None]
        own[land & far] = 3 if sc.get("third") is not None else 0
    return own


def compose(ter, own, colours):
    """Territory over the terrain (MapSurface.tile_pixel / composite): fills blended, borders opaque. The
    window has a 1-tile margin for the neighbours; returns the image without it."""
    h, w = own.shape
    img = ter.copy()
    pad = np.pad(own, 1, mode="edge")
    nbr = [pad[1:-1, :-2], pad[1:-1, 2:], pad[:-2, 1:-1], pad[2:, 1:-1]]
    for o, rgb in colours.items():
        mask = own == o
        border = mask & np.logical_or.reduce([n != o for n in nbr])
        fill = fill_of(rgb)
        bc = hsl_darken(rgb, BORDER_DARKEN)
        for c in range(3):
            img[..., c] = np.where(mask & ~border, ter[..., c] * (1 - ALPHA) + fill[c] * ALPHA, img[..., c])
            img[..., c] = np.where(border, bc[c], img[..., c])
    return np.clip(np.floor(img[1:-1, 1:-1] + 0.5), 0, 255).astype(np.uint8)


def window(sc):
    tb = load(sc["map"])
    x, y = sc["at"]
    win = tb[y - 1:y + CELL_H + 1, x - 1:x + CELL_W + 1]
    if win.shape != (CELL_H + 2, CELL_W + 2):
        sys.exit(f"{sc['map']} window {sc['at']} off the map")
    if sc["flip"]:
        win = win[:, ::-1]
    return win


def scene_images(key, sc):
    """The scene's frames (one unless it advances): (h, w, 3) uint8 each."""
    win = window(sc)
    ter = terrain(win)
    land = win >= 128
    colours = {1: PLAYER} if sc["split"] is None else {1: PLAYER, 2: sc["enemy"]}
    if sc.get("third") is not None:
        colours[3] = sc["third"]
    base = (sc["split"] or 0.5) * CELL_W + 1
    n = sc.get("frames", 1)
    out = []
    for k in range(n):
        bx = base + (sc.get("advance", 0) * k / max(1, n - 1))
        out.append(compose(ter, owners(key, sc, land, bx), colours))
    return out


def build():
    os.makedirs(BUILD, exist_ok=True)
    cells = []  # (key, frame, image)
    for key, sc in SCENES.items():
        for k, im in enumerate(scene_images(key, sc)):
            cells.append((key, k, im))
    cols = max(1, (1024 - 2 * GUTTER) // (CELL_W + 2 * GUTTER))
    rows = math.ceil(len(cells) / cols)
    sw, sh = CELL_W + 2 * GUTTER, CELL_H + 2 * GUTTER
    atlas = np.zeros((rows * sh, cols * sw, 3), np.uint8)
    placed = {}
    for i, (key, k, im) in enumerate(cells):
        cx, cy = (i % cols) * sw, (i // cols) * sh
        atlas[cy:cy + sh, cx:cx + sw] = np.pad(im, ((GUTTER, GUTTER), (GUTTER, GUTTER), (0, 0)), mode="edge")
        placed.setdefault(key, []).append((cx + GUTTER, cy + GUTTER))
    path = os.path.join(BUILD, "arsenal_maps.png")
    Image.fromarray(atlas).save(path, optimize=True)
    print(f"atlas {atlas.shape[1]}x{atlas.shape[0]}, {len(cells)} cells -> {path}")
    return path, placed, (atlas.shape[1], atlas.shape[0])


def rect(sc, aspect):
    """The client's rect of a cell for a scene of this aspect (w / h): (x, y, w, h) in tiles."""
    if aspect <= CELL_W / CELL_H:
        rh, rw = CELL_H, CELL_H * aspect
    else:
        rw, rh = CELL_W, CELL_W / aspect
    split = sc["split"] if sc["split"] is not None else 0.5
    return split * (CELL_W - rw), (CELL_H - rh) / 2, rw, rh


def sheet(placed, atlas_path):
    atlas = Image.open(atlas_path)
    shapes = [("desktop", 486 / 244), ("phone", 269 / 276)]
    S = 3
    tiles = []
    for key, sc in SCENES.items():
        for name, aspect in shapes:
            x0, y0 = placed[key][0]
            x, y, w, h = rect(sc, aspect)
            im = atlas.crop((int(x0 + x), int(y0 + y), int(x0 + x + w), int(y0 + y + h)))
            im = im.resize((int(w * S), int(h * S)), Image.NEAREST)
            d = ImageDraw.Draw(im)
            for fx, fy in sc["marks"]:
                cx, cy = fx * im.width, fy * im.height
                d.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], outline=(255, 255, 255), width=3)
            if sc["split"] is not None:
                d.line([(sc["split"] * im.width, 0), (sc["split"] * im.width, 12)], fill=(255, 255, 0), width=3)
            d.text((6, 4), f"{key} {name}", fill=(0, 0, 0))
            tiles.append(im)
    W = 2 * 600 + 30
    H = sum(max(a.height, b.height) + 10 for a, b in zip(tiles[::2], tiles[1::2]))
    out = Image.new("RGB", (W, H), (16, 18, 30))
    y = 0
    for a, b in zip(tiles[::2], tiles[1::2]):
        out.paste(a, (0, y))
        out.paste(b, (a.width + 20, y))
        y += max(a.height, b.height) + 10
    p = os.path.join(REPO, "build", "arsenal_maps_sheet.png")
    out.save(p)
    print("sheet ->", p)


def upload(path, group):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import make_shop_flags as sf
    sf.ua.CREATOR = {"groupId": str(group)}
    ids = sf.upload_sheets([path], f"g{group}:arsenal_maps", "the Arsenal's map previews")
    if not sf.wait_approved(ids):
        sys.exit("the atlas is not approved yet: the manifest still points at the old one; run again later")
    return ids[0]


def write_manifest(aid, placed, size):
    L = [
        "-- GENERATED by tools/assets/make_arsenal_maps.py. Do not edit.",
        "-- The Arsenal previews' ground: pieces of real maps (CC BY-SA 4.0, credited with the maps), drawn like a match.",
        "-- cell: a scene's size in the atlas (tiles = px); scenes[key]: its cells (one per frame, top left)",
        "-- and its border's split of the scene (nil: the player's land only).",
        "return {",
        f'\tid = "rbxassetid://{aid}",',
        f"\tsize = Vector2.new({size[0]}, {size[1]}),",
        f"\tcell = Vector2.new({CELL_W}, {CELL_H}),",
        "\tscenes = {",
    ]
    for key, sc in SCENES.items():
        frames = ", ".join(f"Vector2.new({x}, {y})" for x, y in placed[key])
        split = "nil" if sc["split"] is None else repr(sc["split"])
        enemy = "nil" if sc["enemy"] is None else "Color3.fromRGB(%d, %d, %d)" % sc["enemy"]
        adv = sc.get("advance", 0)
        L.append(f"\t\t{key} = {{ frames = {{ {frames} }}, split = {split}, enemy = {enemy}, advance = {adv} }},")
    L += ["\t},", "\tplayer = Color3.fromRGB(%d, %d, %d)," % PLAYER, "}"]
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", MANIFEST)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--group", type=int, default=421623341)
    args = ap.parse_args()
    path, placed, size = build()
    if args.sheet:
        sheet(placed, path)
    if args.upload:
        aid = upload(path, args.group)
        write_manifest(aid, placed, size)


if __name__ == "__main__":
    main()
