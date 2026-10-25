#!/usr/bin/env python3
"""Generates the static UI shape images ui-screens needs (no EditableImage at runtime) and writes
src/shared/Assets/UiShapes.luau.

  .venv/bin/python tools/ui/make_shapes.py            # render + upload + write the manifest
  .venv/bin/python tools/ui/make_shapes.py --no-upload

Shapes (white RGB + alpha coverage masks unless noted; tint with ImageColor3):
* radial menu segments (ui_root radial_menu.gd): annular sectors for n = 2..8 items, centred on
  "up" (-90 deg), with the 2.2 deg gap, for 4 ratio variants (desktop / touch x base / hovered r_out+6),
  as FILL masks and 1-logical-px OUTLINE masks. Rendered at 2 image px per logical px, cropped to the
  segment and shelf-packed into 1024x1024 pages. At runtime: size = w * s, rotate about the ring
  centre (the manifest gives the ring centre inside each crop).
* radial gradients of the title vignette, title glow and game-over dim (Godot GradientTexture2D,
  exact offsets/colours; glow + dim carry their colour, vignette is a mask).
* arrow head triangle (coach), soft disc.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "ui_shapes")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "UiShapes.luau")
PX = 2.0          # image px per logical px for radial masks
PAGE = 1024
GAP_DEG = 2.2

# (name, r_in, r_out) in logical px (radial_menu.gd: desktop 44/116, touch 50/128, compact 44/112;
# hovered segments grow r_out by 6). Compact maps to the touch variants (ratio within 0.003).
VARIANTS = [
    ("desk", 44.0, 116.0),
    ("desk_hov", 44.0, 122.0),
    ("touch", 50.0, 128.0),
    ("touch_hov", 50.0, 134.0),
]


def seg_masks(n, ri, ro):
    """Fill + outline coverage (float arrays) of one segment, and the ring centre in the crop."""
    s = PX
    ri_i, ro_i = ri * s, ro * s
    span = 2 * math.pi / n
    gap = math.radians(GAP_DEG) if n > 1 else 0.0
    a0 = -math.pi / 2 - (span - gap) / 2
    a1 = -math.pi / 2 + (span - gap) / 2
    # bounding box of the sector (+ padding for AA / outline)
    pts = []
    for k in range(65):
        a = a0 + (a1 - a0) * k / 64
        pts.append((math.cos(a) * ro_i, math.sin(a) * ro_i))
        pts.append((math.cos(a) * ri_i, math.sin(a) * ri_i))
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    pad = 4
    x0 = math.floor(min(xs)) - pad
    y0 = math.floor(min(ys)) - pad
    x1 = math.ceil(max(xs)) + pad
    y1 = math.ceil(max(ys)) + pad
    w, h = x1 - x0, y1 - y0
    # supersampled fill coverage
    ss = 4
    yy, xx = np.mgrid[0:h * ss, 0:w * ss].astype(np.float64)
    px = x0 + (xx + 0.5) / ss
    py = y0 + (yy + 0.5) / ss
    r = np.hypot(px, py)
    ang = np.arctan2(py, px)
    mid = -math.pi / 2
    d = (ang - mid + math.pi) % (2 * math.pi) - math.pi
    half = (a1 - a0) / 2
    inside = (r >= ri_i) & (r <= ro_i) & (np.abs(d) <= half)
    fill = inside.reshape(h, ss, w, ss).mean(axis=(1, 3))
    # outline: distance to the boundary (pixel centres), 1 logical px wide, AA
    yy2, xx2 = np.mgrid[0:h, 0:w].astype(np.float64)
    px2 = x0 + xx2 + 0.5
    py2 = y0 + yy2 + 0.5
    r2 = np.hypot(px2, py2)
    ang2 = np.arctan2(py2, px2)
    d2 = (ang2 - mid + math.pi) % (2 * math.pi) - math.pi
    within = np.abs(d2) <= half

    def arc_dist(R):
        on = np.abs(r2 - R)
        e0 = np.hypot(px2 - R * math.cos(a0), py2 - R * math.sin(a0))
        e1 = np.hypot(px2 - R * math.cos(a1), py2 - R * math.sin(a1))
        return np.where(within, on, np.minimum(e0, e1))

    def seg_dist(a):
        ax, ay = ri_i * math.cos(a), ri_i * math.sin(a)
        bx, by = ro_i * math.cos(a), ro_i * math.sin(a)
        vx, vy = bx - ax, by - ay
        t = np.clip(((px2 - ax) * vx + (py2 - ay) * vy) / (vx * vx + vy * vy), 0, 1)
        return np.hypot(px2 - (ax + t * vx), py2 - (ay + t * vy))

    dist = np.minimum(arc_dist(ro_i), arc_dist(ri_i))
    if n > 1:
        dist = np.minimum(dist, np.minimum(seg_dist(a0), seg_dist(a1)))
    lw = 1.0 * s
    outline = np.clip(lw * 0.5 + 0.5 - dist, 0.0, 1.0)
    return fill, outline, (-x0, -y0)


def to_img(cov):
    a = (np.clip(cov, 0, 1) * 255 + 0.5).astype(np.uint8)
    rgba = np.zeros(a.shape + (4,), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = a
    return Image.fromarray(rgba, "RGBA")


class Packer:
    def __init__(self):
        self.pages = []   # list of Image
        self.shelves = []  # per page: list of [y, h, x]
        self.cur = -1

    def add(self, img):
        w, h = img.size
        for pi in range(len(self.pages)):
            for sh in self.shelves[pi]:
                if h <= sh[1] and sh[2] + w + 2 <= PAGE:
                    x, y = sh[2], sh[0]
                    sh[2] += w + 2
                    self.pages[pi].paste(img, (x, y))
                    return pi, x, y
            used = sum(s[1] + 2 for s in self.shelves[pi])
            if used + h <= PAGE and w <= PAGE:
                y = used
                self.shelves[pi].append([y, h, w + 2])
                self.pages[pi].paste(img, (0, y))
                return pi, 0, y
        self.pages.append(Image.new("RGBA", (PAGE, PAGE), (255, 255, 255, 0)))
        self.shelves.append([])
        return self.add(img)


def radial_gradient(size, frm, to, offsets, colors):
    """Godot GradientTexture2D FILL_RADIAL: t = |uv - from| / |to - from|."""
    w, h = size
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    u = (xx + 0.5) / w
    v = (yy + 0.5) / h
    t = np.hypot(u - frm[0], v - frm[1]) / math.hypot(to[0] - frm[0], to[1] - frm[1])
    t = np.clip(t, 0, 1)
    out = np.zeros((h, w, 4))
    cols = np.array(colors, np.float64)
    for c in range(4):
        out[..., c] = np.interp(t, offsets, cols[:, c])
    # Godot gradients interpolate in sRGB space: store as-is
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def triangle(size=64):
    # arrow head pointing +x: tip (10, 0), base (-4, +-7) in logical px -> fit the 14x14 box
    ss = 4
    s = size / 14.0
    yy, xx = np.mgrid[0:size * ss, 0:size * ss].astype(np.float64)
    px = (xx + 0.5) / ss / s - 4.0       # logical x in [-4, 10]
    py = (yy + 0.5) / ss / s - 7.0       # logical y in [-7, 7]
    # inside test against three edges
    def side(ax, ay, bx, by):
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    A, B, C = (10.0, 0.0), (-4.0, 7.0), (-4.0, -7.0)
    s1 = side(*A, *B)
    s2 = side(*B, *C)
    s3 = side(*C, *A)
    inside = ((s1 >= 0) & (s2 >= 0) & (s3 >= 0)) | ((s1 <= 0) & (s2 <= 0) & (s3 <= 0))
    cov = inside.reshape(size, ss, size, ss).mean(axis=(1, 3))
    return to_img(cov)


def disc_glow(size=128, inner=26.0, outer=36.0):
    """Godot StyleBoxFlat shadow of a round panel (radius `inner`, shadow_size outer-inner):
    alpha 1 inside the disc falling linearly to 0 at `outer` (tint with the glow colour/alpha)."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    c = size / 2.0
    r = np.hypot(xx + 0.5 - c, yy + 0.5 - c) / c * outer
    a = np.clip((outer - r) / (outer - inner), 0.0, 1.0)
    return to_img(a)


def main():
    os.makedirs(OUT, exist_ok=True)
    packer = Packer()
    segs = {}
    for name, ri, ro in VARIANTS:
        for n in range(2, 9):
            fill, outline, (cx, cy) = seg_masks(n, ri, ro)
            for layer, cov in (("fill", fill), ("line", outline)):
                img = to_img(cov)
                pi, x, y = packer.add(img)
                segs["%s_%d_%s" % (name, n, layer)] = {
                    "page": pi, "x": x, "y": y, "w": img.size[0], "h": img.size[1],
                    "cx": cx, "cy": cy,
                }
    files = {}
    for i, pg in enumerate(packer.pages):
        p = os.path.join(OUT, "radial_page_%d.png" % i)
        pg.save(p)
        files["radial_page_%d" % i] = p
    # radial gradients
    ink = (0.01, 0.015, 0.05)
    vig = radial_gradient((256, 256), (0.5, 0.45), (1.05, 1.05), [0.0, 0.55, 1.0],
                          [(1, 1, 1, 0.0), (1, 1, 1, 0.25), (1, 1, 1, 0.85)])
    p = os.path.join(OUT, "title_vignette.png"); vig.save(p); files["title_vignette"] = p
    glow = radial_gradient((256, 128), (0.5, 0.5), (1.0, 0.5), [0.0, 1.0],
                           [(1.0, 0.72, 0.35, 0.28), (1.0, 0.6, 0.2, 0.0)])
    p = os.path.join(OUT, "title_glow.png"); glow.save(p); files["title_glow"] = p
    dim = radial_gradient((256, 256), (0.5, 0.45), (1.1, 1.1), [0.0, 1.0],
                          [(0.01, 0.015, 0.05, 0.55), (0.0, 0.005, 0.02, 0.92)])
    p = os.path.join(OUT, "over_dim.png"); dim.save(p); files["over_dim"] = p
    dg = disc_glow()
    p = os.path.join(OUT, "disc_glow.png"); dg.save(p); files["disc_glow"] = p
    tri = triangle(64)
    p = os.path.join(OUT, "arrow_head.png"); tri.save(p); files["arrow_head"] = p
    ids = {}
    if "--no-upload" not in sys.argv:
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import upload  # noqa: E402
        res = upload.upload_images(list(files.values()))
        for k, path in files.items():
            ids[k] = res.get(path, "")
    lines = [
        "-- GENERATED by tools/ui/make_shapes.py — do not edit by hand. (owner: ui-screens)",
        "-- Static UI shapes (white masks unless noted). Radial segments: annular sectors centred on",
        "-- \"up\", cropped; `cx, cy` = ring centre inside the crop, `ro` = outer radius in image px.",
        "return {",
        "\tpx = %g, -- image px per logical px (radial masks)" % PX,
        "\tgap_deg = %g," % GAP_DEG,
        "\tvariants = {",
    ]
    for name, ri, ro in VARIANTS:
        lines.append("\t\t%s = { ri = %g, ro = %g }," % (name, ri, ro))
    lines.append("\t},")
    lines.append("\tpages = {")
    for i in range(len(packer.pages)):
        lines.append("\t\t[%d] = \"%s\"," % (i, ids.get("radial_page_%d" % i, "")))
    lines.append("\t},")
    lines.append("\tsegments = {")
    for k in sorted(segs):
        d = segs[k]
        lines.append("\t\t%s = { page = %d, x = %d, y = %d, w = %d, h = %d, cx = %d, cy = %d }," % (
            k, d["page"], d["x"], d["y"], d["w"], d["h"], d["cx"], d["cy"]))
    lines.append("\t},")
    lines.append("\t-- disc_glow: a round panel's soft shadow; the disc (radius 26) spans 26/36 of the image radius")
    for k in ("title_vignette", "title_glow", "over_dim", "arrow_head", "disc_glow"):
        lines.append("\t%s = \"%s\"," % (k, ids.get(k, "")))
    lines.append("}")
    with open(MANIFEST, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("pages:", len(packer.pages), "segments:", len(segs), "->", MANIFEST)


if __name__ == "__main__":
    main()
