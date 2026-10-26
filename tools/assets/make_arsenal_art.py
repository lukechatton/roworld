#!/usr/bin/env python3
"""Art for the Arsenal (Data/Arsenal; 2026-10-04): original glyphs drawn here, nothing sampled.

  (the map plates and glyphs of the Arsenal's structures are drawn with every other structure's by
  tools/assets/make_map_sprites.py since 2026-10-25)
  assets/arsenal/ui/<key>.png white 128 px masks for the interface, tinted with ImageColor3 like
                              Assets/UiIcons: artillery, airfield, railgun, mega, scatter, reinforce,
                              airstrike, slug, star, lock, reload, arsenal
  assets/arsenal/renders/<key>.png  the shop cards' item renders (tools/assets/make_arsenal_renders.py
                              makes them; this script only uploads them)

--upload sends them through tools/upload.py (content-hash cached) and writes
src/shared/Assets/ArsenalArt.luau. STUDIO_MATCH picks the Studio window that uploads.

Usage: .venv/bin/python tools/assets/make_arsenal_art.py [--upload]
"""
import argparse
import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "arsenal")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "ArsenalArt.luau")
SS = 8          # supersampling
UI_PX = 128     # interface masks


class Canvas:
    """A 64-unit square drawn supersampled; white coverage becomes the mask's alpha."""

    def __init__(self, px):
        self.px = px
        self.k = px * SS / 64.0
        self.img = Image.new("L", (px * SS, px * SS), 0)
        self.d = ImageDraw.Draw(self.img)

    def _p(self, pts):
        return [(x * self.k, y * self.k) for x, y in pts]

    def poly(self, pts, fill=255):
        self.d.polygon(self._p(pts), fill=fill)

    def circle(self, cx, cy, r, fill=255):
        k = self.k
        self.d.ellipse([(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k], fill=fill)

    def ring(self, cx, cy, r, w, fill=255):
        self.circle(cx, cy, r + w / 2, fill)
        self.circle(cx, cy, r - w / 2, 0)

    def line(self, a, b, w, fill=255, cap=True):
        (x0, y0), (x1, y1) = a, b
        dx, dy = x1 - x0, y1 - y0
        ln = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / ln * w / 2, dx / ln * w / 2
        self.poly([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], fill)
        if cap:
            self.circle(x0, y0, w / 2, fill)
            self.circle(x1, y1, w / 2, fill)

    def rect(self, x0, y0, x1, y1, r=0.0, fill=255):
        k = self.k
        self.d.rounded_rectangle([x0 * k, y0 * k, x1 * k, y1 * k], radius=r * k, fill=fill)

    def arc(self, cx, cy, r, w, a0, a1, fill=255):
        """A stroked arc from angle a0 to a1 (degrees, clockwise from +x, y down)."""
        steps = max(8, int(abs(a1 - a0) / 4))
        pts = [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / steps)),
                cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / steps))) for i in range(steps + 1)]
        for p, q in zip(pts, pts[1:]):
            self.line(p, q, w, fill)

    def mask(self):
        a = self.img.resize((self.px, self.px), Image.LANCZOS)
        out = Image.new("RGBA", (self.px, self.px), (255, 255, 255, 0))
        out.putalpha(a)
        return out


def rot(pts, deg, cx=32.0, cy=32.0):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [(cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c) for x, y in pts]


# ---------------------------------------------------------------------------------------------------
# Glyphs (64-unit canvas, the drawing spans about 6..58)
# ---------------------------------------------------------------------------------------------------

def g_artillery(c):
    # a field gun: the barrel up to the right, a trail down to the left, one big wheel
    c.line((22, 40), (52, 16), 8.5)
    c.rect(48, 9, 58, 21, 2)                                # muzzle brake
    c.poly(rot([(48, 9), (58, 9), (58, 21), (48, 21)], 0))
    c.line((24, 42), (8, 54), 5)                            # trail
    c.circle(26, 44, 13)
    c.circle(26, 44, 7.5, 0)
    c.circle(26, 44, 3.2)


def g_airfield(c):
    # a plane from above, nose up
    c.rect(28.5, 6, 35.5, 56, 3.5)                          # fuselage
    c.poly([(32, 20), (58, 36), (58, 42), (35, 36), (29, 36), (6, 42), (6, 36)])   # wings
    c.poly([(32, 44), (45, 53), (45, 57), (32, 54), (19, 57), (19, 53)])           # tail


def g_railgun(c):
    # two long rails on a turret, with the cross-ties of a coil gun
    pts = rot([(28, 4), (31, 4), (31, 40), (28, 40)], 38, 32, 40)
    c.poly(pts)
    c.poly(rot([(33, 4), (36, 4), (36, 40), (33, 40)], 38, 32, 40))
    for y in (10, 18, 26, 34):
        c.poly(rot([(26, y), (38, y), (38, y + 3.4), (26, y + 3.4)], 38, 32, 40))
    c.circle(26, 46, 12)
    c.circle(26, 46, 5, 0)
    c.rect(8, 54, 44, 59, 2)


def g_mega(c):
    # a mushroom cloud
    k = c.k
    c.d.ellipse([7 * k, 5 * k, 57 * k, 31 * k], fill=255)       # the cap
    c.d.ellipse([16 * k, 20 * k, 48 * k, 36 * k], fill=255)     # the roll under it
    c.poly([(26, 30), (38, 30), (40, 46), (47, 55), (17, 55), (24, 46)])   # the stem, flaring out
    c.rect(9, 53, 55, 59, 3)                                    # the ground ring


def g_scatter(c):
    # one warhead in the middle and five around it, each with a short tail
    c.circle(32, 32, 9)
    for i in range(5):
        a = math.radians(-90 + i * 72)
        x, y = 32 + 21 * math.cos(a), 32 + 21 * math.sin(a)
        c.circle(x, y, 5.2)
        c.line((32 + 12.5 * math.cos(a), 32 + 12.5 * math.sin(a)), (x, y), 2.4, cap=False)


def g_reinforce(c):
    # three chevrons, pointing up: more troops
    for y in (14, 28, 42):
        c.poly([(32, y - 6), (54, y + 10), (54, y + 18), (32, y + 2), (10, y + 18), (10, y + 10)])


def g_airstrike(c):
    # the plane over a target ring
    c.ring(32, 34, 23, 3.4)
    c.rect(30, 6, 34, 52, 2)
    c.poly([(32, 18), (50, 30), (50, 34), (34, 30), (30, 30), (14, 34), (14, 30)])
    c.poly([(32, 40), (41, 47), (41, 50), (32, 48), (23, 50), (23, 47)])


def g_slug(c):
    # a bolt
    c.poly([(38, 4), (14, 36), (29, 36), (24, 60), (50, 26), (34, 26)])


def g_star(c):
    pts = []
    for i in range(10):
        r = 27 if i % 2 == 0 else 11.5
        a = math.radians(-90 + i * 36)
        pts.append((32 + r * math.cos(a), 33.5 + r * math.sin(a)))
    c.poly(pts)


def g_lock(c):
    c.ring(32, 24, 12, 6)
    c.rect(18, 24, 46, 30, 0, 0)                            # open the shackle's lower half
    c.rect(17, 12, 23, 32, 0)
    c.rect(41, 12, 47, 32, 0)
    c.rect(17, 12, 47, 20, 0, 0)
    c.ring(32, 24, 12, 6)
    c.rect(10, 26, 54, 34, 0, 0)
    c.rect(20, 18, 26, 32)
    c.rect(38, 18, 44, 32)
    c.rect(12, 30, 52, 58, 6)                               # body
    c.circle(32, 42, 4.5, 0)
    c.rect(30, 42, 34, 51, 1.5, 0)


def g_reload(c):
    # an arrow going round
    c.arc(32, 32, 20, 6.5, -60, 215)
    c.poly([(38, 2), (58, 13), (38, 25)])


def g_arsenal(c):
    # a crate of ordnance: a shield with a star cut out
    c.poly([(32, 5), (56, 13), (56, 34), (32, 59), (8, 34), (8, 13)])
    pts = []
    for i in range(10):
        r = 14 if i % 2 == 0 else 6
        a = math.radians(-90 + i * 36)
        pts.append((32 + r * math.cos(a), 29 + r * math.sin(a)))
    c.poly(pts, 0)


UI = {
    "artillery": g_artillery,
    "airfield": g_airfield,
    "railgun": g_railgun,
    "mega": g_mega,
    "scatter": g_scatter,
    "reinforce": g_reinforce,
    "airstrike": g_airstrike,
    "slug": g_slug,
    "star": g_star,
    "lock": g_lock,
    "reload": g_reload,
    "arsenal": g_arsenal,
}


def glyph(name, px):
    c = Canvas(px)
    UI[name](c)
    return c.mask()


def make():
    os.makedirs(os.path.join(OUT, "ui"), exist_ok=True)
    for name in UI:
        glyph(name, UI_PX).save(os.path.join(OUT, "ui", name + ".png"))
    # a contact sheet to look at (dark ground, like the game's panels)
    names = list(UI)
    sheet = Image.new("RGBA", (UI_PX * 6, UI_PX * 2), (22, 26, 34, 255))
    for i, name in enumerate(names):
        g = Image.open(os.path.join(OUT, "ui", name + ".png"))
        sheet.alpha_composite(g, ((i % 6) * UI_PX, (i // 6) * UI_PX))
    sheet.save(os.path.join(ROOT, "build", "arsenal_art_sheet.png"))
    return names


def upload(names):
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import upload as up
    paths = [os.path.join(OUT, "ui", n + ".png") for n in names]
    rdir = os.path.join(OUT, "renders")
    renders = sorted(f[:-4] for f in os.listdir(rdir) if f.endswith(".png")) if os.path.isdir(rdir) else []
    rpaths = [os.path.join(rdir, r + ".png") for r in renders]
    ids = up.upload_images(paths + rpaths)
    L = ["-- GENERATED by tools/assets/make_arsenal_art.py — do not edit by hand.",
         "-- The Arsenal's art (Data/Arsenal): white interface masks and the shop cards' renders (its",
         "-- structures' map plates and glyphs are in Assets/MapSprites with every other structure's).",
         "return {",
         "\tui = {"]
    for i, n in enumerate(names):
        L.append(f'\t\t{n} = "{ids[paths[i]]}",')
    L += ["\t},",
          "\t--- the shop cards' item renders (Data/Arsenal item key -> image; models of military hardware",
          "\t--- generated in Studio, photographed and cut out by tools/assets/make_arsenal_renders.py):",
          "\t--- { id, w, h }",
          "\trenders = {"]
    from PIL import Image as _Image
    for r, rp in zip(renders, rpaths):
        w, h = _Image.open(rp).size
        L.append(f'\t\t{r} = {{ id = "{ids[rp]}", w = {w}, h = {h} }},')
    L += ["\t},", "}"]
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")
    print("manifest ->", os.path.relpath(MANIFEST, ROOT))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upload", action="store_true")
    args = ap.parse_args()
    names = make()
    print("wrote", os.path.relpath(OUT, ROOT), "and build/arsenal_art_sheet.png")
    if args.upload:
        upload(names)


if __name__ == "__main__":
    main()
