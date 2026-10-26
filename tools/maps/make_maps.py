#!/usr/bin/env python3
"""Builds every map from public-domain data: the data modules (World replicated in src/shared/Data/Maps,
the others in src/server/MapData) and the registry src/shared/Data/MapList.luau. Run with the repo's
.venv/bin/python (numpy, scipy, Pillow, zstandard).

Sources (public domain), downloaded into build/worldsrc/ on the first run:
  - Natural Earth (naturalearthdata.com, via github.com/nvkelso/natural-earth-vector): 1:10m land and
    lakes; 1:50m countries (names, ISO codes, population, label points); 1:10m states and provinces
    (names and label points: the nations of a big country on a continent map).
  - NOAA ETOPO1 (ice surface) through NOAA's ERDDAP server: the whole Earth every 6 arc-minutes for
    World, each continent's window every 1 or 2 (`etopo_step`).

Projection: equirectangular, `ppd` tiles per degree of latitude and ppd * cos(lat_std) per degree of
longitude (World: the same both ways, placed where the earlier World map was: the tests' Earth-grid fit in
tests/simsys_fixture.luau and tests/world_places.luau, x = (lon + 180) * W / 360 - 65, y = (90 - lat) *
W / 360 - 10, so its left edge is at 168.3 W, the Bering Strait, its top row at 88.2 N, and Antarctica
fills its bottom rows).
A tile is land when most of its SS x SS sample points are. Its elevation class comes from the mean ETOPO
height of its land samples: 0-300 m plains (0-9), 300-1200 m highland (10-19), higher mountain (20-30).
STRAITS too narrow for a map's scale are opened as channels, islands and lakes under MIN_ISLAND /
MIN_LAKE tiles go, then water bodies, shorelines and water depths are worked out as the game expects (the
tile byte format in WorldMap.luau: bit 7 land, bit 6 shoreline, bit 5 ocean, bits 0-4 magnitude).

Nations, each at its point (or the nearest inland tile), leaving out one within `min_gap` tiles of one
already placed:
  - World: a few big thinly peopled regions (REGIONS), then the most populous countries with a flag;
  - a continent: its countries (those of `continents`, Natural Earth's CONTINENT) by population, then
    the states / provinces of the big countries it splits (`split`; Russia's west or east of the Urals,
    `split_lon`), the farthest from those placed first, up to `nations`; none smaller than MIN_ROOM *
    min_gap^2 tiles (a microstate, a city), no name twice.

Usage (from the repo root): .venv/bin/python tools/maps/make_maps.py [--src build/worldsrc] [--only europe]
    [--preview <dir>]
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
SS = 3  # sample points per tile side
# left out: names Roblox's text moderation may flag (2026-09-26), as before; a disputed territory and
# provinces whose name or flag takes a side or reads badly as a nation (2026-10-26, the continent maps)
EXCLUDED_NATIONS = {"Niger", "Western Sahara", "Autonomous Republic of Crimea", "Sevastopol", "Jewish"}
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
    "Kingdom of eSwatini": "Eswatini",
}
# World: regions given a nation of their own, so big thinly peopled lands get a spawn too: name, flag,
# lon, lat.
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
# Narrow straits that close at a map's scale (World: a tile is about 20 km), opened as 1-tile channels so
# the Mediterranean, the Black Sea, the Sea of Azov, the Red Sea and the Baltic stay connected to the
# ocean: lon/lat polylines (a map opens the ones inside it).
STRAITS = [
    [(-6.4, 35.95), (-5.6, 35.97), (-4.9, 36.05)],  # Gibraltar
    [(42.9, 13.3), (43.4, 12.6), (43.9, 12.3)],  # Bab-el-Mandeb
    [(26.1, 40.0), (26.7, 40.4), (27.5, 40.7), (28.9, 40.95), (29.1, 41.3)],  # Dardanelles, Marmara, Bosphorus
    [(36.6, 45.5), (36.6, 45.1)],  # Kerch
    [(11.6, 57.0), (12.3, 56.3), (12.65, 55.9), (12.8, 55.3)],  # Kattegat, Øresund
]
WORLD_LON0 = -180.0 + 65 / (2000 / 360.0)
WORLD_LAT_TOP = 90.0 - 10 / (2000 / 360.0)
# The maps: id, name, module, the window (lon0 .. lon1, lat_top .. lat_bottom), tiles per degree of latitude,
# the latitude whose scale the longitudes keep (lat_std), ETOPO's sampling (arc-minutes; World's is its own
# global file), the registry's fields, the nations and how they are chosen.
MAPS = [
    dict(id="world", name="World", module="World", world=True, width=2000, height=1000,
         lon0=WORLD_LON0, lat_top=WORLD_LAT_TOP, ppd=2000 / 360.0, lat_std=0.0, lakes=3,
         categories=["featured", "world"], frequency=30, modifiers=["isCrowded:50"],
         nations=71, min_gap=30),
    dict(id="europe", name="Europe", module="Europe", lon0=-25.0, lon1=45.0, lat_top=72.0, lat_bottom=34.0,
         ppd=33.0, lat_std=52.0, etopo_step=1, lakes=9,
         categories=["featured", "continental", "europe"], frequency=10, modifiers=[],
         nations=48, min_gap=55, split=["ru"], continents=["Europe", "Asia"], split_lon={"ru": (-180, 60)}),
    dict(id="northamerica", name="North America", module="NorthAmerica", lon0=-170.0, lon1=-50.0,
         lat_top=75.0, lat_bottom=7.0, ppd=18.0, lat_std=40.0, etopo_step=2, lakes=9,
         categories=["featured", "continental", "north_america"], frequency=10, modifiers=[],
         nations=50, min_gap=55, split=["us", "ca", "mx"], continents=["North America"]),
    dict(id="southamerica", name="South America", module="SouthAmerica", lon0=-92.0, lon1=-30.0,
         lat_top=14.0, lat_bottom=-57.0, ppd=20.0, lat_std=-20.0, etopo_step=2, lakes=9,
         categories=["featured", "continental", "south_america"], frequency=10, modifiers=[],
         nations=36, min_gap=55, split=["br", "ar", "co", "pe", "ve", "bo"], continents=["South America"]),
    dict(id="asia", name="Asia", module="Asia", lon0=25.0, lon1=150.0, lat_top=78.0, lat_bottom=-12.0,
         ppd=15.0, lat_std=35.0, etopo_step=2, lakes=9,
         categories=["featured", "continental", "asia"], frequency=10, modifiers=[],
         nations=64, min_gap=50, split=["ru", "cn", "in", "kz", "id", "mn"], continents=["Asia"],
         split_lon={"ru": (60, 180)}),
    dict(id="africa", name="Africa", module="Africa", lon0=-26.0, lon1=58.0, lat_top=38.0, lat_bottom=-36.0,
         ppd=18.0, lat_std=10.0, etopo_step=2, lakes=9,
         categories=["featured", "continental", "africa"], frequency=10, modifiers=[],
         nations=50, min_gap=40, split=[], continents=["Africa"]),
]
NE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
ERDDAP = "https://coastwatch.pfeg.noaa.gov/erddap/griddap/etopo180.nc"
SOURCES = {
    "ne_10m_land.geojson": NE + "ne_10m_land.geojson",
    "ne_10m_lakes.geojson": NE + "ne_10m_lakes.geojson",
    "ne_50m_admin_0_countries.geojson": NE + "ne_50m_admin_0_countries.geojson",
    "ne_10m_admin_1_states_provinces.geojson": NE + "ne_10m_admin_1_states_provinces.geojson",
    "etopo.nc": ERDDAP + "?altitude%5B(-90.0):6:(90.0)%5D%5B(-180.0):6:(180.0)%5D",
}
# Islands smaller than this (tiles) become sea and lakes smaller than this become land (2026-10-26: the
# hundreds of 1-20 tile islands and lakes got in the way of play; the maps before had none that small).
MIN_ISLAND = 21
MIN_LAKE = 21
FOUR = [[0, 1, 0], [1, 1, 1], [0, 1, 0]]
# A continent's nation has at least MIN_ROOM * min_gap^2 tiles of its own country / province (smaller ones
# would spawn on a neighbour's land, their own being too small for the map or gone with the small islands).
MIN_ROOM = 0.2
LICENSE = "Public domain"
ATTRIBUTION = "Natural Earth, NOAA"
CREDITS = "Maps made with Natural Earth and NOAA ETOPO1 data (public domain)."

LAND = 0x80
SHORE = 0x40
OCEAN = 0x20
IMPASSABLE = 0x9F


class Proj:
    """A map's equirectangular grid: tile coordinates of a lon/lat and back."""

    def __init__(self, spec):
        self.py = spec["ppd"]
        self.px = spec["ppd"] * math.cos(math.radians(spec["lat_std"]))
        self.lon0, self.lat_top = spec["lon0"], spec["lat_top"]
        self.w = spec.get("width") or int(round((spec["lon1"] - spec["lon0"]) * self.px))
        self.h = spec.get("height") or int(round((spec["lat_top"] - spec["lat_bottom"]) * self.py))
        self.world = spec.get("world", False)

    def project(self, lon, lat):
        """lon/lat arrays -> tile coordinates (x unwrapped: west of lon0 gives a negative x)."""
        return ((np.asarray(lon, dtype=np.float64) - self.lon0) * self.px,
                (self.lat_top - np.asarray(lat, dtype=np.float64)) * self.py)

    def unproject(self, x, y):
        """Tile coordinates -> lon (wrapped to -180..180), lat (the rows past the South Pole read the pole)."""
        lon = self.lon0 + np.asarray(x) / self.px
        lat = np.maximum(self.lat_top - np.asarray(y) / self.py, -89.95)
        return (lon + 180.0) % 360.0 - 180.0, lat

    def inside(self, x, y):
        return 0 <= x < self.w and 0 <= y < self.h


def etopo_name(spec):
    return "etopo.nc" if spec.get("world") else "etopo_%s.nc" % spec["id"]


def fetch(src, specs):
    os.makedirs(src, exist_ok=True)
    wanted = dict(SOURCES)
    for spec in specs:
        if not spec.get("world"):
            s = spec["etopo_step"]
            lat0, lat1 = max(spec["lat_bottom"] - 1, -90), min(spec["lat_top"] + 1, 90)
            lon0, lon1 = max(spec["lon0"] - 1, -180), min(spec["lon1"] + 1, 180)
            wanted[etopo_name(spec)] = ERDDAP + "?altitude%%5B(%s):%d:(%s)%%5D%%5B(%s):%d:(%s)%%5D" % (
                lat0, s, lat1, lon0, s, lon1)
    for name, url in wanted.items():
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


def draw_rings(proj, draw, rings, fill, hole_fill):
    """Exterior ring then its holes; on World, rings west of the seam again a turn of the Earth later."""
    for i, ring in enumerate(rings):
        a = np.asarray(ring)
        x, y = proj.project(a[:, 0], a[:, 1])
        for shift in (0.0, proj.w) if proj.world and x.min() < 0 else (0.0,):
            pts = list(zip(((x + shift) * SS).tolist(), (y * SS).tolist()))
            if len(pts) >= 3:
                draw.polygon(pts, fill=fill if i == 0 else hole_fill)


def land_samples(src, proj, spec):
    """Bool (H*SS, W*SS): land at each sample point."""
    img = Image.new("L", (proj.w * SS, proj.h * SS), 0)
    draw = ImageDraw.Draw(img)
    # biggest first, so an island inside another polygon's hole is drawn after the hole
    land = sorted(polygons(os.path.join(src, "ne_10m_land.geojson")), key=lambda p: -ring_area(p[1][0]))
    for _, rings in land:
        draw_rings(proj, draw, rings, 1, 0)
    lakes = [p for p in polygons(os.path.join(src, "ne_10m_lakes.geojson"))
             if (p[0].get("scalerank") or 99) <= spec["lakes"]]
    for _, rings in sorted(lakes, key=lambda p: -ring_area(p[1][0])):
        draw_rings(proj, draw, rings, 0, 1)
    out = np.array(img, dtype=bool)
    if proj.world:
        # the rows past the South Pole: Antarctica
        pole = int(proj.project(0.0, -90.0)[1] * SS)
        out[max(pole - SS, 0):, :] = True
    return out


def elevation_samples(src, proj, spec):
    """ETOPO height (m) at each sample point (nearest grid value)."""
    with netcdf_file(os.path.join(src, etopo_name(spec)), "r", mmap=False) as nc:
        lats = np.array(nc.variables["latitude"][:], dtype=np.float64)
        lons = np.array(nc.variables["longitude"][:], dtype=np.float64)
        alt = np.array(nc.variables["altitude"][:], dtype=np.float64)
    xs = (np.arange(proj.w * SS) + 0.5) / SS
    ys = (np.arange(proj.h * SS) + 0.5) / SS
    lon, _ = proj.unproject(xs, np.zeros_like(xs))
    _, lat = proj.unproject(np.zeros_like(ys), ys)
    i = np.clip(np.rint((lat - lats[0]) / (lats[1] - lats[0])).astype(int), 0, len(lats) - 1)
    j = np.clip(np.rint((lon - lons[0]) / (lons[1] - lons[0])).astype(int), 0, len(lons) - 1)
    return alt[i[:, None], j[None, :]]


def magnitude(elev):
    e = np.clip(elev, 0, None)
    m = np.where(e < 300, e / 300 * 10, np.where(e < 1200, 10 + (e - 300) / 900 * 10,
                                                 20 + np.clip((e - 1200) / 2800, 0, 1) * 10))
    return np.clip(np.floor(m), 0, 30).astype(np.uint8)


def carve_straits(proj, land):
    for line in STRAITS:
        x, y = proj.project([p[0] for p in line], [p[1] for p in line])
        if not all(proj.inside(int(a), int(b)) for a, b in zip(x, y)):
            continue
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


def edge_labels(lab):
    """Labels of the bodies reaching the map's edge (0 excluded)."""
    edge = np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]])
    return set(np.unique(edge).tolist()) - {0}


def tidy(land):
    """Drops islands under MIN_ISLAND tiles and fills lakes under MIN_LAKE tiles, in place: a lake is a
    water body other than the largest that doesn't reach the map's edge (one that does is a sea going on
    past it). Returns the mask of the filled lake tiles."""
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
    for e in edge_labels(lab):
        small[e] = False
    filled = small[lab]
    land[filled] = True
    return filled


def postprocess(tiles, w, h):
    """Water bodies (the ocean: the largest and those reaching the map's edge), shoreline bits on land and
    water next to each other, and water magnitude = ceil(distance from the shoreline water / 2), capped
    at 31."""
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
    oceans = {max(range(1, cur + 1), key=lambda i: sizes[i])} if cur else set()
    for x in range(w):
        oceans.add(label[x])
        oceans.add(label[n - w + x])
    for y in range(h):
        oceans.add(label[y * w])
        oceans.add(label[y * w + w - 1])
    oceans.discard(0)
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
        v = OCEAN if label[t] in oceans else 0
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
    h, w = grid.shape
    best = None
    for r in range(radius + 1):
        for dy in range(-r, r + 1):
            for dx in (-r, r) if abs(dy) != r else range(-r, r + 1):
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and 0 <= yy < h:
                    b = grid[yy, xx]
                    if b & LAND and not b & SHORE:
                        return xx, yy
                    if b & LAND and best is None:
                        best = (xx, yy)
        if best is not None and r >= 3:
            return best
    return best


def flag_codes():
    return {f[:-4] for f in os.listdir(os.path.join(REPO, "assets", "flags")) if f.endswith(".svg")}


def deg2_area(geom):
    """Area of a (Multi)Polygon in square degrees (holes taken out)."""
    if geom is None:
        return 0.0
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    return sum(ring_area(rings[0]) - sum(ring_area(r) for r in rings[1:]) for rings in polys)


def countries(src, flags):
    """(population, name, flag, lon, lat, continent, area in square degrees) of every country with a flag
    (its label point)."""
    rows = []
    with open(os.path.join(src, "ne_50m_admin_0_countries.geojson"), encoding="utf-8") as f:
        for feat in json.load(f)["features"]:
            p = feat["properties"]
            # (ISO_A2 can be "-99" or a point-of-view code like "CN-TW"; ISO_A2_EH is the plain code)
            iso = next((c for c in (p.get("ISO_A2_EH"), p.get("ISO_A2")) if c and len(c) == 2), None)
            name = NAMES.get(p.get("NAME_LONG"), p.get("NAME_LONG") or p.get("NAME"))
            if not iso or iso.lower() not in flags or name in EXCLUDED_NATIONS:
                continue
            rows.append((p.get("POP_EST") or 0, name, iso.lower(), p["LABEL_X"], p["LABEL_Y"],
                         p.get("CONTINENT"), deg2_area(feat["geometry"])))
    return rows


def provinces(src, isos, flags, lon_range=None):
    """(name, flag, lon, lat, area in square degrees) of the states / provinces of the countries `isos`
    (their label points; `lon_range`: {iso: (west, east)} keeps a country's between those longitudes)."""
    out = []
    if not isos:
        return out
    with open(os.path.join(src, "ne_10m_admin_1_states_provinces.geojson"), encoding="utf-8") as f:
        for feat in json.load(f)["features"]:
            p = feat["properties"]
            iso = (p.get("iso_a2") or "").lower()
            if iso not in isos or p.get("longitude") is None:
                continue
            lo, hi = (lon_range or {}).get(iso, (-180, 180))
            if not lo <= p["longitude"] < hi:
                continue
            name = p.get("name_en") or p.get("name")
            if not name or name in EXCLUDED_NATIONS:
                continue
            key = "".join(ch for ch in name.lower() if ch.isalnum())
            out.append((name, key if key in flags else iso, p["longitude"], p["latitude"], deg2_area(feat["geometry"])))
    return out


def place(proj, grid, lon, lat):
    x, y = proj.project(lon, lat)
    x = int(x) % proj.w if proj.world else int(x)
    y = int(y)
    if not proj.inside(x, y):
        return None
    return nearest_inland(grid, x, y)


def pick_nations(src, proj, grid, spec):
    flags = flag_codes()
    gap2 = spec["min_gap"] ** 2
    count = spec["nations"]
    picked = []

    def free(spot):
        return all((spot[0] - n["x"]) ** 2 + (spot[1] - n["y"]) ** 2 >= gap2 for n in picked)

    rows = sorted(countries(src, flags), reverse=True)
    if spec.get("world"):
        # regions first (each stands for a big area), then countries by population
        candidates = [(0, name, flag, lon, lat) for name, flag, lon, lat in REGIONS] + [r[:5] for r in rows]
        for _, name, flag, lon, lat in candidates:
            spot = place(proj, grid, lon, lat)
            if spot is None or not free(spot):
                continue
            picked.append({"name": name, "flag": flag, "x": spot[0], "y": spot[1]})
            if len(picked) == count:
                break
        return picked
    split = set(spec.get("split", []))
    continents = set(spec.get("continents") or [])
    room = MIN_ROOM * spec["min_gap"] ** 2 / (proj.px * proj.py)  # square degrees
    for _, name, flag, lon, lat, continent, area in rows:
        if flag in split or (continents and continent not in continents) or area < room:
            continue
        spot = place(proj, grid, lon, lat)
        if spot is None or not free(spot):
            continue
        picked.append({"name": name, "flag": flag, "x": spot[0], "y": spot[1]})
        if len(picked) == count:
            return picked
    # the big countries' states / provinces, the farthest from those placed first
    pool = []
    for name, flag, lon, lat, area in provinces(src, split, flags, spec.get("split_lon")):
        if area < room or any(n["name"] == name for n in picked) or any(c[0] == name for c in pool):
            continue
        spot = place(proj, grid, lon, lat)
        if spot is not None:
            pool.append((name, flag, spot))
    while pool and len(picked) < count:
        def space(c):
            return min(((c[2][0] - n["x"]) ** 2 + (c[2][1] - n["y"]) ** 2 for n in picked), default=math.inf)
        best = max(pool, key=space)
        if space(best) < gap2:
            break
        pool.remove(best)
        picked.append({"name": best[0], "flag": best[1], "x": best[2][0], "y": best[2][1]})
    return picked


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_list(xs):
    return "{ " + ", ".join(lua_str(x) for x in xs) + " }" if xs else "{}"


def module_path(spec):
    if spec.get("world"):
        return os.path.join(REPO, "src", "shared", "Data", "Maps", spec["module"] + ".luau")
    return os.path.join(REPO, "src", "server", "MapData", spec["module"] + ".luau")


def write_module(spec, proj, tiles, land_tiles, nations):
    z = zstandard.ZstdCompressor(level=19, write_content_size=True).compress(tiles)
    lines = [
        "-- GENERATED by tools/maps/make_maps.py from public-domain data (Natural Earth, NOAA ETOPO1). Do not edit.",
        "-- terrain = base64(zstd(width * height bytes)), the tile byte format of WorldMap.luau.",
        "return {",
        "\tid = %s," % lua_str(spec["id"]),
        "\tname = %s," % lua_str(spec["name"]),
        "\tmodule = %s," % lua_str(spec["module"]),
        "\twidth = %d," % proj.w,
        "\theight = %d," % proj.h,
        "\tk_lin = 1.0,",
        "\tcategories = %s," % lua_list(spec["categories"]),
        "\tmultiplayer_frequency = %d," % spec["frequency"],
        "\tforced_modifiers = %s," % lua_list(spec["modifiers"]),
        "\tland_tiles = %d," % land_tiles,
        "\tnations = {",
    ]
    for n in nations:
        lines.append("\t\t{ name = %s, flag = %s, x = %d, y = %d }," % (lua_str(n["name"]), lua_str(n["flag"]), n["x"], n["y"]))
    lines += [
        "\t},",
        '\tcodec = "zstd+base64",',
        "\tsize = %d," % (proj.w * proj.h),
        '\tterrain = "%s",' % base64.b64encode(z).decode("ascii"),
        "}",
        "",
    ]
    os.makedirs(os.path.dirname(module_path(spec)), exist_ok=True)
    with open(module_path(spec), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return len(z)


def write_registry(rows):
    lines = [
        "-- GENERATED by tools/maps/make_maps.py. Do not edit.",
        "-- Registry of the playable maps (small and replicated: the map picker lists these without",
        "-- loading terrain). Terrain lives in src/server/MapData/<module>.luau (server only; clients fetch",
        "-- it through MapFetch) except World, replicated in src/shared/Data/Maps/World.luau so the title",
        "-- screen and solo games start at once.",
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
    ]
    # (one row per line: tools/assets/make_map_thumbs.py reads the rows with a regex)
    for spec, proj, land_tiles, nation_count in sorted(rows, key=lambda r: r[0]["name"].lower()):
        fields = [
            "id = %s" % lua_str(spec["id"]),
            "name = %s" % lua_str(spec["name"]),
            "module = %s" % lua_str(spec["module"]),
            "width = %d" % proj.w,
            "height = %d" % proj.h,
            "k_lin = 1.0",
            "categories = %s" % lua_list(spec["categories"]),
            "multiplayer_frequency = %d" % spec["frequency"],
        ]
        if spec["modifiers"]:
            fields.append("forced_modifiers = %s" % lua_list(spec["modifiers"]))
        fields += ["land_tiles = %d" % land_tiles, "nations = %d" % nation_count]
        if spec.get("world"):
            fields.append("replicated = true")
        lines.append("\t{ %s }," % ", ".join(fields))
    lines += [
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


def read_row(spec):
    """(width, height, land_tiles, nations) of a map module already built (for --only)."""
    import re  # noqa: PLC0415

    s = open(module_path(spec), encoding="utf-8").read()
    w, h = int(re.search(r"\bwidth = (\d+)", s).group(1)), int(re.search(r"\bheight = (\d+)", s).group(1))
    land = int(re.search(r"\bland_tiles = (\d+)", s).group(1))
    return w, h, land, s.count("flag = ")


def build(src, spec, preview):
    proj = Proj(spec)
    land_s = land_samples(src, proj, spec)
    elev_s = elevation_samples(src, proj, spec)
    W, H = proj.w, proj.h
    frac = land_s.reshape(H, SS, W, SS).mean(axis=(1, 3))
    land = frac > 0.5
    carve_straits(proj, land)
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
    nations = pick_nations(src, proj, grid, spec)
    zbytes = write_module(spec, proj, tiles, land_tiles, nations)
    lake = int((((grid & LAND) == 0) & ((grid & OCEAN) == 0)).sum())
    print("%-14s %dx%d, %d land tiles, %d lake tiles, %d nations, %d KB zstd"
          % (spec["name"], W, H, land_tiles, lake, len(nations), zbytes // 1024))
    if preview:
        m = grid & 0x1F
        img = np.zeros((H, W, 3), np.uint8)
        water = (grid & LAND) == 0
        img[water] = np.stack([20 + 0 * m[water], 60 - m[water], 110 - m[water] * 2], -1)
        img[water & ((grid & OCEAN) == 0)] = (70, 140, 210)
        lm = ~water
        img[lm] = np.stack([70 + m[lm] * 5, 130 - m[lm], 60 + m[lm] * 2], -1).clip(0, 255)
        im = Image.fromarray(img)
        d = ImageDraw.Draw(im)
        for n in nations:
            d.rectangle([n["x"] - 3, n["y"] - 3, n["x"] + 3, n["y"] + 3], fill=(255, 255, 255))
            d.text((n["x"] + 5, n["y"] - 6), n["name"], fill=(255, 255, 255))
        os.makedirs(preview, exist_ok=True)
        im.save(os.path.join(preview, spec["id"] + ".png"))
    return spec, proj, land_tiles, len(nations)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(REPO, "build", "worldsrc"))
    ap.add_argument("--only", help="comma-separated map ids to rebuild (the others' rows are read back)")
    ap.add_argument("--preview", help="also write a PNG of each map into this folder")
    args = ap.parse_args()
    only = set(args.only.split(",")) if args.only else None
    fetch(args.src, MAPS if only is None else [m for m in MAPS if m["id"] in only])
    rows = []
    for spec in MAPS:
        if only is None or spec["id"] in only:
            rows.append(build(args.src, spec, args.preview))
        else:
            w, h, land, nations = read_row(spec)
            proj = Proj(dict(spec, width=w, height=h))
            rows.append((spec, proj, land, nations))
    write_registry(rows)


if __name__ == "__main__":
    main()
