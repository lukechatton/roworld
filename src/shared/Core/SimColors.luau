-- Port of scripts/core/sim_colors.gd: owner colour assignment in OKLab (perceptual) space: every
-- owner should read as distinct from the owners around it (target ΔE ≥ MIN_DE). Used at spawn
-- time; colours never change while a human holds land.
--
-- Colours are RGBA8 ints (0xRRGGBBAA). OKLab values are tables {x = L, y = a, z = b} (GDScript
-- Vector3); `refs` are 1-based arrays of them.
--
-- float32: Godot's Vector3 / Vector2 / Color are float32 (real_t = float), so OKLab triples,
-- distances (distance_to / length) and the shifted candidates are rounded to float32 exactly where
-- the original rounds them (the scalar math in between is GDScript double) — the port picks and
-- re-tints to the very same RGBA values (verified in lockstep with the original, tools/parity).
local Defs = require("./Defs")

local f32 = Defs.f32b

--- Vector2(x, y).length() in float32.
local function len2_f32(x: number, y: number): number
	return f32(math.sqrt(f32(f32(x * x) + f32(y * y))))
end

local SimColors = {}

export type Lab = { x: number, y: number, z: number }

--- Target minimum OKLab distance between neighbouring owners.
SimColors.MIN_DE = 0.12
local MIN_DE = 0.12

local function _lin(v: number): number
	if v <= 0.04045 then
		return v / 12.92
	end
	return ((v + 0.055) / 1.055) ^ 2.4
end

local function _gamma(v: number): number
	if v < 0 then
		v = 0
	elseif v > 1 then
		v = 1
	end
	if v <= 0.0031308 then
		return v * 12.92
	end
	return 1.055 * v ^ (1.0 / 2.4) - 0.055
end

local function cbrt(v: number): number
	-- Godot pow(x, 1/3) (NaN for negatives; inputs here are never negative)
	return v ^ (1.0 / 3.0)
end

--- sRGB colour (RGBA8 int, as on the wire) → OKLab {x = L, y = a, z = b}.
function SimColors.oklab(rgba: number): Lab
	local cr, cg, cb = Defs.rgba_floats(rgba)
	local r = _lin(Defs.f32(cr))
	local g = _lin(Defs.f32(cg))
	local b = _lin(Defs.f32(cb))
	local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
	local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
	local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
	return {
		x = f32(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
		y = f32(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
		z = f32(0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s),
	}
end

--- OKLab → sRGB RGBA8 int (out-of-gamut values are clipped).
function SimColors.to_rgba(lab: Lab): number
	local l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
	local m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
	local s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
	local l = l_ * l_ * l_
	local m = m_ * m_ * m_
	local s = s_ * s_ * s_
	local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
	local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
	local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	-- Color(r, g, b) stores float32 components before to_rgba32().
	return Defs.floats_rgba(Defs.f32(_gamma(r)), Defs.f32(_gamma(g)), Defs.f32(_gamma(b)), 1.0)
end

--- OKLab distance (Vector3.distance_to, float32: component differences, squares, sums, sqrtf).
function SimColors.dist(a: Lab, b: Lab): number
	local dx, dy, dz = f32(b.x - a.x), f32(b.y - a.y), f32(b.z - a.z)
	return f32(math.sqrt(f32(f32(f32(dx * dx) + f32(dy * dy)) + f32(dz * dz))))
end
local dist = SimColors.dist

--- Smallest OKLab distance from `lab` to any of `refs` (10 when there are none).
function SimColors.min_de(lab: Lab, refs: { Lab }): number
	local d = 10.0
	for _, r in refs do
		local e = dist(lab, r)
		if e < d then
			d = e
		end
	end
	return d
end
local min_de = SimColors.min_de

--- Curated tribe palette: 32 saturated, mid-bright colours (sat 0.55–0.8, value 0.68–0.9). 1-based.
function SimColors.tribe_palette(): { number }
	local out = {}
	for i = 0, 15 do
		local h = i / 16.0
		table.insert(out, Defs.hsv_rgba(h, 0.62, 0.9))
		table.insert(out, Defs.hsv_rgba(h + 1.0 / 32.0, 0.8, 0.68))
	end
	return out
end

local _human_palette: { number }? = nil

--- Human candidates in the nations' style: vivid but not neon (OKLab L 0.64–0.76, chroma
--- 0.11–0.155, every 15° of hue); out-of-gamut variants are dropped, so no pure RGB primaries.
function SimColors.human_palette(): { number }
	if _human_palette ~= nil then
		return _human_palette
	end
	local out = {}
	for i = 0, 23 do
		local h = 2 * math.pi * i / 24.0
		for _, l in { 0.64, 0.70, 0.76 } do
			for _, c in { 0.11, 0.155 } do
				-- Yellow-green hues turn olive / muddy at low lightness.
				local deg = math.deg(h)
				if deg > 75.0 and deg < 140.0 and l < 0.74 then
					continue
				end
				local lab = { x = f32(l), y = f32(math.cos(h) * c), z = f32(math.sin(h) * c) }
				local rgba = SimColors.to_rgba(lab)
				if dist(SimColors.oklab(rgba), lab) < 0.01 then
					table.insert(out, rgba)
				end
			end
		end
	end
	_human_palette = out
	return out
end

--- Candidate with the largest minimum ΔE to `refs`. With `rng`, picks randomly among the
--- candidates that already reach MIN_DE (so neighbours don't all get the same "best" colour).
function SimColors.pick(cands: { number }, refs: { Lab }, rng: any?): number
	local best = cands[1]
	local best_d = -1.0
	local good = {}
	for _, c in cands do
		local d = min_de(SimColors.oklab(c), refs)
		if d >= MIN_DE then
			table.insert(good, c)
		end
		if d > best_d + 1e-4 then
			best_d = d
			best = c
		end
	end
	if rng ~= nil and #good > 0 then
		return good[rng:randi() % #good + 1]
	end
	return best
end

--- Authored colours are only touched when a neighbour is this close (clearly confusable).
SimColors.NUDGE_BELOW = 0.08

--- Keeps an authored colour unless it is closer than NUDGE_BELOW to `refs`; then applies the
--- smallest lightness / hue shift (in OKLab) that reaches MIN_DE (or the best one found).
function SimColors.nudge(rgba: number, refs: { Lab }): number
	if min_de(SimColors.oklab(rgba), refs) >= SimColors.NUDGE_BELOW then
		return rgba
	end
	return SimColors.shift(rgba, refs)
end

local DLS = { 0.0, 0.05, -0.05, 0.1, -0.1, 0.15, -0.15 }
local DHS = { 0.0, 0.26, -0.26, 0.52, -0.52, 0.79, -0.79, 1.05, -1.05 }

--- The smallest OKLab lightness / hue shift of `rgba` that reaches MIN_DE from every ref (or the
--- most distinct variant found when none does).
function SimColors.shift(rgba: number, refs: { Lab }): number
	local lab = SimColors.oklab(rgba)
	local chroma = len2_f32(lab.y, lab.z)
	local hue = math.atan2(lab.z, lab.y)
	local best = rgba
	local best_cost = 1e9
	local best_d = min_de(lab, refs)
	for _, dl in DLS do
		for _, dh in DHS do
			local h = hue + dh
			local lx = lab.x + dl
			if lx < 0.35 then
				lx = 0.35
			elseif lx > 0.92 then
				lx = 0.92
			end
			local rgb = SimColors.to_rgba({ x = f32(lx), y = f32(math.cos(h) * chroma), z = f32(math.sin(h) * chroma) })
			local d = min_de(SimColors.oklab(rgb), refs)
			local cost = math.abs(dl) * 2.0 + math.abs(dh) * math.max(chroma, 0.05)
			if d >= MIN_DE and (best_d < MIN_DE or cost < best_cost) then
				best = rgb
				best_cost = cost
				best_d = d
			elseif best_d < MIN_DE and d > best_d then
				best = rgb
				best_d = d
			end
		end
	end
	return best
end

-- =============================================================================================
-- Assignment helpers (operate on the Sim's owner arrays)
-- =============================================================================================

--- OKLab colours of living, spawned owners (of `kind`, or any when -1/nil) whose start lies within
--- `radius` tiles of `id`'s start.
function SimColors.refs_near(st: any, id: number, radius: number, kind: number?): { Lab }
	local k = kind or -1
	local refs = {}
	local t = st.o_spawn_tile[id]
	if t < 0 then
		return refs
	end
	local r2 = radius * radius
	local dist2 = st.dist2
	for o = 1, st.owner_total do
		if k >= 0 and st.o_kind[o] ~= k then
			continue
		end
		if o ~= id and st.o_alive[o] == 1 and st.o_spawn_tile[o] >= 0 and dist2(st.o_spawn_tile[o], t) <= r2 then
			table.insert(refs, SimColors.oklab(st.o_color[o]))
		end
	end
	return refs
end

--- Colour for human `id` starting at `t`: the nation-style candidate most distinct from the owners
--- it will border (territory or start within NEAR_HUMAN tiles of the original 1024-wide grid —
--- scaled by the map's LEGACY_LIN — full weight), from owners up to `radius` tiles away (with 0.04
--- slack) and from all other present humans.
SimColors.NEAR_HUMAN = 45

function SimColors.for_human(st: any, id: number, t: number, radius: number): number
	local near_refs = {}
	local far_refs = {}
	local r2 = radius * radius
	local near = SimColors.NEAR_HUMAN * st.R.LEGACY_LIN
	local n2 = near * near
	local dist2 = st.dist2
	local W, H = st.W, st.H
	for o = 1, st.owner_total do
		if o == id or st.o_alive[o] == 0 then
			continue
		end
		local d2 = 2 ^ 30
		if st.o_kind[o] == Defs.KIND_HUMAN and st.o_left[o] == 0 then
			d2 = 0
		elseif st.o_tiles[o] > 0 then
			local n = st.o_tiles[o]
			local cx = math.clamp(math.floor(st.o_cx[o] / n + 0.5), 0, W - 1)
			local cy = math.clamp(math.floor(st.o_cy[o] / n + 0.5), 0, H - 1)
			d2 = dist2(cy * W + cx, t)
			if st.o_spawn_tile[o] >= 0 then
				d2 = math.min(d2, dist2(st.o_spawn_tile[o], t))
			end
		end
		if d2 <= n2 then
			table.insert(near_refs, SimColors.oklab(st.o_color[o]))
		elseif d2 <= r2 then
			table.insert(far_refs, SimColors.oklab(st.o_color[o]))
		end
	end
	local best = 0
	local best_s = -1.0
	for _, c in SimColors.human_palette() do
		local lab = SimColors.oklab(c)
		local sc = math.min(min_de(lab, near_refs), min_de(lab, far_refs) + 0.04)
		-- Slight preference for brighter, livelier tints among equally distinct ones.
		sc += 0.08 * (lab.x - 0.64) + 0.1 * (len2_f32(lab.y, lab.z) - 0.11)
		if sc > best_s then
			best_s = sc
			best = c
		end
	end
	return best
end

return SimColors
