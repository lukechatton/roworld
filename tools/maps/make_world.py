#!/usr/bin/env python3
"""Builds the World map from public-domain data: src/shared/Data/Maps/World.luau, and the map registry
src/shared/Data/MapList.luau with World as the only map. Run with the repo's .venv/bin/python (numpy,
scipy, Pillow, zstandard).

Sources (public domain), downloaded into build/worldsrc/ on the first run:
  - Natural Earth (naturalearthdata.com, via github.com/nvkelso/natural-earth-vector): 1:10m land and
    lakes; 1:50m countries (names, ISO codes, population, label points).
  - NOAA ETOPO1 (ice surface), sampled every 6 arc-minutes through NOAA's ERDDAP server.

Projection: equirectangular, W / 360 tiles per degree both ways, placed where the earlier World map was
(the tests' Earth-grid fit in tests/simsys_fixture.luau and tests/world_places.luau: x = (lon + 180) * W / 360
- 65, y = (90 - lat) * W / 360 - 10), so the left edge is at 168.3 W (the Bering Strait) and the top row at
88.2 N; Antarctica fills the bottom rows.
A tile is land when most of its SS x SS sample points are. Its elevation class comes from the mean ETOPO
height of its land samples: 0-300 m plains (0-9), 300-1200 m highland (10-19), higher mountain (20-30).
Then water bodies, shorelines and water depths are worked out as the game expects (the tile byte format in
WorldMap.luau: bit 7 land, bit 6 shoreline, bit 5 ocean, bits 0-4 magnitude).

Nations: a few big thinly peopled regions (REGIONS), then the most populous countries that have a flag,
each at its point (Natural Earth's label point for a country) or the nearest inland tile, leaving out one
within MIN_GAP tiles of one already placed. STRAITS too narrow for this scale are opened as channels.

Usage (from the repo root): .venv/bin/python tools/maps/make_world.py [--src build/worldsrc] [--nations 71]
"""
import argparse
import base64
import collections
import json
import math
import os
import urllib.request

import numpy as np
import zstandard
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.io import netcdf_file

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
W, H = 2000, 1000
SS = 3  # sample points per tile side
PPD = W / 360.0  # tiles per degree
LON0 = -180.0 + 65 / PPD  # longitude of the left edge
LAT_TOP = 90.0 - 10 / PPD  # latitude of the top edge
MIN_GAP = 30  # tiles between two nations' spawns
# left out: names Roblox's text moderation may flag (2026-09-26), as before
EXCLUDED_NATIONS = {"Niger"}
NAMES = {  # Natural Earth's NAME_LONG -> the name shown in game
    "Russian Federation": "Russia",
    "Republic of Korea": "South Korea",
    "Dem. Rep. Korea": "North Korea",
    "Lao PDR": "Laos",
    "Democratic Republic of the Congo": "DR Congo",
    "Republic of the Congo": "Congo",
    "Côte d'Ivoire": "Ivory Coast",
    "Czech Republic": "Czechia",
    "Syrian Arab Republic": "Syria",
    "Turkey": "Türkiye",
}
# Regions given a nation of their own, so big thinly peopled lands get a spawn too: name, flag, lon, lat.
REGIONS = [
    ("Alaska", "us", -152.0, 64.5),
    ("Yukon", "ca", -134.0, 63.0),
    ("Nunavut", "ca", -96.0, 65.0),
    ("Quebec", "ca", -72.0, 52.0),
    ("California", "california", -119.5, 37.0),
    ("Texas", "us", -99.0, 31.5),
    ("Greenland", "gl", -40.0, 72.0),
    ("Siberia", "ru", 98.0, 63.0),
    ("Yakutia", "ru", 128.0, 64.0),
    ("Kamchatka", "ru", 159.0, 56.5),
    ("Mongolia", "mn", 103.0, 46.8),
    ("Western Australia", "au", 121.0, -25.5),
    ("Patagonia", "ar", -69.0, -45.5),
    ("West Antarctica", "aq", -110.0, -78.0),
    ("Antarctica", "aq", 10.0, -76.0),
    ("East Antarctica", "aq", 120.0, -74.0),
]
# Narrow straits that close at this scale (a tile is about 20 km), opened as 1-tile channels so the
# Mediterranean, the Black Sea, the Sea of Azov, the Red Sea and the Baltic stay connected to the ocean:
# lon/lat polylines.
STRAITS = [
    [(-6.4, 35.95), (-5.6, 35.97), (-4.9, 36.05)],  # Gibraltar
    [(42.9, 13.3), (43.4, 12.6), (43.9, 12.3)],  # Bab-el-Mandeb
    [(26.1, 40.0), (26.7, 40.4), (27.5, 40.7), (28.9, 40.95), (29.1, 41.3)],  # Dardanelles, Marmara, Bosphorus
    [(36.6, 45.5), (36.6, 45.1)],  # Kerch
    [(11.6, 57.0), (12.3, 56.3), (12.65, 55.9), (12.8, 55.3)],  # Kattegat, Øresund
]
NE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
SOURCES = {
    "ne_10m_land.geojson": NE + "ne_10m_land.geojson",
    "ne_10m_lakes.geojson": NE + "ne_10m_lakes.geojson",
    "ne_50m_admin_0_countries.geojson": NE + "ne_50m_admin_0_countries.geojson",
    "etopo.nc": "https://coastwatch.pfeg.noaa.gov/erddap/griddap/etopo180.nc"
    "?altitude%5B(-90.0):6:(90.0)%5D%5B(-180.0):6:(180.0)%5D",
}
LAKE_MAX_SCALERANK = 3
# Islands smaller than this (tiles) become sea and lakes smaller than this become land (2026-10-26: the
# hundreds of 1-20 tile islands and lakes got in the way of play; the map before had none that small).
MIN_ISLAND = 21
MIN_LAKE = 21
FOUR = [[0, 1, 0], [1, 1, 1], [0, 1, 0]]
LICENSE = "Public domain"
ATTRIBUTION = "Natural Earth, NOAA"
CREDITS = "World map made with Natural Earth and NOAA ETOPO1 data (public domain)."

LAND = 0x80
SHORE = 0x40
OCEAN = 0x20
IMPASSABLE = 0x9F

def project(lon, lat):
    """lon/lat arrays -> tile coordinates (x unwrapped: west of LON0 gives a small negative x)."""
    return (np.asarray(lon, dtype=np.float64) - LON0) * PPD, (LAT_TOP - np.asarray(lat, dtype=np.float64)) * PPD


def unproject(x, y):
    """Tile coordinates -> lon (wrapped to -180..180), lat (the rows past the South Pole read the pole)."""
    lon = LON0 + np.asarray(x) / PPD
    lat = np.maximum(LAT_TOP - np.asarray(y) / PPD, -89.95)
    return (lon + 180.0) % 360.0 - 180.0, lat


def fetch(src):
    os.makedirs(src, exist_ok=True)
    for name, url in SOURCES.items():
        path = os.path.join(src, name)
        if not os.path.exists(path):
            print("downloading", name)
            urllib.request.urlretrieve(url, path + ".part")
            os.replace(path + ".part", path)


def polygons(path):
    with open(path, encoding="utf-8") as f:
        features = json.load(f)["features"]
    for feat in features:
        g = feat["geometry"]
        if g is None:
            continue
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for rings in polys:
            yield feat["properties"], rings


def ring_area(ring):
    a = np.asarray(ring)
    return abs(np.dot(a[:, 0], np.roll(a[:, 1], 1)) - np.dot(a[:, 1], np.roll(a[:, 0], 1))) / 2


def draw_rings(draw, rings, fill, hole_fill):
    """Exterior ring then its holes, at x and, for rings west of the seam, x + 360 degrees."""
    for i, ring in enumerate(rings):
        a = np.asarray(ring)
        x, y = project(a[:, 0], a[:, 1])
        for shift in (0.0, W) if x.min() < 0 else (0.0,):
            pts = list(zip(((x + shift) * SS).tolist(), (y * SS).tolist()))
            if len(pts) >= 3:
                draw.polygon(pts, fill=fill if i == 0 else hole_fill)


def land_samples(src):
    """Bool (H*SS, W*SS): land at each sample point."""
    img = Image.new("L", (W * SS, H * SS), 0)
    draw = ImageDraw.Draw(img)
    # biggest first, so an island inside another polygon's hole is drawn after the hole
    land = sorted(polygons(os.path.join(src, "ne_10m_land.geojson")), key=lambda p: -ring_area(p[1][0]))
    for _, rings in land:
        draw_rings(draw, rings, 1, 0)
    lakes = [p for p in polygons(os.path.join(src, "ne_10m_lakes.geojson"))
             if (p[0].get("scalerank") or 99) <= LAKE_MAX_SCALERANK]
    for _, rings in sorted(lakes, key=lambda p: -ring_area(p[1][0])):
        draw_rings(draw, rings, 0, 1)
    out = np.array(img, dtype=bool)
    # the rows past the South Pole: Antarctica
    pole = int(project(0.0, -90.0)[1] * SS)
    out[max(pole - SS, 0):, :] = True
    return out


def elevation_samples(src):
    """ETOPO height (m) at each sample point (nearest grid value)."""
    with netcdf_file(os.path.join(src, "etopo.nc"), "r", mmap=False) as nc:
        lats = np.array(nc.variables["latitude"][:], dtype=np.float64)
        lons = np.array(nc.variables["longitude"][:], dtype=np.float64)
        alt = np.array(nc.variables["altitude"][:], dtype=np.float64)
    xs = (np.arange(W * SS) + 0.5) / SS
    ys = (np.arange(H * SS) + 0.5) / SS
    lon, _ = unproject(xs, np.zeros_like(xs))
    _, lat = unproject(np.zeros_like(ys), ys)
    i = np.clip(np.rint((lat - lats[0]) / (lats[1] - lats[0])).astype(int), 0, len(lats) - 1)
    j = np.clip(np.rint((lon - lons[0]) / (lons[1] - lons[0])).astype(int), 0, len(lons) - 1)
    return alt[i[:, None], j[None, :]]


def magnitude(elev):
    e = np.clip(elev, 0, None)
    m = np.where(e < 300, e / 300 * 10, np.where(e < 1200, 10 + (e - 300) / 900 * 10,
                                                 20 + np.clip((e - 1200) / 2800, 0, 1) * 10))
    return np.clip(np.floor(m), 0, 30).astype(np.uint8)


def carve_straits(land):
    for line in STRAITS:
        x, y = project([p[0] for p in line], [p[1] for p in line])
        prev = None
        for i in range(len(line) - 1):
            steps = int(max(abs(x[i + 1] - x[i]), abs(y[i + 1] - y[i])) * 5) + 1
            for s in range(steps + 1):
                tx = int(x[i] + (x[i + 1] - x[i]) * s / steps)
                ty = int(y[i] + (y[i + 1] - y[i]) * s / steps)
                land[ty, tx] = False
                if prev is not None and prev[0] != tx and prev[1] != ty:
                    land[prev[1], tx] = False  # keep the channel 4-connected
                prev = (tx, ty)


def tidy(land):
    """Drops islands under MIN_ISLAND tiles and fills lakes (water bodies other than the largest) under
    MIN_LAKE tiles, in place. Returns the mask of the filled lake tiles."""
    lab, _ = ndimage.label(land, structure=FOUR)
    small = np.bincount(lab.ravel()) < MIN_ISLAND
    small[0] = False
    land[small[lab]] = False
    lab, _ = ndimage.label(~land, structure=FOUR)
    sizes = np.bincount(lab.ravel())
    sizes[0] = 0
    small = sizes < MIN_LAKE
    small[0] = False
    small[int(np.argmax(sizes))] = False  # the ocean
    filled = small[lab]
    land[filled] = True
    return filled


def postprocess(tiles, w, h):
    """Water bodies (the largest is the ocean), shoreline bits on land and water next to each other,
    and water magnitude = ceil(distance from the shoreline water / 2), capped at 31."""
    n = w * h
    is_water = bytearray(1 if (b & LAND) == 0 else 0 for b in tiles)
    label = [0] * n
    sizes = [0]
    cur = 0
    for start in range(n):
        if not is_water[start] or label[start]:
            continue
        cur += 1
        label[start] = cur
        stack = [start]
        size = 0
        while stack:
            t = stack.pop()
            size += 1
            x = t % w
            for u, ok in ((t - 1, x > 0), (t + 1, x < w - 1), (t - w, t >= w), (t + w, t < n - w)):
                if ok and is_water[u] and not label[u]:
                    label[u] = cur
                    stack.append(u)
        sizes.append(size)
    ocean = max(range(1, cur + 1), key=lambda i: sizes[i]) if cur else 0
    dist = [-1] * n
    queue = collections.deque()
    out = bytearray(n)
    for t in range(n):
        b = tiles[t]
        x = t % w
        near = [u for u, ok in ((t - 1, x > 0), (t + 1, x < w - 1), (t - w, t >= w), (t + w, t < n - w)) if ok]
        if b & LAND:
            out[t] = b | SHORE if any(is_water[u] for u in near) else b
            continue
        v = OCEAN if label[t] == ocean else 0
        if any(not is_water[u] for u in near):
            v |= SHORE
            dist[t] = 0
            queue.append(t)
        out[t] = v
    while queue:
        t = queue.popleft()
        d = dist[t] + 1
        x = t % w
        for u, ok in ((t - 1, x > 0), (t + 1, x < w - 1), (t - w, t >= w), (t + w, t < n - w)):
            if ok and is_water[u] and dist[u] < 0:
                dist[u] = d
                queue.append(u)
    for t in range(n):
        if is_water[t] and dist[t] > 0:
            out[t] |= min(int(math.ceil(dist[t] / 2.0 - 1e-9)), 31)
    return bytes(out)


def nearest_inland(grid, x, y, radius=40):
    """The nearest land tile that isn't on the shore (else any land tile), or None."""
    best = None
    for r in range(radius + 1):
        for dy in range(-r, r + 1):
            for dx in (-r, r) if abs(dy) != r else range(-r, r + 1):
                xx, yy = x + dx, y + dy
                if 0 <= xx < W and 0 <= yy < H:
                    b = grid[yy, xx]
                    if b & LAND and not b & SHORE:
                        return xx, yy
                    if b & LAND and best is None:
                        best = (xx, yy)
        if best is not None and r >= 3:
            return best
    return best


def pick_nations(src, grid, count):
    flags = {f[:-4] for f in os.listdir(os.path.join(REPO, "assets", "flags")) if f.endswith(".svg")}
    rows = []
    with open(os.path.join(src, "ne_50m_admin_0_countries.geojson"), encoding="utf-8") as f:
        for feat in json.load(f)["features"]:
            p = feat["properties"]
            # (ISO_A2 can be "-99" or a point-of-view code like "CN-TW"; ISO_A2_EH is the plain code)
            iso = next((c for c in (p.get("ISO_A2_EH"), p.get("ISO_A2")) if c and len(c) == 2), None)
            name = NAMES.get(p.get("NAME_LONG"), p.get("NAME_LONG") or p.get("NAME"))
            if not iso or iso.lower() not in flags or name in EXCLUDED_NATIONS:
                continue
            rows.append((p.get("POP_EST") or 0, name, iso.lower(), p["LABEL_X"], p["LABEL_Y"]))
    picked = []
    # regions first (each stands for a big area), then countries by population
    candidates = [(0, name, flag, lon, lat) for name, flag, lon, lat in REGIONS] + sorted(rows, reverse=True)
    for _, name, flag, lon, lat in candidates:
        x, y = project(lon, lat)
        x = int(x) % W
        y = int(y)
        if not 0 <= y < H:
            continue
        spot = nearest_inland(grid, x, y)
        if spot is None or any((spot[0] - n["x"]) ** 2 + (spot[1] - n["y"]) ** 2 < MIN_GAP ** 2 for n in picked):
            continue
        picked.append({"name": name, "flag": flag, "x": spot[0], "y": spot[1]})
        if len(picked) == count:
            break
    return picked


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_registry(land_tiles, nation_count):
    lines = [
        "-- GENERATED by tools/maps/make_world.py. Do not edit.",
        "-- Registry of the playable maps (small and replicated: the map picker lists these without",
        "-- loading terrain). The only map today is World, replicated in src/shared/Data/Maps/World.luau",
        "-- so the title screen and solo games start at once.",
        "local MapList = {}",
        "",
        'MapList.DEFAULT = "world"',
        "MapList.LICENSE = %s" % lua_str(LICENSE),
        "MapList.ATTRIBUTION = %s" % lua_str(ATTRIBUTION),
        "MapList.CREDITS = %s" % lua_str(CREDITS),
        "",
        "--- {id, name, module, width, height, k_lin, categories, multiplayer_frequency, forced_modifiers,",
        "--- land_tiles, nations (count), replicated} sorted by name.",
        "MapList.maps = {",
        # (one row per line: tools/assets/make_map_thumbs.py reads the rows with a regex)
        '\t{ id = "world", name = "World", module = "World", width = %d, height = %d, k_lin = 1.0, '
        'categories = { "featured", "world" }, multiplayer_frequency = 30, forced_modifiers = { "isCrowded:50" }, '
        "land_tiles = %d, nations = %d, replicated = true }," % (W, H, land_tiles, nation_count),
        "}",
        "",
        "local by_id: { [string]: any } = {}",
        "for _, m in MapList.maps do",
        "\tby_id[m.id] = m",
        "end",
        "",
        "--- Registry row of map `id` (nil if unknown).",
        '--- (a size suffix — "world@80", see WorldMap.split_id — is ignored)',
        "function MapList.get(id: string): any",
        '\treturn by_id[string.match(id, "^(.-)@%d+$") or id]',
        "end",
        "",
        "return MapList",
        "",
    ]
    with open(os.path.join(REPO, "src", "shared", "Data", "MapList.luau"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(REPO, "build", "worldsrc"))
    ap.add_argument("--nations", type=int, default=71)
    ap.add_argument("--preview", help="also write a PNG of the map here")
    args = ap.parse_args()
    fetch(args.src)

    land_s = land_samples(args.src)
    elev_s = elevation_samples(args.src)
    frac = land_s.reshape(H, SS, W, SS).mean(axis=(1, 3))
    land = frac > 0.5
    carve_straits(land)
    filled = tidy(land)
    elev_sum = np.where(land_s, elev_s, 0).reshape(H, SS, W, SS).sum(axis=(1, 3))
    elev = elev_sum / np.maximum(land_s.reshape(H, SS, W, SS).sum(axis=(1, 3)), 1)
    mag = magnitude(elev)
    # a filled lake takes the height of the land around it
    for _ in range(6):
        near = ndimage.grey_dilation(np.where(filled, 0, mag), footprint=FOUR)
        mag = np.where(filled, np.maximum(mag, near), mag)
    typed = np.where(land, LAND | mag, 0).astype(np.uint8)
    tiles = postprocess(typed.tobytes(), W, H)
    grid = np.frombuffer(tiles, np.uint8).reshape(H, W)
    land_tiles = int(land.sum())
    nations = pick_nations(args.src, grid, args.nations)

    z = zstandard.ZstdCompressor(level=19, write_content_size=True).compress(tiles)
    lines = [
        "-- GENERATED by tools/maps/make_world.py from public-domain data (Natural Earth, NOAA ETOPO1). Do not edit.",
        "-- terrain = base64(zstd(width * height bytes)), the tile byte format of WorldMap.luau.",
        "return {",
        '\tid = "world",',
        '\tname = "World",',
        '\tmodule = "World",',
        "\twidth = %d," % W,
        "\theight = %d," % H,
        "\tk_lin = 1.0,",
        '\tcategories = { "featured", "world" },',
        "\tmultiplayer_frequency = 30,",
        '\tforced_modifiers = { "isCrowded:50" },',
        "\tland_tiles = %d," % land_tiles,
        "\tnations = {",
    ]
    for n in nations:
        lines.append("\t\t{ name = %s, flag = %s, x = %d, y = %d }," % (lua_str(n["name"]), lua_str(n["flag"]), n["x"], n["y"]))
    lines += [
        "\t},",
        '\tcodec = "zstd+base64",',
        "\tsize = %d," % (W * H),
        '\tterrain = "%s",' % base64.b64encode(z).decode("ascii"),
        "}",
        "",
    ]
    with open(os.path.join(REPO, "src", "shared", "Data", "Maps", "World.luau"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    write_registry(land_tiles, len(nations))
    lake = int((((grid & LAND) == 0) & ((grid & OCEAN) == 0)).sum())
    print("World: %dx%d, %d land tiles, %d lake tiles, %d nations, %d KB zstd"
          % (W, H, land_tiles, lake, len(nations), len(z) // 1024))

    if args.preview:
        mag = grid & 0x1F
        img = np.zeros((H, W, 3), np.uint8)
        water = (grid & LAND) == 0
        img[water] = np.stack([20 + 0 * mag[water], 60 - mag[water], 110 - mag[water] * 2], -1)
        img[water & ((grid & OCEAN) == 0)] = (70, 140, 210)
        lm = ~water
        img[lm] = np.stack([70 + mag[lm] * 5, 130 - mag[lm], 60 + mag[lm] * 2], -1).clip(0, 255)
        im = Image.fromarray(img)
        d = ImageDraw.Draw(im)
        for n in nations:
            d.rectangle([n["x"] - 3, n["y"] - 3, n["x"] + 3, n["y"] + 3], fill=(255, 255, 255))
            d.text((n["x"] + 5, n["y"] - 6), n["name"], fill=(255, 255, 255))
        im.save(args.preview)


if __name__ == "__main__":
    main()
