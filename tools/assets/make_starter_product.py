#!/usr/bin/env python3
"""The starter pack's developer product (Data/Starter, Data/Products: starter_pack): its icon, and the product
itself through Open Cloud (the same calls as make_arsenal_products.py).

  icon     512 px: the three items' renders (assets/arsenal/renders/<key>.png) on a red ground with a gold
           glow, STARTER PACK under them -> build/products/starter_pack.png
  --create --universe <id>   create the product "Starter Pack" there at Data/Products' price (on sale, with
           its icon), or set its price and icon again if it exists. Prints `starter_pack <product id>`.
  --write prod|staging        with --create: put the id into src/shared/Data/Products.luau (`id =` for
           production, `staging =` for Rofront Staging).

Usage: .venv/bin/python tools/assets/make_starter_product.py [--create --universe ID [--write staging]]
"""
import argparse
import json
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import make_arsenal_products as arsenal  # noqa: E402  (call / existing / paths)

ROOT = arsenal.ROOT
SIZE = 512
NAME = "Starter Pack"
ITEMS = ["scatter", "mega", "stars2x"]  # left, middle (in front), right


def price():
    m = re.search(r"starter_pack = \{ id = \d+, robux = (\d+)", open(arsenal.PRODUCTS, encoding="utf-8").read())
    assert m, "starter_pack not in Data/Products"
    return int(m.group(1))


def render():
    im = Image.new("RGBA", (SIZE, SIZE))
    px = im.load()
    top, bottom = (214, 52, 52), (96, 10, 30)
    for y in range(SIZE):
        k = y / (SIZE - 1)
        col = tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)) + (255,)
        for x in range(SIZE):
            px[x, y] = col
    for box, colour, alpha, blur in (([16, -40, 496, 380], (255, 200, 90), 200, 64), ([136, 60, 376, 300], (255, 236, 170), 150, 40)):
        glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse(box, fill=colour + (alpha,))
        im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(blur)))
    slots = {"scatter": (130, 200, 250), "stars2x": (382, 200, 230), "mega": (256, 186, 300)}
    for key in ITEMS:
        g = Image.open(os.path.join(ROOT, "assets", "arsenal", "renders", key + ".png")).convert("RGBA")
        cx, cy, h = slots[key]
        k = min(h / g.size[1], 230 / g.size[0])
        g = g.resize((round(g.size[0] * k), round(g.size[1] * k)), Image.LANCZOS)
        gx, gy = cx - g.size[0] // 2, cy - g.size[1] // 2
        sh = Image.new("RGBA", g.size, (0, 0, 0, 0))
        sh.putalpha(g.getchannel("A").point(lambda v: int(v * 0.5)))
        im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(8)), (gx, gy + 12))
        im.alpha_composite(g, (gx, gy))
    d = ImageDraw.Draw(im)
    font = ImageFont.truetype(arsenal.FONT, 64)
    d.text((SIZE / 2, 412), "STARTER", font=font, fill=(255, 255, 255, 255), anchor="mm", stroke_width=6, stroke_fill=(60, 8, 12, 200))
    d.text((SIZE / 2, 468), "PACK", font=font, fill=(255, 214, 90, 255), anchor="mm", stroke_width=6, stroke_fill=(60, 8, 12, 200))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=72, fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    os.makedirs(arsenal.OUT, exist_ok=True)
    p = os.path.join(arsenal.OUT, "starter_pack.png")
    out.save(p, optimize=True)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--create", action="store_true")
    ap.add_argument("--universe", default="")
    ap.add_argument("--write", choices=["prod", "staging"], default="")
    args = ap.parse_args()
    icon = render()
    robux = price()
    print(f"icon starter_pack ({robux} Robux) -> {os.path.relpath(icon, ROOT)}")
    if not args.create:
        return
    if not args.universe:
        raise SystemExit("--create needs --universe")
    have = arsenal.existing(args.universe)
    fields = {"name": NAME, "description": "Mega Nuke, Scattershot and 2x Stars. Yours for good.",
              "price": str(robux), "isForSale": "true"}
    pid = have.get(NAME)
    if pid:
        status, text = arsenal.call("PATCH", f"{arsenal.API}/{args.universe}/developer-products/{pid}", fields, icon)
    else:
        status, text = arsenal.call("POST", f"{arsenal.API}/{args.universe}/developer-products", fields, icon)
        if status < 300:
            d = json.loads(text)
            pid = d.get("productId") or d.get("id")
    if status >= 300 or not pid:
        raise SystemExit(f"{NAME}: HTTP {status} {text[:300]}")
    print(f"starter_pack {pid}")
    if args.write:
        src = open(arsenal.PRODUCTS, encoding="utf-8").read()
        pat = re.compile(r"(starter_pack = \{ id = )(\d+)(, robux = \d+, grants = \"starter\", staging = )(\d+)( \})")
        m = pat.search(src)
        assert m, "starter_pack line"
        prod_id = str(pid) if args.write == "prod" else m.group(2)
        staging = str(pid) if args.write == "staging" else m.group(4)
        src = src[:m.start()] + f"{m.group(1)}{prod_id}{m.group(3)}{staging}{m.group(5)}" + src[m.end():]
        open(arsenal.PRODUCTS, "w", encoding="utf-8").write(src)
        print("wrote", os.path.relpath(arsenal.PRODUCTS, ROOT))


if __name__ == "__main__":
    main()
