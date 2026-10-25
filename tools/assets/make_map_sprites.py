#!/usr/bin/env python3
"""Tint-ready sprite atlases derived from OpenFront's (assets/openfront/, CC BY-SA 4.0).

Roblox ImageLabels can only multiply an image by one colour, while OpenFront's shaders recolour
sprites per pixel. This splits each look into white masks that the client tints and stacks:

  of_shapes.png   structure plates (structure.frag.glsl shapeSDF), 6 columns in OpenFront's atlas
                  order (City circle, Port pentagon, Factory hexagon, Defense Post octagon, SAM
                  square, Silo triangle) x 2 rows: row 0 the whole shape (tinted with the border
                  colour), row 1 the shape inset by the border width (tinted with the fill colour).
                  CELL px per cell, shape radius 0.45 of the cell, border 0.06 / shape scale.
  of_units.png    unit-atlas.png (12 columns of 13 x 13) split by grey level like unit.frag.glsl:
                  row 0 = pixels drawn in the territory colour (grey > 0.34; the 0.45-0.6 "spawn"
                  band at half alpha is covered by row 1), row 1 = pixels drawn in the border
                  colour (grey <= 0.34, plus the spawn band at alpha 0.5).

  of_units_one.png / of_shapes_one.png
                  the two rows of each as ONE image, for a sprite of one ImageLabel instead of two
                  (2026-10-08: every object in a ScreenGui that changes is laid out again each frame,
                  and the map has hundreds of each): the fill's pixels white, the border's a grey,
                  so the one tint (the fill colour) gives both. Units: grey 0.8, the border colour
                  being the territory colour 0.16 of value darker. Plates: grey 0.154 = BORDER_V /
                  FILL_V (0.1 / 0.65), the rim being the same colour at a tenth of its value.

Usage: .venv/bin/python tools/assets/make_openfront_sprites.py   (writes into assets/openfront/)
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "openfront")
CELL = 128
SS = 4  # supersampling for antialiased edges
# render-settings.json structure.shapes[*].scale, atlas order
SHAPE_SCALE = [1.0, 1.08, 1.08, 1.0, 1.4, 1.55]
# (sides, rotation) per shape; 0 sides = circle (structure.frag.glsl shapeSDF)
SHAPES = [(0, 0.0), (5, math.pi * 0.5), (6, math.pi / 6), (8, 0.0), (4, 0.0), (3, math.pi * 0.5)]


def polygon_points(cx, cy, apothem, n, rot):
    """Regular polygon whose sdPolygon(p, R, n, rot) = 0 boundary: apothem R*cos(pi/n)."""
    # sdPolygon: length(p)*cos(a) - R*cos(an) with a folded angle => edges at distance R*cos(pi/n)
    # from the centre, vertices at radius R; vertices sit between edge normals at rot + pi/n.
    r_vertex = apothem / math.cos(math.pi / n)
    pts = []
    for k in range(n):
        ang = rot + math.pi / n + k * 2 * math.pi / n
        # the shader's local +y is map / screen down (vLocalPos from the quad), like image rows
        pts.append((cx + r_vertex * math.cos(ang), cy + r_vertex * math.sin(ang)))
    return pts


def shape_mask(idx, inset):
    size = CELL * SS
    img = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(img)
    c = size / 2
    n, rot = SHAPES[idx]
    radius = 0.45 * size
    border = 0.06 / SHAPE_SCALE[idx] * size
    if inset:
        radius -= border
    if n == 0:
        d.ellipse([c - radius, c - radius, c + radius, c + radius], fill=255)
    else:
        # sdPolygon(p, R, n): distance R*cos(pi/n) to the edges. R = radius here.
        apothem = radius * math.cos(math.pi / n)
        d.polygon(polygon_points(c, c, apothem, n, rot), fill=255)
    return img.resize((CELL, CELL), Image.LANCZOS)


def make_shapes():
    atlas = Image.new("RGBA", (CELL * 6, CELL * 2), (255, 255, 255, 0))
    for i in range(6):
        for row, inset in ((0, False), (1, True)):
            m = shape_mask(i, inset)
            cell = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
            cell.putalpha(m)
            atlas.paste(cell, (i * CELL, row * CELL))
    p = os.path.join(OUT, "of_shapes.png")
    atlas.save(p)
    return p


def make_units():
    src = Image.open(os.path.join(OUT, "unit-atlas.png")).convert("RGBA")
    w, h = src.size
    out = Image.new("RGBA", (w, h * 2), (255, 255, 255, 0))
    px = src.load()
    o = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 3:
                continue
            gray = r / 255.0
            if gray > 0.6 or (0.34 < gray <= 0.45):
                o[x, y] = (255, 255, 255, a)
            elif gray > 0.45:
                o[x, y] = (255, 255, 255, a)
                o[x, y + h] = (255, 255, 255, a // 2)
            else:
                o[x, y + h] = (255, 255, 255, a)
    p = os.path.join(OUT, "of_units.png")
    out.save(p)
    return p


def one_image(under_alpha, under_level, over_alpha, over_level):
    """Two masks as one image: `under` at grey level `under_level`, `over` at `over_level` on top of
    it (straight alpha), the way the two tinted layers were stacked."""
    w, h = under_alpha.size
    out = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    ua, oa, o = under_alpha.load(), over_alpha.load(), out.load()
    for y in range(h):
        for x in range(w):
            u = ua[x, y] / 255.0
            v = oa[x, y] / 255.0
            alpha = v + u * (1 - v)
            if alpha <= 0:
                continue
            level = (over_level * v + under_level * u * (1 - v)) / alpha
            o[x, y] = (round(level),) * 3 + (round(alpha * 255),)
    return out


def make_units_one():
    # (the border-colour row is drawn over the territory-colour row: a bomb's markings are in it)
    src = Image.open(os.path.join(OUT, "of_units.png")).convert("RGBA")
    w, h2 = src.size
    h = h2 // 2
    fill = src.crop((0, 0, w, h)).getchannel("A")
    rim = src.crop((0, h, w, h2)).getchannel("A")
    out = one_image(fill, 255, rim, round(0.8 * 255))
    p = os.path.join(OUT, "of_units_one.png")
    out.save(p)
    return p


def make_shapes_one():
    # (the inset shape, the fill, is drawn over the whole shape, the rim)
    src = Image.open(os.path.join(OUT, "of_shapes.png")).convert("RGBA")
    w, h2 = src.size
    h = h2 // 2
    whole = src.crop((0, 0, w, h)).getchannel("A")
    inset = src.crop((0, h, w, h2)).getchannel("A")
    out = one_image(whole, round(0.1 / 0.65 * 255), inset, 255)
    p = os.path.join(OUT, "of_shapes_one.png")
    out.save(p)
    return p


if __name__ == "__main__":
    print(make_shapes())
    print(make_units())
    print(make_units_one())
    print(make_shapes_one())
