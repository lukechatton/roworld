#!/usr/bin/env python3
"""Imports OpenFront maps (github.com/openfrontio/OpenFrontIO, resources/maps/<id>/) as Luau data
modules for Rofront. Standard library + the `zstandard` module or the zstd CLI (frames must carry their content size: Roblox's
DecompressBuffer requires it). Run with the repo's .venv/bin/python.

Map data (c) OpenFront, licensed CC BY-SA 4.0 — our converted data stays CC BY-SA 4.0 and every
module / the registry carries the attribution "OpenFront".

Usage (from the repo root):
    python3 tools/maps/import_maps.py --src <OpenFrontIO checkout> [--budget 2500000]
        [--only world,pangaea] [--jobs 8] [--lune .bin/lune] [--default world]

Input per map: manifest.json (name, categories, map sizes, nations [{coordinates: [x, y] in
full-res px, flag, name}], multiplayer_frequency, forced_modifiers) and map.bin (FULL resolution,
1 byte per tile, row-major): bit 7 land, bit 6 shoreline, bit 5 ocean (water only), bits 0-4
magnitude — land 0..30 elevation class (plains < 10, highland 10-19, mountain >= 20), 0x9F
(land bit + 31, no other bits) = impassable; water = min(ceil(dist / 2), 31) where dist is the
4-neighbour BFS distance from the shoreline water tiles (0 on the shoreline), water next to
impassable terrain = 10 (OpenFront map-generator/map_generator.go packTerrain / processWater).

Tile budget: a map with more than --budget tiles is resampled by s = sqrt(budget / tiles) (integer
dimensions, never above the budget): every output tile is the majority of its source block (water
wins ties, so rivers survive where they can), impassable when most of the block's non-water tiles
are impassable, else land with the mean elevation of the block's passable land. Then the ocean
bit (largest 4-connected water body), shoreline bits and water magnitudes are recomputed the way
OpenFront's generator does, with water distances measured in ORIGINAL-resolution tiles (dist / s).
Nation coordinates are scaled by s. `k_lin` = OpenFront full-res tiles per our tile (1 unscaled).

Output:
    src/shared/Data/Maps/<Module>.luau   the default map (replicated: title screen + default solo)
    src/server/MapData/<Module>.luau     every other map (server only; clients fetch on demand)
    src/shared/Data/MapList.luau         registry (small, replicated): metadata for the map picker
Module fields: id, name, module, width, height, k_lin, categories, multiplayer_frequency,
forced_modifiers, land_tiles, nations = {{name, flag, x, y}} (our grid; x/y nil = random spawn),
license, attribution, source (OpenFront dimensions / scale), codec = "zstd+base64", size,
terrain = base64(zstd(tile bytes)) in the OpenFront byte format above.
"""
import argparse
import base64
import collections
import itertools
import json
import math
import multiprocessing
import operator
import os
import subprocess
import sys
import tempfile

# Nations left out of every imported map: names Roblox's text moderation may flag as a slur
# (2026-09-26).
EXCLUDED_NATIONS = {"Niger"}
# Map categories left out of the import: only maps of the real world are kept, no fictional ones
# (2026-10-25). 31 maps went that day.
EXCLUDED_CATEGORIES = {"fictional", "arcade", "cosmic", "tournament"}

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LICENSE = "CC BY-SA 4.0"
ATTRIBUTION = "OpenFront"
ATTRIBUTION_TEXT = ("Maps from OpenFront, "
                    "licensed CC BY-SA 4.0; converted map data is shared under the same licence.")

IMPASSABLE = 0x9F
LAND = 0x80
SHORE = 0x40
OCEAN = 0x20

# translate tables (bytes -> per-tile values) for the resampler's prefix sums
T_WATER = bytes(1 if (b & LAND) == 0 else 0 for b in range(256))
T_IMP = bytes(1 if b == IMPASSABLE else 0 for b in range(256))
T_PLAND = bytes(1 if (b & LAND) and b != IMPASSABLE else 0 for b in range(256))
T_MAG = bytes((b & 0x1F) if (b & LAND) and b != IMPASSABLE else 0 for b in range(256))


def module_name(manifest_id):
    s = "".join(ch for ch in manifest_id if ch.isalnum())
    return s[:1].upper() + s[1:]


def lua_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif o < 32:
            out.append("\\%d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_value(v, indent="\t"):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        r = repr(v)
        return r if r not in ("inf", "nan") else "0"
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        return "{ " + ", ".join(lua_value(x, indent) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            parts.append("%s = %s" % (k, lua_value(x, indent)))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(type(v))


# ---------------------------------------------------------------------------------------------
# Resampling + OpenFront post-processing
# ---------------------------------------------------------------------------------------------

def budget_dims(w, h, budget):
    if w * h <= budget:
        return w, h
    s = math.sqrt(budget / float(w * h))
    w2 = max(1, int(round(w * s)))
    h2 = max(1, int(round(h * s)))
    while w2 * h2 > budget:
        if w2 / w >= h2 / h:
            w2 -= 1
        else:
            h2 -= 1
    return w2, h2


def prefix(row, table):
    return list(itertools.accumulate(row.translate(table), initial=0))


def resample(data, w, h, w2, h2):
    """Majority-vote downscale of OpenFront tile bytes (terrain type + land elevation only)."""
    xs = [(ox * w) // w2 for ox in range(w2 + 1)]
    g0 = operator.itemgetter(*xs[:-1])
    g1 = operator.itemgetter(*xs[1:])
    widths = [xs[i + 1] - xs[i] for i in range(w2)]
    out = bytearray(w2 * h2)
    for oy in range(h2):
        y0 = (oy * h) // h2
        y1 = ((oy + 1) * h) // h2
        water = [0] * w2
        imp = [0] * w2
        pland = [0] * w2
        msum = [0] * w2
        for y in range(y0, y1):
            row = data[y * w:(y + 1) * w]
            for acc, table in ((water, T_WATER), (imp, T_IMP), (pland, T_PLAND), (msum, T_MAG)):
                p = prefix(row, table)
                if w2 > 1:
                    d = map(operator.sub, g1(p), g0(p))
                else:
                    d = (p[xs[1]] - p[xs[0]],)
                acc[:] = list(map(operator.add, acc, d))
        rows = y1 - y0
        base = oy * w2
        for ox in range(w2):
            total = widths[ox] * rows
            wv = water[ox]
            if wv * 2 >= total:
                out[base + ox] = 0  # water; ocean / shore / magnitude recomputed below
            elif imp[ox] > pland[ox]:
                out[base + ox] = IMPASSABLE
            else:
                pl = pland[ox]
                mag = int(math.floor(msum[ox] / pl + 0.5)) if pl > 0 else 0
                out[base + ox] = LAND | min(mag, 30)
    return out


def postprocess(tiles, w, h, k_lin):
    """OpenFront processWater + processShore + processDistToLand + setImpassableNeighborWaterDepth
    on already-typed tiles (water bytes 0, land LAND|mag, impassable 0x9F). Water distances are
    scaled to original-resolution tiles by k_lin."""
    n = w * h
    is_water = bytearray(1 if (b & LAND) == 0 else 0 for b in tiles)
    # 1. water bodies (4-connected); the largest is the ocean
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
            if x > 0:
                u = t - 1
                if is_water[u] and not label[u]:
                    label[u] = cur
                    stack.append(u)
            if x < w - 1:
                u = t + 1
                if is_water[u] and not label[u]:
                    label[u] = cur
                    stack.append(u)
            if t >= w:
                u = t - w
                if is_water[u] and not label[u]:
                    label[u] = cur
                    stack.append(u)
            if t < n - w:
                u = t + w
                if is_water[u] and not label[u]:
                    label[u] = cur
                    stack.append(u)
        sizes.append(size)
    ocean = 0
    if cur > 0:
        ocean = max(range(1, cur + 1), key=lambda i: sizes[i])
    # 2. shorelines; 3. BFS distance from shoreline water
    dist = [-1] * n
    queue = collections.deque()
    out = bytearray(n)
    is_pland = bytearray(1 if (b & LAND) and b != IMPASSABLE else 0 for b in tiles)
    for t in range(n):
        b = tiles[t]
        if b == IMPASSABLE:
            out[t] = IMPASSABLE
            continue
        x = t % w
        if b & LAND:
            if (x > 0 and is_water[t - 1]) or (x < w - 1 and is_water[t + 1]) or \
                    (t >= w and is_water[t - w]) or (t < n - w and is_water[t + w]):
                b |= SHORE
            out[t] = b
            continue
        v = OCEAN if label[t] == ocean else 0
        if (x > 0 and is_pland[t - 1]) or (x < w - 1 and is_pland[t + 1]) or \
                (t >= w and is_pland[t - w]) or (t < n - w and is_pland[t + w]):
            v |= SHORE
            dist[t] = 0
            queue.append(t)
        out[t] = v
    while queue:
        t = queue.popleft()
        d = dist[t] + 1
        x = t % w
        if x > 0:
            u = t - 1
            if is_water[u] and dist[u] < 0:
                dist[u] = d
                queue.append(u)
        if x < w - 1:
            u = t + 1
            if is_water[u] and dist[u] < 0:
                dist[u] = d
                queue.append(u)
        if t >= w:
            u = t - w
            if is_water[u] and dist[u] < 0:
                dist[u] = d
                queue.append(u)
        if t < n - w:
            u = t + w
            if is_water[u] and dist[u] < 0:
                dist[u] = d
                queue.append(u)
    for t in range(n):
        if not is_water[t]:
            continue
        d = dist[t]
        mag = 0
        if d > 0:
            mag = min(int(math.ceil(d * k_lin / 2.0 - 1e-9)), 31)
        # water next to impassable terrain renders as deep water (magnitude 20 -> 10)
        x = t % w
        if (x > 0 and tiles[t - 1] == IMPASSABLE) or (x < w - 1 and tiles[t + 1] == IMPASSABLE) or \
                (t >= w and tiles[t - w] == IMPASSABLE) or (t < n - w and tiles[t + w] == IMPASSABLE):
            mag = 10
        out[t] = out[t] | mag
    return out


# ---------------------------------------------------------------------------------------------
# One map
# ---------------------------------------------------------------------------------------------

def count_land(tiles):
    return sum(1 for b in tiles if (b & LAND) and b != IMPASSABLE)


def zstd_compress(lune, raw, level=19):
    """zstd frame WITH the decompressed size in its header: Roblox's EncodingService:DecompressBuffer
    rejects frames without Frame_Content_Size (Lune's serde / streaming encoders omit it). Uses the
    `zstandard` module (the repo's .venv) or the zstd CLI; `lune` is unused (kept for the job tuple)."""
    try:
        import zstandard  # noqa: PLC0415

        return zstandard.ZstdCompressor(level=level, write_content_size=True).compress(raw)
    except ImportError:
        pass
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in.bin")
        dst = os.path.join(tmp, "out.zst")
        with open(src, "wb") as f:
            f.write(raw)
        subprocess.run(["zstd", "-q", "-%d" % level, "-f", "-o", dst, src], check=True)
        with open(dst, "rb") as f:
            out = f.read()
    # descriptor byte: Frame_Content_Size flag (bits 7-6) or Single_Segment (bit 5) must be set
    if not (out[4] & 0xC0 or out[4] & 0x20):
        raise RuntimeError("zstd frame has no content size")
    return out


def import_map(job):
    src_dir, dirname, budget, lune, out_path, default_id = job
    mdir = os.path.join(src_dir, "resources", "maps", dirname)
    with open(os.path.join(mdir, "manifest.json")) as f:
        man = json.load(f)
    w = man["map"]["width"]
    h = man["map"]["height"]
    with open(os.path.join(mdir, "map.bin"), "rb") as f:
        data = f.read()
    if len(data) != w * h:
        raise ValueError("%s: map.bin is %d bytes, expected %d" % (dirname, len(data), w * h))
    w2, h2 = budget_dims(w, h, budget)
    if (w2, h2) == (w, h):
        tiles = bytes(data)
        k_lin = 1.0
        land = count_land(tiles)
        if land != man["map"]["num_land_tiles"]:
            raise ValueError("%s: %d land tiles, manifest says %d" % (dirname, land, man["map"]["num_land_tiles"]))
    else:
        k_lin = math.sqrt((w * h) / float(w2 * h2))
        typed = resample(data, w, h, w2, h2)
        tiles = bytes(postprocess(typed, w2, h2, k_lin))
        land = count_land(tiles)
    sx = w2 / float(w)
    sy = h2 / float(h)
    nations = []
    on_land = 0
    for nd in man.get("nations", []):
        if str(nd.get("name", "")) in EXCLUDED_NATIONS:
            continue
        row = {"name": str(nd.get("name", "Nation")), "flag": nd.get("flag")}
        c = nd.get("coordinates")
        if c is not None:
            x = min(w2 - 1, max(0, int(math.floor(c[0] * sx))))
            y = min(h2 - 1, max(0, int(math.floor(c[1] * sy))))
            row["x"] = x
            row["y"] = y
            b = tiles[y * w2 + x]
            if (b & LAND) and b != IMPASSABLE:
                on_land += 1
        nations.append(row)
    z = zstd_compress(lune, tiles)
    b64 = base64.b64encode(z).decode("ascii")
    mid = dirname
    mod = module_name(man.get("id", dirname))
    meta = {
        "id": mid,
        "name": str(man.get("display_name") or man.get("name") or dirname),
        "module": mod,
        "width": w2,
        "height": h2,
        "k_lin": round(k_lin, 6),
        "categories": list(man.get("categories", [])),
        "multiplayer_frequency": int(man.get("multiplayer_frequency", 0) or 0),
        "forced_modifiers": [str(x) for x in man.get("forced_modifiers", [])],
        "land_tiles": land,
        "nation_count": len(nations),
        "source_width": w,
        "source_height": h,
        "source_land_tiles": man["map"]["num_land_tiles"],
        "replicated": mid == default_id,
        "zstd_bytes": len(z),
        "nations_on_land": on_land,
        "nations_with_coords": sum(1 for n in nations if "x" in n),
    }
    lines = [
        "-- GENERATED by tools/maps/import_maps.py. Do not edit.",
        "-- Map data licensed CC BY-SA 4.0 (`license`, `attribution`); this converted data is CC BY-SA 4.0.",
        "-- terrain = base64(zstd(width * height bytes)), the tile byte format of WorldMap.luau.",
        "return {",
        "\tid = %s," % lua_str(mid),
        "\tname = %s," % lua_str(meta["name"]),
        "\tmodule = %s," % lua_str(mod),
        "\twidth = %d," % w2,
        "\theight = %d," % h2,
        "\tk_lin = %s," % lua_value(meta["k_lin"]),
        "\tcategories = %s," % lua_value(meta["categories"]),
        "\tmultiplayer_frequency = %d," % meta["multiplayer_frequency"],
        "\tforced_modifiers = %s," % lua_value(meta["forced_modifiers"]),
        "\tland_tiles = %d," % land,
        "\tlicense = %s," % lua_str(LICENSE),
        "\tattribution = %s," % lua_str(ATTRIBUTION),
        "\tsource = { width = %d, height = %d, land_tiles = %d }," % (w, h, man["map"]["num_land_tiles"]),
        "\tnations = {",
    ]
    for n in nations:
        lines.append("\t\t%s," % lua_value(n))
    lines += [
        "\t},",
        "\tcodec = \"zstd+base64\",",
        "\tsize = %d," % (w2 * h2),
        "\tterrain = \"%s\"," % b64,
        "}",
        "",
    ]
    os.makedirs(os.path.dirname(out_path(meta)), exist_ok=True)
    with open(out_path(meta), "w") as f:
        f.write("\n".join(lines))
    return meta


def write_registry(path, metas, default_id, commit):
    lines = [
        "-- GENERATED by tools/maps/import_maps.py. Do not edit.",
        "-- Registry of the playable maps (small and replicated: the map picker lists these without",
        "-- loading terrain). Terrain lives in src/server/MapData/<module>.luau (server only; clients",
        "-- fetch it through MapFetch) except the default map, which is replicated in",
        "-- src/shared/Data/Maps/<module>.luau so the title screen and default solo start instantly.",
        "--",
        "-- Licensed CC BY-SA 4.0 (`LICENSE`, `ATTRIBUTION`, `CREDITS`); converted map data is shared under the same",
        "-- licence. `SOURCE_COMMIT`: the commit the maps were imported from.",
        "local MapList = {}",
        "",
        "MapList.DEFAULT = %s" % lua_str(default_id),
        "MapList.LICENSE = %s" % lua_str(LICENSE),
        "MapList.ATTRIBUTION = %s" % lua_str(ATTRIBUTION),
        "MapList.CREDITS = %s" % lua_str(ATTRIBUTION_TEXT),
        "MapList.SOURCE_COMMIT = %s" % lua_str(commit),
        "",
        "--- {id, name, module, width, height, k_lin, categories, multiplayer_frequency, forced_modifiers,",
        "--- land_tiles, nations (count), replicated} sorted by name.",
        "MapList.maps = {",
    ]
    for m in sorted(metas, key=lambda m: m["name"].lower()):
        row = {
            "id": m["id"],
            "name": m["name"],
            "module": m["module"],
            "width": m["width"],
            "height": m["height"],
            "k_lin": m["k_lin"],
            "categories": m["categories"],
            "multiplayer_frequency": m["multiplayer_frequency"],
            "forced_modifiers": m["forced_modifiers"] or None,
            "land_tiles": m["land_tiles"],
            "nations": m["nation_count"],
            "replicated": m["replicated"] or None,
        }
        lines.append("\t%s," % lua_value(row))
    lines += [
        "}",
        "",
        "local by_id: { [string]: any } = {}",
        "for _, m in MapList.maps do",
        "\tby_id[m.id] = m",
        "end",
        "",
        "--- Registry row of map `id` (nil if unknown).",
        "function MapList.get(id: string): any",
        "\treturn by_id[id]",
        "end",
        "",
        "return MapList",
        "",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="OpenFrontIO checkout (contains resources/maps)")
    ap.add_argument("--budget", type=int, default=2500000, help="max tiles per map (default 2,500,000)")
    ap.add_argument("--only", default="", help="comma-separated map ids (directory names) to import")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ap.add_argument("--lune", default=os.path.join(REPO, ".bin", "lune"))
    ap.add_argument("--default", default="world", help="default map id (replicated to clients)")
    ap.add_argument("--no-registry", action="store_true", help="do not rewrite MapList.luau")
    args = ap.parse_args()

    maps_dir = os.path.join(args.src, "resources", "maps")
    names = sorted(d for d in os.listdir(maps_dir) if os.path.isfile(os.path.join(maps_dir, d, "manifest.json")))
    def real_world(d):
        with open(os.path.join(maps_dir, d, "manifest.json")) as f:
            return not (set(json.load(f).get("categories", [])) & EXCLUDED_CATEGORIES)
    names = [d for d in names if real_world(d)]
    if args.only:
        want = set(x.strip() for x in args.only.split(",") if x.strip())
        names = [d for d in names if d in want]
    commit = "unknown"
    try:
        commit = subprocess.run(["git", "-C", args.src, "rev-parse", "HEAD"], capture_output=True,
                                text=True, check=True).stdout.strip()
    except Exception:
        pass

    jobs = [(args.src, d, args.budget, args.lune, None, args.default) for d in names]
    metas = []
    with multiprocessing.Pool(args.jobs) as pool:
        for meta in pool.imap_unordered(_run, jobs):
            metas.append(meta)
            print("%-24s %5dx%-5d k_lin %.3f land %8d nations %3d (on land %d/%d) zstd %7d B" % (
                meta["id"], meta["width"], meta["height"], meta["k_lin"], meta["land_tiles"],
                meta["nation_count"], meta["nations_on_land"], meta["nations_with_coords"], meta["zstd_bytes"]))
            sys.stdout.flush()
    metas_path = os.path.join(REPO, "build", "maps", "metas.json")
    if not args.no_registry and args.only and not os.path.exists(metas_path):
        # a partial import must not replace the registry with just these maps
        print("--only without build/maps/metas.json (from a full import): MapList.luau left unchanged")
    elif not args.no_registry:
        # keep registry rows of maps not re-imported this run
        reg = os.path.join(REPO, "src", "shared", "Data", "MapList.luau")
        if args.only:
            with open(metas_path) as f:
                old = {m["id"]: m for m in json.load(f)}
            for m in metas:
                old[m["id"]] = m
            all_metas = list(old.values())
        else:
            all_metas = metas
        os.makedirs(os.path.join(REPO, "build", "maps"), exist_ok=True)
        with open(os.path.join(REPO, "build", "maps", "metas.json"), "w") as f:
            json.dump(all_metas, f, indent=1)
        write_registry(reg, all_metas, args.default, commit)
    total = sum(m["zstd_bytes"] for m in metas)
    print("imported %d maps, %.1f MB zstd (%.1f MB base64)" % (len(metas), total / 1e6, total * 4 / 3 / 1e6))


def _out_path(meta):
    if meta["replicated"]:
        return os.path.join(REPO, "src", "shared", "Data", "Maps", meta["module"] + ".luau")
    return os.path.join(REPO, "src", "server", "MapData", meta["module"] + ".luau")


def _run(job):
    src, d, budget, lune, _, default_id = job
    return import_map((src, d, budget, lune, _out_path, default_id))


if __name__ == "__main__":
    main()
