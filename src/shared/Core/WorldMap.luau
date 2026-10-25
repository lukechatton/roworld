--!native
-- A playable map: static geography — terrain codes, water bodies, coasts and the flat grid
-- geometry every system uses. Maps are imported by tools/maps/import_maps.py (data CC BY-SA 4.0,
-- credited in MapList.CREDITS): WorldMap.from_terrain(data) builds one from a data module,
-- WorldMap.get(id) returns the shared instance of a map id (built once per process),
-- WorldMap.shared() the default map (MapList.DEFAULT, "world").
--
-- Geometry: a flat W x H grid, no wrap; tile i = y * W + x (0-based);
-- neighbours are the 4 orthogonal tiles inside the map (our order: west, east, north, south);
-- distances are the squared euclidean distance (dist2 / range_d2) and the manhattan distance
-- (geo_manhattan) in tiles. The functions are closures stored on the map (map.dist2(a, b), no
-- ':'), so hot code captures them in locals; several maps may live in one process.
--
-- Scale: one of our tiles is `k_lin` full-resolution full-size tiles across (1.0 unless the
-- importer resampled the map to its tile budget); Rules.for_map(map) scales the rules' constants.
--
-- Representation (all 0-based by tile, read-only once built):
--   tile_bytes    u8  the full-size tile byte: bit 7 land, bit 6 shoreline, bit 5 ocean (water),
--                   bits 0-4 magnitude (land 0-30 elevation, 31 with no other bits = impassable;
--                   water min(ceil(dist to land / 2), 31) in full-res full-size tiles)
--   terrain     u8  Defs.T_* code: T_OCEAN (ocean bit) / T_LAKE water, T_PLAINS (< 10),
--                   T_HIGHLAND (10-19), T_MOUNTAIN (20-30) land, T_ICECAP impassable
--   land        u8  1 on contestable land (plains / highland / mountain)
--   water_body  u16 0 on land, 1 = the ocean (largest body), 2.. other 4-connected water bodies
--   coastal     u8  1 on contestable land 4-adjacent to water
--   coast_body  u16 the water body a coastal tile touches (first of west, east, north, south)
--   land_list / coast_list  i32 buffers of tile indices (land_count / coast_count entries)
--   nations     1-based {name, flag, x, y, tile} (tile -1 = no coordinates: random spawn)
local Defs = require("./Defs")
local MapCodec = require("./MapCodec")
local MapList = require("../Data/MapList")
local Tribes = require("../Data/Tribes")
local Coop = require("../Net/Coop")

local T_OCEAN = Defs.T_OCEAN
local T_LAKE = Defs.T_LAKE
local T_PLAINS = Defs.T_PLAINS
local T_HIGHLAND = Defs.T_HIGHLAND
local T_MOUNTAIN = Defs.T_MOUNTAIN
local T_ICECAP = Defs.T_ICECAP

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local readi32 = buffer.readi32
local writei32 = buffer.writei32

local WorldMap = {}
WorldMap.__index = WorldMap

-- The ModuleScript in Roblox (nil under Lune).
local RBX_SCRIPT: any = script

--- Full-size tile byte of impassable terrain.
WorldMap.TB_IMPASSABLE = 0x9F

export type WorldMap = typeof(setmetatable(
	{} :: {
		id: string,
		name: string,
		W: number,
		H: number,
		N: number,
		k_lin: number,
		k_area: number,
		--- build size relative to the map's data (1, or < 1 for a smaller build: "id@80")
		scale: number,
		tile_bytes: buffer,
		terrain: buffer,
		land: buffer,
		water_body: buffer,
		water_body_count: number,
		coastal: buffer,
		coast_body: buffer,
		land_list: buffer,
		land_count: number,
		coast_list: buffer,
		coast_count: number,
		contestable_count: number,
		nations: { any },
		meta: { [string]: any },
		dist2: (number, number) -> number,
		range_d2: (number, number) -> number,
		geo_manhattan: (number, number) -> number,
		geo_span: (number, number) -> number,
		gc_dist: (number, number) -> number,
		ok: boolean,
	},
	WorldMap
))

-- =============================================================================================
-- Construction
-- =============================================================================================

--- Installs the flat grid metrics (closures over W) on `m`.
local function install_geometry(m: any)
	local W = m.W
	local W1 = W - 1
	--- Squared euclidean distance in tiles.
	local function dist2(a: number, b: number): number
		local dx = a % W - b % W
		local dy = a // W - b // W
		return dx * dx + dy * dy
	end
	--- Manhattan distance in tiles.
	local function manhattan(a: number, b: number): number
		local dx = a % W - b % W
		if dx < 0 then
			dx = -dx
		end
		local dy = a // W - b // W
		if dy < 0 then
			dy = -dy
		end
		return dx + dy
	end
	--- Columns a box query around a tile must span to cover a radius of `r` tiles.
	local function span(_center: number, r: number): number
		local s = math.ceil(r)
		return if s > W1 then W1 else s
	end
	--- Straight-line distance in tiles.
	local function dist(a: number, b: number): number
		local dx = a % W - b % W
		local dy = a // W - b // W
		return math.sqrt(dx * dx + dy * dy)
	end
	m.dist2 = dist2
	m.range_d2 = dist2
	m.geo_manhattan = manhattan
	m.geo_span = span
	m.gc_dist = dist
	m.tile_distance = dist
end

--- An empty W x H map (all water) with its geometry; fill tile_bytes and call _derive().
function WorldMap.new(w: number, h: number): WorldMap
	local n = w * h
	local self = setmetatable({
		id = "",
		name = "",
		W = w,
		H = h,
		N = n,
		k_lin = 1.0,
		k_area = 1.0,
		scale = 1.0,
		tile_bytes = buffer.create(n),
		terrain = buffer.create(n),
		land = buffer.create(n),
		water_body = buffer.create(n * 2),
		water_body_count = 0,
		coastal = buffer.create(n),
		coast_body = buffer.create(n * 2),
		land_list = buffer.create(0),
		land_count = 0,
		coast_list = buffer.create(0),
		coast_count = 0,
		contestable_count = 0,
		nations = {},
		meta = {},
		ok = false,
	}, WorldMap) :: any
	install_geometry(self)
	return self
end

--- Builds a map from a map data table (a src/server/MapData module, or the same fields
--- fetched from the server): {id, name, width, height, k_lin, nations = {{name, flag, x, y}},
--- terrain = base64(zstd(bytes)) string or a buffer of raw bytes, codec?, ...}.
--- `scale` (< 1): build the map that many times smaller in width and height (public matches play
--- maps a bit smaller; see WorldMap.split_id).
function WorldMap.from_terrain(data: { [string]: any }, scale: number?): WorldMap
	local w0 = data.width
	local h0 = data.height
	assert(type(w0) == "number" and type(h0) == "number" and w0 > 0 and h0 > 0, "WorldMap: bad map size")
	local s = math.clamp(scale or 1.0, 0.25, 1.0)
	local w = if s < 1.0 then math.max(8, math.floor(w0 * s + 0.5)) else w0
	local h = if s < 1.0 then math.max(8, math.floor(h0 * s + 0.5)) else h0
	local m = WorldMap.new(w, h)
	m.id = tostring(data.id or "")
	m.name = tostring(data.name or m.id)
	m.scale = w / w0
	-- a tile of a smaller build covers more full-size tiles
	m.k_lin = (tonumber(data.k_lin) or 1.0) * (w0 / w)
	m.k_area = m.k_lin * m.k_lin
	local meta = {}
	for k, v in data do
		if k ~= "terrain" and k ~= "nations" then
			meta[k] = v
		end
	end
	m.meta = meta
	Coop.check()
	local bytes = MapCodec.terrain_bytes(data)
	if w ~= w0 or h ~= h0 then
		Coop.check()
		bytes = WorldMap._resample(bytes, w0, h0, w, h)
	end
	m.tile_bytes = bytes
	Coop.check()
	m:_derive()
	local nations = {}
	for _, nd in data.nations or {} do
		local x = tonumber(nd.x)
		local y = tonumber(nd.y)
		local tile = -1
		if x ~= nil and y ~= nil then
			x = math.clamp(math.floor(x * w / w0), 0, w - 1)
			y = math.clamp(math.floor(y * h / h0), 0, h - 1)
			tile = y * w + x
		end
		table.insert(nations, { name = tostring(nd.name or "Nation"), flag = nd.flag, x = x, y = y, tile = tile })
	end
	m.nations = nations
	m.ok = true
	return m
end

--- Tile bytes of a w0 x h0 map resampled to w x h (smaller): each tile takes the full-size tile
--- under its centre — elevation and water depth are in full-res full-size tiles, so they stay valid — then the
--- shoreline bit (0x40: land beside water or water beside land) is recomputed for the new grid.
function WorldMap._resample(src: buffer, w0: number, h0: number, w: number, h: number): buffer
	local out = buffer.create(w * h)
	local xs = table.create(w, 0)
	for x = 0, w - 1 do
		xs[x + 1] = math.min(w0 - 1, math.floor((x + 0.5) * w0 / w))
	end
	for y = 0, h - 1 do
		if y % 64 == 0 then
			Coop.check()
		end
		local row = math.min(h0 - 1, math.floor((y + 0.5) * h0 / h)) * w0
		local o = y * w
		for x = 0, w - 1 do
			writeu8(out, o + x, readu8(src, row + xs[x + 1]))
		end
	end
	local function is_land(i: number): boolean
		return readu8(out, i) >= 128
	end
	for y = 0, h - 1 do
		if y % 64 == 0 then
			Coop.check()
		end
		for x = 0, w - 1 do
			local i = y * w + x
			local b = readu8(out, i)
			if b == 0x9F then
				continue -- impassable keeps its byte
			end
			local l = b >= 128
			local shore = (x > 0 and is_land(i - 1) ~= l)
				or (x < w - 1 and is_land(i + 1) ~= l)
				or (y > 0 and is_land(i - w) ~= l)
				or (y < h - 1 and is_land(i + w) ~= l)
			local nb = if shore then bit32.bor(b, 0x40) else bit32.band(b, 0xBF)
			if nb ~= b then
				writeu8(out, i, nb)
			end
		end
	end
	return out
end

--- Map ids can carry a size: "world@80" is map "world" at 80 % of its width and height. The base id
--- and the linear scale (1 without a suffix).
function WorldMap.split_id(id: string): (string, number)
	local base, pct = string.match(id, "^(.-)@(%d+)$")
	if base ~= nil and base ~= "" then
		return base, math.clamp(tonumber(pct) or 100, 25, 100) / 100
	end
	return id, 1.0
end

--- Derives terrain codes, land, water bodies and coasts from tile_bytes.
function WorldMap._derive(self: WorldMap)
	local W, H, N = self.W, self.H, self.N
	local of = self.tile_bytes
	local terrain = self.terrain
	local land = self.land
	-- 1. terrain codes
	local nl = 0
	for i = 0, N - 1 do
		if i % 262144 == 0 then
			Coop.check()
		end
		local b = readu8(of, i)
		local code
		if b < 128 then
			code = if bit32.band(b, 0x20) ~= 0 then T_OCEAN else T_LAKE
		elseif b == 0x9F then
			code = T_ICECAP
		else
			local mag = bit32.band(b, 0x1F)
			code = if mag < 10 then T_PLAINS elseif mag < 20 then T_HIGHLAND else T_MOUNTAIN
			writeu8(land, i, 1)
			nl += 1
		end
		writeu8(terrain, i, code)
	end
	-- 2. water bodies (4-connected flood fill; the ocean-bit body is 1, others 2.. in scan order)
	local body = self.water_body
	local stack = buffer.create(4 * 65536)
	local cap = 65536
	local next_id = 2
	local function fill(start: number, id: number)
		writeu16(body, start * 2, id)
		writei32(stack, 0, start)
		local sp = 1
		while sp > 0 do
			sp -= 1
			local t = readi32(stack, sp * 4)
			local x = t % W
			for k = 1, 4 do
				local u
				if k == 1 then
					if x == 0 then
						continue
					end
					u = t - 1
				elseif k == 2 then
					if x == W - 1 then
						continue
					end
					u = t + 1
				elseif k == 3 then
					if t < W then
						continue
					end
					u = t - W
				else
					if t >= N - W then
						continue
					end
					u = t + W
				end
				if readu8(of, u) < 128 and readu16(body, u * 2) == 0 then
					writeu16(body, u * 2, id)
					if sp >= cap then
						local grown = buffer.create(cap * 8)
						buffer.copy(grown, 0, stack, 0, cap * 4)
						stack = grown
						cap *= 2
					end
					writei32(stack, sp * 4, u)
					sp += 1
				end
			end
		end
	end
	local ocean_done = false
	for i = 0, N - 1 do
		if i % 262144 == 0 then
			Coop.check()
		end
		local b = readu8(of, i)
		if b < 128 and readu16(body, i * 2) == 0 then
			if not ocean_done and bit32.band(b, 0x20) ~= 0 then
				ocean_done = true
				fill(i, 1)
			else
				if next_id > 65535 then
					error("WorldMap: more than 65534 water bodies")
				end
				fill(i, next_id)
				next_id += 1
			end
		end
	end
	self.water_body_count = next_id - 1
	-- 3. land and coast lists
	local land_list = buffer.create(nl * 4)
	local coastal = self.coastal
	local coast_body = self.coast_body
	local coast_tmp = buffer.create(math.max(nl, 1) * 4)
	local li, nc = 0, 0
	for i = 0, N - 1 do
		if i % 262144 == 0 then
			Coop.check()
		end
		if readu8(land, i) == 0 then
			continue
		end
		writei32(land_list, li * 4, i)
		li += 1
		local x = i % W
		local cb = 0
		if x > 0 and readu8(of, i - 1) < 128 then
			cb = readu16(body, (i - 1) * 2)
		end
		if cb == 0 and x < W - 1 and readu8(of, i + 1) < 128 then
			cb = readu16(body, (i + 1) * 2)
		end
		if cb == 0 and i >= W and readu8(of, i - W) < 128 then
			cb = readu16(body, (i - W) * 2)
		end
		if cb == 0 and i < N - W and readu8(of, i + W) < 128 then
			cb = readu16(body, (i + W) * 2)
		end
		if cb ~= 0 then
			writeu8(coastal, i, 1)
			writeu16(coast_body, i * 2, cb)
			writei32(coast_tmp, nc * 4, i)
			nc += 1
		end
	end
	local coast_list = buffer.create(nc * 4)
	buffer.copy(coast_list, 0, coast_tmp, 0, nc * 4)
	self.land_list = land_list
	self.land_count = nl
	self.coast_list = coast_list
	self.coast_count = nc
	self.contestable_count = nl
	local _ = H
end

-- =============================================================================================
-- Registry (one shared instance per map id per process)
-- =============================================================================================

local cache: { [string]: WorldMap } = {}
local data_cache: { [string]: { [string]: any } } = {}
local providers: { (string) -> { [string]: any }? } = {}

--- Registers a data source: fn(id) → map data table or nil. The server registers one that
--- requires src/server/MapData modules; the client registers what MapFetch downloaded.
function WorldMap.add_provider(fn: (string) -> { [string]: any }?)
	table.insert(providers, fn)
end

--- Makes a data table available for `id` (e.g. fetched from the server).
function WorldMap.put_data(id: string, data: { [string]: any })
	data_cache[(WorldMap.split_id(id))] = data
end

--- Raw data of map `id` (nil when no provider has it; cached). Replicated maps (MapList
--- `replicated`) are required from Data/Maps; under Lune the server MapData folder is read directly.
--- Call it once outside coroutine jobs (Session does): Lune's require may yield.
function WorldMap.load_data(id: string): { [string]: any }?
	id = (WorldMap.split_id(id))
	local d = data_cache[id]
	if d == nil then
		d = WorldMap._load_data(id)
		if d ~= nil then
			data_cache[id] = d
		end
	end
	return d
end

function WorldMap._load_data(id: string): { [string]: any }?
	for _, p in providers do
		local ok, res = pcall(p, id)
		if ok and type(res) == "table" then
			return res
		end
	end
	local row = MapList.get(id)
	local module = if row ~= nil then row.module else nil
	if module == nil then
		return nil
	end
	local ok, res = pcall(function(): any
		if RBX_SCRIPT ~= nil then
			-- Roblox: replicated maps live in ReplicatedStorage.Airfront.Data.Maps.
			local data = RBX_SCRIPT.Parent.Parent:FindFirstChild("Data")
			local maps = if data ~= nil then data:FindFirstChild("Maps") else nil
			local mod = if maps ~= nil then maps:FindFirstChild(module) else nil
			return if mod ~= nil then (require :: any)(mod) else nil
		end
		return (require :: any)("../Data/Maps/" .. module)
	end)
	if ok and type(res) == "table" then
		return res
	end
	if RBX_SCRIPT == nil then
		-- Lune: tests and tools read the server data modules straight from the source tree.
		local ok2, res2 = pcall(function()
			return (require :: any)("../../server/MapData/" .. module)
		end)
		if ok2 and type(res2) == "table" then
			return res2
		end
	end
	return nil
end

--- True when map `id` is built or its data can be loaded without a network fetch.
function WorldMap.available(id: string): boolean
	return cache[id] ~= nil or WorldMap.load_data(id) ~= nil
end

--- The shared map `id` (built on first use; errors when its data is unavailable — clients fetch
--- non-replicated maps with MapFetch first).
function WorldMap.get(id: string?): WorldMap
	local key = id or MapList.DEFAULT
	local m = cache[key]
	if m == nil then
		local data = WorldMap.load_data(key)
		if data == nil then
			error("WorldMap: map '" .. tostring(key) .. "' is not available")
		end
		local _, scale = WorldMap.split_id(key)
		m = WorldMap.from_terrain(data, scale)
		if m.id == "" or scale < 1.0 then
			m.id = key
		end
		cache[key] = m
	end
	return m :: WorldMap
end

--- Id of the default map.
WorldMap.DEFAULT = MapList.DEFAULT

--- The default map (MapList.DEFAULT).
function WorldMap.shared(): WorldMap
	return WorldMap.get(MapList.DEFAULT)
end

--- Drops a cached map (tests / memory pressure). Sims holding it keep their reference.
function WorldMap.release(id: string)
	cache[id] = nil
end

-- =============================================================================================
-- Queries
-- =============================================================================================

function WorldMap.tile_x(self: WorldMap, i: number): number
	return i % self.W
end

function WorldMap.tile_y(self: WorldMap, i: number): number
	return i // self.W
end

--- Tile at (x, y), or -1 outside the map.
function WorldMap.tile_index(self: WorldMap, x: number, y: number): number
	if x < 0 or y < 0 or x >= self.W or y >= self.H then
		return -1
	end
	return y * self.W + x
end

function WorldMap.in_bounds(self: WorldMap, i: number): boolean
	return i >= 0 and i < self.N
end

function WorldMap.is_water(self: WorldMap, i: number): boolean
	return readu8(self.terrain, i) <= T_LAKE
end

--- Land in the broad sense (contestable land or impassable terrain).
function WorldMap.is_land(self: WorldMap, i: number): boolean
	return readu8(self.terrain, i) >= T_PLAINS
end

function WorldMap.is_contestable(self: WorldMap, i: number): boolean
	return readu8(self.land, i) == 1
end

function WorldMap.is_impassable(self: WorldMap, i: number): boolean
	return readu8(self.tile_bytes, i) == 0x9F
end

function WorldMap.is_coastal(self: WorldMap, i: number): boolean
	return readu8(self.coastal, i) == 1
end

--- Water body id of tile `i` (0 on land).
function WorldMap.body_of(self: WorldMap, i: number): number
	return readu16(self.water_body, i * 2)
end

--- Water body a coastal land tile touches (0 when not coastal).
function WorldMap.coast_body_of(self: WorldMap, i: number): number
	return readu16(self.coast_body, i * 2)
end

--- Land tile number `k` (0-based, k < land_count).
function WorldMap.land_tile(self: WorldMap, k: number): number
	return readi32(self.land_list, k * 4)
end

function WorldMap.coast_tile(self: WorldMap, k: number): number
	return readi32(self.coast_list, k * 4)
end

--- 4-neighbourhood inside the map as a 1-based array (west, east, north, south; allocates —
--- avoid in hot loops, use neighbor()).
function WorldMap.neighbors4(self: WorldMap, i: number): { number }
	local W = self.W
	local x = i % W
	local out = {}
	if x > 0 then
		table.insert(out, i - 1)
	end
	if x < W - 1 then
		table.insert(out, i + 1)
	end
	if i >= W then
		table.insert(out, i - W)
	end
	if i < self.N - W then
		table.insert(out, i + W)
	end
	return out
end

--- Neighbour in direction d (0 west, 1 east, 2 north, 3 south); -1 past the map edge.
function WorldMap.neighbor(self: WorldMap, i: number, d: number): number
	local W = self.W
	local x = i % W
	if d == 0 then
		return if x > 0 then i - 1 else -1
	elseif d == 1 then
		return if x < W - 1 then i + 1 else -1
	elseif d == 2 then
		return if i >= W then i - W else -1
	end
	return if i < self.N - W then i + W else -1
end

--- Tile centre in map space (x right, y down, in tiles).
function WorldMap.tile_center(self: WorldMap, i: number): (number, number)
	local W = self.W
	return i % W + 0.5, i // W + 0.5
end

--- Tile containing map-space point (x, y) (clamped to the map).
function WorldMap.point_tile(self: WorldMap, x: number, y: number): number
	local tx = math.clamp(math.floor(x), 0, self.W - 1)
	local ty = math.clamp(math.floor(y), 0, self.H - 1)
	return ty * self.W + tx
end

--- Nation spawn list of the map (1-based {name, flag, x, y, tile}).
function WorldMap.load_nations(self: WorldMap): { any }
	return self.nations
end

--- Tribe names (1-based array; Data/Tribes).
function WorldMap.load_tribe_names(): { string }
	return (Tribes :: any).names
end

return WorldMap
