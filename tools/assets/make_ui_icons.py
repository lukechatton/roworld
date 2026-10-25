#!/usr/bin/env python3
"""Rasterise AIRFRONT's UI SVG icons into Roblox-ready PNGs, upload them, write the manifest.

Sources (never modified):  ~/games/airfront/assets/icons/ui/*.svg      -> <name>
                           ~/games/airfront/assets/ui/*.svg            -> <name>   (check, chevron, clock)
                           ~/games/airfront/assets/icons/hud/*.svg     -> hud_<name>
                           ~/games/airfront/assets/icons/app_icon.svg  -> app_icon (full colour)
Rofront's own icons:       assets/icons_src/ui/*.svg                   -> <name>   (settings, pops)
                           assets/icons_src/hud/*.svg                  -> hud_<name>
Outputs:  assets/ui_icons/<key>.png         (MASK px white-on-transparent masks; app_icon APP px colour)
          src/shared/Assets/UiIcons.luau    ({ key = "rbxassetid://…" }, sorted)

Masks: pure white RGB everywhere (also in fully transparent texels, so bilinear/mip filtering never
pulls in a dark fringe) with the SVG's anti-aliased coverage as alpha -> tint with ImageColor3.
The 64×64 SVG framing is kept (glyph spans ≈4..60), so an ImageLabel of the Godot icon px size
matches the original TextureRect exactly. The app icon keeps its colours; its transparent texels
get the nearest opaque colour bled in (Godot's Image.fix_alpha_edges equivalent).

Usage:
  .venv/bin/python tools/assets/make_ui_icons.py            # render + upload + write manifest
  .venv/bin/python tools/assets/make_ui_icons.py --no-upload  # render only
Upload goes through tools/upload.py (content-hash cached; unchanged PNGs are not re-uploaded) and uses
the Studio instance picked by STUDIO_MATCH (defaults to assets.rbxl here).
"""
import argparse
import io
import os
import sys

import numpy as np
import resvg_py
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.expanduser("~/games/airfront/assets")
OUT = os.path.join(ROOT, "assets", "ui_icons")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "UiIcons.luau")

MASK_PX = 128   # 64-unit SVGs at 2x: crisp up to ~64 px on a 2x display; mipmapped below that
APP_PX = 512    # 256-unit app icon at 2x (Godot rasterises it at 2x too)


def sources():
    """[(key, svg_path, colour)] in a stable order."""
    out = []
    for sub, prefix in (("icons/ui", ""), ("ui", ""), ("icons/hud", "hud_")):
        d = os.path.join(SRC, sub)
        for f in sorted(os.listdir(d)):
            if f.endswith(".svg"):
                out.append((prefix + f[:-4], os.path.join(d, f), False))
    # Rofront's own (the original has no settings screen): the same framing, drawn for this repo
    for sub, prefix in (("ui", ""), ("hud", "hud_")):
        d = os.path.join(ROOT, "assets", "icons_src", sub)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".svg"):
                    out.append((prefix + f[:-4], os.path.join(d, f), False))
    out.append(("app_icon", os.path.join(SRC, "icons", "app_icon.svg"), True))
    keys = [k for k, _, _ in out]
    assert len(keys) == len(set(keys)), "duplicate icon keys"
    return out


def render_svg(path, px):
    """RGBA float array (straight alpha, 0..1) of the SVG rendered to px×px."""
    svg = open(path, encoding="utf-8").read()
    png = bytes(resvg_py.svg_to_bytes(svg_string=svg, width=px, height=px))
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    assert img.size == (px, px), (path, img.size)
    return np.asarray(img).astype(np.float32) / 255.0


def to_mask(rgba):
    a = rgba[..., 3]
    out = np.empty(rgba.shape, np.uint8)
    out[..., :3] = 255
    out[..., 3] = np.clip(np.round(a * 255.0), 0, 255).astype(np.uint8)
    return out


def bleed_edges(rgba8, iterations=24):
    """Fill RGB of transparent texels with the average colour of already-filled neighbours."""
    rgb = rgba8[..., :3].astype(np.float32)
    known = rgba8[..., 3] > 0
    rgb[~known] = 0.0
    for _ in range(iterations):
        if known.all():
            break
        acc = np.zeros_like(rgb)
        cnt = np.zeros(known.shape, np.float32)
        k = known.astype(np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                acc += np.roll(np.roll(rgb * k[..., None], dy, 0), dx, 1)
                cnt += np.roll(np.roll(k, dy, 0), dx, 1)
        grow = (~known) & (cnt > 0)
        rgb[grow] = acc[grow] / cnt[grow][:, None]
        known = known | grow
    if not known.all():
        rgb[~known] = rgb[known].mean(axis=0)
    out = rgba8.copy()
    out[..., :3] = np.clip(np.round(rgb), 0, 255).astype(np.uint8)
    return out


def render_all(mask_px=MASK_PX, app_px=APP_PX):
    os.makedirs(OUT, exist_ok=True)
    files = {}
    for key, path, colour in sources():
        if colour:
            rgba = render_svg(path, app_px)
            img = bleed_edges(np.clip(np.round(rgba * 255.0), 0, 255).astype(np.uint8))
        else:
            img = to_mask(render_svg(path, mask_px))
        dst = os.path.join(OUT, key + ".png")
        Image.fromarray(img, "RGBA").save(dst, optimize=True)
        files[key] = dst
    return files


def write_manifest(ids):
    lines = [
        "-- GENERATED by tools/assets/make_ui_icons.py — do not edit by hand.",
        "-- UI icon images (Rasterised from ~/games/airfront/assets/{icons/ui,ui,icons/hud}/*.svg and",
        "-- icons/app_icon.svg). Keys = UITheme.icon() names; HUD top-bar variants are prefixed \"hud_\".",
        f"-- Masks are {MASK_PX}×{MASK_PX} white-on-transparent (tint with ImageColor3; keep the 64-unit SVG",
        f"-- framing, so size the ImageLabel to the Godot px). app_icon is full colour ({APP_PX}×{APP_PX}), do not tint.",
        "return {",
    ]
    for key in sorted(ids):
        lines.append(f'\t{key} = "{ids[key]}",')
    lines.append("}")
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-upload", action="store_true")
    args = ap.parse_args()
    files = render_all()
    print(f"rendered {len(files)} icons -> {os.path.relpath(OUT, ROOT)}")
    if args.no_upload:
        return
    os.environ.setdefault("STUDIO_MATCH", "assets.rbxl")
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import upload  # noqa: E402

    res = upload.upload_images(list(files.values()))
    ids = {key: res[os.path.abspath(p)] for key, p in files.items()}
    write_manifest(ids)
    print(f"uploaded {len(ids)} -> {os.path.relpath(MANIFEST, ROOT)}")


if __name__ == "__main__":
    main()
