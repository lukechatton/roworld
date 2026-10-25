#!/usr/bin/env python3
"""Bake the globe's static images from AIRFRONT's world art (re-runnable).

Sources (never modified): ~/games/airfront/assets/world/{earth_color.jpg, landmask.png, relief.png}
(4096 x 2048 equirectangular, lon -180..180 left->right, lat 90..-90 top->bottom).

Outputs (assets/globe/, then uploaded with tools/upload.py; manifest src/shared/Assets/Globe.luau):
  base_eq.png        1024 x 512 equirect of the same (the fallback SpecialMesh sphere)
  cap_n / cap_s.png  1024^2 azimuthal projections of the same for |lat| >= 80 (polar cap meshes)
  base_<i>_<j>.png   4 x 2 tiles of 1024^2: the globe shader's *unclaimed* look (navy ocean, muted
                     satellite land with relief + highlight squash, coast antialiased by the landmask).
                     Shown by the static fallback sphere (before / without the territory compositor).
  col_<i>_<j>.png    RGB = processed satellite colour `col` of globe_body.gdshaderinc for unclaimed land
                     (mix(lum_k, sat_k, land_sat) * land_bright * shade), NOT mixed with the ocean.
  dat_<i>_<j>.png    R = L  (owned-tint luminance, clamp(0.5 + (lum_k - tint_mid) * tint_contrast +
                              (shade - 1) * tint_relief, 0.3, 0.7), encoded (L - 0.3) / 0.4 * 255)
                     G = relief (raw relief.png; shade = 1 + relief_amount * (g / 255 - 0.5))
                     B = coast SDF (signed distance to the landmask 0.5 contour in 4096-texel units,
                              land > 0, encoded 128 + 8 * d, clamped: +-16 texels = +-4 tiles)
  m_col_<j>.png / m_dat_<j>.png  mobile tier: the same maps at 2048 x 1024 (2 tiles of 1024^2)
  moon.png           512 x 256 equirect moon albedo * fixed sun lighting (moon.gdshader), for a
                     SpecialMesh sphere (UV layout verified in Studio, see build/notes/globe.md)
  sky_<face>.png     6 x 1024^2 cube faces: space_sky.gdshader (bg colour + 3 hashed star layers)
  rim.png            256 x 4 gradient ramps used by Atmosphere (row 0 rim, row 1 halo)

Usage: .venv/bin/python tools/globe/make_globe.py [--no-upload] [--only base,col,dat,moon,sky]
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.expanduser("~/games/airfront/assets/world")
OUT = os.path.join(ROOT, "assets", "globe")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "Globe.luau")
sys.path.insert(0, os.path.join(ROOT, "tools"))

LUMA = np.array([0.299, 0.587, 0.114], np.float32)
OCEAN = np.array([0.039, 0.035, 0.192], np.float32)
LAND_SAT, LAND_BRIGHT, RELIEF_AMOUNT, HIGHLIGHT_SQUASH = 0.72, 0.80, 0.9, 0.6
TINT_CONTRAST, TINT_RELIEF, TINT_MID = 0.62, 0.55, 0.3
SDF_SCALE = 8.0


def pole_smooth(a):
    """Horizontal box blur of each row over 1 / cos(lat) texels (wrapping): near the poles the
    equirect rows are hugely over-sampled and the original's mip-mapped sampling blurs them along
    longitude; a baked texture (and the CPU compositor) would otherwise show radial streaks."""
    h, w = a.shape[:2]
    out = a.astype(np.float32).copy()
    for y in range(h):
        lat = (0.5 - (y + 0.5) / h) * np.pi
        k = int(round(min(1.0 / max(np.cos(lat), 1e-3), 256)))
        if k <= 1:
            continue
        row = out[y]
        ext = np.concatenate([row[-k:], row, row[:k]], axis=0)
        cs = np.cumsum(ext, axis=0, dtype=np.float64)
        cs = np.concatenate([np.zeros((1,) + cs.shape[1:]), cs], axis=0)
        lo = k // 2
        hi = k - lo
        idx = np.arange(w) + k
        out[y] = ((cs[idx + hi] - cs[idx - lo]) / k).astype(np.float32)
    return out


def load():
    earth = np.asarray(Image.open(os.path.join(SRC, "earth_color.jpg")).convert("RGB"), np.float32) / 255.0
    land = np.asarray(Image.open(os.path.join(SRC, "landmask.png")).convert("L"), np.float32) / 255.0
    relief = np.asarray(Image.open(os.path.join(SRC, "relief.png")).convert("L"), np.uint8)
    earth = pole_smooth(earth)
    relief = np.clip(np.round(pole_smooth(relief.astype(np.float32))), 0, 255).astype(np.uint8)
    return earth, land, relief


CAP_LAT = 80.0


def polar_cap(eq, sign, size=1024):
    """Azimuthal (polar) projection of an equirect image for |lat| >= CAP_LAT: pixel (x, y) at
    r = dist from centre / (size / 2) -> lat = sign * (90 - r * (90 - CAP_LAT)),
    lon = atan2(x - c, -(y - c)) (north cap: lon 0 up); south cap: lon 0 up, mirrored so the
    texture reads as seen from outside (matches tools/globe/upload_meshes.py cap UVs)."""
    h, w = eq.shape[:2]
    c = (size - 1) / 2.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    dx, dy = (xx - c) / (size / 2.0), (yy - c) / (size / 2.0)
    r = np.clip(np.sqrt(dx * dx + dy * dy), 0, 1)
    lat = sign * (90.0 - r * (90.0 - CAP_LAT))
    lon = np.degrees(np.arctan2(dx, -dy)) * sign
    fx = (lon + 180.0) / 360.0 * w - 0.5
    fy = (90.0 - lat) / 180.0 * h - 0.5
    x0 = np.floor(fx).astype(int)
    y0 = np.clip(np.floor(fy).astype(int), 0, h - 1)
    wx = (fx - x0)[..., None]
    wy = (fy - np.floor(fy))[..., None]
    x1 = (x0 + 1) % w
    x0 = x0 % w
    y1 = np.clip(y0 + 1, 0, h - 1)
    top = eq[y0, x0] * (1 - wx) + eq[y0, x1] * wx
    bot = eq[y1, x0] * (1 - wx) + eq[y1, x1] * wx
    return top * (1 - wy) + bot * wy


def shade_of(relief_u8):
    return 1.0 + RELIEF_AMOUNT * (relief_u8.astype(np.float32) / 255.0 - 0.5)


def looks(earth, relief_u8):
    """(col, L) exactly as globe_body.gdshaderinc (sRGB space)."""
    lum = earth @ LUMA
    lum_k = lum - np.maximum(lum - 0.5, 0.0) * HIGHLIGHT_SQUASH
    sat_k = earth * (lum_k / np.maximum(lum, 1e-3))[..., None]
    shade = shade_of(relief_u8)
    col = (lum_k[..., None] + (sat_k - lum_k[..., None]) * LAND_SAT) * LAND_BRIGHT * shade[..., None]
    L = np.clip(0.5 + (lum_k - TINT_MID) * TINT_CONTRAST + (shade - 1.0) * TINT_RELIEF, 0.3, 0.7)
    return np.clip(col, 0, 1), L


def coast_sdf(land):
    """Signed distance (texels of `land`'s grid) to the 0.5 contour, land positive. Computed on a
    2x bilinear upsample so the contour is sub-texel accurate. x wraps (EDT on a padded strip)."""
    h, w = land.shape
    pad = 64
    ext = np.concatenate([land[:, -pad:], land, land[:, :pad]], axis=1)
    up = np.asarray(Image.fromarray((ext * 255).astype(np.uint8)).resize((ext.shape[1] * 2, h * 2), Image.BILINEAR),
                    np.float32) / 255.0
    inside = up >= 0.5
    d_in = ndimage.distance_transform_edt(inside)
    d_out = ndimage.distance_transform_edt(~inside)
    sdf2 = np.where(inside, d_in - 0.5, -(d_out - 0.5))
    # sample back at the original texel centres (2x grid: centre of texel k = 2k + 0.5)
    s = (sdf2[0::2, 0::2] + sdf2[1::2, 0::2] + sdf2[0::2, 1::2] + sdf2[1::2, 1::2]) * 0.25
    s = s[:, pad:pad + w] / 2.0
    return s.astype(np.float32)


def to_u8(a):
    return np.clip(np.round(a * 255.0), 0, 255).astype(np.uint8)


# Roblox 3D output crushes the darkest values (Lighting.Technology Compatibility, measured
# in -> out: 5->2, 10->5, 15->11, 20->17, 25->22, identity from ~30): displayed textures are written
# through the inverse so they come out as the shader's values (same table as GlobeCompositor.INV).
_CURVE = [(0, 0), (5, 2), (10, 5), (15, 11), (20, 17), (25, 22), (30, 29), (35, 35)]


def _inv_table():
    inv = np.arange(256, dtype=np.float64)
    for t in range(35):
        for (a0, b0), (a1, b1) in zip(_CURVE, _CURVE[1:]):
            if b0 <= t <= b1:
                inv[t] = a0 + (a1 - a0) * (t - b0) / max(b1 - b0, 1)
                break
    return np.clip(np.round(inv), 0, 255).astype(np.uint8)


INV = _inv_table()


def to_u8_display(a):
    return INV[to_u8(a)]


def save_tiles(arr, prefix, tiles_x, tiles_y, size=1024):
    paths = {}
    for j in range(tiles_y):
        for i in range(tiles_x):
            t = arr[j * size:(j + 1) * size, i * size:(i + 1) * size]
            p = os.path.join(OUT, f"{prefix}_{i}_{j}.png")
            Image.fromarray(t).save(p, optimize=True)
            paths[(i, j)] = p
    return paths


def box2(a):
    return (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2]) * 0.25


# ------------------------------------------------------------------------------------------------
# shader hash helpers (float32 like the GPU)
# ------------------------------------------------------------------------------------------------

def fract(x):
    return x - np.floor(x)


def hash33(p):
    p = p.astype(np.float32)
    p = fract(p * np.array([0.1031, 0.1030, 0.0973], np.float32))
    d = (p * (p[..., [1, 0, 2]] + np.float32(33.33))).sum(-1, keepdims=True)
    p = p + d
    a = p[..., [0, 0, 1]] + p[..., [1, 0, 0]]
    b = p[..., [2, 1, 0]]
    return fract(a * b).astype(np.float32)


def hash12(p):
    p3 = fract(np.stack([p[..., 0], p[..., 1], p[..., 0]], -1).astype(np.float32) * np.float32(0.1031))
    d = (p3 * (p3[..., [1, 2, 0]] + np.float32(33.33))).sum(-1, keepdims=True)
    p3 = p3 + d
    return fract((p3[..., 0] + p3[..., 1]) * p3[..., 2]).astype(np.float32)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ------------------------------------------------------------------------------------------------
# sky (space_sky.gdshader) as Roblox cube faces
# ------------------------------------------------------------------------------------------------

BG = np.array([0.008, 0.022, 0.026], np.float32)
STAR_DENSITY, STAR_BRIGHTNESS = 0.16, 0.55
# The original sizes stars to the pixel footprint (star_radius = 1.6 px): 0.0009 rad at its 1800 px
# captures; a 1024 skybox texel is 0.0015 rad, so stars are ~0.6 texel (faint single-texel dots).
STAR_GAIN = 1.7   # compensates the supersampled sub-texel core


def star_layer(d, scale, seed, density, radius):
    c = np.floor(d * scale)
    h = hash33(c + seed)
    sp = (c + 0.25 + 0.5 * hash33(c * 1.7 + seed + 3.1)) / scale
    sp = sp / np.linalg.norm(sp, axis=-1, keepdims=True)
    ang = np.linalg.norm(d - sp, axis=-1)
    r = radius * (0.7 + 0.8 * h[..., 1])
    core = 1.0 - smoothstep(0.0, r, ang)
    v = core * core * (0.25 + 0.75 * h[..., 2] * h[..., 2])
    return np.where(h[..., 0] > density, 0.0, v)


# Roblox skybox faces: direction for face pixel (u right, v down), u,v in [-1, 1].
# Verified in Studio with labelled faces (see notes): Ft looks -Z? The mapping below is filled in
# from that test; FACES maps name -> (forward, right, up) world vectors of the face centre.
FACES = {
    "ft": ((0, 0, -1), (1, 0, 0), (0, 1, 0)),
    "bk": ((0, 0, 1), (-1, 0, 0), (0, 1, 0)),
    "lf": ((-1, 0, 0), (0, 0, -1), (0, 1, 0)),
    "rt": ((1, 0, 0), (0, 0, 1), (0, 1, 0)),
    "up": ((0, 1, 0), (0, 0, 1), (-1, 0, 0)),
    "dn": ((0, -1, 0), (0, 0, 1), (1, 0, 0)),
}


def sky_face(name, size=1024, ss=3, radius=0.0009, label=False):
    fwd, right, up = (np.array(v, np.float32) for v in FACES[name])
    n = size * ss
    t = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    u, v = np.meshgrid(t, t)
    d = fwd[None, None, :] + u[..., None] * right[None, None, :] - v[..., None] * up[None, None, :]
    d = d / np.linalg.norm(d, axis=-1, keepdims=True)
    s = star_layer(d, 70.0, 11.0, STAR_DENSITY * 0.7, radius)
    s = s + star_layer(d, 160.0, 37.0, STAR_DENSITY, radius)
    s = s + 0.6 * star_layer(d, 330.0, 71.0, STAR_DENSITY * 0.8, radius)
    tint_k = hash12(np.floor(d[..., :2] * 97.0))[..., None]
    tint = np.array([0.75, 0.82, 1.0], np.float32) * (1 - tint_k) + np.array([1.0, 0.92, 0.8], np.float32) * tint_k
    col = BG[None, None, :] + tint * (s * STAR_BRIGHTNESS * STAR_GAIN)[..., None]
    col = np.clip(col.reshape(size, ss, size, ss, 3).mean(axis=(1, 3)), 0, 1)
    img = Image.fromarray(to_u8_display(np.clip(col, 0, 1)))
    if label:
        from PIL import ImageDraw
        dr = ImageDraw.Draw(img)
        dr.rectangle([0, 0, size - 1, size - 1], outline=(255, 0, 0), width=6)
        dr.text((size // 2 - 40, size // 2 - 20), name.upper(), fill=(255, 255, 0))
        dr.line([size // 2, size // 2, size // 2, 60], fill=(0, 255, 0), width=8)   # arrow to "up" edge
        dr.line([size // 2, size // 2, size - 60, size // 2], fill=(255, 0, 255), width=8)   # to "right"
    return img


# ------------------------------------------------------------------------------------------------
# moon (moon.gdshader), equirect lat/lon texture
# ------------------------------------------------------------------------------------------------

def vnoise(p):
    i = np.floor(p)
    f = p - i
    f = f * f * (3.0 - 2.0 * f)

    def h(o):
        return hash33(i + np.array(o, np.float32))[..., 0]
    n000, n100, n010, n110 = h((0, 0, 0)), h((1, 0, 0)), h((0, 1, 0)), h((1, 1, 0))
    n001, n101, n011, n111 = h((0, 0, 1)), h((1, 0, 1)), h((0, 1, 1)), h((1, 1, 1))
    fx, fy, fz = f[..., 0], f[..., 1], f[..., 2]
    a = n000 + (n100 - n000) * fx
    b = n010 + (n110 - n010) * fx
    c = n001 + (n101 - n001) * fx
    d = n011 + (n111 - n011) * fx
    return (a + (b - a) * fy) + ((c + (d - c) * fy) - (a + (b - a) * fy)) * fz


def craters(p):
    c = np.floor(p)
    v = np.zeros(p.shape[:-1], np.float32)
    for k in range(8):
        o = np.array([k & 1, (k >> 1) & 1, (k >> 2) & 1], np.float32)
        cell = c + o
        h = hash33(cell)
        cp = cell + h
        r = 0.25 + 0.35 * h[..., 2]
        d = np.linalg.norm(p - cp, axis=-1) / r
        v += (smoothstep(1.0, 0.75, d) * 0.6 - smoothstep(1.15, 1.0, d) * smoothstep(0.85, 1.0, d) * 0.5) * \
            (h[..., 0] >= 0.45)
    return v


def moon_texture(w=512, h=256):
    lon = ((np.arange(w, dtype=np.float32) + 0.5) / w * 2.0 - 1.0) * np.pi
    lat = (0.5 - (np.arange(h, dtype=np.float32) + 0.5) / h) * np.pi
    lo, la = np.meshgrid(lon, lat)
    p = np.stack([np.cos(la) * np.sin(lo), np.sin(la), np.cos(la) * np.cos(lo)], -1).astype(np.float32)
    maria = smoothstep(0.45, 0.65, vnoise(p * 2.3 + 4.0)) * 0.28
    cr = craters(p * 5.0) * 0.12 + craters(p * 11.0) * 0.07
    base = np.array([0.66, 0.66, 0.64], np.float32)
    albedo = base * (1.0 - maria - cr)[..., None] + (vnoise(p * 30.0) * 0.05)[..., None]
    sun = np.array([0.35, 0.3, 0.9], np.float32)
    sun = sun / np.linalg.norm(sun)
    lit = np.clip(p @ sun, 0.0, 1.0)
    lit = smoothstep(0.0, 0.35, lit) * 0.9 + 0.035
    return Image.fromarray(to_u8_display(np.clip(albedo * lit[..., None], 0, 1)))


# ------------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--sky-label", action="store_true", help="draw face labels (orientation test)")
    args = ap.parse_args()
    only = set(args.only.split(",")) if args.only else {"base", "col", "dat", "moon", "sky", "embed"}
    os.makedirs(OUT, exist_ok=True)
    files = {}

    if only & {"base", "col", "dat"}:
        earth, land, relief = load()
        col, L = looks(earth, relief)
        if "base" in only:
            cov = land[..., None]
            base = OCEAN[None, None, :] * (1 - cov) + col * cov
            for k, p in save_tiles(to_u8_display(base), "base", 4, 2).items():
                files[f"base_{k[0]}_{k[1]}"] = p
            # one 1024 x 512 equirect for the fallback sphere (SpecialMesh sphere: no editable budget)
            eq = base.reshape(512, 4, 1024, 4, 3).mean(axis=(1, 3))
            p = os.path.join(OUT, "base_eq.png")
            Image.fromarray(to_u8_display(eq)).save(p)
            files["base_eq"] = p
            # polar caps (|lat| >= 80): azimuthal projection, so the pole has no lat/lon convergence
            for name, sign in (("cap_n", 1), ("cap_s", -1)):
                p = os.path.join(OUT, f"{name}.png")
                Image.fromarray(to_u8_display(polar_cap(base, sign))).save(p)
                files[name] = p
            print("base done")
        if "col" in only:
            for k, p in save_tiles(to_u8(col), "col", 4, 2).items():
                files[f"col_{k[0]}_{k[1]}"] = p
            mcol = box2(col)
            for k, p in save_tiles(to_u8(mcol), "m_col", 2, 1).items():
                files[f"m_col_{k[0]}_{k[1]}"] = p
            print("col done")
        if "dat" in only:
            sdf = coast_sdf(land)
            lq = to_u8((L - 0.3) / 0.4)
            sq = np.clip(np.round(128.0 + sdf * SDF_SCALE), 0, 255).astype(np.uint8)
            dat = np.stack([lq, relief, sq], -1)
            for k, p in save_tiles(dat, "dat", 4, 2).items():
                files[f"dat_{k[0]}_{k[1]}"] = p
            # mobile: 2048 x 1024; sdf in mobile texels = sdf / 2
            ml = to_u8((box2(L) - 0.3) / 0.4)
            mr = np.clip(np.round(box2(relief.astype(np.float32))), 0, 255).astype(np.uint8)
            ms = np.clip(np.round(128.0 + box2(sdf) * 0.5 * SDF_SCALE), 0, 255).astype(np.uint8)
            for k, p in save_tiles(np.stack([ml, mr, ms], -1), "m_dat", 2, 1).items():
                files[f"m_dat_{k[0]}_{k[1]}"] = p
            np.save(os.path.join(ROOT, "build", "globe_sdf_stats.npy"), np.array([sdf.min(), sdf.max()]))
            print("dat done", float(sdf.min()), float(sdf.max()))
    if "embed" in only:
        write_embedded()
    if "moon" in only:
        p = os.path.join(OUT, "moon.png")
        moon_texture().save(p)
        files["moon"] = p
        print("moon done")
    if "sky" in only:
        for f in FACES:
            p = os.path.join(OUT, f"sky_{f}{'_label' if args.sky_label else ''}.png")
            sky_face(f, label=args.sky_label).save(p)
            files[f"sky_{f}"] = p
        print("sky done")

    if args.no_upload:
        mf = os.path.join(ROOT, "build", "globe_manifest.json")
        if os.path.exists(mf):
            write_manifest(json.load(open(mf)))
        return
    import upload
    ids = upload.upload_images(list(files.values()))
    man = {}
    if os.path.exists(os.path.join(ROOT, "build", "globe_manifest.json")):
        man = json.load(open(os.path.join(ROOT, "build", "globe_manifest.json")))
    for k, p in files.items():
        man[k] = ids[os.path.abspath(p)]
    json.dump(man, open(os.path.join(ROOT, "build", "globe_manifest.json"), "w"), indent=1, sort_keys=True)
    write_manifest(man)


EMBED_DIR = os.path.join(ROOT, "src", "shared", "Assets", "GlobeData")
EMBED_PART = 280_000   # chars per module (tools/sync.py pushes <= 350 KB per call)
EMBED_STRIP = 64       # rows per independently compressed frame (the client decodes one per slice)


def write_embedded():
    """The 2048 x 1024 look maps as Luau modules (no EditableImage needed to read them):
    planes R, G, B (col), L, relief, sdf — each row horizontally delta-coded. Format 2: every plane
    is cut into strips of EMBED_STRIP rows, each strip zstd-compressed on its own (EncodingService on
    the client) and base64-encoded, so the client can decode it a strip at a time without a long
    frame; the Part modules return lists of those strings, in order (plane-major)."""
    import base64
    import zstandard as zstd
    col = np.concatenate([np.asarray(Image.open(os.path.join(OUT, f"m_col_{i}_0.png")).convert("RGB")) for i in range(2)], axis=1)
    dat = np.concatenate([np.asarray(Image.open(os.path.join(OUT, f"m_dat_{i}_0.png")).convert("RGB")) for i in range(2)], axis=1)
    planes = [col[..., 0], col[..., 1], col[..., 2], dat[..., 0], dat[..., 1], dat[..., 2]]
    h = planes[0].shape[0]
    assert h % EMBED_STRIP == 0
    frames = []
    raw_size = 0
    cz = zstd.ZstdCompressor(level=19)
    for pl in planes:
        d = pl.astype(np.int16)
        d[:, 1:] = d[:, 1:] - d[:, :-1]
        raw = (d % 256).astype(np.uint8)
        for r0 in range(0, h, EMBED_STRIP):
            b = raw[r0:r0 + EMBED_STRIP].tobytes()
            raw_size += len(b)
            frames.append(base64.b64encode(cz.compress(b)).decode())
    os.makedirs(EMBED_DIR, exist_ok=True)
    for f in os.listdir(EMBED_DIR):
        if f.endswith(".luau"):
            os.remove(os.path.join(EMBED_DIR, f))
    parts, cur, size = [], [], 0
    for fr in frames:
        if cur and size + len(fr) > EMBED_PART:
            parts.append(cur)
            cur, size = [], 0
        cur.append(fr)
        size += len(fr) + 4
    if cur:
        parts.append(cur)
    for k, lst in enumerate(parts):
        with open(os.path.join(EMBED_DIR, f"Part{k + 1:02d}.luau"), "w") as f:
            f.write("-- Generated by tools/globe/make_globe.py (embedded globe look maps, part %d/%d).\n" % (k + 1, len(parts)))
            f.write("return {\n")
            for fr in lst:
                f.write('\t"' + fr + '",\n')
            f.write("}\n")
    with open(os.path.join(EMBED_DIR, "init.luau"), "w") as f:
        f.write("-- Generated by tools/globe/make_globe.py — the globe's look maps embedded as Luau data so\n")
        f.write("-- the territory compositor never depends on EditableImage read-back. 2048 x 1024 texels,\n")
        f.write("-- planes R G B (col) L relief sdf, rows delta-coded; format 2: strips of strip_rows rows,\n")
        f.write("-- each zstd + base64 on its own, listed in order (plane-major) by the Part modules.\n")
        f.write("return {\n")
        f.write("\tformat = 2,\n\twidth = %d,\n\theight = %d,\n\tplanes = 6,\n\tsdf_scale = %d,\n" % (planes[0].shape[1], h, int(SDF_SCALE)))
        f.write("\tstrip_rows = %d,\n\tframes = %d,\n" % (EMBED_STRIP, len(frames)))
        f.write("\traw_size = %d,\n\tparts = %d,\n" % (raw_size, len(parts)))
        f.write("}\n")
    print("embedded", sum(len(fr) for fr in frames) * 3 // 4, "bytes zstd,", len(frames), "frames,", len(parts), "parts")


def write_manifest(man):
    lines = [
        "-- Generated by tools/globe/make_globe.py — do not edit. Globe images (see the tool's header).",
        "-- base_i_j / col_i_j / dat_i_j: 4 x 2 tiles of 1024^2 (i = lon quarter from -180, j = 0 north);",
        "-- m_col_i_0 / m_dat_i_0: mobile 2048 x 1024 maps as 2 tiles; moon; sky_<face>.",
        "return {",
        "\tsdf_scale = 8,",
    ]
    for k in sorted(man):
        lines.append(f'\t{k} = "{man[k]}",')
    # static meshes (tools/globe/upload_meshes.py): id + local bounds (centre, size) in studs
    mp = os.path.join(ROOT, "build", "globe_meshes.json")
    if os.path.exists(mp):
        meshes = json.load(open(mp))
        lines.append("\tmeshes = {")
        for k in sorted(meshes):
            m = meshes[k]
            if not m.get("mesh_id"):
                continue
            c = ", ".join(f"{v:.4f}" for v in m["center"])
            z = ", ".join(f"{v:.4f}" for v in m["size"])
            lines.append(f'\t\t{k} = {{ id = "{m["mesh_id"]}", center = {{ {c} }}, size = {{ {z} }} }},')
        lines.append("\t},")
    lines.append("}")
    open(MANIFEST, "w").write("\n".join(lines) + "\n")
    print("manifest", MANIFEST, len(man), "entries")


if __name__ == "__main__":
    main()
