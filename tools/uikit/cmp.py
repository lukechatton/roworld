# usage: cmp.py mine.png ref.png outprefix [logical_w]
# Resizes `mine` (Studio capture) to the logical viewport and builds side-by-side crops vs `ref`
# (the original at 1600x900 logical, 1x). Crops are anchored like the HUD (top-left / top-centre /
# top-right / bottom-left / bottom-centre).
import sys
from PIL import Image, ImageDraw
mine = Image.open(sys.argv[1]).convert("RGB")
ref = Image.open(sys.argv[2]).convert("RGB")
out = sys.argv[3]
lw = float(sys.argv[4]) if len(sys.argv) > 4 else 1602.87
lh = 900.0
m = mine.resize((round(lw), round(lh)), Image.LANCZOS)
rw, rh = ref.size
if rw != 1600:
    ref = ref.resize((1600, 900), Image.LANCZOS)
dx = (lw - 1600) / 2  # centred content shifts by half the extra width
regions = {
    # name: (x0, y0, x1, y1, anchor) in ref coords; anchor: 'l' left, 'c' centre, 'r' right
    "top": (520, 0, 1080, 160, "c"),
    "board": (1280, 0, 1600, 580, "r"),
    "feed": (0, 460, 380, 800, "l"),
    "bar_l": (100, 790, 820, 900, "c"),
    "bar_r": (800, 790, 1500, 900, "c"),
}
for name, (x0, y0, x1, y1, a) in regions.items():
    off = 0 if a == "l" else (dx if a == "c" else lw - 1600)
    r = ref.crop((x0, y0, x1, y1))
    mm = m.crop((round(x0 + off), y0, round(x1 + off), y1))
    w, h = r.size
    k = 2
    canvas = Image.new("RGB", (w * k, h * k * 2 + 6), (255, 0, 255))
    canvas.paste(r.resize((w * k, h * k), Image.NEAREST), (0, 0))
    canvas.paste(mm.resize((w * k, h * k), Image.NEAREST), (0, h * k + 6))
    canvas.save(f"{out}_{name}.png")
print("ok")
