#!/usr/bin/env python3
"""The flag shop's flags (Data/Shop, docs/flag-shop.md) from assets/shop_flags: flags.json (names,
rarities, sets) and art/<key>.png (gen_shop_flags.py: Codex's, kept at 768 x 512).

  atlases   each flag at FLAG_W x FLAG_H (name tags, the leaderboard, the Locker: like the country
            flags) and at BIG_W x BIG_H (the shop's cards), packed into sheets, uploaded as the group
  icons     512 px product icons: the flag on a dark ground lit in its rarity's colour, its name
            under it -> build/shop_flags/icons/<key>.png
  products  --create --universe <id> --write prod|staging: one developer product per flag ("<Name>
            Flag", at Data/Shop.PRICES of its rarity, with its icon), made or updated (matched by
            name); the ids go to assets/shop_flags/products.json. --only k1,k2: just those products
            (a flag's art changed: its icon again). A set with a `bundle` price (Data/Shop.SETS) gets
            one more: "<Set> Flag Pack", all its flags (--only set:<id> for just that one)
  manifest  src/shared/Assets/ShopFlags.luau: the sheets, each flag's rects and its product ids; written
            only once every sheet is Approved by moderation (players see an image under review as a
            blank; Studio shows it to its owner), unless --allow-pending

Usage: .venv/bin/python tools/assets/make_shop_flags.py --group 421623341 [--no-upload]
         [--create --universe <id> --write prod|staging]
Production is universe 10768172922, Rofront Staging 10769439627 (Data/Staging).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_arsenal_products as mp  # noqa: E402
import upload_audio as ua  # noqa: E402

ROOT = ua.ROOT
SRC = os.path.join(ROOT, "assets", "shop_flags")
OUT = os.path.join(ROOT, "build", "shop_flags")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "ShopFlags.luau")
SHOP = os.path.join(ROOT, "src", "shared", "Data", "Shop.luau")
FORMAT = "shopflags-v1"
FLAG_W, FLAG_H, CELL_W, CELL_H, COLS = 114, 76, 120, 80, 8
BIG_W, BIG_H, BIG_CW, BIG_CH, BIG_COLS = 228, 152, 232, 156, 4
PER_SHEET = {"small": COLS * 8, "big": BIG_COLS * 6}
RARITY = {"rare": (61, 139, 255), "epic": (163, 91, 255), "legendary": (255, 178, 46)}
FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"


def prices():
    src = open(SHOP, encoding="utf-8").read()
    m = re.search(r"Shop\.PRICES = \{([^}]*)\}", src)
    return {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", m.group(1))}


def set_bundles():
    """{set id: (name, bundle Robux)} for Data/Shop.SETS entries with a `bundle`."""
    src = open(SHOP, encoding="utf-8").read()
    body = src[src.index("Shop.SETS = {"):]
    body = body[:body.index("\n}") + 2]
    out = {}
    for sid, fields in re.findall(r"(\w+) = \{ ([^}]*) \}", body):
        name = re.search(r'name = "([^"]+)"', fields)
        bundle = re.search(r"bundle = (\d+)", fields)
        if name and bundle:
            out[sid] = (name.group(1), int(bundle.group(1)))
    return out


def bundle_icon(sid, name, members):
    """512 px: the set's flags (rarest first) in a 3 x 2 grid on a dark ground, its name and FLAG PACK."""
    S = 512
    im = Image.new("RGBA", (S, S), (8, 12, 26, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([30, 0, 482, 360], fill=(255, 140, 40, 140))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(70)))
    w, h, gap = 138, 92, 12
    x0, y0 = (S - (3 * w + 2 * gap)) // 2, 64
    for i, f in enumerate(members[:6]):
        fl = flag_at(os.path.join(SRC, "art", f["key"] + ".png"), w, h)
        x, y = x0 + (i % 3) * (w + gap), y0 + (i // 3) * (h + gap)
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=10, fill=255)
        im.paste(fl, (x, y), mask)
        col = RARITY.get(f["rarity"], RARITY["rare"])
        ImageDraw.Draw(im).rounded_rectangle([x - 2, y - 2, x + w + 1, y + h + 1], radius=12, outline=col + (255,), width=4)
    d = ImageDraw.Draw(im)
    d.text((S / 2, 330), name.upper(), font=ImageFont.truetype(FONT, 64), fill=(255, 255, 255, 255), anchor="mm", stroke_width=5, stroke_fill=(0, 0, 0, 160))
    d.text((S / 2, 400), f"{len(members)} FLAG PACK", font=ImageFont.truetype(FONT, 40), fill=(255, 160, 60, 255), anchor="mm")
    rmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rmask).rounded_rectangle([0, 0, S - 1, S - 1], radius=72, fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(im, (0, 0), rmask)
    p = os.path.join(OUT, "icons", "set_" + sid + ".png")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    out.save(p, optimize=True)
    return p


def flag_at(path, w, h):
    im = Image.open(path).convert("RGB")
    # (centre crop to 3:2, then down in two steps: a softer result than one big LANCZOS jump)
    W, H = im.size
    if W / H > w / h:
        nw = round(H * w / h)
        im = im.crop(((W - nw) // 2, 0, (W - nw) // 2 + nw, H))
    else:
        nh = round(W * h / w)
        im = im.crop((0, (H - nh) // 2, W, (H - nh) // 2 + nh))
    if im.width > w * 3:
        im = im.resize((w * 3, h * 3), Image.LANCZOS)
    return im.resize((w, h), Image.LANCZOS).convert("RGBA")


def sheets(flags, size):
    w, h, cw, ch, cols = (FLAG_W, FLAG_H, CELL_W, CELL_H, COLS) if size == "small" else (BIG_W, BIG_H, BIG_CW, BIG_CH, BIG_COLS)
    per = PER_SHEET[size]
    paths, rects = [], {}
    for a in range((len(flags) + per - 1) // per):
        part = flags[a * per:(a + 1) * per]
        rows = (len(part) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
        for k, f in enumerate(part):
            im = flag_at(os.path.join(SRC, "art", f["key"] + ".png"), w, h)
            x, y = (k % cols) * cw + (cw - w) // 2, (k // cols) * ch + (ch - h) // 2
            sheet.alpha_composite(im, (x, y))
            rects[f["key"]] = {"atlas": a + 1, "x": x, "y": y, "w": w, "h": h}
        p = os.path.join(OUT, f"shopflags_{size}_{a + 1}.png")
        sheet.save(p, optimize=True)
        paths.append(p)
    return paths, rects


def icon(f):
    """512 px: dark ground, a glow of the rarity's colour, the flag framed, the name under it."""
    S = 512
    col = RARITY.get(f["rarity"], RARITY["rare"])
    im = Image.new("RGBA", (S, S), (8, 12, 26, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([40, 10, 472, 380], fill=col + (150,))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(70)))
    fl = flag_at(os.path.join(SRC, "art", f["key"] + ".png"), 420, 280)
    fx, fy = (S - 420) // 2, 52
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([fx - 6, fy + 4, fx + 426, fy + 292], radius=18, fill=(0, 0, 0, 150))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(10)))
    mask = Image.new("L", (420, 280), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 419, 279], radius=14, fill=255)
    im.paste(fl, (fx, fy), mask)
    ImageDraw.Draw(im).rounded_rectangle([fx - 3, fy - 3, fx + 422, fy + 282], radius=16, outline=col + (255,), width=6)
    label = f["name"].upper()
    size = 64
    font = ImageFont.truetype(FONT, size)
    d = ImageDraw.Draw(im)
    while d.textlength(label, font=font) > S - 50 and size > 30:
        size -= 4
        font = ImageFont.truetype(FONT, size)
    d.text((S / 2, 410), label, font=font, fill=(255, 255, 255, 255), anchor="mm", stroke_width=5, stroke_fill=(0, 0, 0, 160))
    d.text((S / 2, 468), f["rarity"].upper() + " FLAG", font=ImageFont.truetype(FONT, 30), fill=col + (255,), anchor="mm")
    rmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rmask).rounded_rectangle([0, 0, S - 1, S - 1], radius=72, fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(im, (0, 0), rmask)
    p = os.path.join(OUT, "icons", f["key"] + ".png")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    out.save(p, optimize=True)
    return p


def upload_sheets(paths, prefix, what):
    cache = ua.load_cache()
    ids = []
    for p in paths:
        digest = hashlib.sha256(open(p, "rb").read()).hexdigest()
        ck = f"{prefix}{FORMAT}:{digest}"
        e = cache.get(ck) or {}
        aid = e.get("asset_id")
        if aid is None:
            label = "Rofront " + os.path.basename(p)[:-4]
            op_id = e.get("pending_op")
            if not op_id:
                op_id = ua.upload_start(p, label, "Rofront shop flags (" + what + ")", "Image")
                cache[ck] = {"pending_op": op_id, "name": label}
                ua.save_cache(cache)
            aid, resp = ua.upload_wait(op_id)
            mod = (resp.get("moderationResult") or {}).get("moderationState", "?")
            cache[ck] = {"asset_id": aid, "name": label, "moderation": mod, "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
            ua.save_cache(cache)
            print(f"{os.path.basename(p)}: rbxassetid://{aid} moderation={mod}")
        ids.append(aid)
    return ids


def wait_approved(ids, timeout_s=1800):
    """Every sheet Approved by Roblox's moderation before the manifest points the game at it: Studio shows
    an image under review to its owner, but players get a blank (2026-10-22: the Halloween flags were
    blank on a phone while their re-uploaded sheet was in review). True when all are approved."""
    t0 = time.time()
    while True:
        states = {aid: ua.asset_state(int(aid))[0] for aid in ids}
        waiting = [a for a, st in states.items() if st != "Approved"]
        if not waiting:
            return True
        bad = [a for a in waiting if states[a] not in ("Reviewing", "Pending", "?", None)]
        if bad or time.time() - t0 > timeout_s:
            print("not approved:", ", ".join(f"{a} {states[a]}" for a in waiting))
            return False
        print(f"waiting for moderation: {len(waiting)} sheet(s) Reviewing ({int(time.time() - t0)} s)", flush=True)
        time.sleep(20)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="")
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--allow-pending", action="store_true", help="write the manifest before moderation approves")
    ap.add_argument("--create", action="store_true")
    ap.add_argument("--universe", default="")
    ap.add_argument("--write", choices=["prod", "staging"], default="")
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    data = json.load(open(os.path.join(SRC, "flags.json"), encoding="utf-8"))
    flags = [f for f in data["flags"] if os.path.exists(os.path.join(SRC, "art", f["key"] + ".png"))]
    missing = [f["key"] for f in data["flags"] if f not in flags]
    if missing:
        print("no art yet (left out):", ", ".join(missing))
    os.makedirs(OUT, exist_ok=True)
    small, small_rects = sheets(flags, "small")
    big, big_rects = sheets(flags, "big")
    icons = {f["key"]: icon(f) for f in flags}
    print(f"{len(flags)} flags: {len(small)} small + {len(big)} big sheets, icons -> {os.path.relpath(OUT, ROOT)}")
    pj = os.path.join(SRC, "products.json")
    products = json.load(open(pj, encoding="utf-8")) if os.path.exists(pj) else {}
    if args.create:
        if not args.universe or not args.write:
            raise SystemExit("--create needs --universe and --write prod|staging")
        price = prices()
        have = mp.existing(args.universe)
        only = {k for k in args.only.split(",") if k}
        for f in flags:
            if only and f["key"] not in only:
                continue
            name = f["name"] + " Flag"
            fields = {"name": name, "price": str(price[f["rarity"]]), "isForSale": "true",
                      "description": "A " + f["rarity"] + " flag for your nation, by your name on the map and the leaderboard. Yours for good."}
            pid = have.get(name)
            if pid:
                status, text = mp.call("PATCH", f"{mp.API}/{args.universe}/developer-products/{pid}", fields, icons[f["key"]])
            else:
                status, text = mp.call("POST", f"{mp.API}/{args.universe}/developer-products", fields, icons[f["key"]])
                if status < 300:
                    d = json.loads(text)
                    pid = d.get("productId") or d.get("id")
            if status >= 300 or not pid:
                raise SystemExit(f"{name}: HTTP {status} {text[:300]}")
            products.setdefault(f["key"], {})[args.write] = int(pid)
            print(f"{name}: {pid} ({price[f['rarity']]} Robux)")
            with open(pj, "w", encoding="utf-8") as fh:
                json.dump(products, fh, indent=2, sort_keys=True)
                fh.write("\n")
        # the sets' bundles: all of a set in one product
        for sid, (sname, robux) in set_bundles().items():
            if only and ("set:" + sid) not in only:
                continue
            members = sorted([f for f in flags if f.get("set") == sid], key=lambda f: ({"legendary": 0, "epic": 1, "rare": 2}.get(f["rarity"], 3), f["name"]))
            name = sname + " Flag Pack"
            fields = {"name": name, "price": str(robux), "isForSale": "true",
                      "description": f"All {len(members)} {sname} flags at once. Yours for good."}
            icon_path = bundle_icon(sid, sname, members)
            pid = have.get(name)
            if pid:
                status, text = mp.call("PATCH", f"{mp.API}/{args.universe}/developer-products/{pid}", fields, icon_path)
            else:
                status, text = mp.call("POST", f"{mp.API}/{args.universe}/developer-products", fields, icon_path)
                if status < 300:
                    d = json.loads(text)
                    pid = d.get("productId") or d.get("id")
            if status >= 300 or not pid:
                raise SystemExit(f"{name}: HTTP {status} {text[:300]}")
            products.setdefault("set:" + sid, {})[args.write] = int(pid)
            print(f"{name}: {pid} ({robux} Robux)")
            with open(pj, "w", encoding="utf-8") as fh:
                json.dump(products, fh, indent=2, sort_keys=True)
                fh.write("\n")
    if args.no_upload:
        return
    if args.group:
        ua.CREATOR = {"groupId": str(args.group)}
    prefix = f"g{args.group}:" if args.group else ""
    small_ids = upload_sheets(small, prefix, "name tags")
    big_ids = upload_sheets(big, prefix, "shop cards")
    if not args.allow_pending and not wait_approved(small_ids + big_ids):
        raise SystemExit("manifest NOT written: a sheet isn't approved (players would see blank flags)")
    L = [
        "-- GENERATED by tools/assets/make_shop_flags.py — do not edit by hand (assets/shop_flags/flags.json,",
        "-- products.json). The flag shop's flags (Data/Shop): `atlases` for name tags, the leaderboard and the",
        "-- Locker (like Assets/Flags), `big` for the shop's cards; each flag's rects, and its developer",
        "-- product in production (`product`) and Rofront Staging (`staging`), 0 = not made yet.",
        "return {",
        "\tatlases = { " + ", ".join(f'"rbxassetid://{i}"' for i in small_ids) + " },",
        "\tbig = { " + ", ".join(f'"rbxassetid://{i}"' for i in big_ids) + " },",
        "\tflags = {",
    ]
    for f in flags:
        s, b = small_rects[f["key"]], big_rects[f["key"]]
        p = products.get(f["key"], {})
        fields = [f'key = {lua_str(f["key"])}', f'name = {lua_str(f["name"])}', f'theme = {lua_str(f["theme"])}',
                  f'rarity = {lua_str(f["rarity"])}']
        if f.get("set"):
            fields.append(f'set = {lua_str(f["set"])}')
        fields += [f'atlas = {s["atlas"]}, x = {s["x"]}, y = {s["y"]}, w = {s["w"]}, h = {s["h"]}',
                   f'big_rect = {{ {b["atlas"]}, {b["x"]}, {b["y"]}, {b["w"]}, {b["h"]} }}',
                   f'product = {p.get("prod", 0)}', f'staging = {p.get("staging", 0)}']
        L.append("\t\t{ " + ", ".join(fields) + " },")
    L += ["\t},", "\tsets = {"]
    for sid in sorted(set_bundles()):
        p = products.get("set:" + sid, {})
        L.append(f'\t\t{sid} = {{ product = {p.get("prod", 0)}, staging = {p.get("staging", 0)} }},')
    L += ["\t},", "}"]
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")
    print(f"manifest: {len(flags)} flags -> {os.path.relpath(MANIFEST, ROOT)}")


if __name__ == "__main__":
    main()
