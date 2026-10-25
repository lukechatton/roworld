#!/usr/bin/env python3
"""Developer product icons, one look each (2026-09-29), so each product is easy to tell apart on the
group transactions page.
Each is a 512 px square in its own colour with a big glyph and a label:

  takeover     crimson, a crown           TAKE OVER
  crate        blue, the chest            CRATE
  crate_first  green, the chest + a star  FIRST CRATE
  crate3       violet, three chests       3 CRATES

--upload sets them on the products (Open Cloud developer-products v2 PATCH, multipart imageFile; ids
from src/shared/Data/Products.luau; one not created yet, id 0, is skipped). The API key is read from
.secrets/roblox_api_key, never printed.
--create KEY --universe ID [--write prod|staging] makes product KEY in that experience (matched by
name: one that exists is only reported, its price left alone) at Data/Products' Robux price, on sale,
with its icon, and with --write puts its id into Products.luau (`id =` production, `staging =`).

Usage: .venv/bin/python tools/assets/make_product_icons.py [--upload | --create KEY --universe ID [--write W]]
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request
import uuid

import resvg_py
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "build", "products")
UNIVERSE = 10768172922
FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
SIZE = 512

ICONS = {
    "takeover": {"top": (226, 58, 58), "bottom": (120, 14, 30), "label": "TAKE OVER", "glyph": "crown"},
    "crate": {"top": (70, 132, 255), "bottom": (22, 38, 128), "label": "CRATE", "glyph": "chest"},
    "crate_first": {"top": (56, 196, 110), "bottom": (10, 92, 52), "label": "FIRST CRATE", "glyph": "chest_star"},
    "crate3": {"top": (164, 104, 255), "bottom": (58, 22, 132), "label": "3 CRATES", "glyph": "chest3"},
}
# --create: the product's name and description (as the crates' on production)
NAMES = {
    "crate3": ("3 Cosmetic Crates", "Three crates, each a territory skin or a flag you don't own yet. Odds are shown in "
               "the game before you buy."),
}


def gradient(top, bottom):
    im = Image.new("RGBA", (SIZE, SIZE))
    d = ImageDraw.Draw(im)
    for y in range(SIZE):
        k = y / (SIZE - 1)
        d.line([(0, y), (SIZE, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)) + (255,))
    return im


def rounded_mask(r=88):
    m = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=r, fill=255)
    return m


def shadowed(layer, offset=10, blur=10, alpha=110):
    """layer (RGBA) over a soft drop shadow of itself."""
    a = layer.getchannel("A")
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sh.putalpha(a.point(lambda v: v * alpha // 255))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.alpha_composite(sh, (0, offset))
    out.alpha_composite(layer)
    return out


def chest(px):
    svg = open(os.path.join(ROOT, "assets", "crate", "crate_icon.svg"), encoding="utf-8").read()
    im = Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg, width=px, height=px)))).convert("RGBA")
    return im


def crown(px):
    im = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    w, h = px, px
    base_top, base_bot = h * 0.70, h * 0.86
    pts = [
        (w * 0.10, base_top), (w * 0.06, h * 0.30), (w * 0.30, h * 0.52), (w * 0.50, h * 0.16),
        (w * 0.70, h * 0.52), (w * 0.94, h * 0.30), (w * 0.90, base_top),
    ]
    d.polygon(pts, fill=(255, 255, 255, 255))
    d.rounded_rectangle([w * 0.10, base_top + h * 0.03, w * 0.90, base_bot], radius=h * 0.03, fill=(255, 255, 255, 255))
    for cx, cy in ((0.06, 0.30), (0.50, 0.16), (0.94, 0.30)):
        r = w * 0.06
        d.ellipse([w * cx - r, h * cy - r, w * cx + r, h * cy + r], fill=(255, 255, 255, 255))
    return im


def star(px, fill):
    im = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    import math
    c = px / 2
    pts = []
    for i in range(16):
        r = c * (0.98 if i % 2 == 0 else 0.74)
        a = math.pi * 2 * i / 16 - math.pi / 2
        pts.append((c + math.cos(a) * r, c + math.sin(a) * r))
    d.polygon(pts, fill=fill)
    return im


def render(key, spec):
    im = gradient(spec["top"], spec["bottom"])
    # a soft light behind the glyph
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([96, 40, 416, 360], fill=(255, 255, 255, 60))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(40)))
    g = spec["glyph"]
    if g == "crown":
        glyph = crown(300)
        im.alpha_composite(shadowed(glyph), ((SIZE - 300) // 2, 30))
    elif g == "chest3":
        # two behind (tinted with the ground), one in front with a cut-out edge so the three read apart
        back = chest(220)
        tint = Image.new("RGBA", back.size, (206, 184, 255, 255))
        tint.putalpha(back.getchannel("A"))
        im.alpha_composite(shadowed(tint), (34, 52))
        im.alpha_composite(shadowed(tint), (SIZE - 34 - 220, 52))
        front = chest(280)
        pad = 14
        edge = Image.new("RGBA", (280 + pad * 2, 280 + pad * 2), (0, 0, 0, 0))
        a = Image.new("L", edge.size, 0)
        a.paste(front.getchannel("A"), (pad, pad))
        ring = Image.new("RGBA", edge.size, spec["bottom"] + (255,))
        ring.putalpha(a.filter(ImageFilter.MaxFilter(2 * (pad // 2) + 1)))
        x0 = (SIZE - 280) // 2
        im.alpha_composite(ring, (x0 - pad, 96 - pad))
        im.alpha_composite(shadowed(front, offset=12, blur=12, alpha=150), (x0, 96))
    else:
        glyph = chest(300)
        im.alpha_composite(shadowed(glyph), ((SIZE - 300) // 2, 40))
        if g == "chest_star":
            st = star(170, (255, 206, 60, 255))
            d = ImageDraw.Draw(st)
            f = ImageFont.truetype(FONT, 50)
            d.text((85, 88), "1st", font=f, fill=(96, 50, 0, 255), anchor="mm")
            im.alpha_composite(shadowed(st.rotate(-12, resample=Image.BICUBIC), offset=6, blur=6), (322, 12))
    # the label
    label = spec["label"]
    size = 92
    font = ImageFont.truetype(FONT, size)
    d = ImageDraw.Draw(im)
    while d.textlength(label, font=font) > SIZE - 56 and size > 40:
        size -= 4
        font = ImageFont.truetype(FONT, size)
    txt = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(txt).text((SIZE / 2, 430), label, font=font, fill=(255, 255, 255, 255), anchor="mm",
                             stroke_width=6, stroke_fill=(0, 0, 0, 150))
    im.alpha_composite(shadowed(txt, offset=6, blur=5))
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(im, (0, 0), rounded_mask())
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, key + ".png")
    out.save(p, optimize=True)
    return p


def product_ids():
    src = open(os.path.join(ROOT, "src", "shared", "Data", "Products.luau"), encoding="utf-8").read()
    return {k: int(v) for k, v in re.findall(r"^\s*(\w+) = \{ id = (\d+)", src, re.M)}


def call(method, url, fields=None, image=None):
    api_key = open(os.path.join(ROOT, ".secrets", "roblox_api_key"), encoding="utf-8").read().strip()
    boundary = "----rofront" + uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
             for k, v in (fields or {}).items()]
    if image is not None:
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="imageFile"; filename="icon.png"\r\n'
                     f"Content-Type: image/png\r\n\r\n".encode() + open(image, "rb").read() + b"\r\n")
    headers = {"x-api-key": api_key}
    body = None
    if parts:
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def create(key, universe, write, icon):
    name, desc = NAMES[key]
    src = open(os.path.join(ROOT, "src", "shared", "Data", "Products.luau"), encoding="utf-8").read()
    robux = int(re.search(rf"^\s*{key} = \{{[^\n]*robux = (\d+)", src, re.M).group(1))
    api = f"https://apis.roblox.com/developer-products/v2/universes/{universe}/developer-products"
    status, text = call("GET", api + "/creator?pageSize=100")
    if status >= 300:
        raise SystemExit(f"can't list the experience's products: HTTP {status} {text[:200]}")
    pid = next((p.get("productId") for p in json.loads(text).get("developerProducts", []) if p.get("name") == name), None)
    if pid:
        print(f"{key}: {name!r} exists in {universe}: {pid} (price left alone)")
    else:
        status, text = call("POST", api, {"name": name, "description": desc, "price": str(robux), "isForSale": "true"}, icon)
        if status >= 300:
            raise SystemExit(f"{key}: HTTP {status} {text[:300]}")
        pid = json.loads(text).get("productId")
        print(f"{key}: created {name!r} in {universe} at {robux} Robux: {pid}")
    if write:
        field = "id" if write == "prod" else "staging"
        path = os.path.join(ROOT, "src", "shared", "Data", "Products.luau")
        lines = open(path, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            if re.match(rf"^\s*{key} = \{{", line):
                lines[i] = re.sub(rf"\b{field} = \d+", f"{field} = {int(pid)}", line, count=1)
        open(path, "w", encoding="utf-8").write("\n".join(lines))
        print(f"{key}: {field} = {pid} -> src/shared/Data/Products.luau")


def upload(key, path, pid):
    api_key = open(os.path.join(ROOT, ".secrets", "roblox_api_key"), encoding="utf-8").read().strip()
    boundary = "----rofront" + uuid.uuid4().hex
    data = open(path, "rb").read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"imageFile\"; filename=\"{key}.png\"\r\n"
        f"Content-Type: image/png\r\n\r\n".encode(), data, b"\r\n", f"--{boundary}--\r\n".encode(),
    ])
    url = f"https://apis.roblox.com/developer-products/v2/universes/{UNIVERSE}/developer-products/{pid}"
    req = urllib.request.Request(url, data=body, method="PATCH", headers={
        "x-api-key": api_key, "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode("utf-8", "replace")[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:300]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--create", default="")
    ap.add_argument("--universe", default="")
    ap.add_argument("--write", choices=["prod", "staging"], default="")
    args = ap.parse_args()
    paths = {k: render(k, s) for k, s in ICONS.items()}
    for k, p in paths.items():
        print(k, "->", os.path.relpath(p, ROOT))
    if args.create:
        if args.create not in NAMES or not args.universe:
            raise SystemExit("--create KEY (one of " + ", ".join(NAMES) + ") needs --universe")
        create(args.create, args.universe, args.write, paths[args.create])
        return
    if not args.upload:
        return
    ids = product_ids()
    failed = False
    for k, p in paths.items():
        pid = ids.get(k)
        if pid == 0:
            print(k, "not created yet (id 0): skipped")
            continue
        if not pid:
            print(k, "no product id")
            failed = True
            continue
        status, text = upload(k, p, pid)
        print(k, pid, "PATCH", status, text)
        failed = failed or status >= 300
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
