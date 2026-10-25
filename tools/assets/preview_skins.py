#!/usr/bin/env python3
"""Contact sheet of the territory skins (src/shared/Data/Cosmetics.luau) the way MapSurface draws them:
a patch of territory in a few player colours over sand-coloured land, fill alpha 150 (saturation
0.85), secondary tiles at Cosmetics.SECONDARY_ALPHA, a darker border. Dev preview only.

Usage: .venv/bin/python tools/assets/preview_skins.py [out.png] [--px 4]
"""
import re
import sys

from PIL import Image, ImageDraw

SRC = "src/shared/Data/Cosmetics.luau"
TERRAIN = (221, 205, 160)
COLORS = [(214, 77, 77), (70, 130, 220), (80, 170, 90), (200, 160, 60)]
ALPHA, ALPHA2, SAT = 150, 190, 0.85
TILES = 40


def mask_key(ch):
    """Cosmetics.luau mask_key: 0 = the owner's fill, 1 = '#', '1'..'9' -> 1..9, 'a'..'z' -> 10..35."""
    if ch == "#":
        return 1
    if "1" <= ch <= "9":
        return ord(ch) - 48
    if "a" <= ch <= "z":
        return ord(ch) - 87
    return 0


def exclusive_skins(s=None):
    """Cosmetics.exclusive_skins: skins with several colours (`colors`, drawn at `alpha`)."""
    s = s if s is not None else open(SRC).read()
    i = s.find("Cosmetics.exclusive_skins = {")
    if i < 0:
        return []
    body = s[i:s.find("\n}\n", i)]
    out = []
    for m in re.finditer(r'\{\s*id = "([a-z_]+)",\s*name = "([^"]+)",(.*?)mask = \{(.*?)\},?\s*\}', body, re.S):
        mid = m.group(3)
        scale = int(re.search(r"scale = (\d)", mid).group(1))
        am = re.search(r"alpha = (\d+)", mid)
        colors = [int(c, 16) for c in re.findall(r"0x([0-9A-Fa-f]{6})", re.search(r"colors = \{(.*?)\}", mid, re.S).group(1))]
        rows = re.findall(r'"([#.0-9a-z]+)"', m.group(4))
        out.append(dict(id=m.group(1), name=m.group(2), rarity="exclusive", scale=scale, tone=None, accent=None,
                        alpha=int(am.group(1)) if am else ALPHA2, colors=colors, rows=rows))
    return out


def tile_color(sk, row_s, mx, own, s2):
    """(rgb floats, alpha 0..255) of one interior tile, the way MapSurface.tile_pixel draws it."""
    k = mask_key(row_s[mx]) if mx < len(row_s) else 0
    if sk.get("colors"):
        if 1 <= k <= len(sk["colors"]):
            c = sk["colors"][k - 1]
            return (((c >> 16) & 255) / 255, ((c >> 8) & 255) / 255, (c & 255) / 255), sk["alpha"]
        return own, ALPHA
    return (s2, ALPHA2) if k else (own, ALPHA)


def skins():
    """The crate skins, then the exclusive ones."""
    s = open(SRC).read()
    out = []
    for m in re.finditer(r'\{\s*id = "([a-z_]+)",\s*name = "([^"]+)",\s*rarity = "(\w+)",\s*scale = (\d),\s*(tone|accent) = ([-0-9.x A-F]+),\s*mask = \{(.*?)\},?\s*\}', s, re.S):
        rows = re.findall(r'"([#.]+)"', m.group(7))
        v = m.group(6).strip().rstrip(",")
        out.append(dict(id=m.group(1), name=m.group(2), rarity=m.group(3), scale=int(m.group(4)),
                        tone=float(v) if m.group(5) == "tone" else None,
                        accent=int(v, 16) if m.group(5) == "accent" else None, rows=rows))
    return out + exclusive_skins(s)


def sat(c):
    r, g, b = [x / 255 for x in c]
    l = 0.299 * r + 0.587 * g + 0.114 * b
    return tuple(max(0, min(1, l + (x - l) * SAT)) for x in (r, g, b))


def second(sk, r, g, b):
    if sk.get("colors"):
        return r, g, b
    if sk["accent"] is not None:
        a = sk["accent"]
        return ((a >> 16) & 255) / 255, ((a >> 8) & 255) / 255, (a & 255) / 255
    t = sk["tone"]
    if t >= 0:
        return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
    return r * (1 + t), g * (1 + t), b * (1 + t)


def blend(base, c, a):
    f = a / 255
    return tuple(int(base[i] * (1 - f) + c[i] * 255 * f) for i in range(3))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "build/skins_preview.png"
    px = int(sys.argv[sys.argv.index("--px") + 1]) if "--px" in sys.argv else 4
    sk = skins()
    cell = TILES * px
    cols = len(COLORS)
    im = Image.new("RGB", (cols * (cell + 8) + 150, len(sk) * (cell + 8) + 8), (24, 26, 32))
    d = ImageDraw.Draw(im)
    for row, s in enumerate(sk):
        w = max(len(r) for r in s["rows"])
        h = len(s["rows"])
        y0 = 8 + row * (cell + 8)
        d.text((8, y0 + cell // 2 - 12), f'{s["name"]}\n{s["rarity"]}', fill=(230, 230, 230))
        for ci, col in enumerate(COLORS):
            x0 = 150 + ci * (cell + 8)
            r, g, b = sat(col)
            s2 = second(s, r, g, b)
            for ty in range(TILES):
                for tx in range(TILES):
                    edge = tx in (0, TILES - 1) or ty in (0, TILES - 1)
                    if edge:
                        c = tuple(int(v * 255 * 0.875) for v in (r, g, b))
                    else:
                        mx = (tx >> s["scale"]) % w
                        my = (ty >> s["scale"]) % h
                        tc, ta = tile_color(s, s["rows"][my], mx, (r, g, b), s2)
                        c = blend(TERRAIN, tc, ta)
                    d.rectangle([x0 + tx * px, y0 + ty * px, x0 + tx * px + px - 1, y0 + ty * px + px - 1], fill=c)
    im.save(out)
    print(f"{len(sk)} skins -> {out}")


if __name__ == "__main__":
    main()
