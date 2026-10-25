--!native
--!strict
-- Port of scripts/core/defs.gd: shared enums, grid helpers and small lookup tables used by the
-- simulation, the client mirror and the views — plus the GDScript builtin helpers the port needs
-- (posmod, trunc, idiv/imod, smoothstep, clampi, round, colour conversions).
--
-- Conventions (see build/notes/READY-core-api):
-- * Tables indexed by an enum value (STRUCT_NAMES, NUKE_NAMES, …) are keyed by that value (0-based):
--   Defs.STRUCT_NAMES[Defs.S_CITY] == "city". Their sizes: Defs.STRUCT_KIND_COUNT, Defs.NUKE_KIND_COUNT.
-- * Functions that returned a Vector2 in GDScript return two numbers (tile_latlon → lat, lon).
-- * Colours are RGBA8 ints (0xRRGGBBAA, Godot Color.to_rgba32 layout) everywhere in Core.

local Defs = {}

--- DEPRECATED fallbacks: the size of the default map ("World", 2000 x 1000). Every map
--- has its own size (map.W / map.H / map.N); simulation code never uses these.
Defs.W = 2000
Defs.H = 1000
Defs.TILE_COUNT = 2000 * 1000
Defs.TICK_RATE = 10
Defs.MAX_OWNERS = 1024

-- Terrain codes (assets/world/terrain.png)
Defs.T_OCEAN = 0
Defs.T_LAKE = 1
Defs.T_PLAINS = 2
Defs.T_HIGHLAND = 3
Defs.T_MOUNTAIN = 4
Defs.T_TUNDRA = 5
Defs.T_ICECAP = 6

-- Owner kinds
Defs.KIND_NATION = 0
Defs.KIND_TRIBE = 1
Defs.KIND_HUMAN = 2

-- Match phases
Defs.PHASE_SPAWN = 0
Defs.PHASE_PLAYING = 1
Defs.PHASE_OVER = 2

-- Structure kinds (value doubles as the map atlas column in row 0)
Defs.S_CITY = 0
Defs.S_PORT = 1
Defs.S_FACTORY = 2
Defs.S_DEFENSE = 3
Defs.S_SAM = 4
Defs.S_SILO = 5
-- The Arsenal's structures (Data/Arsenal: unlocked with Stars or Robux; 2026-10-04)
Defs.S_ARTILLERY = 6
Defs.S_AIRFIELD = 7
Defs.S_RAILGUN = 8
Defs.STRUCT_KIND_COUNT = 9
Defs.STRUCT_NAMES = { [0] = "city", "port", "factory", "defense", "sam", "silo", "artillery", "airfield", "railgun" }
Defs.STRUCT_TITLES = {
	[0] = "City",
	"Port",
	"Factory",
	"Defense Post",
	"SAM Launcher",
	"Missile Silo",
	"Artillery",
	"Airfield",
	"Railgun",
}

-- Unit kinds
Defs.U_TRANSPORT = 0
Defs.U_TRADE = 1
Defs.U_WARSHIP = 2
Defs.U_TRUCK = 3
Defs.UNIT_KIND_COUNT = 4

-- Nuke kinds
Defs.N_ATOM = 0
Defs.N_HYDROGEN = 1
Defs.N_MIRV = 2
Defs.N_WARHEAD = 3
-- The Arsenal's munitions (Data/Arsenal). Mega and scatter leave a silo like an atom bomb; a shell is
-- fired by an Artillery battery on its own; an air strike leaves an Airfield and a slug a Railgun.
Defs.N_MEGA = 4
Defs.N_SCATTER = 5
Defs.N_SHELL = 6
Defs.N_AIRSTRIKE = 7
Defs.N_SLUG = 8
Defs.NUKE_KIND_COUNT = 9
Defs.NUKE_NAMES = { [0] = "atom", "hydrogen", "mirv", "warhead", "mega", "scatter", "shell", "airstrike", "slug" }
Defs.NUKE_TITLES = {
	[0] = "Atom Bomb",
	"Hydrogen Bomb",
	"MIRV",
	"Warhead",
	"Mega Nuke",
	"Scattershot",
	"Artillery Shell",
	"Air Strike",
	"Railgun Slug",
}

-- Arsenal unlocks an owner holds (Sim.o_unlock bit mask; Data/Arsenal names them). Without its bit
-- the Sim refuses the build, the launch or the call.
Defs.UNLOCK = {
	mega = 1,
	scatter = 2,
	reinforce = 4,
	artillery = 8,
	airfield = 16,
	railgun = 32,
	reload2x = 64,
}
Defs.UNLOCK_ALL = 127
--- The unlock a structure kind (Defs.S_*) / a munition (Defs.N_*) needs: 0 = none.
Defs.STRUCT_UNLOCK = { [0] = 0, 0, 0, 0, 0, 0, 8, 16, 32 }
Defs.NUKE_UNLOCK = { [0] = 0, 0, 0, 0, 1, 2, 8, 16, 32 }

-- Tile flags (GameState.flags / delta "flags")
Defs.F_FALLOUT = 1

-- Unit removal reasons
Defs.DEL_ARRIVED = 0
Defs.DEL_DESTROYED = 1
Defs.DEL_INTERCEPTED = 2
Defs.DEL_CAPTURED = 3

-- Message categories
Defs.MSG_INFO = 0
Defs.MSG_GOOD = 1
Defs.MSG_BAD = 2
Defs.MSG_ALERT = 3
Defs.MSG_ALLIANCE = 4

-- Game-over reasons
Defs.OVER_DOMINATION = 0
Defs.OVER_TIME = 1
Defs.OVER_DEFEATED = 2
Defs.OVER_ABANDONED = 3

-- Map atlas cells (assets/icons/map_atlas.png, 8 x 2 cells of 128 px) as {x, y} (Vector2i in GDScript).
Defs.ATLAS_CITY = { x = 0, y = 0 }
Defs.ATLAS_PORT = { x = 1, y = 0 }
Defs.ATLAS_FACTORY = { x = 2, y = 0 }
Defs.ATLAS_DEFENSE = { x = 3, y = 0 }
Defs.ATLAS_SAM = { x = 4, y = 0 }
Defs.ATLAS_SILO = { x = 5, y = 0 }
Defs.ATLAS_WARSHIP = { x = 6, y = 0 }
Defs.ATLAS_TRANSPORT = { x = 7, y = 0 }
Defs.ATLAS_TRADE = { x = 0, y = 1 }
Defs.ATLAS_TRUCK = { x = 1, y = 1 }
Defs.ATLAS_TARGET = { x = 2, y = 1 }
Defs.ATLAS_ATTACK = { x = 3, y = 1 }
Defs.ATLAS_CAPITAL = { x = 4, y = 1 }
Defs.ATLAS_RADIATION = { x = 5, y = 1 }
Defs.ATLAS_GLOW = { x = 6, y = 1 }
Defs.ATLAS_SPAWN = { x = 7, y = 1 }

local DEG = math.pi / 180

-- =============================================================================================
-- GDScript builtin equivalents
-- =============================================================================================

--- GDScript posmod(a, b) (result has the sign of b) == Luau `%`.
function Defs.posmod(a: number, b: number): number
	return a % b
end

--- GDScript int(x): truncate toward zero.
function Defs.trunc(x: number): number
	if x >= 0 then
		return math.floor(x)
	end
	return -math.floor(-x)
end

--- GDScript integer `a / b` (truncating division of ints).
function Defs.idiv(a: number, b: number): number
	local q = a / b
	if q >= 0 then
		return math.floor(q)
	end
	return -math.floor(-q)
end

--- GDScript integer `a % b` (C remainder: sign of a).
function Defs.imod(a: number, b: number): number
	return math.fmod(a, b)
end

function Defs.clampi(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

Defs.clampf = Defs.clampi
Defs.clamp = Defs.clampi

function Defs.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Defs.inverse_lerp(a: number, b: number, v: number): number
	if a == b then
		return 0
	end
	return (v - a) / (b - a)
end

--- Godot smoothstep(from, to, x).
function Defs.smoothstep(from: number, to: number, x: number): number
	if from == to then
		return if x < from then 0 else 1
	end
	local s = (x - from) / (to - from)
	if s < 0 then
		s = 0
	elseif s > 1 then
		s = 1
	end
	return s * s * (3.0 - 2.0 * s)
end

--- Godot round(): half away from zero.
function Defs.round(x: number): number
	if x >= 0 then
		return math.floor(x + 0.5)
	end
	return -math.floor(-x + 0.5)
end

--- Godot snappedf(x, step).
function Defs.snappedf(x: number, step: number): number
	if step == 0 then
		return x
	end
	return math.floor(x / step + 0.5) * step
end

--- Godot wrapf(value, min, max).
function Defs.wrapf(value: number, lo: number, hi: number): number
	local range = hi - lo
	if range == 0 then
		return lo
	end
	return value - range * math.floor((value - lo) / range)
end

function Defs.wrapi(value: number, lo: number, hi: number): number
	local range = hi - lo
	if range == 0 then
		return lo
	end
	return lo + ((value - lo) % range)
end

--- Godot move_toward(from, to, delta).
function Defs.move_toward(from: number, to: number, delta: number): number
	if math.abs(to - from) <= delta then
		return to
	end
	return from + (if to > from then delta else -delta)
end

--- Godot is_finite for numbers (false for NaN / ±inf).
function Defs.is_finite(x: number): boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end

--- Rounds a double to float32 precision (PackedFloat32Array / Color components).
function Defs.f32(x: number): number
	return string.unpack("f", string.pack("f", x)) :: number
end

--- Index (0-based, matching the enum values) of `value` in an enum-keyed table, or -1.
function Defs.find(tbl: { [number]: any }, value: any): number
	local i = 0
	while tbl[i] ~= nil do
		if tbl[i] == value then
			return i
		end
		i += 1
	end
	return -1
end

-- =============================================================================================
-- Enums
-- =============================================================================================

function Defs.struct_kind_from_name(kind_name: string): number
	for k = 0, Defs.STRUCT_KIND_COUNT - 1 do
		if Defs.STRUCT_NAMES[k] == kind_name then
			return k
		end
	end
	return -1
end

function Defs.nuke_kind_from_name(kind_name: string): number
	for k = 0, Defs.NUKE_KIND_COUNT - 1 do
		if Defs.NUKE_NAMES[k] == kind_name then
			return k
		end
	end
	return -1
end

-- =============================================================================================
-- Grid geometry
-- =============================================================================================
-- Every map is a flat W x H grid (no wrap, plain grid metrics); the helpers that need the
-- map size live on the map (WorldMap: map.W / map.H / map.N, map.dist2, map.range_d2,
-- map.geo_manhattan, map.geo_span, map.gc_dist, map:tile_x / tile_y / tile_index / neighbor).
-- The sphere helpers below are plain math (no grid) kept for camera code.

--- Unit-sphere position (x, y, z) of a lat/lon (Y up, lon 0 faces +Z) as three numbers.
function Defs.latlon_xyz(lat_deg: number, lon_deg: number): (number, number, number)
	local lat = lat_deg * DEG
	local lon = lon_deg * DEG
	local c = math.cos(lat)
	return c * math.sin(lon), math.sin(lat), c * math.cos(lon)
end

function Defs.latlon_vec3(lat_deg: number, lon_deg: number): Vector3
	local x, y, z = Defs.latlon_xyz(lat_deg, lon_deg)
	return Vector3.new(x, y, z)
end

--- lat, lon (degrees) of a direction given as numbers (normalised internally).
function Defs.xyz_latlon(x: number, y: number, z: number): (number, number)
	local l = math.sqrt(x * x + y * y + z * z)
	if l > 0 then
		x /= l
		y /= l
		z /= l
	end
	local ny = y
	if ny < -1 then
		ny = -1
	elseif ny > 1 then
		ny = 1
	end
	return math.asin(ny) / DEG, math.atan2(x, z) / DEG
end

function Defs.vec3_latlon(v: Vector3): (number, number)
	return Defs.xyz_latlon(v.X, v.Y, v.Z)
end

-- ---------------------------------------------------------------------------------------------
-- DEPRECATED view-map shims for client UI written against the old fixed grid (TargetCard,
-- UIInteract, UIRules, UIAdvisor). They follow the map of the most recently created / switched
-- GameState (GameState calls Defs.set_view_map) and use its flat metrics; Defs.W / H / TILE_COUNT
-- follow it too. Simulation code never uses them (several maps may live in one process) — new code
-- should use state.map (map.W, map.range_d2, map.gc_dist, map:point_tile ...).
-- ---------------------------------------------------------------------------------------------

local view_w = Defs.W
local view_h = Defs.H

--- Called by GameState: the map the client UI shows.
function Defs.set_view_map(map: any)
	view_w = map.W
	view_h = map.H
	Defs.W = map.W
	Defs.H = map.H
	Defs.TILE_COUNT = map.N
end

--- DEPRECATED (use map.gc_dist): straight-line tile distance on the view map.
function Defs.tile_distance(a: number, b: number): number
	local dx = a % view_w - b % view_w
	local dy = a // view_w - b // view_w
	return math.sqrt(dx * dx + dy * dy)
end

--- DEPRECATED (use map.range_d2 / map.dist2): squared tile distance on the view map.
function Defs.range_d2(a: number, b: number): number
	local dx = a % view_w - b % view_w
	local dy = a // view_w - b // view_w
	return dx * dx + dy * dy
end
Defs.dist2 = Defs.range_d2

--- DEPRECATED (use map.geo_manhattan).
function Defs.geo_manhattan(a: number, b: number): number
	return math.abs(a % view_w - b % view_w) + math.abs(a // view_w - b // view_w)
end

--- DEPRECATED: tile containing map-space point (x, y) on the view map (the old sphere-to-tile
--- helpers now receive GameState's map-space positions; z is ignored).
function Defs.xyz_tile(x: number, y: number, _z: number?): number
	local tx = math.clamp(math.floor(x), 0, view_w - 1)
	local ty = math.clamp(math.floor(y), 0, view_h - 1)
	return ty * view_w + tx
end

function Defs.vec3_tile(v: Vector3): number
	return Defs.xyz_tile(v.X, v.Y, v.Z)
end

-- float32 rounding through a scratch buffer (faster than string.pack for hot callers).
local F32B = buffer.create(4)
local function f32b(x: number): number
	buffer.writef32(F32B, 0, x)
	return buffer.readf32(F32B, 0)
end
Defs.f32b = f32b

-- =============================================================================================
-- Colours (RGBA8 ints, Godot Color.to_rgba32 layout 0xRRGGBBAA)
-- =============================================================================================

--- r, g, b, a bytes of an RGBA8 int.
function Defs.rgba_bytes(c: number): (number, number, number, number)
	c = c % 4294967296
	return c // 16777216, (c // 65536) % 256, (c // 256) % 256, c % 256
end

--- r, g, b, a floats (0..1) of an RGBA8 int (Godot Color.hex).
function Defs.rgba_floats(c: number): (number, number, number, number)
	local r, g, b, a = Defs.rgba_bytes(c)
	return r / 255, g / 255, b / 255, a / 255
end

--- Godot Color(r, g, b, a).to_rgba32(): components rounded half away from zero, wrapped to a byte.
function Defs.floats_rgba(r: number, g: number, b: number, a: number?): number
	-- Color::to_rgba32: (uint8_t)Math::round(r * 255.0f) — the product is a float32
	local function byte(v: number): number
		return Defs.round(Defs.f32b(v * 255.0)) % 256
	end
	return ((byte(r) * 256 + byte(g)) * 256 + byte(b)) * 256 + byte(a or 1.0)
end

--- "#rrggbb" / "rrggbb" / "#rrggbbaa" → RGBA8 int (Color.html(h).to_rgba32()).
function Defs.html_rgba(hex: string): number
	local s = string.gsub(hex, "^#", "")
	if #s == 6 then
		return (tonumber(s, 16) or 0x888888) * 256 + 255
	elseif #s == 8 then
		return tonumber(s, 16) or 0x888888FF
	elseif #s == 3 then
		local r = tonumber(string.sub(s, 1, 1), 16) or 8
		local g = tonumber(string.sub(s, 2, 2), 16) or 8
		local b = tonumber(string.sub(s, 3, 3), 16) or 8
		return (((r * 17) * 256 + g * 17) * 256 + b * 17) * 256 + 255
	end
	return 0x888888FF
end

--- Godot Color.from_hsv(h, s, v, a) → r, g, b floats (0..1).
function Defs.hsv_floats(h: number, s: number, v: number): (number, number, number)
	if s == 0 then
		return v, v, v
	end
	h *= 6.0
	h = math.fmod(h, 6)
	local i = math.floor(h)
	local f = h - i
	local p = v * (1.0 - s)
	local q = v * (1.0 - s * f)
	local t = v * (1.0 - s * (1.0 - f))
	if i == 0 then
		return v, t, p
	elseif i == 1 then
		return q, v, p
	elseif i == 2 then
		return p, v, t
	elseif i == 3 then
		return p, q, v
	elseif i == 4 then
		return t, p, v
	end
	return v, p, q
end

--- Color.from_hsv(h, s, v).to_rgba32().
function Defs.hsv_rgba(h: number, s: number, v: number): number
	local r, g, b = Defs.hsv_floats(h, s, v)
	return Defs.floats_rgba(r, g, b, 1.0)
end

--- Godot Color.hex(c) as a Roblox Color3 (falls back to a plain {R,G,B} table where Color3 is missing).
function Defs.color_from_int(c: number): any
	local r, g, b = Defs.rgba_bytes(c)
	local C3: any = Color3
	if C3 ~= nil then
		return C3.fromRGB(r, g, b)
	end
	return { R = r / 255, G = g / 255, B = b / 255 }
end

--- Color.to_html(false) of an RGBA8 int ("rrggbb").
function Defs.rgba_html(c: number): string
	local r, g, b = Defs.rgba_bytes(c)
	return string.format("%02x%02x%02x", r, g, b)
end

-- =============================================================================================
-- Text
-- =============================================================================================

--- "12.3K", "1.25M", "-850" (Defs.format_troops).
function Defs.format_troops(value: number): string
	local v = math.abs(value)
	local s: string
	if v >= 1000000.0 then
		if v < 10000000.0 then
			s = string.format("%.2fM", v / 1000000.0)
		else
			s = string.format("%.1fM", v / 1000000.0)
		end
	elseif v >= 1000.0 then
		if v < 100000.0 then
			s = string.format("%.1fK", v / 1000.0)
		else
			s = string.format("%dK", Defs.trunc(v / 1000.0))
		end
	else
		s = tostring(Defs.trunc(v))
	end
	return (if value < 0.0 then "-" else "") .. s
end

-- =============================================================================================
-- Godot's sort (core/templates/sort_array.h: introsort — median-of-3 quicksort, heapsort past
-- 2*log2(n) levels, final insertion sort), so Array.sort_custom() orders equal elements exactly
-- like the original (table.sort is a different, also unstable, algorithm).
-- =============================================================================================

local INTROSORT_THRESHOLD = 16

--- Sorts the 1-based array `a` in place with Godot's SortArray algorithm; `less(x, y)` is the
--- sort_custom callable. Equal elements end up in the same order as in Godot.
function Defs.godot_sort(a: { any }, less: (any, any) -> boolean)
	local len = #a
	if len < 2 then
		return
	end
	-- 0-based helpers over the 1-based array
	local function get(i: number): any
		return a[i + 1]
	end
	local function set(i: number, v: any)
		a[i + 1] = v
	end
	local function median_of_3(x: any, y: any, z: any): any
		if less(x, y) then
			if less(y, z) then
				return y
			elseif less(x, z) then
				return z
			else
				return x
			end
		elseif less(x, z) then
			return x
		elseif less(y, z) then
			return z
		else
			return y
		end
	end
	local function push_heap(first: number, hole: number, top: number, value: any)
		local parent = (hole - 1) // 2
		while hole > top and less(get(first + parent), value) do
			set(first + hole, get(first + parent))
			hole = parent
			parent = (hole - 1) // 2
		end
		set(first + hole, value)
	end
	local function adjust_heap(first: number, hole: number, n: number, value: any)
		local top = hole
		local second = 2 * hole + 2
		while second < n do
			if less(get(first + second), get(first + second - 1)) then
				second -= 1
			end
			set(first + hole, get(first + second))
			hole = second
			second = 2 * (second + 1)
		end
		if second == n then
			set(first + hole, get(first + second - 1))
			hole = second - 1
		end
		push_heap(first, hole, top, value)
	end
	local function pop_heap_to(first: number, last: number, result: number, value: any)
		set(result, get(first))
		adjust_heap(first, 0, last - first, value)
	end
	local function make_heap(first: number, last: number)
		if last - first < 2 then
			return
		end
		local n = last - first
		local parent = (n - 2) // 2
		while true do
			adjust_heap(first, parent, n, get(first + parent))
			if parent == 0 then
				return
			end
			parent -= 1
		end
	end
	local function partial_sort(first: number, last: number, middle: number)
		make_heap(first, middle)
		for i = middle, last - 1 do
			if less(get(i), get(first)) then
				pop_heap_to(first, middle, i, get(i))
			end
		end
		-- sort_heap
		local l = middle
		while l - first > 1 do
			pop_heap_to(first, l - 1, l - 1, get(l - 1))
			l -= 1
		end
	end
	local function partitioner(first: number, last: number, pivot: any): number
		while true do
			while less(get(first), pivot) do
				first += 1
			end
			last -= 1
			while less(pivot, get(last)) do
				last -= 1
			end
			if not (first < last) then
				return first
			end
			local tmp = get(first)
			set(first, get(last))
			set(last, tmp)
			first += 1
		end
	end
	local function introsort(first: number, last: number, depth: number)
		while last - first > INTROSORT_THRESHOLD do
			if depth == 0 then
				partial_sort(first, last, last)
				return
			end
			depth -= 1
			local cut =
				partitioner(first, last, median_of_3(get(first), get(first + (last - first) // 2), get(last - 1)))
			introsort(cut, last, depth)
			last = cut
		end
	end
	local function unguarded_linear_insert(last: number, value: any)
		local nxt = last - 1
		while less(value, get(nxt)) do
			set(last, get(nxt))
			last = nxt
			nxt -= 1
		end
		set(last, value)
	end
	local function linear_insert(first: number, last: number)
		local val = get(last)
		if less(val, get(first)) then
			for i = last, first + 1, -1 do
				set(i, get(i - 1))
			end
			set(first, val)
		else
			unguarded_linear_insert(last, val)
		end
	end
	local function insertion_sort(first: number, last: number)
		if first == last then
			return
		end
		for i = first + 1, last - 1 do
			linear_insert(first, i)
		end
	end
	local k = 0
	local n = len
	while n ~= 1 do
		n = n // 2
		k += 1
	end
	introsort(0, len, k * 2)
	if len > INTROSORT_THRESHOLD then
		insertion_sort(0, INTROSORT_THRESHOLD)
		for i = INTROSORT_THRESHOLD, len - 1 do
			unguarded_linear_insert(i, get(i))
		end
	else
		insertion_sort(0, len)
	end
end

return Defs
