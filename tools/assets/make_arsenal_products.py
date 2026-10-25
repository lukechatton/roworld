#!/usr/bin/env python3
"""The Arsenal's developer products (Data/Arsenal, Data/Products: unlock_<key>): their icons, and the
products themselves through Open Cloud.

  icons    512 px, the item's render (assets/arsenal/renders/<key>.png, make_arsenal_renders.py;
           its glyph without one) on a dark ground with a glow of its colour, as on the shop's
           cards, with its name -> build/products/unlock_<key>.png
  --icons --universe <id>    send only the icons to the products that exist there (matched by
           name). Nothing else of a product is touched: its price may have been changed since on
           the Creator Dashboard, which --create would set back to Data/Products'.
  --create --universe <id>   for each product that doesn't exist in that experience yet (matched by
           name): create it at Data/Products' Robux price, on sale, with its icon. Existing ones get
           their price and icon set again. Prints `unlock_<key> <product id>` for every product.
  --write prod|staging        with --create: put the ids into src/shared/Data/Products.luau (`id =`
           for production, `staging =` for Rofront Staging).

Product ids belong to one experience: run it once for production (universe 10768172922) and once for
Rofront Staging. The API key is read from .secrets/roblox_api_key and only sent in the x-api-key
header; it needs "developer-product" write access for that experience.

Usage: .venv/bin/python tools/assets/make_arsenal_products.py [--create --universe ID [--write staging]]
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "build", "products")
PRODUCTS = os.path.join(ROOT, "src", "shared", "Data", "Products.luau")
ARSENAL = os.path.join(ROOT, "src", "shared", "Data", "Arsenal.luau")
FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
SIZE = 512
NIGHT = (8, 12, 26)
API = "https://apis.roblox.com/developer-products/v2/universes"


def catalogue():
    """[{key, title, icon, tagline, top, bottom, robux}] from Data/Arsenal and Data/Products."""
    src = open(ARSENAL, encoding="utf-8").read()
    prices = dict(re.findall(r"^\s*unlock_(\w+) = \{ id = \d+, robux = (\d+)", open(PRODUCTS, encoding="utf-8").read(), re.M))
    items = []
    for m in re.finditer(r'key = "(\w+)",\s*title = "([^"]+)",\s*kind = "\w+",\s*icon = "(\w+)",\s*tagline = "([^"]+)"', src):
        key, title, icon, tagline = m.groups()
        tail = src[m.end():]
        c = re.search(r"color = \{ 0x([0-9A-Fa-f]{6}), 0x([0-9A-Fa-f]{6}) \}", tail)
        rgb = lambda h: tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
        items.append({"key": key, "title": title, "icon": icon, "tagline": tagline,
                      "top": rgb(c.group(1)), "bottom": rgb(c.group(2)), "robux": int(prices[key])})
    assert len(items) == len(prices), (len(items), len(prices))
    return items


def render(it):
    # the shop card's ground (UI/Arsenal): dark, tinted with the item's colours, a glow of the
    # colour behind the item with a hotter heart
    mix = lambda a, b, k: tuple(a[i] + (b[i] - a[i]) * k for i in range(3))
    top, bottom = mix(it["top"], NIGHT, 0.42), mix(it["bottom"], NIGHT, 0.8)
    im = Image.new("RGBA", (SIZE, SIZE))
    px = im.load()
    for y in range(SIZE):
        col = tuple(int(c) for c in mix(top, bottom, y / (SIZE - 1))) + (255,)
        for x in range(SIZE):
            px[x, y] = col
    for box, k, alpha, blur in (([26, -30, 486, 400], 0.3, 215, 60), ([146, 70, 366, 290], 0.6, 150, 36)):
        glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse(box, fill=tuple(int(c) for c in mix(it["top"], (255, 255, 255), k)) + (alpha,))
        im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(blur)))
    # the item's render (make_arsenal_renders.py) when there is one, else its glyph
    shot = os.path.join(ROOT, "assets", "arsenal", "renders", it["key"] + ".png")
    if os.path.exists(shot):
        g = Image.open(shot).convert("RGBA")
        k = min(340 / g.size[0], 340 / g.size[1])
        g = g.resize((round(g.size[0] * k), round(g.size[1] * k)), Image.LANCZOS)
    else:
        g = Image.open(os.path.join(ROOT, "assets", "arsenal", "ui", it["icon"] + ".png")).convert("RGBA").resize((300, 300), Image.LANCZOS)
    gx, gy = (SIZE - g.size[0]) // 2, 20 + (340 - g.size[1]) // 2
    sh = Image.new("RGBA", g.size, (0, 0, 0, 0))
    sh.putalpha(g.getchannel("A").point(lambda v: int(v * 0.45)))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(6)), (gx, gy + 10))
    im.alpha_composite(g, (gx, gy))
    label = it["title"].upper()
    size = 92
    font = ImageFont.truetype(FONT, size)
    d = ImageDraw.Draw(im)
    while d.textlength(label, font=font) > SIZE - 56 and size > 36:
        size -= 4
        font = ImageFont.truetype(FONT, size)
    d.text((SIZE / 2, 432), label, font=font, fill=(255, 255, 255, 255), anchor="mm", stroke_width=6, stroke_fill=(0, 0, 0, 150))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=72, fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, "unlock_" + it["key"] + ".png")
    out.save(p, optimize=True)
    return p


def call(method, url, fields=None, image=None):
    api_key = open(os.path.join(ROOT, ".secrets", "roblox_api_key"), encoding="utf-8").read().strip()
    headers = {"x-api-key": api_key}
    body = None
    if fields is not None or image is not None:
        boundary = "----rofront" + uuid.uuid4().hex
        parts = []
        for k, v in (fields or {}).items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        if image is not None:
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="imageFile"; filename="icon.png"\r\n'
                         f"Content-Type: image/png\r\n\r\n".encode() + open(image, "rb").read() + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        body = b"".join(parts)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def existing(universe, whole=False):
    """{name: product id} of the experience's developer products (whole: {name: the product})."""
    out, token = {}, ""
    for _ in range(20):
        url = f"{API}/{universe}/developer-products/creator?pageSize=100" + (f"&pageToken={token}" if token else "")
        status, text = call("GET", url)
        if status >= 300:
            raise SystemExit(f"can't list the experience's products: HTTP {status} {text[:200]}")
        d = json.loads(text)
        for p in d.get("developerProducts", []):
            out[p.get("name")] = p if whole else (p.get("productId") or p.get("id"))
        token = d.get("nextPageToken") or ""
        if not token:
            break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--create", action="store_true")
    ap.add_argument("--icons", action="store_true")
    ap.add_argument("--universe", default="")
    ap.add_argument("--write", choices=["prod", "staging"], default="")
    args = ap.parse_args()
    items = catalogue()
    icons = {it["key"]: render(it) for it in items}
    for it in items:
        print(f'icon unlock_{it["key"]} ({it["robux"]} Robux) -> {os.path.relpath(icons[it["key"]], ROOT)}')
    if args.icons:
        if not args.universe:
            raise SystemExit("--icons needs --universe")
        before = existing(args.universe, whole=True)
        for it in items:
            name = "Unlock " + it["title"]
            p = before.get(name)
            if p is None:
                print(f"{name}: no such product in {args.universe}")
                continue
            pid = p.get("productId") or p.get("id")
            status, text = call("PATCH", f"{API}/{args.universe}/developer-products/{pid}", None, icons[it["key"]])
            if status >= 300:
                raise SystemExit(f"{name}: HTTP {status} {text[:300]}")
            print(f"{name} ({pid}): icon sent")
        # nothing but the icon may have moved
        after = existing(args.universe, whole=True)
        for name, p in before.items():
            a = after.get(name) or {}
            same = all(p.get(k) == a.get(k) for k in p if "image" not in k.lower() and "icon" not in k.lower() and "updated" not in k.lower())
            if not same:
                print(f"CHANGED besides its icon: {name}\n  before {p}\n  after  {a}")
        return
    if not args.create:
        return
    if not args.universe:
        raise SystemExit("--create needs --universe")
    have = existing(args.universe)
    ids = {}
    for it in items:
        name = "Unlock " + it["title"]
        fields = {"name": name, "description": it["tagline"] + ". Yours for good.", "price": str(it["robux"]),
                  "isForSale": "true"}
        pid = have.get(name)
        if pid:
            status, text = call("PATCH", f"{API}/{args.universe}/developer-products/{pid}", fields, icons[it["key"]])
        else:
            status, text = call("POST", f"{API}/{args.universe}/developer-products", fields, icons[it["key"]])
            if status < 300:
                d = json.loads(text)
                pid = d.get("productId") or d.get("id")
        if status >= 300 or not pid:
            raise SystemExit(f'{name}: HTTP {status} {text[:300]}')
        ids[it["key"]] = int(pid)
        print(f'unlock_{it["key"]} {pid}')
    if args.write:
        src = open(PRODUCTS, encoding="utf-8").read()
        for key, pid in ids.items():
            pat = re.compile(r"(unlock_" + key + r" = \{ )id = (\d+)(, robux = \d+, grants = \"unlock:" + key + r"\")(, staging = \d+)?( \})")
            m = pat.search(src)
            assert m, key
            prod_id = str(pid) if args.write == "prod" else m.group(2)
            staging = f", staging = {pid}" if args.write == "staging" else (m.group(4) or "")
            src = src[:m.start()] + f"{m.group(1)}id = {prod_id}{m.group(3)}{staging}{m.group(5)}" + src[m.end():]
        if args.write == "staging":
            # (Rofront Staging's universe id lives in Data/Staging)
            sp = os.path.join(os.path.dirname(PRODUCTS), "Staging.luau")
            ss = open(sp, encoding="utf-8").read()
            open(sp, "w", encoding="utf-8").write(re.sub(r"Staging\.UNIVERSE = \d+", f"Staging.UNIVERSE = {int(args.universe)}", ss))
        open(PRODUCTS, "w", encoding="utf-8").write(src)
        print("wrote", os.path.relpath(PRODUCTS, ROOT))


if __name__ == "__main__":
    main()
