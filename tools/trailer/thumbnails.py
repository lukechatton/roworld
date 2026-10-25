#!/usr/bin/env python3
"""Experience thumbnails from real gameplay (2026-10-18, after the three-weeks report's thumbnail and
icon tests). The five live thumbnails are one illustrated picture in different colours, so personalization has
nothing to choose between (each 0.34-0.35% qualified play-through). These are different ideas, each a frame of
the trailer's own captures (build/trailer, Studio film mode, docs/trailer.md): the HUD cropped away, the
ROWORLD wordmark top left as on the live ones. 1920 x 1080 JPEGs in build/thumbnails/.

Usage: .venv/bin/python tools/trailer/thumbnails.py
"""
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "build", "trailer")
OUT = os.path.join(ROOT, "build", "thumbnails")
FONT = "/Applications/RobloxStudio.app/Contents/Resources/content/fonts/Montserrat-Black.ttf"
W, H = 1920, 1080
# The HUD of a 1920 x 1080 capture (film mode): the top bars end about y 100, the attacks list on the right
# starts at x 1545 and reaches y 300, and the bottom bar's shadow starts at y 945 (measured). So a 16:9
# window clear of all of them is x 0-1500, y 100-944; the zoomed-out world shot also starts at x 100, where
# the map begins.
CROP = (0, 100, 1500, 944)
CROP_WORLD = (100, 100, 1540, 910)

# (name, frame, crop, wordmark corner). The hydrogen bomb shot was tried: its country label sits under the
# match time panel in every frame of the blast.
SHOTS = [
    ("mirv_strike", "v3/climax8/00204.jpg", CROP, "right"),
    ("invasion_front", "v2/e_sudan/00105.jpg", CROP, "left"),
    ("world_empire", "v3/climax8/00000.jpg", CROP_WORLD, "left"),
]


def crop(im, box):
    return im.crop(box).resize((W, H), Image.LANCZOS)


def wordmark(im, corner, text="ROWORLD"):
    f = ImageFont.truetype(FONT, 150)
    l, t, r, b = f.getbbox(text)
    pad = 40
    layer = Image.new("RGBA", (r - l + pad * 2, b - t + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.text((pad - l, pad - t), text, font=f, fill=(255, 255, 255, 255), stroke_width=14, stroke_fill=(16, 22, 40, 255))
    shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    shadow.putalpha(layer.getchannel("A").point(lambda v: v * 150 // 255))
    shadow = shadow.filter(ImageFilter.GaussianBlur(10))
    base = im.convert("RGBA")
    x, y = (34 if corner == "left" else W - layer.width - 34), 22
    base.alpha_composite(shadow, (x + 6, y + 10))
    base.alpha_composite(layer, (x, y))
    return base.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, frame, box, corner in SHOTS:
        im = Image.open(os.path.join(SRC, frame)).convert("RGB")
        out = wordmark(crop(im, box), corner)
        p = os.path.join(OUT, f"thumb_{name}.jpg")
        out.save(p, quality=92)
        print(name, "->", os.path.relpath(p, ROOT))


if __name__ == "__main__":
    main()
