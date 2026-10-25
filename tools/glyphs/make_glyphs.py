#!/usr/bin/env python3
"""Map-glyph mask atlases for Roblox (overlays-a; also used by overlays-b).

Source: the original's signed-distance-field atlas ~/games/airfront/assets/icons/map_atlas_sdf.png
(1024x512, 8x4 cells of 128 px; R = whole glyph, G = fill region; spread 16 cell px) plus the glow
cell of map_atlas.png (alpha-only gaussian). See map_atlas.json.

Roblox has no custom shaders, so the SDF is resolved offline into coverage masks at several
resolution tiers (cell px = 16, 32, 64, 128). Each tier image is (8*px) x (8*px), RGB pure white,
alpha = coverage:
  rows 0-3  TOTAL coverage (whole glyph incl. outline) -> paint with the INK colour
  rows 4-7  FILL coverage                             -> paint with the FILL colour on top
Coverage uses exactly map_icon.gdshader's edge rule at that tier's size (1 px anti-aliased edge,
slight emboldening when tiny), so a tier drawn at 1:1 (or up to 2:1 minified) looks like the
original at that size.

Also writes a construction-ring sprite (track + arc masks) used by IconLayer.

Outputs tools/glyphs/out/*.png, uploads them with tools/upload.py (content-hash cached) and writes
src/shared/Assets/MapGlyphs.luau.

Run: .venv/bin/python tools/glyphs/make_glyphs.py [--no-upload]
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.expanduser("~/games/airfront/assets/icons")
OUT = os.path.join(ROOT, "tools", "glyphs", "out")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "MapGlyphs.luau")

CELL = 128
COLS, ROWS = 8, 4
SPREAD = 16.0
TIERS = [16, 32, 64, 128]
GLOW = (6, 1)


def bilinear(img: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
	"""Sample img (h, w) at pixel-centre coordinates (x, y are in pixel units, centre of px k = k)."""
	h, w = img.shape
	x = np.clip(x, 0.0, w - 1.0)
	y = np.clip(y, 0.0, h - 1.0)
	x0 = np.floor(x).astype(np.int32)
	y0 = np.floor(y).astype(np.int32)
	x1 = np.minimum(x0 + 1, w - 1)
	y1 = np.minimum(y0 + 1, h - 1)
	fx = x - x0
	fy = y - y0
	a = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
	b = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
	return a * (1 - fy) + b * fy


def coverage(sdf_cell: np.ndarray, n: int, bold_k: float = 1.0) -> np.ndarray:
	"""Coverage (n x n) of one 128x128 SDF cell channel (0..1 encoded) drawn at n px."""
	cps = CELL / n                       # cell px per screen px
	# 4x4 supersampling of the shader's per-pixel rule: smoother than a single tap when the
	# tier is later minified by the GPU (bilinear, no mipmaps)
	ss = 4
	idx = (np.arange(n * ss) + 0.5) / ss            # output px coords (sub-samples)
	u = idx * cps - 0.5                             # SDF pixel-centre coords
	xx, yy = np.meshgrid(u, u)
	v = bilinear(sdf_cell, xx, yy)
	d_px = (v - 0.5) * 2.0 * SPREAD / cps            # signed distance in screen px
	bold = min(max((cps - 5.0) * 0.06, 0.0), 0.35) * bold_k
	c = np.clip(d_px + 0.5 + bold, 0.0, 1.0)
	return c.reshape(n, ss, n, ss).mean(axis=(1, 3))


def area_resize(a: np.ndarray, n: int) -> np.ndarray:
	im = Image.fromarray(np.clip(a, 0, 1).astype(np.float32), "F").resize((n, n), Image.Resampling.BOX)
	return np.asarray(im, np.float32)


def build_tier(sdf: np.ndarray, atlas_a: np.ndarray, n: int) -> np.ndarray:
	out = np.zeros((ROWS * 2 * n, COLS * n), np.float32)
	for row in range(ROWS):
		for col in range(COLS):
			ys, xs = slice(row * CELL, (row + 1) * CELL), slice(col * CELL, (col + 1) * CELL)
			oy, ox = row * n, col * n
			if (col, row) == GLOW:
				out[oy:oy + n, ox:ox + n] = area_resize(atlas_a[ys, xs], n)
				continue
			r = sdf[ys, xs, 0]
			g = sdf[ys, xs, 1]
			if r.max() <= 0.0:
				continue
			t = coverage(r, n)
			f = coverage(g, n, 0.5) if g.max() > 0.0 else np.zeros((n, n), np.float32)
			f = np.minimum(f, t)
			out[oy:oy + n, ox:ox + n] = t
			out[(ROWS + row) * n:(ROWS + row) * n + n, ox:ox + n] = f
	return out


def save_mask(a: np.ndarray, path: str) -> None:
	h, w = a.shape
	rgba = np.zeros((h, w, 4), np.uint8)
	rgba[..., :3] = 255
	rgba[..., 3] = np.clip(np.rint(a * 255.0), 0, 255).astype(np.uint8)
	Image.fromarray(rgba, "RGBA").save(path, optimize=True)


# ---- construction progress ring (map_icon.gdshader MODE_RING, drawn procedurally there) -------------
# The shader: q in [-1,1]^2, r = |q|; band = 1 - smoothstep(0.13 +- fw, |r - 0.8|); halo same with 0.2;
# track rgb (0.04, 0.05, 0.09) with alpha max(halo*0.3, band*0.45); arc = band * done in lit colour.
# Roblox: TRACK image (colour baked, alpha) + ARC mask (white band) revealed by a radial wipe.
RING_PX = 128


def ring_images():
	n = RING_PX
	ss = 4
	idx = (np.arange(n * ss) + 0.5) / ss / n * 2.0 - 1.0
	xx, yy = np.meshgrid(idx, idx)
	r = np.hypot(xx, yy)
	fw = 2.0 / n  # one pixel in q units

	def smooth(e0, e1, x):
		t = np.clip((x - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)

	band = 1.0 - smooth(0.13 - fw, 0.13 + fw, np.abs(r - 0.8))
	halo = 1.0 - smooth(0.2 - fw, 0.2 + fw, np.abs(r - 0.8))
	track_a = np.maximum(halo * 0.3, band * 0.45)
	band = band.reshape(n, ss, n, ss).mean(axis=(1, 3))
	track_a = track_a.reshape(n, ss, n, ss).mean(axis=(1, 3))
	track = np.zeros((n, n, 4), np.uint8)
	track[..., 0] = round(0.04 * 255)
	track[..., 1] = round(0.05 * 255)
	track[..., 2] = round(0.09 * 255)
	track[..., 3] = np.clip(np.rint(track_a * 255), 0, 255).astype(np.uint8)
	return track, band


# ---- veterancy chevrons (map_icon.gdshader MODE_CHEVRON, procedural there) ----------------------------
# q = (u, 1 - v); for k < n: c = 0.16 + 0.29 k; d = min(d, |q.y - (c + 0.55 |q.x - 0.5| - 0.12)| - 0.07);
# d = max(d, |q.x - 0.5| - 0.44); fill = gold where d < 0, dark rim to d < 0.07. Colours baked.
CHEV_W, CHEV_H = 60, 92   # strip aspect 0.3 : 0.46 of the glyph size


def chevron_image():
	ss = 4
	out = np.zeros((CHEV_H, CHEV_W * 3, 4), np.float32)
	u = (np.arange(CHEV_W * ss) + 0.5) / (CHEV_W * ss)
	v = (np.arange(CHEV_H * ss) + 0.5) / (CHEV_H * ss)
	qx, qv = np.meshgrid(u, v)
	qy = 1.0 - qv
	fw = 1.0 / CHEV_H
	for n in (1, 2, 3):
		d = np.full(qx.shape, 1e3)
		for k in range(n):
			c = 0.16 + k * 0.29
			d = np.minimum(d, np.abs(qy - (c + 0.55 * np.abs(qx - 0.5) - 0.12)) - 0.07)
		d = np.maximum(d, np.abs(qx - 0.5) - 0.44)
		fill = np.clip(0.5 - d / (2 * fw), 0, 1)
		edge = np.clip(0.5 - (d - 0.07) / (2 * fw), 0, 1)
		dark = np.array([0.08, 0.06, 0.02])
		gold = np.array([1.0, 0.82, 0.3])
		rgb = dark[None, None, :] * (1 - fill[..., None]) + gold[None, None, :] * fill[..., None]
		# premultiply for box filtering, then un-premultiply
		pre = np.concatenate([rgb * edge[..., None], edge[..., None]], -1)
		pre = pre.reshape(CHEV_H, ss, CHEV_W, ss, 4).mean(axis=(1, 3))
		a = pre[..., 3:4]
		col = np.where(a > 1e-4, pre[..., :3] / np.maximum(a, 1e-4), 0)
		out[:, (n - 1) * CHEV_W:n * CHEV_W, :3] = col
		out[:, (n - 1) * CHEV_W:n * CHEV_W, 3] = a[..., 0]
	return (np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)


def main():
	upload = "--no-upload" not in sys.argv
	os.makedirs(OUT, exist_ok=True)
	sdf = np.asarray(Image.open(os.path.join(SRC, "map_atlas_sdf.png")).convert("RGB"), np.float32) / 255.0
	atlas = np.asarray(Image.open(os.path.join(SRC, "map_atlas.png")).convert("RGBA"), np.float32) / 255.0
	atlas_a = atlas[..., 3]
	meta = json.load(open(os.path.join(SRC, "map_atlas.json")))
	files = {}
	for n in TIERS:
		a = build_tier(sdf, atlas_a, n)
		p = os.path.join(OUT, f"glyphs_{n}.png")
		save_mask(a, p)
		files[f"tier{n}"] = p
	track, band = ring_images()
	p = os.path.join(OUT, "ring_track.png")
	Image.fromarray(track, "RGBA").save(p, optimize=True)
	files["ring_track"] = p
	p = os.path.join(OUT, "ring_arc.png")
	save_mask(band, p)
	files["ring_arc"] = p
	p = os.path.join(OUT, "chevrons.png")
	Image.fromarray(chevron_image(), "RGBA").save(p, optimize=True)
	files["chevrons"] = p
	ids = {k: "" for k in files}
	if upload:
		sys.path.insert(0, os.path.join(ROOT, "tools"))
		import upload as up  # noqa: E402
		res = up.upload_images(list(files.values()))
		for k, path in files.items():
			ids[k] = res.get(os.path.abspath(path), "")
	glyphs = dict(meta["glyphs"])
	glyphs.update(meta["sdf"]["badges"])
	lines = [
		"-- GENERATED by tools/glyphs/make_glyphs.py (overlays-a). Do not edit.",
		"-- Map glyph mask atlases (see build/notes/overlays-a.md): each tier image is (8*px) x (8*px),",
		"-- rows 0-3 = TOTAL coverage (paint INK colour), rows 4-7 = FILL coverage (paint FILL colour on top);",
		"-- RGB white, alpha = coverage. Cells: glyphs[name] = {col, row} (0-based, row < 4).",
		"return {",
		f"\tcell = {CELL},",
		f"\tcols = {COLS},",
		f"\trows = {ROWS},",
		"\ttiers = {",
	]
	for n in TIERS:
		lines.append(f'\t\t{{ px = {n}, image = "{ids[f"tier{n}"]}" }},')
	lines.append("\t},")
	lines.append("\tglyphs = {")
	order = sorted(glyphs.items(), key=lambda kv: (kv[1][1], kv[1][0]))
	for name, (c, r) in order:
		lines.append(f"\t\t{name} = {{ {c}, {r} }},")
	lines.append("\t},")
	lines.append("\tanchors = {")
	for name, info in meta.get("glyph_info", {}).items():
		if "anchor" in info:
			ax, ay = info["anchor"]
			lines.append(f"\t\t{name} = {{ {ax}, {ay} }},")
	lines.append("\t},")
	lines.append(f"\t-- construction ring ({RING_PX} px): track = dark band + halo (colour baked), arc = white band mask")
	lines.append(f'\tring_track = "{ids["ring_track"]}",')
	lines.append(f'\tring_arc = "{ids["ring_arc"]}",')
	lines.append(f"\t-- veterancy chevrons: 3 cells of {CHEV_W}x{CHEV_H} px side by side (count 1, 2, 3), colours baked")
	lines.append(f'\tchevrons = "{ids["chevrons"]}",')
	lines.append(f"\tchevron_cell = {{ {CHEV_W}, {CHEV_H} }},")
	lines.append("}")
	os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
	with open(MANIFEST, "w") as f:
		f.write("\n".join(lines) + "\n")
	print(json.dumps(ids, indent=1))
	print("wrote", MANIFEST)


if __name__ == "__main__":
	main()
