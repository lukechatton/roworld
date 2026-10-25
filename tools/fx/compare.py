#!/usr/bin/env python3
"""Side-by-side crops of original reference shots and rofront captures at matched relative framing.
Usage: compare.py out.png ref.png ours.png [x0 y0 x1 y1 (relative 0..1)] [--width 1800]"""
import sys
from PIL import Image, ImageDraw

def main():
    a = sys.argv[1:]
    out, ref, ours = a[0], a[1], a[2]
    box = [float(v) for v in a[3:7]] if len(a) >= 7 else [0, 0, 1, 1]
    W = 1800
    ims = []
    for p in (ref, ours):
        im = Image.open(p).convert("RGB")
        w, h = im.size
        c = im.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))
        ims.append(c)
    tw = W // 2
    th = int(tw * ims[0].size[1] / ims[0].size[0])
    sheet = Image.new("RGB", (W, th + 24), (20, 20, 20))
    d = ImageDraw.Draw(sheet)
    for i, c in enumerate(ims):
        sheet.paste(c.resize((tw, th), Image.LANCZOS), (i * tw, 24))
        d.text((i * tw + 8, 4), ["original", "rofront"][i], fill=(255, 255, 255))
    sheet.save(out)

if __name__ == "__main__":
    main()
