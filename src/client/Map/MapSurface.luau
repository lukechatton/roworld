--!native
-- The 2D map surface (terrain, territory and borders): one pixel per
-- tile, nearest-neighbour upscaled (ResampleMode Pixelated) so tiles stay crisp squares at any zoom.
--
-- Terrain and territory are composited on the CPU into one RGBA image of the map, split into
-- image tiles of at most 1024 x 1024 (the client EditableImage limit), each shown by one ImageLabel
-- that MapView moves every frame. Only one displayed EditableImage updates per frame (Roblox), so
-- dirty rows are uploaded round-robin: one image tile per frame, all of its dirty 32-row bands.
--   terrain    terrain_pixel of the map's terrain bytes
--              (map.tile_bytes: bit7 land, bit6 shoreline, bits0-4 magnitude), colours from
--              OCEAN .. MOUNTAIN (e.g. highland #DCCB9E);
--   territory  owned tiles blend the owner's colour at 150/255 (saturation 0.85) over the terrain,
--              border tiles are opaque in the border colour (HSL lightness - 0.125), fallout ground is
--              opaque green noise.
-- The rules:
--   * border tile = a 4-neighbour has another owner (off the map counts as another owner);
--   * hovered owner: fill contrast x1.25 about mid-grey, border mixed 25% to white, border thickened
--     by one tile (Chebyshev 1). The fill only for an owner of HOVER_FILL_MAX tiles or fewer: it
--     means repainting every tile (see HOVER_FILL_MAX);
--   * a border next to an ally is mixed 35% toward green;
--   * defended tiles (near a same-owner defense post): border checkerboard x0.7, fill x0.85.
-- (Lune tests load this file with the shared modules from the repo.)
local IS_ROBLOX = (game :: any) ~= nil
local AssetService = if IS_ROBLOX then game:GetService("AssetService") else nil :: any
local function core(name: string): any
	if IS_ROBLOX then
		return require(
			game:GetService("ReplicatedStorage"):WaitForChild("Airfront"):WaitForChild("Core"):WaitForChild(name)
		) :: any
	end
	return (require :: any)("../../shared/Core/" .. name)
end
local Defs = core("Defs")
local Rules = core("Rules")
local Cosmetics: any = if IS_ROBLOX
	then require(game:GetService("ReplicatedStorage"):WaitForChild("Airfront"):WaitForChild("Data").Cosmetics) :: any
	else (require :: any)("../../shared/Data/Cosmetics")

local F_FALLOUT: number = Defs.F_FALLOUT

local band = bit32.band
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readi32 = buffer.readi32
local readu32, writeu32 = buffer.readu32, buffer.writeu32

local MapSurface = {}
MapSurface.__index = MapSurface

-- Territory look
MapSurface.TERRITORY_ALPHA = 150 -- 0.588
MapSurface.SATURATION = 0.85
MapSurface.BORDER_DARKEN = 0.125
MapSurface.HIGHLIGHT_BRIGHTEN = 0.25
MapSurface.FRIENDLY_TINT = 0.35
MapSurface.DEFENSE_CHECKER_DARKEN = 0.7
MapSurface.DEFENSE_FILL_DARKEN = 0.85
--- Client EditableImage limit (px per side).
MapSurface.IMAGE_MAX = 1024
MapSurface.BAND_ROWS = 32
--- Full rebuild work per frame (tiles).
MapSurface.REBUILD_TILES_PER_STEP = 90000
--- Repaint work per frame (tiles). The tiles a change may have altered wait in a queue, each of them
--- once (on_tiles_changed), and step() paints this many a frame (paint_queue).
---   * Until 2026-10-09 every changed tile repainted its 3 x 3 at once: nine tiles for each, the same
---     ones over and over along a front that moved, most of them tiles whose look could not have
---     changed. 6.5 ms a tick in a World match's first minute on a Mac (1,350 tiles change a tick),
---     71 ms in the one tick a big nation fell (26,000). A client of a public match pays that for
---     every tick it is sent, and a phone or an old PC several times it: the "Slow Frames" of v71
---     were early in matches and in no script that report counted.
---   * Now 2.8 ms that first minute (2.6 tiles repainted for each one changed, where there were 9),
---     and the big tick's repaint goes over a few frames.
MapSurface.REPAINT_TILES_PER_STEP = 6000
--- Recorded tile changes looked at a step at least (more while the budget lasts, and a DRAIN_FRAMES share
--- of what waits whatever the clock says): 2,000 change a tick in a solo match's first minute, ten
--- ticks a second, about 330 a frame (_expand_changes).
MapSurface.EXPAND_MIN_CHANGES = 256
--- A hovered owner's fill is brightened while it holds this many tiles or fewer. Its border is
--- brightened and thickened whatever its size.
---   * Until 2026-10-09 the pointer coming onto a nation repainted every tile it owned, at once, and
---     every tile of the one it left. On a Mac: 15 ms for the biggest nation of a World match at minute
---     2, 123 ms at minute 10, 380 ms at minute 26 (395,000 tiles), and as much again on leaving. A
---     desktop player moving the mouse over a late match had frames of seconds; the "Slow Frames" of
---     v71 and v72 named this ("Script - Map Other") for 6 in 10 of the slow matches on computers,
---     and a player's report was "I went down to like 3fps nearing the end".
---   * Now the call repaints nothing: the tiles a hover changes are found a slice a frame
---     (SWEEP_SCAN_PER_STEP) and repainted through the queue (REPAINT_TILES_PER_STEP). No frame of
---     it is over 5 ms on that Mac whatever the nation; a small one is done in 3 to 6 frames, the
---     395,000-tile one in about 70 (its border comes in from the top).
MapSurface.HOVER_FILL_MAX = 30000
--- Tiles a step() looks at to find the ones an owner's repaint needs (repaint_owner, set_hover,
--- repaint_between).
MapSurface.SWEEP_SCAN_PER_STEP = 20000
--- Time a step() spends repainting (s; `budget_s`, MapView gives phones the MOBILE one). It paints
--- DRAIN_FRAMES' share of what waits whatever that takes (REPAINT_MIN_TILES at least), more while the
--- budget lasts, never more than REPAINT_TILES_PER_STEP; the sweeps look for tiles in what is left
--- (a row at least).
---   * Until 2026-10-10 a step was bounded in tiles only: 6,000 repainted and 20,000 looked at, about
---     4.5 ms on a Mac and many times that on a phone, which runs this without native code. A solo
---     World match has 5 to 10 alliance changes a minute from minute 2, and each was a sweep of both
---     nations at that bound for a few dozen frames. "Slow Frames" after v74: "Script - Territory"
---     was 6% of the slow matches, nearly all phones in Solo Easy, minutes 5 to 19.
---   * A burst (a nation falling, a sweep) now goes over more frames on a slow device; what the game
---     changed waits DRAIN_FRAMES frames at most when the device cannot keep up at all.
MapSurface.STEP_BUDGET_S = 0.003
MapSurface.STEP_BUDGET_MOBILE_S = 0.002
MapSurface.DRAIN_FRAMES = 10
MapSurface.REPAINT_MIN_TILES = 256
--- Tiles painted between two looks at the clock.
MapSurface.REPAINT_CHUNK = 256
--- Map background (also impassable terrain).
MapSurface.BACKGROUND = Color3.fromRGB(0x3c, 0x3c, 0x3c)

local BAND_ROWS = MapSurface.BAND_ROWS
local MAX_OWNERS = 4096

-- ---------------------------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------------------------

local function pack(r: number, g: number, b: number, a: number): number
	r = math.clamp(math.floor(r + 0.5), 0, 255)
	g = math.clamp(math.floor(g + 0.5), 0, 255)
	b = math.clamp(math.floor(b + 0.5), 0, 255)
	a = math.clamp(math.floor(a + 0.5), 0, 255)
	return r + g * 256 + b * 65536 + a * 16777216
end
MapSurface.pack = pack

local function rgb_to_hsl(r: number, g: number, b: number): (number, number, number)
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	if mx == mn then
		return 0.0, 0.0, l
	end
	local d = mx - mn
	local s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
	local h
	if mx == r then
		h = (g - b) / d + (if g < b then 6 else 0)
	elseif mx == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h / 6, s, l
end

local function hue(p: number, q: number, t: number): number
	if t < 0 then
		t += 1
	elseif t > 1 then
		t -= 1
	end
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	elseif t < 1 / 2 then
		return q
	elseif t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end
	return p
end

local function hsl_to_rgb(h: number, s: number, l: number): (number, number, number)
	if s == 0 then
		return l, l, l
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	return hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3)
end

--- Darkened by `amount`: HSL lightness - amount.
local function darken(r: number, g: number, b: number, amount: number): (number, number, number)
	local h, s, l = rgb_to_hsl(r, g, b)
	return hsl_to_rgb(h, s, math.max(0, l - amount))
end
MapSurface.darken = darken

local function saturate(r: number, g: number, b: number, k: number): (number, number, number)
	local luma = r * 0.299 + g * 0.587 + b * 0.114
	return luma + (r - luma) * k, luma + (g - luma) * k, luma + (b - luma) * k
end

local function contrast(v: number, k: number): number
	return math.clamp((v - 0.5) * k + 0.5, 0, 1)
end

-- ---------------------------------------------------------------------------------------------
-- Terrain (colour by terrain class and magnitude)
-- ---------------------------------------------------------------------------------------------

local OCEAN = { 0x47, 0x85, 0xB5 } -- #4785b5
local SAND = { 0xCC, 0xCB, 0x9E } -- #CCCB9E
local PLAINS = { 0xBE, 0xDC, 0x8A } -- #BEDC8A
local HIGHLAND = { 0xDC, 0xCB, 0x9E } -- #DCCB9E
local MOUNTAIN = { 0xE6, 0xE6, 0xE6 } -- #e6e6e6
local BACKGROUND = { 0x3C, 0x3C, 0x3C } -- #3c3c3c

--- RGBA8 terrain pixel of a terrain byte (see tile_bytes).
function MapSurface.terrain_pixel(tb: number): number
	local land = tb >= 128
	local shore = band(tb, 64) ~= 0
	local mag = band(tb, 31)
	if land and mag == 31 then
		return pack(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 255)
	elseif land and shore then
		return pack(SAND[1], SAND[2], SAND[3], 255)
	elseif land then
		if mag < 10 then
			return pack(PLAINS[1], PLAINS[2] - 2 * mag, PLAINS[3], 255)
		elseif mag < 20 then
			local m = mag - 10
			return pack(HIGHLAND[1] + 2 * m, HIGHLAND[2] + 2 * m, HIGHLAND[3] + 2 * m, 255)
		end
		local m = mag // 2
		return pack(MOUNTAIN[1] + m, MOUNTAIN[2] + m, MOUNTAIN[3] + m, 255)
	elseif shore then
		return pack(0.7 * OCEAN[1] + 76.5, 0.7 * OCEAN[2] + 76.5, 0.7 * OCEAN[3] + 76.5, 255)
	end
	local m = math.min(mag, 10)
	return pack(OCEAN[1] - m, OCEAN[2] - m, OCEAN[3] - m, 255)
end

--- Terrain bytes in the map files' format for the legacy 1024 x 512 Earth (terrain classes only, no
--- elevation): each land class ramps with the distance from its edge (plains 0..9 from the coast,
--- highland 10..19 and mountain 20..30 toward the middle of a range), water magnitude is the
--- ceil(Manhattan distance to land in full-size tiles / 2). Retired with the Earth (flat
--- maps carry map.tile_bytes).
function MapSurface.legacy_of_bytes(map: any, yield: (() -> ())?): buffer
	local W, H = map.W or Defs.W, map.H or Defs.H
	local N = W * H
	local terrain: buffer = map.terrain
	local T_LAKE, T_PLAINS, T_HIGHLAND, T_MOUNTAIN, T_TUNDRA =
		Defs.T_LAKE, Defs.T_PLAINS, Defs.T_HIGHLAND, Defs.T_MOUNTAIN, Defs.T_TUNDRA
	local function tclass(i: number): number
		return readu8(terrain, i)
	end
	local dist = buffer.create(N * 2)
	local queue = buffer.create(N * 4)
	local function nb(i: number): (number, number, number, number)
		local x = i % W
		return if x > 0 then i - 1 else -1,
			if x < W - 1 then i + 1 else -1,
			if i >= W then i - W else -1,
			if i < N - W then i + W else -1
	end
	local function bfs(seed: (number) -> boolean, member: (number) -> boolean)
		local qh, qt = 0, 0
		for i = 0, N - 1 do
			if seed(i) then
				buffer.writeu16(dist, i * 2, 0)
				buffer.writeu32(queue, qt * 4, i)
				qt += 1
			else
				buffer.writeu16(dist, i * 2, 65535)
			end
		end
		while qh < qt do
			local i = buffer.readu32(queue, qh * 4)
			qh += 1
			local d = buffer.readu16(dist, i * 2) + 1
			local a, b, c, e = nb(i)
			for _, n in { a, b, c, e } do
				if n >= 0 and buffer.readu16(dist, n * 2) == 65535 and member(n) then
					buffer.writeu16(dist, n * 2, d)
					buffer.writeu32(queue, qt * 4, n)
					qt += 1
				end
			end
			if yield and qh % 65536 == 0 then
				yield()
			end
		end
	end
	local function is_water(tt: number): boolean
		return tt <= T_LAKE
	end
	local out = buffer.create(N)
	local k_lin: number = Rules.K_LIN
	bfs(function(i)
		return not is_water(tclass(i))
	end, function(i)
		return is_water(tclass(i))
	end)
	for i = 0, N - 1 do
		if is_water(tclass(i)) then
			writeu8(out, i, math.min(31, math.ceil(buffer.readu16(dist, i * 2) * k_lin / 2)))
		end
	end
	bfs(function(i)
		return is_water(tclass(i))
	end, function(i)
		return not is_water(tclass(i))
	end)
	for i = 0, N - 1 do
		local tt = tclass(i)
		if tt == T_PLAINS or tt == T_TUNDRA then
			writeu8(out, i, 128 + math.min(9, buffer.readu16(dist, i * 2) // 3))
		elseif tt > T_TUNDRA then
			writeu8(out, i, 128 + 30)
		end
	end
	for _, cls in { T_HIGHLAND, T_MOUNTAIN } do
		bfs(function(i)
			return tclass(i) ~= cls
		end, function(i)
			return tclass(i) == cls
		end)
		for i = 0, N - 1 do
			if tclass(i) == cls then
				local d = buffer.readu16(dist, i * 2)
				writeu8(
					out,
					i,
					128 + (if cls == T_HIGHLAND then 10 + math.min(9, (d - 1) * 2) else 20 + math.min(10, (d - 1) * 3))
				)
			end
		end
	end
	-- shoreline bits: land next to water, water next to land
	for i = 0, N - 1 do
		local w = is_water(tclass(i))
		local a, b, c, e = nb(i)
		for _, n in { a, b, c, e } do
			if n >= 0 and is_water(tclass(n)) ~= w then
				writeu8(out, i, bit32.bor(readu8(out, i), 64))
				break
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- Instance
-- ---------------------------------------------------------------------------------------------

type ImgTile = {
	x0: number,
	y0: number,
	w: number,
	h: number,
	img: EditableImage?,
	label: ImageLabel,
	bands: { boolean },
	dirty: boolean,
	scratch: buffer,
}

export type MapSurface = typeof(setmetatable(
	{} :: {
		root: Frame,
		W: number,
		H: number,
		N: number,
		map: any,
		ok: boolean,
		ready: boolean,
		terrain: buffer,
		tile_bytes: buffer?,
		comp: buffer,
		tiles: { ImgTile },
		cols: number,
		rows: number,
		tile_w: number,
		tile_h: number,
		_rr: number,
		_state: any,
		_own: buffer?,
		_flags: buffer?,
		pal_fill: buffer,
		pal_fill_hi: buffer,
		pal_border: buffer,
		pal_border_hi: buffer,
		pal_border_ally: buffer,
		pal_border_ally_hi: buffer,
		defended: buffer,
		hover: number,
		_rebuild_i: number,
		_rebuild_active: boolean,
		_bbox: { [number]: { number } },
		_skins: { [number]: any },
		budget_s: number,
		uploaded: boolean?,
	},
	MapSurface
))

local function create_image(w: number, h: number): EditableImage?
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	if ok and img ~= nil then
		return img
	end
	return nil
end

function MapSurface.new(parent: Instance): MapSurface
	local root = Instance.new("Frame")
	root.Name = "Surface"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = 1
	root.Parent = parent
	local self = setmetatable({
		root = root,
		W = 0,
		H = 0,
		N = 0,
		map = nil,
		ok = false,
		--- terrain composited (set_map finished)
		ready = false,
		terrain = buffer.create(0),
		tile_bytes = nil :: buffer?,
		comp = buffer.create(0),
		tiles = {},
		cols = 0,
		rows = 0,
		tile_w = 0,
		tile_h = 0,
		_rr = 0,
		_state = nil,
		_own = nil :: buffer?,
		_flags = nil :: buffer?,
		pal_fill = buffer.create(MAX_OWNERS * 4),
		pal_fill_hi = buffer.create(MAX_OWNERS * 4),
		pal_border = buffer.create(MAX_OWNERS * 4),
		pal_border_hi = buffer.create(MAX_OWNERS * 4),
		pal_border_ally = buffer.create(MAX_OWNERS * 4),
		pal_border_ally_hi = buffer.create(MAX_OWNERS * 4),
		--- (per tile: near a same-owner defense post. Nothing writes it today; paint_queue's fast path
		--- does not read it, so whoever starts to must send those tiles through composite())
		defended = buffer.create(0),
		hover = 0,
		_rebuild_i = 0,
		_rebuild_active = false,
		--- per owner: { x0, y0, x1, y1 } of the tiles it has owned since the last rebuild
		_bbox = {},
		--- owner → territory skin runtime (_load_skins)
		_skins = {},
		--- tiles waiting for a repaint (REPAINT_TILES_PER_STEP): the list, its length, the next one to
		--- paint, and a byte a tile that is 1 while it waits
		_queue = {} :: { number },
		_queue_n = 0,
		_queue_head = 1,
		_queued = buffer.create(0),
		--- tile changes not yet looked at (on_tiles_changed records them, step expands them):
		--- packed tile * 1024 + owner, then the old owner (-1: unknown), pairs from _pend_i
		_pend = {} :: { number },
		_pend_n = 0,
		_pend_i = 1,
		--- the records up to here were made before an alliance or a palette changed: each of their
		--- owned neighbours is repainted, whoever owns it (the alliances they were made under are gone)
		_pend_wide_to = 0,
		--- the hovered owner's fill is brightened too (it is small enough: HOVER_FILL_MAX)
		_hover_fill = false,
		--- owners whose tiles are being found for a repaint: { owner, fill (every tile; else the
		--- border and the tiles next to it), y (the next row to look at; -1: from the top), other
		--- (repaint_between: only the owner's and other's tiles that touch each other) }
		_sweeps = {} :: { { owner: number, fill: boolean, y: number, other: number? } },
		--- a step's time (STEP_BUDGET_S)
		budget_s = MapSurface.STEP_BUDGET_S,
	}, MapSurface)
	return self
end

function MapSurface._free_tiles(self: MapSurface)
	for _, t in self.tiles do
		t.label:Destroy()
		if t.img then
			t.img:Destroy()
		end
	end
	table.clear(self.tiles)
end

--- Show map `map` (W / H + tile_bytes, or the legacy Earth): builds the terrain (yields between
--- slices when it may) and the image tiles. Territory is drawn once a state is bound.
function MapSurface.set_map(self: MapSurface, map: any)
	if self.map == map and self.ready then
		return
	end
	self.ready = false
	self:_free_tiles()
	self.map = map
	local W = map.W or map.width or Defs.W
	local H = map.H or map.height or Defs.H
	self.W, self.H, self.N = W, H, W * H
	self._queued = buffer.create(W * H)
	table.clear(self._queue)
	self._queue_n, self._queue_head = 0, 1
	self:_drop_changes()
	local function yield()
		if coroutine.isyieldable() then
			task.wait()
		end
	end
	local of: buffer = map.tile_bytes or MapSurface.legacy_of_bytes(map, yield)
	--- terrain byte per tile (bit7 land, bit6 shoreline, bit5 ocean, bits0-4 magnitude)
	self.tile_bytes = of
	local N = W * H
	local terrain = buffer.create(N * 4)
	for i = 0, N - 1 do
		writeu32(terrain, i * 4, MapSurface.terrain_pixel(readu8(of, i)))
		if i % 262144 == 262143 then
			yield()
		end
	end
	self.terrain = terrain
	local comp = buffer.create(N * 4)
	buffer.copy(comp, 0, terrain, 0, N * 4)
	self.comp = comp
	self.defended = buffer.create(N)
	-- image tiles: an even split into pieces of at most IMAGE_MAX per side
	local cols = math.ceil(W / MapSurface.IMAGE_MAX)
	local rows = math.ceil(H / MapSurface.IMAGE_MAX)
	local tw, th = math.ceil(W / cols), math.ceil(H / rows)
	self.cols, self.rows, self.tile_w, self.tile_h = cols, rows, tw, th
	local all_ok = true
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local x0, y0 = c * tw, r * th
			local w, h = math.min(tw, W - x0), math.min(th, H - y0)
			local img = create_image(w, h)
			all_ok = all_ok and img ~= nil
			local l = Instance.new("ImageLabel")
			l.Name = string.format("Map_%d_%d", c, r)
			l.BackgroundColor3 = MapSurface.BACKGROUND
			l.BackgroundTransparency = if img then 1 else 0
			l.BorderSizePixel = 0
			l.ResampleMode = Enum.ResamplerMode.Pixelated
			l.ScaleType = Enum.ScaleType.Stretch
			l.Active = false
			l.ZIndex = 1
			if img then
				l.ImageContent = Content.fromObject(img)
			end
			l.Parent = self.root
			local nb = math.ceil(h / BAND_ROWS)
			local t: ImgTile = {
				x0 = x0,
				y0 = y0,
				w = w,
				h = h,
				img = img,
				label = l,
				bands = table.create(nb, true),
				dirty = true,
				scratch = buffer.create(w * BAND_ROWS * 4),
			}
			table.insert(self.tiles, t)
		end
	end
	self.ok = all_ok
	if not all_ok then
		warn("[RoWorld] map: EditableImage unavailable (memory budget) — parts of the map cannot be drawn")
	end
	self.ready = true
	if self._state ~= nil then
		self:rebuild_all()
	end
end

--- Place the image tiles for camera `cam` (MapCamera), edges snapped to whole px so neighbouring
--- tiles meet without seams.
function MapSurface.layout(self: MapSurface, cam: any)
	local vp = cam._vp
	for _, t in self.tiles do
		local sx0, sy0 = cam:map_to_screen(t.x0, t.y0)
		local sx1, sy1 = cam:map_to_screen(t.x0 + t.w, t.y0 + t.h)
		sx0, sy0, sx1, sy1 = math.round(sx0), math.round(sy0), math.round(sx1), math.round(sy1)
		local l = t.label
		local vis = sx1 > 0 and sy1 > 0 and sx0 < vp.X and sy0 < vp.Y
		if l.Visible ~= vis then
			l.Visible = vis
		end
		if vis then
			local pos = UDim2.fromOffset(sx0, sy0)
			local size = UDim2.fromOffset(sx1 - sx0, sy1 - sy0)
			if l.Position ~= pos then
				l.Position = pos
			end
			if l.Size ~= size then
				l.Size = size
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Territory
-- ---------------------------------------------------------------------------------------------

function MapSurface.bind(self: MapSurface, state: any)
	self._state = state
	self._own = if state then state.owner else nil
	self._flags = if state then state.flags else nil
	self._skins = {}
	self:_load_skins(nil)
	table.clear(self._bbox)
	if buffer.len(self.defended) > 0 then
		buffer.fill(self.defended, 0, 0)
	end
	self.hover = 0
	(self :: any)._hover_fill = false
	self:refresh_palette()
	self:rebuild_all()
end

function MapSurface.unbind(self: MapSurface)
	self._state = nil
	self._own = nil
	self._flags = nil
end

--- Territory skins (Data/Cosmetics): owner → { mask, w, h, scale, skin, fill2, fill2_hi }. `ids`: the
--- owners to (re)load (nil: every owner with cosmetics). Colours follow in refresh_palette.
function MapSurface._load_skins(self: any, ids: { number }?)
	local st = self._state
	if st == nil then
		return
	end
	local list = ids
	if list == nil then
		list = {}
		for id in st.cosmetics or {} do
			table.insert(list, id)
		end
	end
	for _, id in list do
		local c = (st.cosmetics or {})[id]
		local skin = if c ~= nil then Cosmetics.item(c.skin) else nil
		if skin == nil or skin.kind ~= "skin" then
			self._skins[id] = nil
		else
			local cur = self._skins[id]
			if cur == nil or cur.skin ~= skin then
				local mask, w, h = Cosmetics.mask(skin)
				self._skins[id] = {
					mask = mask,
					w = w,
					h = h,
					scale = skin.scale or 0,
					skin = skin,
					fill2 = 0,
					fill2_hi = 0,
					-- (a skin with several colours: mask byte k -> fills[k]; refresh_palette packs them)
					fills = if skin.colors ~= nil then {} else nil,
					fills_hi = if skin.colors ~= nil then {} else nil,
				}
			end
		end
	end
end

--- Owners' skins changed (GameState.cosmetics_changed): their land repaints.
function MapSurface.on_cosmetics_changed(self: any, ids: { number })
	self:_load_skins(ids)
	self:refresh_palette()
	for _, id in ids do
		self:repaint_owner(id)
	end
end

--- Recompute every owner's fill / border colours (owner added, alliance change).
function MapSurface.refresh_palette(self: MapSurface)
	local st = self._state
	if st == nil then
		return
	end
	local sat = MapSurface.SATURATION
	local alpha = MapSurface.TERRITORY_ALPHA
	local hi_k = 1.0 + MapSurface.HIGHLIGHT_BRIGHTEN
	for id, o in st.owners do
		if id <= 0 or id >= MAX_OWNERS then
			continue
		end
		local r, g, b
		local c = o.color
		if typeof(c) == "Color3" then
			r, g, b = c.R, c.G, c.B
		else
			r, g, b = Defs.rgba_floats(o.rgba or 0x999999FF)
		end
		local fr, fg, fb = saturate(r, g, b, sat)
		writeu32(self.pal_fill, id * 4, pack(fr * 255, fg * 255, fb * 255, alpha))
		writeu32(
			self.pal_fill_hi,
			id * 4,
			pack(contrast(fr, hi_k) * 255, contrast(fg, hi_k) * 255, contrast(fb, hi_k) * 255, alpha)
		)
		local sk = (self :: any)._skins and (self :: any)._skins[id]
		if sk ~= nil and sk.fills ~= nil then
			local a2 = Cosmetics.skin_alpha(sk.skin)
			for k = 1, #sk.skin.colors do
				local sr, sg, sb = Cosmetics.color(sk.skin, k)
				sk.fills[k] = pack((sr :: number) * 255, (sg :: number) * 255, (sb :: number) * 255, a2)
				sk.fills_hi[k] = pack(
					contrast(sr :: number, hi_k) * 255,
					contrast(sg :: number, hi_k) * 255,
					contrast(sb :: number, hi_k) * 255,
					a2
				)
			end
		elseif sk ~= nil then
			local a2 = Cosmetics.SECONDARY_ALPHA
			local sr, sg, sb = Cosmetics.secondary(sk.skin, fr, fg, fb)
			sk.fill2 = pack(sr * 255, sg * 255, sb * 255, a2)
			sk.fill2_hi = pack(contrast(sr, hi_k) * 255, contrast(sg, hi_k) * 255, contrast(sb, hi_k) * 255, a2)
		end
		local br, bg, bb = darken(r, g, b, MapSurface.BORDER_DARKEN)
		local function border(hl: boolean, ally: boolean): number
			local x, y, z = br, bg, bb
			if hl then
				local t = MapSurface.HIGHLIGHT_BRIGHTEN
				x, y, z = x + (1 - x) * t, y + (1 - y) * t, z + (1 - z) * t
			end
			if ally then
				local t = MapSurface.FRIENDLY_TINT
				x, y, z = x * (1 - t), y + (1 - y) * t, z * (1 - t)
			end
			return pack(x * 255, y * 255, z * 255, 255)
		end
		writeu32(self.pal_border, id * 4, border(false, false))
		writeu32(self.pal_border_hi, id * 4, border(true, false))
		writeu32(self.pal_border_ally, id * 4, border(false, true))
		writeu32(self.pal_border_ally_hi, id * 4, border(true, true))
	end
end

local function dim(c: number, k: number): number
	local r = c % 256
	local g = (c // 256) % 256
	local b = (c // 65536) % 256
	local a = c // 16777216
	return math.floor(r * k) + math.floor(g * k) * 256 + math.floor(b * k) * 65536 + a * 16777216
end

--- Territory overlay RGBA of tile i (alpha 0 = terrain only).
function MapSurface.tile_pixel(self: MapSurface, i: number): number
	local own = self._own :: buffer
	local flags = self._flags :: buffer
	local W, N = self.W, self.N
	local x = i % W
	if band(readu8(flags, i), F_FALLOUT) ~= 0 then
		-- stale-nuke ground: (0.05, 0.55, 0.07) + hash noise * 0.05, opaque
		local y = i // W
		local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
		h -= math.floor(h)
		local nz = h * 0.05
		return pack((0.05 + nz) * 255, (0.55 + nz) * 255, (0.07 + nz) * 255, 255)
	end
	local o = readi32(own, i * 4)
	if o <= 0 or o >= MAX_OWNERS then
		return 0
	end
	local nw = if x > 0 then readi32(own, (i - 1) * 4) else -1
	local ne = if x < W - 1 then readi32(own, (i + 1) * 4) else -1
	local nn = if i >= W then readi32(own, (i - W) * 4) else -1
	local ns = if i < N - W then readi32(own, (i + W) * 4) else -1
	local hl = o == self.hover
	local border = nw ~= o or ne ~= o or nn ~= o or ns ~= o
	if not border and hl then
		-- highlight thicken: Chebyshev distance 1 (the diagonals; never off the map here)
		border = readi32(own, (i - W - 1) * 4) ~= o
			or readi32(own, (i - W + 1) * 4) ~= o
			or readi32(own, (i + W - 1) * 4) ~= o
			or readi32(own, (i + W + 1) * 4) ~= o
	end
	local def = readu8(self.defended, i) ~= 0
	if border then
		local st = self._state
		-- (four tests, not a loop over a table of the four: a table a border tile was garbage)
		local ally = st ~= nil
			and (
				(nw > 0 and nw ~= o and st:are_allies(o, nw))
				or (ne > 0 and ne ~= o and st:are_allies(o, ne))
				or (nn > 0 and nn ~= o and st:are_allies(o, nn))
				or (ns > 0 and ns ~= o and st:are_allies(o, ns))
			)
		local c
		if ally then
			c = readu32(if hl then self.pal_border_ally_hi else self.pal_border_ally, o * 4)
		else
			c = readu32(if hl then self.pal_border_hi else self.pal_border, o * 4)
		end
		if def and (x + i // W) % 2 == 1 then
			c = dim(c, MapSurface.DEFENSE_CHECKER_DARKEN)
		end
		return c
	end
	local c
	local hl_fill = hl and (self :: any)._hover_fill == true
	local sk = (self :: any)._skins[o]
	if sk ~= nil then
		-- a territory skin: the mask's secondary tiles (a non-zero mask byte)
		local mx = bit32.rshift(x, sk.scale) % sk.w
		local my = bit32.rshift(i // W, sk.scale) % sk.h
		local k = readu8(sk.mask, my * sk.w + mx)
		if k ~= 0 then
			local fills = sk.fills
			if fills ~= nil then
				-- (several colours: a key past the list falls back to the owner's fill below)
				c = if hl_fill then sk.fills_hi[k] else fills[k]
			else
				c = if hl_fill then sk.fill2_hi else sk.fill2
			end
		end
	end
	if c == nil then
		c = readu32(if hl_fill then self.pal_fill_hi else self.pal_fill, o * 4)
	end
	if def then
		c = dim(c, MapSurface.DEFENSE_FILL_DARKEN)
	end
	return c
end

--- Composite tile i (terrain under its overlay) into the image buffer.
local function composite(self: MapSurface, i: number)
	local over = self:tile_pixel(i)
	local a = over // 16777216
	local k = i * 4
	if a == 0 then
		writeu32(self.comp, k, readu32(self.terrain, k))
	elseif a == 255 then
		writeu32(self.comp, k, over)
	else
		local t = readu32(self.terrain, k)
		local f = a / 255
		local g = 1 - f
		local r = (t % 256) * g + (over % 256) * f
		local gg = ((t // 256) % 256) * g + ((over // 256) % 256) * f
		local b = ((t // 65536) % 256) * g + ((over // 65536) % 256) * f
		writeu32(
			self.comp,
			k,
			math.floor(r + 0.5) + math.floor(gg + 0.5) * 256 + math.floor(b + 0.5) * 65536 + 4278190080
		)
	end
end

local function mark(self: MapSurface, x: number, y: number)
	local tw, th = self.tile_w, self.tile_h
	local t = self.tiles[(y // th) * self.cols + (x // tw) + 1]
	if t then
		t.bands[(y - t.y0) // BAND_ROWS + 1] = true
		t.dirty = true
	end
end

--- Repaints queue[head .. last] (step()). The same picture as composite() for every tile, and for
--- most of them without its calls: a tile with no fallout, no skin, no defense post near and not the
--- skin is nobody's (the terrain), a border (its colour) or a fill (blended over the terrain), from
--- buffers held in locals. The others go through composite().
local function paint_queue(self: MapSurface, head: number, last: number)
	local queue, queued = self._queue, self._queued
	local own = self._own :: buffer
	local flags = self._flags :: buffer
	local comp, terrain = self.comp, self.terrain
	local pal_fill, pal_border, pal_border_ally = self.pal_fill, self.pal_border, self.pal_border_ally
	local pal_fill_hi, pal_border_hi, pal_border_ally_hi = self.pal_fill_hi, self.pal_border_hi, self.pal_border_ally_hi
	local hover_fill = (self :: any)._hover_fill == true
	local W, N = self.W, self.N
	local W4 = W * 4
	-- (each buffer read below is a cache miss on a map this size, which is most of a tile's cost:
	-- the fallout flags are not read while the state has no fallout anywhere)
	local st0 = self._state
	local fallout = st0 == nil or (tonumber(st0.fallout_count) or 1) > 0
	local hover = self.hover
	local skins = (self :: any)._skins
	local st = self._state
	local alliances = if st ~= nil then st.alliances else nil
	if alliances ~= nil and next(alliances) == nil then
		alliances = nil
	end
	local tiles, tw, th, cols = self.tiles, self.tile_w, self.tile_h, self.cols
	for q = head, last do
		local i = queue[q]
		writeu8(queued, i, 0)
		local k = i * 4
		local o = readi32(own, k)
		local x = i % W
		local y = i // W
		if (fallout and band(readu8(flags, i), F_FALLOUT) ~= 0) or o >= MAX_OWNERS or (o > 0 and skins[o] ~= nil) then
			composite(self, i)
		elseif o <= 0 then
			writeu32(comp, k, readu32(terrain, k))
		else
			local nw = if x > 0 then readi32(own, k - 4) else -1
			local ne = if x < W - 1 then readi32(own, k + 4) else -1
			local nn = if i >= W then readi32(own, k - W4) else -1
			local ns = if i < N - W then readi32(own, k + W4) else -1
			local hl = o == hover
			local border = nw ~= o or ne ~= o or nn ~= o or ns ~= o
			if not border and hl then
				-- the hovered owner's border is a tile thicker (the diagonals; never off the map here)
				border = readi32(own, k - W4 - 4) ~= o
					or readi32(own, k - W4 + 4) ~= o
					or readi32(own, k + W4 - 4) ~= o
					or readi32(own, k + W4 + 4) ~= o
			end
			if border then
				local pal = if hl then pal_border_hi else pal_border
				if
					alliances ~= nil
					and (
						(nw > 0 and nw ~= o and alliances[math.min(o, nw) * 1024 + math.max(o, nw)] == true)
						or (ne > 0 and ne ~= o and alliances[math.min(o, ne) * 1024 + math.max(o, ne)] == true)
						or (nn > 0 and nn ~= o and alliances[math.min(o, nn) * 1024 + math.max(o, nn)] == true)
						or (ns > 0 and ns ~= o and alliances[math.min(o, ns) * 1024 + math.max(o, ns)] == true)
					)
				then
					pal = if hl then pal_border_ally_hi else pal_border_ally
				end
				-- (a border is opaque)
				writeu32(comp, k, readu32(pal, o * 4))
			else
				local over = readu32(if hl and hover_fill then pal_fill_hi else pal_fill, o * 4)
				local a = over // 16777216
				if a == 0 then
					writeu32(comp, k, readu32(terrain, k))
				elseif a == 255 then
					writeu32(comp, k, over)
				else
					local t = readu32(terrain, k)
					local f = a / 255
					local g = 1 - f
					local r = (t % 256) * g + (over % 256) * f
					local gg = ((t // 256) % 256) * g + ((over // 256) % 256) * f
					local b = ((t // 65536) % 256) * g + ((over // 65536) % 256) * f
					writeu32(
						comp,
						k,
						math.floor(r + 0.5) + math.floor(gg + 0.5) * 256 + math.floor(b + 0.5) * 65536 + 4278190080
					)
				end
			end
		end
		local t = tiles[(y // th) * cols + (x // tw) + 1]
		if t then
			t.bands[(y - t.y0) // BAND_ROWS + 1] = true
			t.dirty = true
		end
	end
end

local function grow_bbox(self: MapSurface, o: number, x: number, y: number)
	if o <= 0 then
		return
	end
	local b = self._bbox[o]
	if b == nil then
		self._bbox[o] = { x, y, x, y }
		return
	end
	if x < b[1] then
		b[1] = x
	end
	if x > b[3] then
		b[3] = x
	end
	if y < b[2] then
		b[2] = y
	end
	if y > b[4] then
		b[4] = y
	end
end

--- Repaint tile i and its 8 neighbours (border state and highlight thickening depend on them).
function MapSurface.paint_around(self: MapSurface, i: number)
	if self._own == nil or not self.ready then
		return
	end
	local W, H = self.W, self.H
	local x = i % W
	local y = i // W
	for dy = -1, 1 do
		local yy = y + dy
		if yy < 0 or yy >= H then
			continue
		end
		for dx = -1, 1 do
			local xx = x + dx
			if xx >= 0 and xx < W then
				composite(self, yy * W + xx)
				mark(self, xx, yy)
			end
		end
	end
end

--- GameState.tiles_changed: { tile * 1024 + owner } (new owners), and the owners those tiles had.
--- The tiles whose look may have changed are queued for step() to repaint, each once:
---   * the tile itself;
---   * a 4-neighbour of the old or the new owner (it gains or loses a border), or of an ally of
---     either (its border changes colour). A neighbour of anybody else was a border and still is,
---     and nobody's land has no overlay;
---   * a diagonal neighbour of the hovered owner (its border is thickened by one tile).
--- Without `olds`: the tile and its 8 neighbours.
function MapSurface.on_tiles_changed(self: MapSurface, changed: { number }, olds: { number }?)
	if self._own == nil or not self.ready then
		return
	end
	-- recorded here, looked at in step() within its time budget (_expand_changes; GameState reuses
	-- these lists, so they are copied)
	local pend = self._pend
	local n = self._pend_n
	for k, packed in changed do
		n += 1
		pend[n] = packed
		n += 1
		pend[n] = if olds ~= nil then olds[k] else -1
	end
	self._pend_n = n
end

--- GameState.flags_changed: { tile * 256 + flags }.
function MapSurface.on_flags_changed(self: MapSurface, changed: { number })
	if self._own == nil or not self.ready then
		return
	end
	local queue, queued = self._queue, self._queued
	local n = self._queue_n
	for _, packed in changed do
		local t = packed // 256
		if readu8(queued, t) == 0 then
			writeu8(queued, t, 1)
			n += 1
			queue[n] = t
		end
	end
	self._queue_n = n
end

--- Tiles waiting for a repaint (and one for every owner whose tiles are still being found).
function MapSurface.repaint_pending(self: MapSurface): number
	if self._pend_n > 0 then
		self:_expand_changes(math.huge) -- (what was recorded and not yet looked at)
	end
	return self._queue_n - self._queue_head + 1 + #self._sweeps
end

--- Redraw every tile (bind, palette-wide changes); sliced over frames by step().
function MapSurface.rebuild_all(self: MapSurface)
	self._rebuild_i = 0
	self._rebuild_active = self._own ~= nil and self.ready
	table.clear(self._bbox)
	self:_drop_changes() -- (every tile is about to be painted, and the boxes found again)
	-- (every tile is about to be painted: nothing needs to wait for it)
	if self._queue_n > 0 then
		buffer.fill(self._queued, 0, 0)
		table.clear(self._queue)
		self._queue_n, self._queue_head = 0, 1
	end
	table.clear(self._sweeps)
end

--- Repaint every tile of `owner` (a palette change for one owner): found a slice a frame and
--- repainted through the queue (step).
function MapSurface.repaint_owner(self: MapSurface, owner: number)
	self._pend_wide_to = self._pend_n
	self:_sweep(owner, true)
end

--- `owner`'s tiles are to be repainted: all of them (`fill`), or its border and the tiles next to it
--- (what a hover changes of an owner too big for a brightened fill).
function MapSurface._sweep(self: MapSurface, owner: number, fill: boolean)
	if owner <= 0 or self._own == nil or not self.ready or self._bbox[owner] == nil then
		return
	end
	for _, job in self._sweeps do
		if job.owner == owner and job.other == nil then
			-- (already being looked for: from the top again, with the wider of the two asks)
			job.fill = job.fill or fill
			job.y = -1
			return
		end
	end
	table.insert(self._sweeps, { owner = owner, fill = fill, y = -1 })
end

--- An alliance between `a` and `b` formed or ended: the tiles of each next to the other's (their
--- border's green, paint_queue). They can only be where the two owners' boxes overlap: two allies
--- with no border between them repaint nothing.
---   * Until 2026-10-10 an alliance repainted every tile of both owners (repaint_owner).
function MapSurface.repaint_between(self: MapSurface, a: number, b: number)
	if a <= 0 or b <= 0 or a == b or self._own == nil or not self.ready then
		return
	end
	-- (the tile changes not yet looked at were made under the alliances before this one)
	self._pend_wide_to = self._pend_n
	if self._bbox[a] == nil or self._bbox[b] == nil then
		return
	end
	local lo, hi = math.min(a, b), math.max(a, b)
	for _, job in self._sweeps do
		if job.owner == lo and job.other == hi then
			job.y = -1
			return
		end
	end
	table.insert(self._sweeps, { owner = lo, fill = false, y = -1, other = hi })
end

local clock = os.clock

--- Looks at the changes on_tiles_changed recorded: each changed tile, and those of its neighbours whose
--- look the change may have altered, wait for a repaint (paint_queue). At least `min_pairs` changes,
--- then more until `deadline`. (Done in the call until 2026-10-12: a solo match's tick changes about
--- 2,000 tiles in its first minute, and this was 70% of applying the tick, 1.3 ms on a Mac and about
--- ten times that on a phone, in the frame the tick landed.)
--- Records already looked at (or tiles already repainted) are dropped once there are more than
--- COMPACT_MIN of them and they outnumber the ones still waiting. The lists were only emptied when a
--- step got through all of them, and a device that never quite caught up in a busy match kept every
--- change of the match until it ran out of memory ("not enough memory" in on_tiles_changed, 1,149 in a
--- day on v84, 2026-10-14). The waiting ones move to a new list, so the old one's memory is freed.
MapSurface.COMPACT_MIN = 32768

local function compact_pend(self: MapSurface)
	local p, n = self._pend_i, self._pend_n
	if p <= MapSurface.COMPACT_MIN or p - 1 < n - p + 1 then
		return
	end
	self._pend = table.move(self._pend, p, n, 1, table.create(n - p + 1))
	self._pend_n = n - p + 1
	self._pend_i = 1
	self._pend_wide_to = math.max(0, self._pend_wide_to - (p - 1))
end

local function compact_queue(self: MapSurface)
	local h, n = self._queue_head, self._queue_n
	if h <= MapSurface.COMPACT_MIN or h - 1 < n - h + 1 then
		return
	end
	self._queue = table.move(self._queue, h, n, 1, table.create(n - h + 1))
	self._queue_n = n - h + 1
	self._queue_head = 1
end

function MapSurface._expand_changes(self: MapSurface, deadline: number, min_pairs: number?)
	local own = self._own
	if own == nil or not self.ready then
		self:_drop_changes()
		return
	end
	local pend = self._pend
	local pend_n = self._pend_n
	local p = self._pend_i
	local must = p + 2 * (min_pairs or 0)
	local wide_to = self._pend_wide_to
	local W, H = self.W, self.H
	local queue, queued = self._queue, self._queued
	local n = self._queue_n
	local hover = self.hover
	local st = self._state
	local alliances = if st ~= nil then st.alliances else nil
	if alliances ~= nil and next(alliances) == nil then
		alliances = nil
	end
	while p < pend_n do
		if p >= must and (p // 2) % 256 == 0 and clock() >= deadline then
			break
		end
		local packed = pend[p]
		local a = pend[p + 1]
		local wide = p <= wide_to
		p += 2
		local t = packed // 1024
		local b = packed % 1024
		local x = t % W
		local y = t // W
		grow_bbox(self, b, x, y)
		if a < 0 then
			local x0, x1 = if x > 0 then x - 1 else x, if x < W - 1 then x + 1 else x
			for yy = if y > 0 then y - 1 else y, if y < H - 1 then y + 1 else y do
				local row = yy * W
				for i = row + x0, row + x1 do
					if readu8(queued, i) == 0 then
						writeu8(queued, i, 1)
						n += 1
						queue[n] = i
					end
				end
			end
			continue
		end
		if readu8(queued, t) == 0 then
			writeu8(queued, t, 1)
			n += 1
			queue[n] = t
		end
		if a == b then
			continue
		end
		for d = 1, 4 do
			local i
			if d == 1 then
				if x == 0 then
					continue
				end
				i = t - 1
			elseif d == 2 then
				if x == W - 1 then
					continue
				end
				i = t + 1
			elseif d == 3 then
				if y == 0 then
					continue
				end
				i = t - W
			else
				if y == H - 1 then
					continue
				end
				i = t + W
			end
			if readu8(queued, i) ~= 0 then
				continue
			end
			local c = readi32(own, i * 4)
			if c <= 0 then
				continue
			end
			local touched = c == a or c == b or wide
			if not touched and alliances ~= nil then
				touched = (a > 0 and alliances[math.min(a, c) * 1024 + math.max(a, c)] == true)
					or (b > 0 and alliances[math.min(b, c) * 1024 + math.max(b, c)] == true)
			end
			if touched then
				writeu8(queued, i, 1)
				n += 1
				queue[n] = i
			end
		end
		if hover > 0 then
			for dy = -1, 1, 2 do
				local yy = y + dy
				if yy >= 0 and yy < H then
					for dx = -1, 1, 2 do
						local xx = x + dx
						if xx >= 0 and xx < W then
							local i = yy * W + xx
							if readu8(queued, i) == 0 and readi32(own, i * 4) == hover then
								writeu8(queued, i, 1)
								n += 1
								queue[n] = i
							end
						end
					end
				end
			end
		end
	end
	self._queue_n = n
	if p >= pend_n then
		self:_drop_changes()
	else
		self._pend_i = p
		compact_pend(self)
	end
end

function MapSurface._drop_changes(self: MapSurface)
	table.clear(self._pend)
	self._pend_n, self._pend_i, self._pend_wide_to = 0, 1, 0
end

--- step(): looks at SWEEP_SCAN_PER_STEP tiles of the sweeps' boxes and queues the ones to repaint,
--- while the queue holds fewer than `room` tiles and until `deadline` (a row at least).
local function run_sweeps(self: MapSurface, room: number, deadline: number)
	local sweeps = self._sweeps
	local own = self._own :: buffer
	local W, H = self.W, self.H
	local queue, queued = self._queue, self._queued
	local n = self._queue_n
	local pending = n - self._queue_head + 1
	local scan = MapSurface.SWEEP_SCAN_PER_STEP
	local rows = 0
	while #sweeps > 0 and scan > 0 and pending < room and (rows == 0 or clock() < deadline) do
		local job = sweeps[1]
		local owner = job.owner
		local b = self._bbox[owner]
		local other = job.other
		local ob = if other ~= nil then self._bbox[other] else nil
		if b == nil or (other ~= nil and ob == nil) then
			table.remove(sweeps, 1)
			continue
		end
		local y0, y1 = math.max(b[2] - 1, 0), math.min(b[4] + 1, H - 1)
		local x0, x1 = math.max(b[1] - 1, 0), math.min(b[3] + 1, W - 1)
		if ob ~= nil then
			-- (a pair: where the two boxes, a tile wider each, overlap)
			y0, y1 = math.max(y0, ob[2] - 1), math.min(y1, ob[4] + 1)
			x0, x1 = math.max(x0, ob[1] - 1), math.min(x1, ob[3] + 1)
		end
		local y = math.max(job.y, y0)
		local fill = job.fill
		while y <= y1 and x0 <= x1 and scan > 0 and pending < room and (rows == 0 or clock() < deadline) do
			local row = y * W
			rows += 1
			if other ~= nil then
				-- a tile of one with a 4-neighbour of the other's
				for xx = x0, x1 do
					local t = row + xx
					local o = readi32(own, t * 4)
					local want = if o == owner then other else if o == other then owner else 0
					if want ~= 0 and readu8(queued, t) == 0 then
						if
							(xx > 0 and readi32(own, (t - 1) * 4) == want)
							or (xx < W - 1 and readi32(own, (t + 1) * 4) == want)
							or (y > 0 and readi32(own, (t - W) * 4) == want)
							or (y < H - 1 and readi32(own, (t + W) * 4) == want)
						then
							writeu8(queued, t, 1)
							n += 1
							queue[n] = t
							pending += 1
						end
					end
				end
			elseif fill then
				for xx = x0, x1 do
					local t = row + xx
					if readu8(queued, t) == 0 and readi32(own, t * 4) == owner then
						writeu8(queued, t, 1)
						n += 1
						queue[n] = t
						pending += 1
					end
				end
			else
				-- A border, or next to one (the hovered border is a tile thicker): a tile of the
				-- owner with a neighbour of the 8 that is somebody else's or off the map. Three reads
				-- a column: each row's last three tiles are three bits (1: the owner's), and the
				-- tile behind the column being read is inside when all nine are set.
				local up = if y > 0 then row - W else -1
				local dn = if y < H - 1 then row + W else -1
				local bu, bm, bd = 0, 0, 0
				for xx = math.max(x0 - 1, 0), math.min(x1 + 1, W - 1) + 1 do
					-- (one column past the last, as nobody's: the last tile is decided too)
					local inside = xx < W
					local mu = if inside and up >= 0 and readi32(own, (up + xx) * 4) == owner then 1 else 0
					local mm = if inside and readi32(own, (row + xx) * 4) == owner then 1 else 0
					local md = if inside and dn >= 0 and readi32(own, (dn + xx) * 4) == owner then 1 else 0
					bu = (bu * 2 + mu) % 8
					bm = (bm * 2 + mm) % 8
					bd = (bd * 2 + md) % 8
					-- the tile at column xx - 1: the owner's (bit 2 of its row), and not inside
					if bm % 4 >= 2 and not (bu == 7 and bm == 7 and bd == 7) then
						local t = row + xx - 1
						if xx - 1 >= x0 and xx - 1 <= x1 and readu8(queued, t) == 0 then
							writeu8(queued, t, 1)
							n += 1
							queue[n] = t
							pending += 1
						end
					end
				end
			end
			scan -= x1 - x0 + 1
			y += 1
		end
		job.y = y
		if y > y1 or x0 > x1 then
			table.remove(sweeps, 1)
		end
	end
	self._queue_n = n
end

--- Hovered owner (0 = none): the highlight (the border; the fill too for an owner of
--- HOVER_FILL_MAX tiles or fewer). Costs nothing here: the tiles are repainted by step().
function MapSurface.set_hover(self: MapSurface, owner: number)
	if owner == self.hover then
		return
	end
	local old, old_fill = self.hover, (self :: any)._hover_fill == true
	self.hover = owner
	local st = self._state
	local o = if st ~= nil and owner > 0 and st.owners ~= nil then st.owners[owner] else nil
	local fill = o ~= nil and (tonumber(o.tiles) or 0) <= MapSurface.HOVER_FILL_MAX;
	(self :: any)._hover_fill = fill
	if old > 0 then
		self:_sweep(old, old_fill)
	end
	if owner > 0 then
		self:_sweep(owner, fill)
	end
end

--- Mark every band of every image tile for upload.
function MapSurface.mark_all(self: MapSurface)
	for _, t in self.tiles do
		for k = 1, #t.bands do
			t.bands[k] = true
		end
		t.dirty = true
	end
end

--- Per-frame work: continue a full rebuild, repaint the tiles that wait for it (`budget_s`; at most
--- `repaint_tiles`, default REPAINT_TILES_PER_STEP), look for the sweeps' tiles in the time left, then
--- upload the dirty bands of ONE image tile (round-robin: Roblox shows one EditableImage update per
--- frame).
function MapSurface.step(self: MapSurface, budget_tiles: number?, repaint_tiles: number?)
	-- (whether this frame wrote an image: Map/FalloutGlow's waits for a frame that did not)
	self.uploaded = false
	if not self.ready then
		return
	end
	local own = self._own
	local W, N = self.W, self.N
	local repaint = repaint_tiles or MapSurface.REPAINT_TILES_PER_STEP
	local deadline = clock() + self.budget_s
	if self._pend_n > 0 then
		-- (a share whatever the clock says, so what waits never falls far behind)
		local waiting = (self._pend_n - self._pend_i + 1) // 2
		self:_expand_changes(
			deadline,
			math.max(math.ceil(waiting / MapSurface.DRAIN_FRAMES), MapSurface.EXPAND_MIN_CHANGES)
		)
	end
	local qn = self._queue_n
	if qn > 0 and own ~= nil then
		local head = self._queue_head
		local cap = math.min(qn, head + repaint - 1)
		-- (what waits gets its share whatever the clock says, so the picture never falls far behind)
		local share = math.max(math.ceil((qn - head + 1) / MapSurface.DRAIN_FRAMES), MapSurface.REPAINT_MIN_TILES)
		local last = math.min(cap, head + share - 1)
		paint_queue(self, head, last)
		while last < cap and clock() < deadline do
			local from = last + 1
			last = math.min(cap, last + MapSurface.REPAINT_CHUNK)
			paint_queue(self, from, last)
		end
		if last >= qn then
			table.clear(self._queue)
			self._queue_n, self._queue_head = 0, 1
		else
			self._queue_head = last + 1
			compact_queue(self)
		end
	end
	-- (what they find is painted from the next step on)
	if #self._sweeps > 0 and own ~= nil then
		run_sweeps(self, repaint, deadline)
	end
	if self._rebuild_active and own ~= nil then
		local i0 = self._rebuild_i
		local i1 = math.min(N, i0 + (budget_tiles or MapSurface.REBUILD_TILES_PER_STEP))
		for i = i0, i1 - 1 do
			local o = readi32(own, i * 4)
			if o > 0 then
				grow_bbox(self, o, i % W, i // W)
			end
			composite(self, i)
		end
		self._rebuild_i = i1
		if i1 >= N then
			self._rebuild_active = false
			self:mark_all()
		end
	end
	local n = #self.tiles
	for k = 1, n do
		local idx = (self._rr + k - 1) % n + 1
		local t = self.tiles[idx]
		if t.dirty and t.img ~= nil then
			self._rr = idx % n
			t.dirty = false
			local img = t.img :: EditableImage
			local row_bytes = t.w * 4
			for b = 1, #t.bands do
				if t.bands[b] then
					t.bands[b] = false
					local ly0 = (b - 1) * BAND_ROWS
					local rows = math.min(BAND_ROWS, t.h - ly0)
					local scratch = t.scratch
					if rows < BAND_ROWS then
						scratch = buffer.create(t.w * rows * 4)
					end
					for r = 0, rows - 1 do
						buffer.copy(scratch, r * row_bytes, self.comp, ((t.y0 + ly0 + r) * W + t.x0) * 4, row_bytes)
					end
					img:WritePixelsBuffer(Vector2.new(0, ly0), Vector2.new(t.w, rows), scratch)
				end
			end
			self.uploaded = true
			return
		end
	end
end

--- Show the bare terrain (title screen between worlds).
function MapSurface.clear(self: MapSurface)
	if not self.ready then
		return
	end
	buffer.copy(self.comp, 0, self.terrain, 0, self.N * 4)
	self:mark_all()
end

function MapSurface.destroy(self: MapSurface)
	self:_free_tiles()
	self.root:Destroy()
end

return MapSurface
