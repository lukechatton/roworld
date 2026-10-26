#!/usr/bin/env python3
"""RoWorld's own map effects (2026-10-25): every sprite the 2D map plays, original work. They replace
the borrowed CC BY-SA effect sprites the map used until then: explosions, debris and the conquest's
crossed swords (now a victory flag, not swords at all). Drawn here from scratch as pixel
art, a sprite pixel a map tile like the rest of the map, every pixel worked out from shapes (distances,
angles, noise, a smoke density): nothing is traced or derived from their art.

  nuke       12 frames of 60 x 60 (70 ms each, drawn 60 full-size tiles wide, top-down): a white flash, a
             fireball (white-hot heart, yellow, orange, red, a dark outline, lit from the top left) that
             swells inside a thin shock ring, burns down to red and breaks into dark smoke with embers
             flying out, the smoke thinning to wisps
  flag       10 frames of 24 x 24 (90 ms, drawn 12 tiles): the conquest's victory flag (the first version
             was crossed swords; the elimination is now something other than a sword clash). It drops onto
             the conquered land, lands with a puff of
             dust and sinks a pixel, and its swallowtail banner waves; a glint on its gold top. Two rows:
             the flag in its colours (pole, gold top, mound, dust, outline) and the banner's
             cloth in white and greys under it, which the client tints the conqueror's colour.
  sam        9 frames of 48 x 38 (80 ms, drawn 40 tiles): a nuke shot down in the air: a glint where the
             missile hits, a flash with rays, a fireball spraying shrapnel streaks that arc down and dim,
             black flak smoke blooming round it and thinning away, three burning pieces of the bomb
             dropping out of it trailing smoke
  building   10 frames of 17 x 15 (70 ms, drawn 18 tiles): a defense post or Arsenal structure going up:
             a flash, a fireball leaping upward that flings chunks out (they fall back and lie there),
             burning down to red under smoke that rises off it and thins away
  What a nuke leaves burning, looping (the last frame runs into the first; drawn a tile a pixel):
  fire       6 frames of 7 x 13 (100 ms): a flame forking and flickering over a burning heap
  smoke      4 frames of 11 x 12 (120 ms): a smouldering heap puffing up a wisp of smoke
  big_smoke  5 frames of 24 x 16 (120 ms): a wide heap under a billowing cloud bent over by the wind
  smoke_fire 5 frames of 24 x 16 (120 ms): wreckage still burning, sooty smoke rolling off the flames

Out: assets/map_fx/map_fx.png (one atlas, a row each), build/map_fx_sheet.png (--sheet: every frame big,
on land, two territories and the sea, a loop followed by its first frame again, then all of them at the
map's scale), and with --upload (as the group, after Roblox's moderation approves it)
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
# the other explosions and the debris: (width, height, frames)
SAM = (48, 38, 9)
BUILDING = (17, 15, 10)
FIRE = (7, 13, 6)
SMOKE = (11, 12, 4)
BIG_SMOKE = (24, 16, 5)
SMOKE_FIRE = (24, 16, 5)

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
SOOT = (40, 34, 34)
SMOKE_P = (168, 158, 150)
SMOKE_W = (196, 188, 180)

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
# Shared pieces of the smaller effects: a fireball, smoke puffs, tongues of flame, a burning heap
# ---------------------------------------------------------------------------------------------

RAMP = [WHITE, PALE, YELLOW, ORANGE, RED, DARKRED]
SMOKES = [SOOT, SMOKE_D, SMOKE_M, SMOKE_L, SMOKE_P, SMOKE_W]


def canvas(w, h):
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    return np.zeros((h, w, 4), np.uint8), xx, yy


def paint(img, mask, col, a=255):
    img[mask, :3] = col
    img[mask, 3] = a


def edge4(mask):
    """The pixels just outside `mask` (its four neighbours)."""
    pad = np.pad(mask, 1)
    near = pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]
    return near & ~mask


def empty(img):
    return img[:, :, 3] == 0


def fireball(img, xx, yy, cx, cy, R, hot, seed=0, k=6, lobe=0.1, up=1.0, rim=True):
    """A ball of fire at (cx, cy), R px (lobed), lit from the top left: `hot` 1 a white heart through
    yellow and orange to a red edge, 0 burnt down to orange, red and dark red; `up` > 1 stretches it
    upward (flames rising off it). A dark outline round it where nothing is drawn (`rim`)."""
    if R < 0.5:
        return
    dx, dy = xx - cx, yy - cy
    dy = np.where(dy < 0, dy / up, dy)
    edge = np.maximum(R * (1 + lobes(np.arctan2(dy, dx), seed, k=k, amp=lobe)), 0.6)
    rr = np.hypot(dx, dy) / edge
    rh = np.hypot(dx + R * 0.2, dy + R * 0.2) / edge
    m = rr <= 1.0
    idx = np.clip(((rh * 0.7 + rr * 0.3) * 4.6 + (1 - hot) * 3).astype(int), 0, 5)
    for i, col in enumerate(RAMP):
        paint(img, m & (idx == i), col)
    if rim:
        paint(img, edge4(m) & empty(img), OUTLINE)


def smoke_puffs(img, xx, yy, puffs, rim=True, contrast=0.8):
    """Smoke puffs, each (x, y, r, pale, thin), a later one over an earlier: each lit from the top left (a
    pale cap, a dark underside) with a darker seam where its edge lies over another, `pale` (below 0
    sooty .. 1 thinned out) lightening it, `thin` (0 .. 1) breaking it into every other pixel from its
    edge in (all of it at 1). `contrast`: how far the shading runs from cap to underside. A soot rim round
    the thick ones."""
    shape = np.zeros(xx.shape, bool)
    tone = np.zeros(xx.shape)
    gone = np.zeros(xx.shape, bool)
    thick = np.zeros(xx.shape, bool)
    odd = (xx + yy) % 2 == 1
    for (px, py, r, pale, thin) in puffs:
        if r < 0.5:
            continue
        d = np.hypot(xx - px, yy - py)
        m = d <= r
        lt = np.hypot(xx - (px - r * 0.4), yy - (py - r * 0.4)) / r
        t = (1.0 - lt) * contrast + pale
        seam = m & shape & (d > r - 0.85) & (r >= 2.4)
        t = np.where(seam, np.minimum(t, tone) - 0.4, t)
        tone = np.where(m, t, tone)
        gone = np.where(m, odd & (d / r >= 1.05 - thin * 1.15), gone)
        thick = np.where(m, thin < 0.3 and pale < 0.6, thick)
        shape |= m
    # tones step from soot to the palest grey; a checker where two meet
    check = ((xx + yy) % 2 == 0) * 0.07
    idx = np.digitize(tone - check, [-0.4, 0.12, 0.45, 0.8, 1.15])
    draw = shape & ~gone
    for i, col in enumerate(SMOKES):
        paint(img, draw & (idx == i), col)
    if rim:
        paint(img, edge4(shape & thick) & ~shape & empty(img), SOOT)


def smoke_field(img, xx, yy, blobs, rim=True):
    """Smoke as one soft mass: blobs (x, y, r, pale, thin) summed into a density, its outline where that
    passes a level (so they merge into one billowing shape). Lit from the top left by how the density
    falls off toward the light: a pale rim up and left, a dark one down and right; `pale` and `thin`
    blend between the blobs, and thin smoke breaks into every other pixel where it is least dense. A
    soot rim round the thick part."""
    D, Dl, Dl2, P, T, C = (np.zeros(xx.shape) for _ in range(6))
    for (bx, by, r, pale, thin) in blobs:
        if r < 0.4:
            continue
        q = np.clip(1 - ((xx - bx) ** 2 + (yy - by) ** 2) / r ** 2, 0, None) ** 2
        D += q
        Dl += np.clip(1 - ((xx - 1 - bx) ** 2 + (yy - 1 - by) ** 2) / r ** 2, 0, None) ** 2
        Dl2 += np.clip(1 - ((xx + 1 - bx) ** 2 + (yy + 1 - by) ** 2) / r ** 2, 0, None) ** 2
        P += q * pale
        T += q * thin
        # each blob's own cap, up and left of its middle
        C += q * (0.55 - np.hypot(xx - (bx - r * 0.3), yy - (by - r * 0.3)) / r)
    shape = D > 0.3
    w = np.maximum(D, 1e-6)
    P, T, C = P / w, T / w, C / w
    # Dl: the density a step toward the light (up and left), Dl2 a step away
    lit = np.clip((Dl2 - Dl) * 0.9, -0.4, 0.4)
    tone = 0.45 + P + lit + C * 0.6
    check = ((xx + yy) % 2 == 0) * 0.07
    idx = np.digitize(tone - check, [-0.4, 0.12, 0.45, 0.8, 1.15])
    gone = ((xx + yy) % 2 == 1) & (D < 0.3 + T * 1.6) & (T > 0.05)
    draw = shape & ~gone
    for i, col in enumerate(SMOKES):
        paint(img, draw & (idx == i), col)
    if rim:
        paint(img, edge4(shape & (T < 0.3) & (P < 0.45)) & ~shape & empty(img), SOOT)


def billow(x, y, r, pale, thin, spin=0.0):
    """A puff of smoke as a cluster: two lumps on its top (turning with `spin`) behind a main ball, so
    its outline billows."""
    out = []
    for a in (-math.pi / 2 - 1.0 + spin, -math.pi / 2 + 0.9 + spin * 0.7):
        out.append((x + math.cos(a) * r * 0.6, y + math.sin(a) * r * 0.6, r * 0.58, pale + 0.05, thin))
    out.append((x, y + r * 0.1, r * 0.82, pale, thin))
    return out


def flames(img, xx, yy, tongues, rim=True):
    """Tongues of fire, each (x, y, height, half, lean): standing on (x, y), `height` px to the tip, `half`
    px half-width at the foot, the tip leaning `lean` px aside (the flicker). Pale and yellow low in the
    middle, orange, red to the edges and the tip; a dark outline round them."""
    m_all = np.zeros(xx.shape, bool)
    heat = np.full(xx.shape, 9.0)
    for (bx, by, height, half, lean) in tongues:
        if height < 0.8:
            continue
        h = (by - yy) / height
        hc = np.clip(h, 0, 1)
        cx = bx + lean * hc ** 1.5
        # a teardrop: rounded at the foot, widest a little above it, drawn to a point at the tip
        foot = np.clip((h * height + 1.2) / 2.6, 0, 1)
        w = half * (1 - hc) ** 0.8 * np.sqrt(np.sin(foot * math.pi / 2))
        ax = np.abs(xx - cx)
        m = (ax <= w + 0.3) & (h <= 1.0) & (h * height >= -1.2)
        q = ax / np.maximum(w, 0.7) * 0.6 + hc * 0.65
        heat = np.where(m, np.minimum(heat, q), heat)
        m_all |= m
    idx = np.digitize(heat, [0.22, 0.45, 0.72, 1.05])
    for i, col in enumerate([PALE, YELLOW, ORANGE, RED, DARKRED]):
        paint(img, m_all & (idx == i), col)
    if rim:
        paint(img, edge4(m_all) & empty(img), OUTLINE)


def heap(img, xx, yy, cx, cy, a, b, f, n, seed):
    """Burnt wreckage on the ground at (cx, cy) (an a x b px ellipse, seen from above): soot glowing dark
    red inside, a few embers brightening and dimming over the loop (frame f of n)."""
    e = ((xx - cx) / a) ** 2 + ((yy - cy) / b) ** 2
    body = e <= 1.0
    paint(img, body, SOOT)
    paint(img, e <= 0.35, DARKRED)
    rnd = random.Random(seed)
    pts = list(zip(*np.where(body)))
    rnd.shuffle(pts)
    for (y, x) in pts[:max(2, len(pts) // 4)]:
        glow = math.sin(2 * math.pi * f / n + rnd.uniform(0, 2 * math.pi))
        if glow > 0.35:
            paint(img, (yy == y) & (xx == x), EMBER if glow > 0.8 else ORANGE)
        elif glow > -0.3:
            paint(img, (yy == y) & (xx == x), RED)


# ---------------------------------------------------------------------------------------------
# A structure blowing up, a nuke shot down by a SAM
# ---------------------------------------------------------------------------------------------

def building_frame(f):
    """A defense post or an Arsenal structure going up: a flash, a fireball that leaps upward and flings
    chunks of the building out (they fall back and lie there), burns down to red under smoke that rises
    off it and thins away."""
    W, H, _ = BUILDING
    img, xx, yy = canvas(W, H)
    cx, cy = 8.0, 8.5
    r = np.hypot(xx - cx, yy - cy)
    # the smoke rising off it: (rise, radius, pale, thin)
    sm = {3: (0.0, 2.2, -0.1, 0), 4: (1.2, 2.7, 0.0, 0), 5: (2.4, 3.0, 0.1, 0), 6: (3.4, 3.0, 0.25, 0.1),
          7: (4.2, 2.8, 0.45, 0.3), 8: (4.9, 2.4, 0.65, 0.55), 9: (5.4, 2.0, 0.85, 0.75)}.get(f)
    if sm:
        rise, R, pale, thin = sm
        y0 = cy - 1.5 - rise
        smoke_puffs(img, xx, yy, [(cx - 2.4, y0 + 1.0, R * 0.85, pale, thin),
                                  (cx + 2.3, y0 + 0.7, R * 0.8, pale, thin),
                                  (cx - 0.1, y0 - 1.6, R, pale + 0.1, thin)])
    if f == 0:
        paint(img, r <= 3.3, PALE)
        paint(img, (r > 2.3) & (r <= 3.3) & ((xx + yy) % 2 == 0), YELLOW)
        paint(img, r <= 2.0, WHITE)
        for (sx, sy) in ((0, -5), (0, 5), (-5, 0), (5, 0)):
            paint(img, (xx == cx + sx) & (yy == round(cy + sy)), YELLOW)
    # the fire: (radius, heat, how much it leaps up)
    fb = {1: (3.8, 1.0, 1.2), 2: (5.0, 0.85, 1.3), 3: (5.1, 0.6, 1.35), 4: (4.2, 0.35, 1.25),
          5: (3.0, 0.12, 1.15), 6: (1.9, 0.0, 1.0), 7: (1.0, 0.0, 1.0)}.get(f)
    if fb:
        fireball(img, xx, yy, cx, cy + 0.5, fb[0], fb[1], seed=3 + f, k=5, lobe=0.12, up=fb[2])
    # chunks of it flung out of the fire (unseen in it): they arc up and fall back to the ground round
    # it, glowing at first
    if f >= 1:
        free = empty(img)
        rnd = random.Random(17)
        for j in range(6):
            a = -math.pi / 2 + (j - 2.5) * 0.48 + rnd.uniform(-0.15, 0.15)
            v = rnd.uniform(1.7, 2.3)
            ground = cy + 3.5 + rnd.uniform(-1.0, 2.0)
            t = f - 0.4
            x = cx + math.cos(a) * v * t * 1.3
            y = cy + math.sin(a) * v * t + 0.42 * t * t
            landed = y >= ground and t > 1
            y = min(y, ground)
            if f >= 9 or not (0 <= round(x) < W and 0 <= round(y) < H):
                continue
            px, py = int(round(x)), int(round(y))
            if not free[py, px]:
                continue
            img[py, px, :3] = INK if (landed or f >= 4) else DARKRED
            img[py, px, 3] = 255
            if not landed and f <= 4:
                # a glowing trail pixel behind it
                tx, ty = int(round(x - math.cos(a) * 0.9)), int(round(y - math.sin(a) * 0.9 - 0.4 * t))
                if 0 <= tx < W and 0 <= ty < H and (tx, ty) != (px, py) and free[ty, tx]:
                    img[ty, tx, :3] = ORANGE if f <= 2 else RED
                    img[ty, tx, 3] = 255
    return img


def sam_frame(f):
    """A nuke shot down in the air: a glint where the missile hits, a flash with rays, a fireball that
    sprays shrapnel streaks out (they arc down and dim), black flak smoke that blooms round it and thins
    away, and three pieces of the bomb dropping out of it trailing smoke."""
    W, H, _ = SAM
    img, xx, yy = canvas(W, H)
    cx, cy = 23.5, 14.5
    dx, dy = xx - cx, yy - cy
    r = np.hypot(dx, dy)
    if f == 0:
        # the hit: a four-pointed glint, longer across
        arm = ((np.abs(dx) <= 0.5) & (np.abs(dy) <= 6.5)) | ((np.abs(dy) <= 0.5) & (np.abs(dx) <= 9.5))
        core = (np.abs(dx) <= 1.5) & (np.abs(dy) <= 1.5) & (r <= 2.0)
        paint(img, arm | core, YELLOW)
        paint(img, (arm & (r <= 5.0)) | core, PALE)
        paint(img, r <= 1.6, WHITE)
        paint(img, edge4(arm | core), OUTLINE)
        return img
    # the flak smoke: (distance out, puff radius, pale, thin)
    sm = {3: (7.5, 3.4, -0.25, 0), 4: (9.0, 4.4, -0.2, 0), 5: (10.2, 4.8, -0.1, 0), 6: (11.2, 4.5, 0.12, 0.12),
          7: (12.0, 3.7, 0.38, 0.38), 8: (12.6, 2.7, 0.62, 0.62)}.get(f)
    if sm:
        d, R, pale, thin = sm
        rnd = random.Random(23)
        puffs = []
        for i in range(9):
            a = i * 2 * math.pi / 9 + rnd.uniform(-0.2, 0.2)
            dd = d * rnd.uniform(0.85, 1.05)
            puffs.append((cx + math.cos(a) * dd, cy + math.sin(a) * dd * 0.82, R * rnd.uniform(0.85, 1.1), pale, thin))
        if f >= 4:
            for i in range(4):
                a = i * math.pi / 2 + 0.7 + rnd.uniform(-0.2, 0.2)
                puffs.append((cx + math.cos(a) * d * 0.42, cy + math.sin(a) * d * 0.36, R * 0.85, pale + 0.05, thin))
        smoke_puffs(img, xx, yy, puffs)
    # the fire: (radius, heat)
    fb = {1: (4.6, 1.0), 2: (7.6, 0.85), 3: (8.4, 0.5), 4: (5.6, 0.2), 5: (2.8, 0.0)}.get(f)
    if fb:
        fireball(img, xx, yy, cx, cy, fb[0], fb[1], seed=31 + f, k=7, lobe=0.14)
    if f == 1:
        # rays out of the flash, long and short in turn
        for k in range(8):
            a = k * math.pi / 4 + math.pi / 8
            along = dx * math.cos(a) + dy * math.sin(a)
            across = np.abs(-dx * math.sin(a) + dy * math.cos(a))
            ln = 13.0 if k % 2 == 0 else 9.0
            ray = (across < 0.6) & (along > 5.2) & (along <= ln) & empty(img)
            paint(img, ray, PALE)
            paint(img, ray & (along > ln - 3), YELLOW)
    # shrapnel streaks flying out (wider than tall, falling as they go): (distance, drop, head, tail)
    sp = {2: (11.0, 0.0, PALE, YELLOW), 3: (15.5, 0.8, EMBER, ORANGE), 4: (19.0, 2.0, ORANGE, RED),
          5: (21.5, 3.6, RED, DARKRED), 6: (23.0, 5.4, DARKRED, None)}.get(f)
    if sp:
        D, drop, head, tail = sp
        rnd = random.Random(5)
        for j in range(16):
            a = j * 2 * math.pi / 16 + rnd.uniform(-0.12, 0.12)
            v = rnd.uniform(0.78, 1.0)
            if f >= 5 and j % 3 == 0:
                continue
            ca, sa = math.cos(a), math.sin(a) * 0.78
            hx, hy = cx + ca * D * v, cy + sa * D * v + drop * v
            for (k, col) in ((0, head), (1, tail), (2, tail if f <= 3 else None)):
                if col is None:
                    continue
                x, y = int(round(hx - ca * k)), int(round(hy - sa * k - (0.35 * k if f >= 4 else 0)))
                if 0 <= x < W and 0 <= y < H:
                    img[y, x, :3] = col
                    img[y, x, 3] = 255
    # pieces of the bomb falling out, burning at first, each leaving a trail of smoke above it
    if f >= 3:
        t = f - 2
        for (ox, vx, sz) in ((-4.0, -0.6, 2), (1.0, 0.2, 2), (5.5, 0.7, 1)):
            def at(tt):
                return cx + ox + vx * tt, cy + 3.0 + 1.4 * tt + 0.35 * tt * tt
            for back, col in ((1.0, SMOKE_L), (1.7, SMOKE_P), (2.4, SMOKE_W)):
                if t - back < 0.5:
                    continue
                tx, ty = at(t - back)
                tx, ty = int(round(tx)), int(round(ty))
                if 0 <= tx < W and 0 <= ty < H:
                    img[ty, tx, :3] = col
                    img[ty, tx, 3] = 255
            x, y = at(t)
            x0, y0 = int(round(x - (sz - 1) / 2)), int(round(y))
            for i in range(sz):
                for j in range(sz):
                    if 0 <= x0 + i < W and 0 <= y0 + j < H:
                        img[y0 + j, x0 + i, :3] = INK
                        img[y0 + j, x0 + i, 3] = 255
            if 0 <= x0 < W and 0 <= y0 < H and f <= 6:
                img[y0, x0, :3] = EMBER if f <= 4 else ORANGE if f == 5 else RED
    return img


# ---------------------------------------------------------------------------------------------
# What a nuke leaves burning (loops: frame n is frame 0 again)
# ---------------------------------------------------------------------------------------------

def plume(t, columns, lumps=True):
    """Smoke rising in columns, each (n, lag, path): n puffs at s = (i + (t + lag) % 1) / n along it (0 the
    source, 1 gone), every column's puffs drawn oldest first; `path(s)` gives a puff (x, y, r, pale,
    thin) and must hide it in the source at s = 0 and shrink it to nothing by s = 1, so the loop meets
    itself. With `lumps`, each puff billows."""
    out = []
    for (n, lag, path) in columns:
        for i in range(n):
            s = (i + (t + lag) % 1.0) / n
            out.append((s, billow(*path(s), spin=s * 1.6) if lumps else [path(s)]))
    out.sort(key=lambda e: -e[0])
    return [p for (_, ps) in out for p in ps]


def fire_frame(f):
    """A small fire over a burning heap: a tall tongue of flame and a short one forking off it, flickering
    and swaying out of step."""
    W, H, N = FIRE
    img, xx, yy = canvas(W, H)
    ph = 2 * math.pi * f / N
    heap(img, xx, yy, 3.0, 11.9, 2.7, 0.8, f, N, seed=5)
    flames(img, xx, yy, [
        (2.6, 10.5, 5.4 + 1.3 * math.sin(ph + 2.6), 1.5, -1.4 + 0.6 * math.sin(ph + 1.8)),
        (3.0, 10.5, 8.9 + 1.1 * math.sin(ph) + 0.5 * math.sin(2 * ph + 1.0), 2.4, 0.4 + 1.0 * math.sin(ph + 0.9)),
    ])
    return img


def smoke_frame(f):
    """A smouldering heap puffing up a thin trail of smoke that drifts aside, the puffs growing and paling."""
    W, H, N = SMOKE
    img, xx, yy = canvas(W, H)

    def path(s):
        r = (1.7 + 2.6 * s) * (1 - smoothstep(0.75, 1.0, s))
        return (3.8 + 2.6 * s + 1.1 * math.sin(s * 2 * math.pi), 9.4 - 7.6 * s, r, 0.3 + s * 0.5,
                smoothstep(0.5, 1.0, s) * 0.9)
    smoke_field(img, xx, yy, plume(f / N, [(3, 0.0, path)], lumps=False), rim=False)
    heap(img, xx, yy, 3.6, 10.7, 2.4, 1.0, f, N, seed=9)
    return img


def big_smoke_frame(f):
    """A wide heap sending up a thick cloud of smoke: two columns out of step, billowing and bending over in
    the wind."""
    W, H, N = BIG_SMOKE
    img, xx, yy = canvas(W, H)

    def column(x0, k):
        def path(s):
            r = (2.0 + 4.4 * s ** 0.9) * k * (1 - smoothstep(0.75, 1.0, s))
            return (x0 + 7.0 * s ** 1.4, 12.0 - 8.2 * (1 - (1 - s) ** 1.5), r, 0.05 + s * 0.6,
                    smoothstep(0.5, 1.0, s) * 0.9)
        return path
    smoke_field(img, xx, yy, plume(f / N, [(3, 0.5, column(6.0, 1.0)), (3, 0.0, column(11.5, 0.9))]))
    heap(img, xx, yy, 9.5, 13.7, 6.0, 1.4, f, N, seed=13)
    return img


def smoke_fire_frame(f):
    """Wreckage still burning: three tongues of flame over a heap, sooty smoke rolling off their tips."""
    W, H, N = SMOKE_FIRE
    img, xx, yy = canvas(W, H)
    ph = 2 * math.pi * f / N

    def path(s):
        r = (2.4 + 4.0 * s ** 0.8) * (1 - smoothstep(0.75, 1.0, s))
        return (8.5 + 12.0 * s ** 1.1, 6.8 - 4.0 * (1 - (1 - s) ** 1.6), r, -0.2 + s * 0.7,
                smoothstep(0.5, 1.0, s) * 0.9)
    smoke_field(img, xx, yy, plume(f / N, [(3, 0.0, path)]))
    heap(img, xx, yy, 8.0, 13.8, 4.6, 1.3, f, N, seed=21)
    flames(img, xx, yy, [
        (5.6, 13.2, 4.6 + 1.0 * math.sin(ph + 0.5), 1.2, 0.7 * math.sin(ph + 1.5)),
        (10.6, 13.3, 4.0 + 1.0 * math.sin(ph + 3.1), 1.1, 0.6 * math.sin(ph + 2.2)),
        (8.0, 13.0, 7.6 + 1.1 * math.sin(ph) + 0.4 * math.sin(2 * ph + 2.0), 1.8, 1.0 * math.sin(ph + 0.4)),
    ])
    return img


# ---------------------------------------------------------------------------------------------
# Atlas, sheet, upload
# ---------------------------------------------------------------------------------------------

# the rows after the nuke and the flag: name, (w, h, frames), the frame function
EFFECTS = [
    ("sam", SAM, sam_frame),
    ("building", BUILDING, building_frame),
    ("fire", FIRE, fire_frame),
    ("smoke", SMOKE, smoke_frame),
    ("big_smoke", BIG_SMOKE, big_smoke_frame),
    ("smoke_fire", SMOKE_FIRE, smoke_fire_frame),
]


def build():
    """The atlas, a row each: the nuke, the flag, the banner, then EFFECTS. Returns its path, the layout
    (name -> x, y, w, h, frames) and the frames."""
    os.makedirs(OUT, exist_ok=True)
    nuke = [nuke_frame(f) for f in range(NUKE_N)]
    flags = [flag_frame(f) for f in range(FLAG_N)]
    fx = {name: [fn(f) for f in range(n)] for (name, (_, _, n), fn) in EFFECTS}
    layout = {
        "nuke": (0, 0, NUKE_S, NUKE_S, NUKE_N),
        "flag": (0, NUKE_S, FLAG_S, FLAG_S, FLAG_N),
        "banner": (0, NUKE_S + FLAG_S, FLAG_S, FLAG_S, FLAG_N),
    }
    y = NUKE_S + 2 * FLAG_S
    for (name, (w, h, n), _) in EFFECTS:
        layout[name] = (0, y, w, h, n)
        y += h
    W = max(x + w * n for (x, _, w, _, n) in layout.values())
    atlas = np.zeros((y, W, 4), np.uint8)

    def place(name, frames):
        x0, y0, w, h, _ = layout[name]
        for i, fr in enumerate(frames):
            atlas[y0:y0 + h, x0 + i * w:x0 + (i + 1) * w] = fr
    place("nuke", nuke)
    place("flag", [b for (b, _) in flags])
    place("banner", [c for (_, c) in flags])
    for name, frames in fx.items():
        place(name, frames)
    path = os.path.join(OUT, "map_fx.png")
    Image.fromarray(atlas, "RGBA").save(path, optimize=True)
    print(f"atlas {W}x{y} -> {path}")
    return path, layout, nuke, flags, fx


def tinted(base, cloth, col):
    """The flag as the client draws it: the cloth tinted `col`, the flag over it."""
    out = Image.new("RGBA", (FLAG_S, FLAG_S), (0, 0, 0, 0))
    c = cloth.astype(float)
    c[..., :3] = c[..., :3] * np.array(col)[None, None, :] / 255
    out.alpha_composite(Image.fromarray(c.astype(np.uint8), "RGBA"))
    out.alpha_composite(Image.fromarray(base, "RGBA"))
    return out


def on_ground(fr, g, z):
    h, w = fr.shape[:2]
    tile = Image.new("RGBA", (w, h), g + (255,))
    tile.alpha_composite(Image.fromarray(fr, "RGBA"))
    return tile.convert("RGB").resize((w * z, h * z), Image.NEAREST)


def scene(nuke, fx, g):
    """The debris round a nuke's last smoke, a structure and a shot-down nuke going up, at the map's scale
    (a sprite pixel a tile, as the client draws them)."""
    img = Image.new("RGBA", (190, 76), g + (255,))

    def at(fr, x, y):
        h, w = fr.shape[:2]
        img.alpha_composite(Image.fromarray(fr, "RGBA"), (int(x - w / 2), int(y - h / 2)))
    at(nuke[9], 38, 38)
    rnd = random.Random(3)
    for kind, n in (("fire", 4), ("smoke", 3), ("big_smoke", 2), ("smoke_fire", 2)):
        for j in range(n):
            a, d = rnd.uniform(0, 2 * math.pi), rnd.uniform(4, 30)
            at(fx[kind][(j * 2) % len(fx[kind])], 38 + math.cos(a) * d, 38 + math.sin(a) * d)
    at(fx["building"][2], 92, 22)
    at(fx["building"][5], 92, 52)
    at(fx["sam"][2], 134, 22)
    at(fx["sam"][5], 134, 56)
    at(fx["sam"][3], 172, 38)
    return img.convert("RGB")


def sheet(nuke, flags, fx):
    """Every frame big on the map's colours (plains, a pale territory and a red one over them, the sea):
    the nuke and the shot-down nuke 4x, the flag 8x in three players' colours, the rest 8x, a looping one
    followed by its frame 0 again (under a gold bar) to show it meets itself; last, each ground with the
    effects at 3x as the map shows them."""
    grounds = [(190, 220, 138), (178, 160, 190), (176, 74, 64), (71, 133, 181)]
    players = [(150, 92, 226), (220, 68, 60), (40, 170, 170), (240, 200, 60)]
    pad = 8
    strips = []  # (images, a gold bar under the last one)
    for g in grounds:
        strips.append(([on_ground(fr, g, 4) for fr in nuke], False))
    for g, col in zip(grounds, players):
        tiles = []
        for (base, cloth) in flags:
            t = Image.new("RGBA", (FLAG_S, FLAG_S), g + (255,))
            t.alpha_composite(tinted(base, cloth, col))
            tiles.append(t.convert("RGB").resize((FLAG_S * 8, FLAG_S * 8), Image.NEAREST))
        strips.append((tiles, False))
    loops = {"fire", "smoke", "big_smoke", "smoke_fire"}
    for (name, _, _) in EFFECTS:
        z = 4 if name == "sam" else 8
        frames = fx[name] + ([fx[name][0]] if name in loops else [])
        for g in grounds:
            strips.append(([on_ground(fr, g, z) for fr in frames], name in loops))
    strips.append(([scene(nuke, fx, g).resize((190 * 3, 76 * 3), Image.NEAREST) for g in grounds], False))
    w = max(sum(im.width + pad for im in ims) for ims, _ in strips) + pad
    h = sum(max(im.height for im in ims) + pad for ims, _ in strips) + pad
    out = Image.new("RGB", (w, h), (16, 18, 30))
    draw = ImageDraw.Draw(out)
    y = pad
    for ims, loop in strips:
        x = pad
        for i, im in enumerate(ims):
            out.paste(im, (x, y))
            if loop and i == len(ims) - 1:
                draw.rectangle([x, y + im.height + 2, x + im.width - 1, y + im.height + 5], fill=GOLD)
            x += im.width + pad
        y += max(im.height for im in ims) + pad
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


def write_manifest(aid, layout):
    L = [
        "-- GENERATED by tools/assets/make_map_fx.py. Do not edit.",
        "-- Rofront's own map effects (pixel art, a pixel a map tile): rows of one atlas, frames left to right.",
        "-- banner: the flag's cloth in white and greys, drawn under `flag` tinted the conqueror's colour.",
        "-- fire, smoke, big_smoke, smoke_fire: the debris a nuke leaves, looping (the last frame runs into the first).",
        "return {",
        f'\tid = "rbxassetid://{aid}",',
    ]
    for name, (x, y, w, h, n) in layout.items():
        L.append(f"\t{name} = {{ x = {x}, y = {y}, w = {w}, h = {h}, frames = {n} }},")
    L.append("}")
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", MANIFEST)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--group", type=int, default=421623341)
    args = ap.parse_args()
    path, layout, nuke, flags, fx = build()
    if args.sheet:
        sheet(nuke, flags, fx)
    if args.upload:
        write_manifest(upload(path, args.group), layout)


if __name__ == "__main__":
    main()
