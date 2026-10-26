#!/usr/bin/env python3
"""Builds the two test-only fixture maps, tests/fixtures/maps/Pangaea.luau and Onion.luau (registered by id in
tests/fixtures/fixture_maps.luau; not in the game). Both are entirely ours:
  - pangaea (1000 x 1000): a window of our World map (src/shared/Data/Maps/World.luau, made by make_maps.py
    from public-domain data) from Iceland and West Africa to Japan and eastern Australia: Europe, Africa,
    Asia and Australia, with the Mediterranean, the Caspian, the Himalaya. The World rows south of 59.4 S
    (Antarctica) become open ocean. 29 nations: World's nations inside the window, kept spread apart.
  - onion (512 x 512): our own design, an onion cut in half: a hilly core and concentric rings of land
    and water (each layer its own relief), joined by land bridges, with channels letting the ocean into
    the outer water ring (the inner ones stay lakes). 3 nations: on the outer ring, an inner ring, the core.
Tiles are retyped (land = 0x80 | elevation magnitude, water = 0), then make_maps.postprocess works out
water bodies, shorelines and water depths (the tile byte format of WorldMap.luau).

Usage (from the repo root): .venv/bin/python tools/maps/make_fixtures.py [--out tests/fixtures/maps] [--preview DIR]
"""
import argparse
import base64
import math
import os
import re
import sys

import numpy as np
import zstandard

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_maps as mw  # noqa: E402

REPO = mw.REPO
LAND, SHORE, OCEAN = mw.LAND, mw.SHORE, mw.OCEAN

# pangaea: World columns X0 .. X0 + 999 (24.3 W .. 155.7 E), all rows; rows from SOUTH_CUT down
# (south of 59.4 S: Antarctica) turned to ocean.
PANGAEA_X0 = 800
PANGAEA_SOUTH_CUT = 820
PANGAEA_NATIONS = 29

# onion: centre, ring radii (tiles) and nations
ONION_N = 512
ONION_C = 256.0
CORE_R = 30  # hilly core: r < 30
RINGS = [  # (inner, outer) radius of each water ring; land between them
    (30, 38),
    (80, 88),
    (156, 168),
]
OUTER_R = 238  # ocean beyond
BRIDGES = [  # (water ring index, angle (radians, 0 = east, pi/2 = south), width in tiles): land across it
    (0, math.pi / 2, 9),
    (1, 0.4, 10),
    (1, 0.4 + math.pi, 10),
    (2, 2.2, 12),
    (2, -0.6, 12),
]
CHANNELS = [  # (angle, width, from radius, to radius): water across the outer land ring, one into each
    # stretch of the outer water ring between its bridges, so the whole ring is ocean
    (-math.pi / 2 - 0.35, 8, 160, 250),
    (0.9, 8, 160, 250),
]
ONION_NATIONS = [  # name, x, y
    ("Outer Layer", 51, 188),
    ("Inner Layer", 252, 199),
    ("Onion Heart", 252, 233),
]


def read_world():
    with open(os.path.join(REPO, "src", "shared", "Data", "Maps", "World.luau"), encoding="utf-8") as f:
        src = f.read()
    w = int(re.search(r"\twidth = (\d+),", src).group(1))
    h = int(re.search(r"\theight = (\d+),", src).group(1))
    raw = zstandard.ZstdDecompressor().decompress(base64.b64decode(re.search(r'terrain = "([^"]+)"', src).group(1)))
    grid = np.frombuffer(raw, np.uint8).reshape(h, w)
    nations = [{"name": n, "flag": fl, "x": int(x), "y": int(y)} for n, fl, x, y in
               re.findall(r'\{ name = "([^"]*)", flag = "([^"]*)", x = (\d+), y = (\d+) \}', src)]
    return grid, nations


def nearest_inland(grid, x, y, radius=40):
    """The nearest land tile not on the shore, or None."""
    h, w = grid.shape
    for r in range(radius + 1):
        for dy in range(-r, r + 1):
            for dx in (-r, r) if abs(dy) != r else range(-r, r + 1):
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and 0 <= yy < h and grid[yy, xx] & LAND and not grid[yy, xx] & SHORE:
                    return xx, yy
    return None


def spread(cands, count):
    """The first `count` candidates (in their order) kept at least G tiles apart, for the largest G that
    still gives `count`."""
    for gap in range(200, -1, -2):
        picked = []
        for c in cands:
            if all((c["x"] - p["x"]) ** 2 + (c["y"] - p["y"]) ** 2 >= gap * gap for p in picked):
                picked.append(c)
                if len(picked) == count:
                    return picked, gap
    raise SystemExit("only %d nation spots" % len(cands))


def build_pangaea():
    world, world_nations = read_world()
    crop = world[:, PANGAEA_X0:PANGAEA_X0 + 1000].copy()
    h, w = crop.shape
    land = (crop & LAND) != 0
    land[PANGAEA_SOUTH_CUT:, :] = False
    typed = np.where(land, LAND | (crop & 0x1F), 0).astype(np.uint8)
    tiles = mw.postprocess(typed.tobytes(), w, h)
    grid = np.frombuffer(tiles, np.uint8).reshape(h, w)
    cands = []
    for n in world_nations:
        x, y = n["x"] - PANGAEA_X0, n["y"]
        if 0 <= x < w and 0 <= y < PANGAEA_SOUTH_CUT:
            spot = nearest_inland(grid, x, y)
            if spot is not None:
                cands.append({"name": n["name"], "flag": n["flag"], "x": spot[0], "y": spot[1]})
    nations, gap = spread(cands, PANGAEA_NATIONS)
    print("pangaea: %d of %d World nations in the window, at least %d tiles apart" % (len(nations), len(cands), gap))
    return grid, int(land.sum()), nations


def build_onion():
    n = ONION_N
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float64)
    dx, dy = xx + 0.5 - ONION_C, yy + 0.5 - ONION_C
    theta = np.arctan2(dy, dx)
    # a lumpy circle: the rings bulge and pinch a little around
    r = np.hypot(dx, dy) / (1 + 0.025 * np.sin(3 * theta) + 0.015 * np.sin(5 * theta + 1.3))
    land = r < OUTER_R
    for a, b in RINGS:
        land &= ~((r >= a) & (r < b))

    def arc(angle, width):
        """Tiles within width / 2 of the ray from the centre at `angle`, beyond the centre."""
        return (np.abs(np.sin(theta - angle)) * np.hypot(dx, dy) < width / 2) & (np.cos(theta - angle) > 0)

    for ring, angle, width in BRIDGES:
        a, b = RINGS[ring]
        land |= arc(angle, width) & (r >= a - 1) & (r < b + 1)
    for angle, width, r0, r1 in CHANNELS:
        land &= ~(arc(angle, width) & (r >= r0) & (r < r1))

    # elevation magnitude (0-9 plains, 10-19 highland, 20-30 mountain), different on each layer
    mag = np.zeros((n, n))
    core = r < CORE_R
    mag[core] = 30 - r[core] / 2.5  # a mountain in the middle
    l1 = (r >= RINGS[0][1]) & (r < RINGS[1][0])
    mag[l1] = 5 + 4 * np.sin(3 * theta[l1] + r[l1] / 9)  # rolling plains
    l2 = (r >= RINGS[1][1]) & (r < RINGS[2][0])
    mag[l2] = 14 + 5 * np.sin(5 * theta[l2] + r[l2] / 12)  # highland
    l3 = r >= RINGS[2][1]
    # plains with a mountain ridge around the middle of the outer ring, broken by passes
    ridge = 18 * np.exp(-(((r - 203) / 7) ** 2)) * (np.sin(6 * theta + 0.5) < 0.6)
    mag[l3] = (3 + 3 * np.sin(4 * theta + r / 15) + ridge)[l3]
    typed = np.where(land, LAND | np.clip(np.floor(mag), 0, 30).astype(np.uint8), 0).astype(np.uint8)
    tiles = mw.postprocess(typed.tobytes(), n, n)
    grid = np.frombuffer(tiles, np.uint8).reshape(n, n)
    nations = []
    for name, x, y in ONION_NATIONS:
        spot = nearest_inland(grid, x, y)
        nations.append({"name": name, "flag": "", "x": spot[0], "y": spot[1]})
    return grid, int(land.sum()), nations


def write_module(path, header, info, grid, land_tiles, nations):
    h, w = grid.shape
    z = zstandard.ZstdCompressor(level=19, write_content_size=True).compress(grid.tobytes())
    lines = header + [
        "-- terrain = base64(zstd(width * height bytes)), the tile byte format of WorldMap.luau.",
        "return {",
        '\tid = "%s",' % info["id"],
        '\tname = "%s",' % info["name"],
        '\tmodule = "%s",' % info["name"],
        "\twidth = %d," % w,
        "\theight = %d," % h,
        "\tk_lin = 1.0,",
        "\tcategories = { %s }," % ", ".join(mw.lua_str(c) for c in info["categories"]),
        "\tmultiplayer_frequency = %d," % info["multiplayer_frequency"],
        "\tforced_modifiers = {},",
        "\tland_tiles = %d," % land_tiles,
        "\tnations = {",
    ]
    for nd in nations:
        lines.append("\t\t{ name = %s, flag = %s, x = %d, y = %d }," % (mw.lua_str(nd["name"]), mw.lua_str(nd["flag"]), nd["x"], nd["y"]))
    lines += [
        "\t},",
        '\tcodec = "zstd+base64",',
        "\tsize = %d," % (w * h),
        '\tterrain = "%s",' % base64.b64encode(z).decode("ascii"),
        "}",
        "",
    ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    lake = int((((grid & LAND) == 0) & ((grid & OCEAN) == 0)).sum())
    print("%s: %dx%d, %d land tiles, %d lake tiles, %d nations, %d KB zstd"
          % (info["name"], w, h, land_tiles, lake, len(nations), len(z) // 1024))


def preview(path, grid, nations):
    from PIL import Image, ImageDraw
    mag = grid & 0x1F
    img = np.zeros(grid.shape + (3,), np.uint8)
    water = (grid & LAND) == 0
    img[water] = np.stack([20 + 0 * mag[water], 60 - mag[water], 110 - mag[water] * 2], -1)
    img[water & ((grid & OCEAN) == 0)] = (70, 140, 210)
    lm = ~water
    img[lm] = np.stack([70 + mag[lm] * 5, 130 - mag[lm], 60 + mag[lm] * 2], -1).clip(0, 255)
    im = Image.fromarray(img)
    d = ImageDraw.Draw(im)
    for nd in nations:
        d.rectangle([nd["x"] - 3, nd["y"] - 3, nd["x"] + 3, nd["y"] + 3], fill=(255, 255, 255))
        d.text((nd["x"] + 5, nd["y"] - 6), nd["name"], fill=(255, 255, 255))
    im.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "tests", "fixtures", "maps"))
    ap.add_argument("--preview", help="also write PNGs of the maps into this folder")
    args = ap.parse_args()
    common = ["-- GENERATED by tools/maps/make_fixtures.py. Do not edit.",
              "-- A test-only map (tests/fixtures/fixture_maps.luau), not in the game."]
    grid, land_tiles, nations = build_pangaea()
    write_module(os.path.join(args.out, "Pangaea.luau"), common + [
        "-- Cut from our World map (src/shared/Data/Maps/World.luau, made from public-domain data): Europe, Africa,",
        "-- Asia and Australia, Antarctica left out; nations from World's.",
    ], {"id": "pangaea", "name": "Pangaea", "categories": ["fictional"], "multiplayer_frequency": 5},
        grid, land_tiles, nations)
    if args.preview:
        preview(os.path.join(args.preview, "Pangaea.png"), grid, nations)
    grid, land_tiles, nations = build_onion()
    write_module(os.path.join(args.out, "Onion.luau"), common + [
        "-- Our own design: an onion cut in half, a hilly core and rings of land and water (see make_fixtures.py).",
    ], {"id": "onion", "name": "Onion", "categories": ["arcade"], "multiplayer_frequency": 2},
        grid, land_tiles, nations)
    if args.preview:
        preview(os.path.join(args.preview, "Onion.png"), grid, nations)


if __name__ == "__main__":
    main()
