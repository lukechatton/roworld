#!/usr/bin/env python3
"""Rofront's own map effects (2026-10-25): original work for the nuke explosion and the elimination
effect. They replace two of OpenFront's fx atlas sprites (assets/openfront, CC BY-SA): the Nuke
explosion and the conquest's crossed swords (now a victory flag, not swords at all). Drawn here from scratch as pixel art, a sprite pixel a map
tile like the rest of the map, every pixel worked out from shapes (distances, angles, noise): nothing is
traced or derived from their art.

  nuke     12 frames of 60 x 60 (70 ms each, drawn 60 OpenFront tiles wide, top-down): a white flash, a
           fireball (white-hot heart, yellow, orange, red, a dark outline, lit from the top left) that
           swells inside a thin shock ring, burns down to red and breaks into dark smoke with embers
           flying out, the smoke thinning to wisps
  flag     10 frames of 24 x 24 (90 ms, drawn 22 tiles): the conquest's victory flag (the first version
           was crossed swords; the elimination is now something other than a sword clash). It drops onto
           the conquered land, lands with a puff of
           dust and sinks a pixel, and its swallowtail banner waves; a glint on its gold top. Two rows:
           the flag in its colours (pole, gold top, mound, dust, outline) and the banner's
           cloth in white and greys under it, which the client tints the conqueror's colour.

Out: assets/map_fx/map_fx.png (one atlas, a row each), build/map_fx_sheet.png (--sheet: every frame big,
on a land and a territory), and with --upload (as the group, after Roblox's moderation approves it)
src/shared/Assets/MapFx.luau for Map/FxLayer.

Usage: .venv/bin/python tools/assets/make_map_fx.py [--sheet] [--upload --group 421623341]
"""
import argparse
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "assets", "map_fx")
MANIFEST = os.path.join(REPO, "src", "shared", "Assets", "MapFx.luau")

NUKE_N, NUKE_S = 12, 60
FLAG_N, FLAG_S = 10, 24

# the palette (RGB)
WHITE = (255, 253, 240)
PALE = (255, 242, 170)
YELLOW = (255, 206, 60)
ORANGE = (255, 136, 34)
RED = (226, 62, 30)
DARKRED = (138, 30, 22)
OUTLINE = (70, 18, 14)
SMOKE_D = (58, 50, 48)
SMOKE_M = (92, 82, 78)
SMOKE_L = (134, 124, 118)
EMBER = (255, 178, 70)
RING = (255, 248, 226)

GOLD_HI = (255, 222, 110)
GOLD = (232, 168, 42)
GOLD_LO = (150, 94, 26)
WOOD = (120, 76, 42)
WOOD_HI = (168, 112, 64)
DIRT = (110, 82, 54)
DUST_L = (232, 220, 196)
DUST_D = (190, 174, 150)
INK = (24, 22, 34)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def value_noise(n, cells, seed):
    """Smooth noise in [0, 1] over an n x n grid (cells x cells random values, bicubic-ish blend)."""
    rnd = np.random.RandomState(seed)
    g = rnd.rand(cells + 3, cells + 3)
    xs = np.linspace(0, cells, n, endpoint=False)
    i = xs.astype(int)
    f = xs - i
    f = f * f * (3 - 2 * f)
    row = g[:, i] * (1 - f) + g[:, i + 1] * f
    out = row[i, :] * (1 - f)[:, None] + row[i + 1, :] * f[:, None]
    return out


def lobes(theta, seed, k=7, amp=0.12):
    rnd = random.Random(seed)
    v = np.zeros_like(theta)
    for j in range(1, 4):
        v += (amp / j) * np.sin((k + j * 2) * theta * (1 if j % 2 else -1) / 1 + rnd.uniform(0, 6.28))
    return v


# ---------------------------------------------------------------------------------------------
# The nuke
# ---------------------------------------------------------------------------------------------

def nuke_frame(f):
    S = NUKE_S
    c = (S - 1) / 2
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    dx, dy = xx - c, yy - c
    r = np.hypot(dx, dy)
    th = np.arctan2(dy, dx)
    img = np.zeros((S, S, 4), np.uint8)

    def put(mask, col, a=255):
        img[mask, :3] = col
        img[mask, 3] = a

    # the plan per frame: fireball radius, how much of it has burnt (0 hot .. 1 all smoke), the ring's
    # radius (0 none), how far the embers are
    plan = [
        dict(R=5, burn=0.0, ring=0, embers=0),
        dict(R=11, burn=0.0, ring=0, embers=0),
        dict(R=16, burn=0.04, ring=21, embers=0),
        dict(R=20, burn=0.1, ring=25, embers=0),
        dict(R=22.5, burn=0.22, ring=28, embers=23),
    ][min(f, 4)]
    if f >= 5:
        return nuke_smoke(f)
    R, burn = plan["R"], plan["burn"]
    edge = R * (1 + lobes(th, 11 + f // 3, k=6, amp=0.1))
    # lit from the top left: the hot heart sits up and left of the middle
    hx, hy = dx + R * 0.16, dy + R * 0.16
    rh = np.hypot(hx, hy) / np.maximum(edge, 1)
    rr = r / np.maximum(edge, 1)
    noise = value_noise(S, 7, 100 + f)
    fine = value_noise(S, 15, 300 + f)

    if f == 0:
        put(r <= R + 3.5, PALE)
        put((r > R + 2) & (r <= R + 3.5) & ((xx + yy) % 2 == 0), YELLOW)
        put(r <= R, WHITE)
        return img
    if f == 1:
        # a white disc, a yellow edge and eight sparks out
        put(rr <= 1.0, YELLOW)
        put(rr <= 0.82, PALE)
        put(rh <= 0.55, WHITE)
        for k in range(8):
            a = k * math.pi / 4 + 0.2
            for d in (R + 2, R + 3, R + 4):
                x, y = int(round(c + math.cos(a) * d)), int(round(c + math.sin(a) * d))
                img[y, x, :3] = PALE if d < R + 4 else YELLOW
                img[y, x, 3] = 255
        out = (rr > 1.0) & (rr <= 1.0 + 1.2 / R)
        put(out, ORANGE)
        return img

    # the shock ring: thin, broken, fading out as it grows
    if plan["ring"]:
        rg = plan["ring"]
        band = np.abs(r - rg) < 0.75
        gaps = np.sin(th * 9 + f) > -0.55 - 0.1 * (4 - f)
        put(band & gaps, RING)

    inside = rr <= 1.0
    # hot -> burnt: where `heat` is below the burn line, it is smoke
    heat = (1 - rr) * 0.75 + noise * 0.45
    smoke = inside & (heat < burn * 1.25)
    fire = inside & ~smoke
    # holes in the smoke as it thins (the last frames)
    holes = fine < (burn - 0.62) * 1.7
    smoke &= ~holes

    # fire bands from the heart out (they cool as it burns)
    hot = 1 - burn
    bands = [(0.30 * hot, WHITE), (0.52 * hot + 0.06, PALE), (0.72 * hot + 0.12, YELLOW),
             (0.88 * hot + 0.1, ORANGE), (2.0, RED)]
    if burn > 0.4:
        bands = [(0.18 * hot, YELLOW), (0.4 * hot + 0.1, ORANGE), (0.7, RED), (2.0, DARKRED)]
    lit = rh * 0.7 + rr * 0.3 + (noise - 0.5) * 0.18
    done = np.zeros((S, S), bool)
    for lim, col in bands:
        m = fire & ~done & (lit <= lim)
        put(m, col)
        done |= m
    # smoke: dark round the fire, lighter out and as it thins; dithered where tones meet
    tone = rr * 0.6 + noise * 0.5 + burn * 0.35
    dith = ((xx + yy) % 2 == 0)
    put(smoke & (tone < 0.7), SMOKE_D)
    put(smoke & (tone >= 0.7) & (tone < 0.95), SMOKE_M)
    put(smoke & (tone >= 0.7) & (tone < 0.78) & dith, SMOKE_D)
    put(smoke & (tone >= 0.95), SMOKE_L)
    put(smoke & (tone >= 0.95) & (tone < 1.03) & dith, SMOKE_M)
    if burn >= 0.94:
        # the last wisps: only every other pixel of the lightest smoke
        keep = smoke & dith & (fine > 0.45)
        img[smoke & ~keep] = 0
        img[keep, :3] = SMOKE_L
        img[keep, 3] = 255

    # a dark outline round the fireball while it is mostly fire
    body = img[:, :, 3] > 0
    if burn < 0.6:
        pad = np.pad(body, 1)
        near = pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]
        ring_px = (np.abs(r - plan["ring"]) < 0.75) if plan["ring"] else np.zeros_like(body)
        put(~body & near & (rr <= 1.0 + 1.6 / R) & ~ring_px, OUTLINE)

    # embers flung out
    if plan["embers"]:
        rnd = random.Random(7)
        for k in range(14):
            a = rnd.uniform(0, 2 * math.pi)
            d = plan["embers"] * rnd.uniform(0.82, 1.0)
            x, y = int(round(c + math.cos(a) * d)), int(round(c + math.sin(a) * d))
            if 0 <= x < S and 0 <= y < S:
                img[y, x, :3] = EMBER if f < 7 else ORANGE
                img[y, x, 3] = 255
                if f <= 5:
                    x2, y2 = int(round(c + math.cos(a) * (d - 1))), int(round(c + math.sin(a) * (d - 1)))
                    img[y2, x2, :3] = RED
                    img[y2, x2, 3] = 255
    return img


def nuke_smoke(f):
    """Frames 5..11: the fireball has burnt to a red core under a ring of smoke puffs, which drift out,
    shrink and pale until the last wisps go; embers fly out early on."""
    S = NUKE_S
    c = (S - 1) / 2
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    dx, dy = xx - c, yy - c
    r = np.hypot(dx, dy)
    img = np.zeros((S, S, 4), np.uint8)
    k = f - 5  # 0..6
    rnd = random.Random(41)
    puffs = []
    # an outer ring of puffs and an inner one over the core
    for i in range(11):
        a = i * 2 * math.pi / 11 + rnd.uniform(-0.18, 0.18)
        d = (15.5 + rnd.uniform(-1.5, 1.5)) + k * 1.1
        rad = (7.6 + rnd.uniform(-0.8, 0.8)) * [1.0, 0.95, 0.86, 0.74, 0.6, 0.44, 0.28][k]
        puffs.append((c + math.cos(a) * d, c + math.sin(a) * d, rad))
    for i in range(5):
        a = i * 2 * math.pi / 5 + 0.6 + rnd.uniform(-0.2, 0.2)
        d = 6.5 + k * 0.6
        rad = (6.4 + rnd.uniform(-0.6, 0.6)) * [0.0, 0.7, 0.9, 0.85, 0.7, 0.5, 0.3][k]
        puffs.append((c + math.cos(a) * d, c + math.sin(a) * d, rad))
    shape = np.zeros((S, S), bool)
    shade = np.full((S, S), 9.0)
    for (px, py, rad) in puffs:
        if rad < 0.8:
            continue
        dd = np.hypot(xx - px, yy - py)
        m = dd <= rad
        shape |= m
        # lit from the top left: distance to a point up and left inside the puff, over its radius
        lt = np.hypot(xx - (px - rad * 0.35), yy - (py - rad * 0.35)) / rad
        shade = np.where(m, np.minimum(shade, lt), shade)
    # tones darken toward the shadow side, and the whole cloud pales as it goes
    pale = k * 0.12
    tone = shade - pale
    light = [SMOKE_L, (168, 158, 150), (196, 188, 180)][min(2, k // 3)]
    put = lambda m, col: (img.__setitem__((m, slice(0, 3)), col), img.__setitem__((m, 3), 255))
    put(shape & (tone >= 0.95), SMOKE_D if k < 3 else SMOKE_M)
    put(shape & (tone >= 0.55) & (tone < 0.95), SMOKE_M if k < 3 else SMOKE_L)
    put(shape & (tone < 0.55), light)
    # the core, glowing then cooling (under the inner puffs, which cover it more as they grow)
    core = [6.0, 4.6, 3.4, 2.2, 1.2, 0.0, 0.0][k]
    if core > 0:
        hot = (r <= core) & (k == 0 | ~shape)
        put((r <= core) & ~(shape & (k > 0)), RED)
        put((r <= core * 0.55) & ~(shape & (k > 0)), ORANGE if k < 2 else RED)
    # a dark outline round the cloud while it is thick
    if k <= 3:
        pad = np.pad(shape, 1)
        near = pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]
        put(near & ~shape & (img[:, :, 3] == 0), (40, 34, 34))
    # embers flung out
    if k <= 2:
        er = random.Random(7)
        for j in range(14):
            a = er.uniform(0, 2 * math.pi)
            d = (25.0 + k * 1.8) * er.uniform(0.86, 1.0)
            x, y = int(round(c + math.cos(a) * d)), int(round(c + math.sin(a) * d))
            if 0 <= x < S and 0 <= y < S and img[y, x, 3] == 0:
                img[y, x, :3] = EMBER if k == 0 else ORANGE if k == 1 else RED
                img[y, x, 3] = 255
    return img


# ---------------------------------------------------------------------------------------------
# The victory flag
# ---------------------------------------------------------------------------------------------

POLE_X, GROUND_Y, POLE_TOP = 8, 21, 4
BANNER_W, BANNER_H = 11, 7


def outline(mask):
    pad = np.pad(mask, 1)
    near = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:] |
            pad[:-2, :-2] | pad[:-2, 2:] | pad[2:, :-2] | pad[2:, 2:])
    return near & ~mask


def flag_frame(f):
    """Two layers of frame f: the flag (pole, gold top, mound, dust, outline) in its
    colours, and the banner's cloth in white and greys (the client tints it the conqueror's colour)."""
    S = FLAG_S
    base = np.zeros((S, S, 4), np.uint8)
    cloth = np.zeros((S, S, 4), np.uint8)
    yy, xx = np.mgrid[0:S, 0:S]
    # it drops in, lands, sinks a pixel into the ground and comes back up
    dy = [-11, -5, 0, 1, 0, 0, 0, 0, 0, 0][f]
    top = POLE_TOP + dy
    # the pole, its gold top
    pole = (xx >= POLE_X - 1) & (xx <= POLE_X) & (yy >= top) & (yy <= GROUND_Y + min(dy, 1))
    knob = (np.abs(xx - (POLE_X - 0.5)) <= 1.2) & (np.abs(yy - (top - 1.0)) <= 1.2)
    # the banner: off the pole to the right, waving more toward its free end (still while it falls)
    phase = f * 0.95
    cols = np.arange(BANNER_W)
    amp = 0.0 if f < 2 else 1.1
    off = np.round(np.sin(cols * 0.6 - phase) * amp * (cols + 1) / BANNER_W).astype(int)
    # while falling the cloth streams up; at the landing it whips
    lift = {0: -2, 1: -1, 2: 1, 3: -1}.get(f, 0)
    banner = np.zeros((S, S), bool)
    fold = np.zeros((S, S))
    for i in range(BANNER_W):
        x = POLE_X + 1 + i
        h = BANNER_H if f >= 2 else BANNER_H - 1 - (i > 6)
        y0 = top + 1 + off[i] + (lift if i > 3 else lift // 2)
        if 0 <= x < S:
            for y in range(max(0, y0), min(S, y0 + h)):
                banner[y, x] = True
                fold[y, x] = math.cos(i * 0.6 - phase)
    # a notch cut in the free end (a swallowtail)
    tip = POLE_X + BANNER_W
    for y in range(S):
        if banner[y, tip]:
            ys = np.where(banner[:, tip])[0]
            mid = (ys.min() + ys.max()) / 2
            if abs(y - mid) < 1.2:
                banner[y, tip] = False
    mound = (np.abs(xx - (POLE_X - 0.5)) <= 2.5) & (yy == GROUND_Y + 1) | \
            (np.abs(xx - (POLE_X - 0.5)) <= 1.5) & (yy == GROUND_Y)
    mound &= f >= 2
    shape = pole | knob | banner | mound
    ol = outline(shape)
    base[ol, :3] = INK
    base[ol, 3] = 255
    base[pole, :3] = WOOD
    base[pole & (xx == POLE_X - 1), :3] = WOOD_HI
    base[knob, :3] = GOLD
    base[knob & (xx <= POLE_X - 1) & (yy <= top - 1), :3] = GOLD_HI
    base[knob | pole, 3] = 255
    base[mound & ~pole, :3] = DIRT
    base[mound & ~pole, 3] = 255
    # the cloth: lit where the wave faces the light, shaded in its folds, the top row brightest
    lit = np.where(fold > 0.35, 255, np.where(fold < -0.35, 168, 212)).astype(np.uint8)
    cloth[banner, 0] = lit[banner]
    cloth[banner, 1] = lit[banner]
    cloth[banner, 2] = lit[banner]
    cloth[banner, 3] = 255
    # speed lines above it as it drops
    if f <= 1:
        for x in (POLE_X - 3, POLE_X + 4, POLE_X + 9):
            for y in range(max(0, top - 6), max(0, top - 2)):
                if base[y, x, 3] == 0 and cloth[y, x, 3] == 0:
                    base[y, x, :3] = (250, 250, 240)
                    base[y, x, 3] = 200 if f == 0 else 140
    # dust kicked up at the landing, spreading out and settling
    dust = {2: [(4.5, 1.6), (12.5, 1.6)], 3: [(3.0, 2.4), (14.0, 2.4)], 4: [(1.8, 2.6), (15.6, 2.6)],
            5: [(1.2, 2.0), (16.6, 2.0)], 6: [(0.8, 1.2), (17.2, 1.2)]}.get(f, [])
    for (dx, rad) in dust:
        d = np.hypot(xx - dx, (yy - (GROUND_Y - 0.5)) * 1.3)
        m = (d <= rad) & (base[:, :, 3] == 0) & (cloth[:, :, 3] == 0)
        base[m, :3] = DUST_L if f <= 4 else DUST_D
        base[m & (yy >= GROUND_Y), :3] = DUST_D
        base[m, 3] = 255 if f <= 5 else 170
    # a glint on the gold top once it stands
    if f in (5, 6):
        k = 2 if f == 5 else 1
        gx, gy = POLE_X, top - 2
        for d in range(-k, k + 1):
            for (x, y) in ((gx + d, gy), (gx, gy + d)):
                if 0 <= x < S and 0 <= y < S:
                    base[y, x, :3] = (255, 255, 255)
                    base[y, x, 3] = 255
                    cloth[y, x, 3] = 0
    return base, cloth


# ---------------------------------------------------------------------------------------------
# Atlas, sheet, upload
# ---------------------------------------------------------------------------------------------

def build():
    os.makedirs(OUT, exist_ok=True)
    nuke = [nuke_frame(f) for f in range(NUKE_N)]
    flags = [flag_frame(f) for f in range(FLAG_N)]
    W = max(NUKE_N * NUKE_S, FLAG_N * FLAG_S)
    H = NUKE_S + 2 * FLAG_S
    atlas = np.zeros((H, W, 4), np.uint8)
    for i, fr in enumerate(nuke):
        atlas[0:NUKE_S, i * NUKE_S:(i + 1) * NUKE_S] = fr
    for i, (base, cloth) in enumerate(flags):
        atlas[NUKE_S:NUKE_S + FLAG_S, i * FLAG_S:(i + 1) * FLAG_S] = base
        atlas[NUKE_S + FLAG_S:NUKE_S + 2 * FLAG_S, i * FLAG_S:(i + 1) * FLAG_S] = cloth
    path = os.path.join(OUT, "map_fx.png")
    Image.fromarray(atlas, "RGBA").save(path, optimize=True)
    print(f"atlas {W}x{H} -> {path}")
    return path, nuke, flags


def tinted(base, cloth, col):
    """The flag as the client draws it: the cloth tinted `col`, the flag over it."""
    out = Image.new("RGBA", (FLAG_S, FLAG_S), (0, 0, 0, 0))
    c = cloth.astype(float)
    c[..., :3] = c[..., :3] * np.array(col)[None, None, :] / 255
    out.alpha_composite(Image.fromarray(c.astype(np.uint8), "RGBA"))
    out.alpha_composite(Image.fromarray(base, "RGBA"))
    return out


def sheet(nuke, flags):
    """Every frame 4x, on the map's colours: plains, a territory over them, the sea; the flags in three
    players' colours."""
    Z = 4
    grounds = [(190, 220, 138), (178, 160, 190), (71, 133, 181)]
    players = [(150, 92, 226), (220, 68, 60), (40, 170, 170)]
    pad = 8
    w = NUKE_N * (NUKE_S * Z + pad) + pad
    h = (NUKE_S * Z + pad) * len(grounds) + (FLAG_S * Z * 2 + pad) * len(grounds) + pad
    out = Image.new("RGB", (w, h), (16, 18, 30))
    y = pad
    for g in grounds:
        for i, fr in enumerate(nuke):
            tile = Image.new("RGB", (NUKE_S, NUKE_S), g)
            tile.paste(Image.fromarray(fr, "RGBA"), (0, 0), Image.fromarray(fr, "RGBA"))
            out.paste(tile.resize((NUKE_S * Z, NUKE_S * Z), Image.NEAREST), (pad + i * (NUKE_S * Z + pad), y))
        y += NUKE_S * Z + pad
    for g, col in zip(grounds, players):
        for i, (base, cloth) in enumerate(flags):
            tile = Image.new("RGBA", (FLAG_S, FLAG_S), g + (255,))
            tile.alpha_composite(tinted(base, cloth, col))
            out.paste(tile.convert("RGB").resize((FLAG_S * Z * 2, FLAG_S * Z * 2), Image.NEAREST),
                      (pad + i * (FLAG_S * Z * 2 + pad), y))
        y += FLAG_S * Z * 2 + pad
    p = os.path.join(REPO, "build", "map_fx_sheet.png")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    out.save(p)
    print("sheet ->", p)


def upload(path, group):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import make_shop_flags as sf
    sf.ua.CREATOR = {"groupId": str(group)}
    ids = sf.upload_sheets([path], f"g{group}:map_fx", "Rofront's map effects")
    if not sf.wait_approved(ids):
        sys.exit("the atlas is not approved yet: the manifest still points at the old one; run again later")
    return ids[0]


def write_manifest(aid):
    L = [
        "-- GENERATED by tools/assets/make_map_fx.py. Do not edit.",
        "-- Rofront's own map effects (pixel art, a pixel a map tile): rows of one atlas, frames left to right.",
        "-- banner: the flag's cloth in white and greys, drawn under `flag` tinted the conqueror's colour.",
        "return {",
        f'\tid = "rbxassetid://{aid}",',
        f"\tnuke = {{ x = 0, y = 0, w = {NUKE_S}, h = {NUKE_S}, frames = {NUKE_N} }},",
        f"\tflag = {{ x = 0, y = {NUKE_S}, w = {FLAG_S}, h = {FLAG_S}, frames = {FLAG_N} }},",
        f"\tbanner = {{ x = 0, y = {NUKE_S + FLAG_S}, w = {FLAG_S}, h = {FLAG_S}, frames = {FLAG_N} }},",
        "}",
    ]
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", MANIFEST)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--group", type=int, default=421623341)
    args = ap.parse_args()
    path, nuke, flags = build()
    if args.sheet:
        sheet(nuke, flags)
    if args.upload:
        write_manifest(upload(path, args.group))


if __name__ == "__main__":
    main()
