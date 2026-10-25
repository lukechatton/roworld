#!/usr/bin/env python3
"""Generate the overlays-b FX textures (particles, beams, trails, range-ring lines, warship overlays)
and upload them; writes src/shared/Assets/Fx.luau.

Ports the procedural looks of the original shaders (~/games/airfront/shaders/fx_*.gdshader,
combat_fx.gdshaderinc, range_ring.gdshader, map_icon.gdshader procedural modes) into static images:
white RGB + alpha masks are tinted at runtime (ParticleEmitter.Color / Beam.Color / ImageColor3);
two-tone looks (dark halo + bright line, white-hot core in a tinted glow) are split into layers.

Usage: .venv/bin/python tools/fx/make_fx.py [--no-upload]
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "out")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "Fx.luau")
sys.path.insert(0, os.path.join(ROOT, "tools"))


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def grid(w, h=None):
    h = h or w
    y, x = np.mgrid[0:h, 0:w]
    u = (x + 0.5) / w
    v = (y + 0.5) / h
    return u, v


def radial(n):
    u, v = grid(n)
    qx, qy = u * 2 - 1, v * 2 - 1
    return np.sqrt(qx * qx + qy * qy), qx, qy


def hash12(px, py):
    p3x = np.modf(px * 0.1031)[0]
    p3y = np.modf(py * 0.1031)[0]
    p3z = np.modf(px * 0.1031)[0]
    d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x, p3y, p3z = p3x + d, p3y + d, p3z + d
    return np.modf((p3x + p3y) * p3z)[0] % 1.0


def vnoise(px, py):
    ix, iy = np.floor(px), np.floor(py)
    fx, fy = px - ix, py - iy
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    a = hash12(ix, iy)
    b = hash12(ix + 1, iy)
    c = hash12(ix, iy + 1)
    d = hash12(ix + 1, iy + 1)
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy


# The original blended these FX in LINEAR space (Godot); Roblox blends in sRGB space. For an overlay
# over a dark background the linear result is ~ (alpha * colour_lin)^(1/2.2) in sRGB, and that power
# law is multiplicative, so storing profile^(1/2.2) in the texture (and gamma-matching the global
# alpha at runtime, FxLayer.ga) reproduces the original's falloff: glows keep their wide soft halo.
# (additive glows / rings / ribbons only: they mostly sit on the dark ocean or space; the dome, smoke
# and scorch cover land, where the linear / sRGB difference is small — FxLayer.ga handles those)
GAMMA_ALPHA = {"glow_soft", "glow_wide", "glow_flash", "glow_core", "glow_combat", "hot_core", "spark",
               "ring_thin", "ring_shock", "warhead_ring", "ribbon_soft", "ribbon_solid"}
# (blast_ring / blast_ring_soft: not gamma-encoded — the nuke shockwave lies over lit land, where the
# encoded soft halo read as a thick fuzzy band with a blue rim; overlay-fixer, visual review P1-6)


def save(name, rgb, a):
    """rgb: HxWx3 in 0..1 (or scalar grey), a: HxW in 0..1."""
    a = np.clip(a, 0, 1)
    if name in GAMMA_ALPHA:
        a = a ** (1 / 2.2)
    if np.isscalar(rgb):
        rgb = np.ones(a.shape + (3,)) * rgb
    elif rgb.ndim == 2:
        rgb = np.repeat(rgb[..., None], 3, axis=2)
    img = np.zeros(a.shape + (4,), np.uint8)
    img[..., :3] = np.clip(rgb * 255 + 0.5, 0, 255).astype(np.uint8)
    img[..., 3] = np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8)
    path = os.path.join(OUT, name + ".png")
    Image.fromarray(img, "RGBA").save(path)
    return path


def glow(n, falloff, core):
    """fx_glow.gdshader profile, normalised to a peak of 1."""
    r, _, _ = radial(n)
    a = np.exp(-r * r * falloff) * (1 - smoothstep(0.8, 1.0, r))
    a = a + core * (1 - smoothstep(0.0, 0.22, r)) * (0.35 + 0.65 * np.exp(-r * r * 30))
    return a / a.max()


def build():
    os.makedirs(OUT, exist_ok=True)
    files = {}
    # --- glows (additive; tinted by Color) -----------------------------------------------
    files["glow_soft"] = save("glow_soft", 1.0, glow(256, 4.0, 0.0))
    files["glow_wide"] = save("glow_wide", 1.0, glow(256, 2.0, 0.0))
    files["glow_flash"] = save("glow_flash", 1.0, glow(256, 3.0, 0.25))
    files["glow_core"] = save("glow_core", 1.0, glow(128, 4.0, 0.9))
    # combat flash / shell head glow (exp(-r^2 4) in the shader, widened: HDR additive in linear
    # space kept the halo visible further out than an sRGB blend does)
    files["glow_combat"] = save("glow_combat", 1.0, glow(256, 4.0, 0.0))
    r, qx, qy = radial(128)
    # hot core of a combat flash / shell head (white layer over the tinted glow)
    files["hot_core"] = save("hot_core", 1.0, np.exp(-r * r * 22) * (1 - smoothstep(0.8, 1, r)))
    # combat flash glow (exp(-r^2 4)) and spark / debris dot (exp(-r^2 9))
    files["spark"] = save("spark", 1.0, np.exp(-r * r * 9) * (1 - smoothstep(0.85, 1, r)))
    # --- rings lying on the surface ------------------------------------------------------
    n = 256
    r, _, _ = radial(n)
    px = 2.0 / n
    # band ~1.4 px on screen at typical sizes (the original's band is pixel-constant: fwidth-based)
    for name, w, inner in (("ring_thin", 0.05, 0.06), ("ring_shock", 0.055, 0.10)):
        band = 1 - smoothstep(w * 0.5, w * 0.5 + px * 1.5, np.abs(r - 0.82))
        fill = (1 - smoothstep(0.55, 0.82, r)) * inner
        files[name] = save(name, 1.0, (band + fill) * (1 - smoothstep(0.96, 1.0, r)))
    n = 512
    r, _, _ = radial(n)
    px = 2.0 / n
    for name, w, fill_k in (("blast_ring_soft", 0.08, 0.0), ("warhead_ring", 0.04, 0.0)):
        ring = 1 - smoothstep(w * 0.5, w * 0.5 + px * 1.5, np.abs(r - 0.8))
        soft = np.exp(-(((r - 0.8) / (w * 2.5)) ** 2)) * 0.15
        inner = fill_k * (1 - smoothstep(0.8 - px, 0.8, r)) * (0.35 + 0.65 * r / 0.8) / max(fill_k, 1e-6) * fill_k
        a = (np.maximum(ring, soft) + inner) * (1 - smoothstep(0.96, 1.0, r))
        files[name] = save(name, 1.0, a)
    # the nuke shockwave: a crisp white core band (~4 px at its final size, like the original's
    # ring_w 0.025 + its fwidth AA) in a narrow dark halo (reads crisp over lit land when drawn
    # mostly alpha-blended), a faint soft glow and the faint inner fill (fx_ring: fill 0.05)
    w = 0.034
    d = np.abs(r - 0.8)
    core = 1 - smoothstep(w * 0.5, w * 0.5 + px * 1.5, d)
    halo = (1 - smoothstep(w * 1.2, w * 1.2 + px * 2.0, d)) * 0.4
    soft = np.exp(-((d / (w * 3.0)) ** 2)) * 0.1
    inner = 0.05 * (1 - smoothstep(0.8 - px, 0.8, r)) * (0.35 + 0.65 * r / 0.8)
    a_dark = np.maximum(halo - core, 0)
    a = np.clip(core + a_dark + np.maximum(soft + inner - core - a_dark, 0), 0, 1)
    rgb_v = (core * 1.0 + a_dark * 0.08 + np.maximum(soft + inner - core - a_dark, 0) * 1.0) / np.maximum(a, 1e-4)
    a = a * (1 - smoothstep(0.96, 1.0, r))
    files["blast_ring"] = save("blast_ring", np.clip(rgb_v, 0, 1), a)
    # --- smoke / dust (alpha blended, grey-white; tinted by Color) ------------------------
    n = 256
    u, v = grid(n)
    qx, qy = u - 0.5, v - 0.5
    r = np.sqrt(qx * qx + qy * qy) * 2
    nz = vnoise(qx * 5 + 3.1, qy * 5 + 1.7) * 0.6 + vnoise(qx * 11 - 2.0, qy * 11 + 5.0) * 0.4
    a = (1 - smoothstep(0.35 + 0.35 * nz, 1.0, r)) * (0.65 + 0.35 * nz)
    files["smoke"] = save("smoke", np.clip(0.85 + 0.3 * nz, 0, 1) / 1.15, a)
    # --- scorch: ash base + ember layer ---------------------------------------------------
    nz = vnoise(qx * 9 + 7.7, qy * 9 + 2.2) * 0.6 + vnoise(qx * 23 - 1.3, qy * 23 + 4.1) * 0.4
    edge = 1 - smoothstep(0.5 + 0.3 * nz, 1.0, r)
    core = 1 - smoothstep(0.0, 0.6, r)
    files["scorch_ash"] = save("scorch_ash", 0.85 + 0.15 * nz, edge)
    # ember spots (red-orange, fading with heat) and the hot core (light orange) as separate layers
    files["scorch_ember"] = save("scorch_ember", 1.0, smoothstep(0.42, 0.78, nz) * edge)
    files["scorch_core"] = save("scorch_core", 1.0, core * edge)
    # --- fireball dome (lit sphere, grey; tinted hot -> ash over its life) ------------------
    n = 256
    u, v = grid(n)
    qx, qy = u * 2 - 1, -(v * 2 - 1)
    r2 = qx * qx + qy * qy
    rr = np.sqrt(r2)
    nzz = np.sqrt(np.clip(1 - r2, 0, 1))
    L = np.array([-0.45, 0.55, 0.7])
    L = L / np.linalg.norm(L)
    lit = 0.6 + 0.4 * (qx * L[0] + qy * L[1] + nzz * L[2])
    shade = lit * (1.0 - 0.22 * r2)
    a = (1 - smoothstep(0.9, 1.0, rr)) * (0.35 + 0.45 * (1 - r2))
    files["dome"] = save("dome", np.clip(shade, 0, 1), a)
    # --- ribbons (Trail / Beam across-width profiles). Roblox maps a Beam texture's V (top ->
    # bottom) ALONG the beam and U ACROSS it, so profiles vary along the image's x axis.
    u, v = grid(64, 16)
    d = np.abs(u * 2 - 1)
    files["ribbon_solid"] = save("ribbon_solid", 1.0, np.clip((1 - d) * 6, 0, 1))
    files["ribbon_soft"] = save("ribbon_soft", 1.0, (1 - d) ** 1.6)
    # --- range-ring lines: dark halo | bright line | dark halo, solid / dashed / dotted ------
    W, H = 32, 128                   # U across the line, V along it (one dash period)
    u, v = grid(W, H)
    d = np.abs(u * 2 - 1)            # 0 centre .. 1 edge
    line = 1 - smoothstep(0.46, 0.54, d)   # line = centre 50 %
    halo = 1 - smoothstep(0.9, 1.0, d)
    for name, duty in (("ring_line_solid", 0.0), ("ring_line_dash", 0.62), ("ring_line_dot", 0.3)):
        if duty > 0:
            tw = 2.0 / H
            dash = smoothstep(0.0, tw, v) * (1 - smoothstep(duty - tw, duty, v))
        else:
            dash = np.ones_like(v)
        la = line * dash
        ha = halo * 0.3 * dash  # 0.42 in the original, blended in linear space (darker here in sRGB)
        a = la + ha * (1 - la)
        rgb = (1.0 * la + 0.1 * ha * (1 - la)) / np.maximum(a, 1e-4)
        files[name] = save(name, rgb, a)
    # --- range-ring fill bands (flat Beams lying on the globe; U across the band, V along).
    # profile FILL * (0.55 + 0.45 * smoothstep(0.55, 1, d)) split into d in [0.05, 0.55] (flat),
    # [0.55, 0.8] and [0.8, 1.0] (ramps), normalised to 1 at the rim, gamma-encoded (x^(1/2.2))
    W2 = 256   # wide: the wrap-around blend at the band edges stays sub-pixel
    u, v = grid(W2, 4)
    def prof(d):
        return 0.55 + 0.45 * smoothstep(0.55, 1.0, d)
    files["fill_flat"] = save("fill_flat", 1.0, np.full(u.shape, prof(0.3)) ** (1 / 2.2))
    # the centre of the fill (d < 0.12): a flat disc at the same level, crisp edge
    rr, _, _ = radial(128)
    disc = 1 - smoothstep(1.0 - 2.0 / 128, 1.0, rr)
    files["fill_disc"] = save("fill_disc", 1.0, disc * prof(0.3) ** (1 / 2.2))
    for name, d0, d1 in (("fill_mid", 0.55, 0.8), ("fill_out", 0.8, 1.0)):
        d = d0 + (d1 - d0) * u
        files[name] = save(name, 1.0, prof(d) ** (1 / 2.2))
    # --- warship overlays ---------------------------------------------------------------
    n = 128
    r, _, _ = radial(n)
    fw = 2.0 / n
    band = 1 - smoothstep(0.13 - fw, 0.13 + fw, np.abs(r - 0.8))
    halo = 1 - smoothstep(0.2 - fw, 0.2 + fw, np.abs(r - 0.8))
    a = np.maximum(halo * 0.3, band)
    rgb = np.where(band[..., None] > 0.01, 1.0, 0.0) * np.ones(r.shape + (3,))
    rgb = band[..., None] * np.ones(3) + (1 - band[..., None]) * np.array([0.04, 0.05, 0.09])
    files["sel_ring"] = save("sel_ring", rgb, a)
    # veterancy chevrons 1..3 (gold, dark outline): cell 0.3 x 0.46 of the glyph size
    CW, CH = 60, 92
    u, v = grid(CW, CH)
    qx, qy = u, 1 - v
    fwv = 1.0 / CH
    for cnt in (1, 2, 3):
        dd = np.full(u.shape, 1e3)
        for k in range(cnt):
            c = 0.16 + k * 0.29
            dd = np.minimum(dd, np.abs(qy - (c + 0.55 * np.abs(qx - 0.5) - 0.12)) - 0.07)
        dd = np.maximum(dd, np.abs(qx - 0.5) - 0.44)
        fill = 1 - smoothstep(-fwv, fwv, dd)
        edge = 1 - smoothstep(-fwv, fwv, dd - 0.07)
        rgb = np.array([0.08, 0.06, 0.02]) * (1 - fill[..., None]) + np.array([1.0, 0.82, 0.3]) * fill[..., None]
        files[f"chevron{cnt}"] = save(f"chevron{cnt}", rgb, edge)
    files.update(build_units())
    return files


# Unit glyph atlas: ships (plus mirrored side views: negative ImageRectSize does not mirror in
# Roblox), truck, transport, port anchor, SAM shield. From the original coverage atlas
# (assets/icons/map_atlas.png: R = fill, G = ink, 8 x 2 cells of 128 px). Each tier image is
# (8*px) x (4*px): row 0 = TOTAL coverage (paint the ink colour), row 1 = FILL coverage (paint on
# top), rows 2 / 3 = the same for the second group of cells.
UNIT_CELLS = [
    ("warship", (6, 0), False), ("warship_m", (6, 0), True), ("trade", (0, 1), False), ("trade_m", (0, 1), True),
    ("truck", (1, 1), False), ("truck_m", (1, 1), True), ("transport", (7, 0), False), ("port", (1, 0), False),
    ("sam", (4, 0), False),
]
UNIT_TIERS = (32, 64, 128)
SRC_ATLAS = os.path.expanduser("~/games/airfront/assets/icons/map_atlas.png")


def build_units():
    src = np.asarray(Image.open(SRC_ATLAS).convert("RGBA")).astype(np.float64) / 255.0
    out = {}
    for px in UNIT_TIERS:
        tot = np.zeros((4 * px, 8 * px))
        fil = np.zeros((4 * px, 8 * px))
        for i, (_name, (cx, cy), mirror) in enumerate(UNIT_CELLS):
            cell = src[cy * 128:(cy + 1) * 128, cx * 128:(cx + 1) * 128]
            if mirror:
                cell = cell[:, ::-1]
            t = np.clip(cell[..., 0] + cell[..., 1], 0, 1)
            f = cell[..., 0]
            if px != 128:
                t = np.asarray(Image.fromarray((t * 255).astype(np.uint8)).resize((px, px), Image.LANCZOS)) / 255.0
                f = np.asarray(Image.fromarray((f * 255).astype(np.uint8)).resize((px, px), Image.LANCZOS)) / 255.0
            gx, gy = i % 8, (i // 8) * 2
            tot[gy * px:(gy + 1) * px, gx * px:(gx + 1) * px] = t
            fil[gy * px:(gy + 1) * px, gx * px:(gx + 1) * px] = f
        img = np.zeros((4 * px, 8 * px))
        a = np.zeros((4 * px, 8 * px))
        # interleave: rows 0 / 2 = total, rows 1 / 3 = fill
        for g in range(2):
            a[(2 * g) * px:(2 * g + 1) * px] = tot[(2 * g) * px:(2 * g + 1) * px]
            a[(2 * g + 1) * px:(2 * g + 2) * px] = fil[(2 * g) * px:(2 * g + 1) * px]
        name = f"units_{px}"
        out[name] = save(name, 1.0, a)
    return out


def write_manifest(ids):
    lines = [
        "-- GENERATED by tools/fx/make_fx.py (overlays-b). Do not edit.",
        "-- FX textures: white RGB + alpha masks (tint with Color / ImageColor3) unless noted:",
        "-- ring_line_* = dark halo | bright line | dark halo (Beam, V across), sel_ring = dark halo + white band,",
        "-- chevron1..3 = pre-coloured gold, dome / smoke / scorch_ash = grey shading.",
        "return {",
    ]
    for k in sorted(ids):
        lines.append(f'\t{k} = "{ids[k]}",')
    lines.append("\t-- unit glyph atlas: tiers of (8*px) x (4*px); cell {col, group}: TOTAL at row 2*group,")
    lines.append("\t-- FILL at row 2*group + 1 (RGB white, alpha = coverage). *_m = mirrored (bow faces -x).")
    lines.append("\tunit_tiers = { " + ", ".join(f'{{ px = {px}, image = "{ids[f"units_{px}"]}" }}' for px in UNIT_TIERS) + " },")
    cells = ", ".join(f"{n} = {{ {i % 8}, {i // 8} }}" for i, (n, _c, _m) in enumerate(UNIT_CELLS))
    lines.append("\tunit_cells = { " + cells + " },")
    lines.append("}")
    open(MANIFEST, "w").write("\n".join(lines) + "\n")


def main():
    files = build()
    if "--no-upload" in sys.argv:
        print("\n".join(sorted(files.values())))
        return
    import upload  # noqa: E402

    res = upload.upload_images(list(files.values()))
    ids = {k: res[os.path.abspath(p)] for k, p in files.items()}
    write_manifest(ids)
    print("wrote", MANIFEST, len(ids), "textures")


if __name__ == "__main__":
    main()
