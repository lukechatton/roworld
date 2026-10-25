--!native
-- Port of scripts/core/sim_nav.gd: water pathfinding for boats, trade ships and warships.
--
-- The map's grid (flat, no wrap) is cut into 8 x 8 tile cells (edge cells may be smaller). Inside
-- each cell the water tiles are split into 4-connected regions; regions touching across a cell
-- edge (or diagonally through a one-tile strait) are linked in a small graph. A path query runs A*
-- on that graph, stitches the regions together with tiny in-region BFS walks through precomputed
-- portal tiles, then straightens the result with line-of-sight string pulling and rasterises it
-- back into a dense tile path (consecutive tiles are 4/8-neighbours). The graph is built once per
-- map (cached on the map) and shared read-only by every Sim on it; each Sim gets private scratch.
--
-- Luau: body = map.water_body (u16 buffer: readu16(body, t * 2)), region = i32 buffer per tile
-- (-1 on land); per-region data and the adjacency (CSR) are buffers (reg_* / adj_* below); paths
-- are 1-based arrays of tiles ({} = none).
local Defs = require("./Defs")
local Coop = require("../Net/Coop")

local CELL = 8
--- Weighted A* (slightly inadmissible): far fewer expansions; smoothing removes the kinks.
local HEURISTIC_W = 1.4
--- Region-pair key stride (region ids stay below 2^24).
local PAIR_K = 16777216

local readu16 = buffer.readu16
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readi32 = buffer.readi32
local writei32 = buffer.writei32
local readf32 = buffer.readf32
local writef32 = buffer.writef32
local readf64 = buffer.readf64
local writef64 = buffer.writef64
local f32b = Defs.f32b

local SimNav = {}
SimNav.__index = SimNav
SimNav.CELL = CELL
SimNav.HEURISTIC_W = HEURISTIC_W

local function clock_us(): number
	return os.clock() * 1e6
end

local function new_blank(): any
	return setmetatable({
		map = nil,
		W = 0,
		H = 0,
		N = 0,
		CW = 0,
		CH = 0,
		body = nil,
		region = nil,
		reg_count = 0,
		-- per region (0-based r): body (i32), representative tile (i32), centroid x / y (f32),
		-- full 8x8 water cell (u8)
		reg_body = nil,
		reg_tile = nil,
		reg_x = nil,
		reg_y = nil,
		reg_full = nil,
		-- CSR adjacency: edges of r are adj_off[r] .. adj_off[r + 1] - 1 (i32); per edge the other
		-- region (i32), cost (f32) and portal tiles on this / the other side (i32)
		adj_off = nil,
		adj_to = nil,
		adj_cost = nil,
		adj_pa = nil,
		adj_pb = nil,
		-- A* scratch (per instance): g (f64), came / seen / closed stamps (i32) per region
		_g = nil,
		_came = nil,
		_seen = nil,
		_closed = nil,
		_stamp = 0,
		_heap_n = {},
		_heap_f = {},
		_heap_size = 0,
		-- in-region BFS scratch (a region has at most 64 tiles)
		_t_seen = {},
		_t_par = {},
		_q = {},
		-- statistics for the bench
		searches = 0,
		expanded = 0,
		usec = 0,
		usec_astar = 0,
		usec_smooth = 0,
		usec_max = 0,
		fails = 0,
	}, SimNav)
end

function SimNav.new(): any
	return new_blank()
end

--- A SimNav for one Sim: the region graph is built once per map (cached on the map object) and
--- shared read-only, while the A*/BFS scratch is private.
function SimNav.shared(world: any): any
	local g = world._nav_graph
	if g == nil then
		g = new_blank()
		g:build(world)
		world._nav_graph = g
	end
	return g:_instance()
end

function SimNav._instance(self: any): any
	local n = new_blank()
	for _, k in
		{
			"map",
			"W",
			"H",
			"N",
			"CW",
			"CH",
			"body",
			"region",
			"reg_count",
			"reg_body",
			"reg_tile",
			"reg_x",
			"reg_y",
			"reg_full",
			"adj_off",
			"adj_to",
			"adj_cost",
			"adj_pa",
			"adj_pb",
		}
	do
		n[k] = self[k]
	end
	n:_alloc_scratch()
	return n
end

function SimNav._alloc_scratch(self: any)
	local rc = math.max(self.reg_count, 1)
	self._g = buffer.create(rc * 8)
	self._came = buffer.create(rc * 4)
	self._seen = buffer.create(rc * 4)
	self._closed = buffer.create(rc * 4)
	self._stamp = 0
	self._heap_n = {}
	self._heap_f = {}
end

local function _dist(ax: number, ay: number, bx: number, by: number): number
	local dx = ax - bx
	local dy = ay - by
	return math.sqrt(dx * dx + dy * dy)
end
SimNav._dist = _dist

function SimNav.build(self: any, world: any)
	self.map = world
	local W, H, N = world.W, world.H, world.N
	self.W = W
	self.H = H
	self.N = N
	local CW = (W + CELL - 1) // CELL
	local CH = (H + CELL - 1) // CELL
	self.CW = CW
	self.CH = CH
	local body = world.water_body
	self.body = body
	local region = buffer.create(N * 4)
	buffer.fill(region, 0, 255) -- -1 everywhere
	self.region = region
	local reg_count = 0
	-- growable per-region arrays (plain tables while building)
	local reg_body, reg_tile, reg_x, reg_y, reg_full = {}, {}, {}, {}, {}
	local stack = {}
	local members = {}
	-- 1. Regions: flood fill water inside each cell.
	for cy = 0, CH - 1 do
		for cx = 0, CW - 1 do
			if cx % 16 == 0 then
				Coop.check()
			end
			local x0 = cx * CELL
			local y0 = cy * CELL
			local x1 = math.min(x0 + CELL, W) - 1
			local y1 = math.min(y0 + CELL, H) - 1
			for yy = y0, y1 do
				for xx = x0, x1 do
					local t0 = yy * W + xx
					if readu16(body, t0 * 2) == 0 or readi32(region, t0 * 4) ~= -1 then
						continue
					end
					local r = reg_count
					reg_count += 1
					local b = readu16(body, t0 * 2)
					writei32(region, t0 * 4, r)
					table.clear(stack)
					table.clear(members)
					stack[1] = t0
					local fx = 0.0
					local fy = 0.0
					while #stack > 0 do
						local t = stack[#stack]
						stack[#stack] = nil
						members[#members + 1] = t
						local tx = t % W
						local ty = t // W
						fx += tx
						fy += ty
						if tx > x0 and readu16(body, (t - 1) * 2) == b and readi32(region, (t - 1) * 4) == -1 then
							writei32(region, (t - 1) * 4, r)
							stack[#stack + 1] = t - 1
						end
						if tx < x1 and readu16(body, (t + 1) * 2) == b and readi32(region, (t + 1) * 4) == -1 then
							writei32(region, (t + 1) * 4, r)
							stack[#stack + 1] = t + 1
						end
						if ty > y0 and readu16(body, (t - W) * 2) == b and readi32(region, (t - W) * 4) == -1 then
							writei32(region, (t - W) * 4, r)
							stack[#stack + 1] = t - W
						end
						if ty < y1 and readu16(body, (t + W) * 2) == b and readi32(region, (t + W) * 4) == -1 then
							writei32(region, (t + W) * 4, r)
							stack[#stack + 1] = t + W
						end
					end
					local m = #members
					fx /= m
					fy /= m
					local best = members[1]
					local bd = 1e20
					for _, t in members do
						local ddx = (t % W) - fx
						local ddy = (t // W) - fy
						local dd = ddx * ddx + ddy * ddy
						if dd < bd then
							bd = dd
							best = t
						end
					end
					reg_full[r + 1] = if m == CELL * CELL then 1 else 0
					reg_x[r + 1] = fx
					reg_y[r + 1] = fy
					reg_body[r + 1] = b
					reg_tile[r + 1] = best
				end
			end
		end
	end
	assert(reg_count < PAIR_K, "SimNav: too many regions")
	self.reg_count = reg_count
	local rb = buffer.create(math.max(reg_count, 1) * 4)
	local rt = buffer.create(math.max(reg_count, 1) * 4)
	local rx = buffer.create(math.max(reg_count, 1) * 4)
	local ry = buffer.create(math.max(reg_count, 1) * 4)
	local rf = buffer.create(math.max(reg_count, 1))
	for r = 0, reg_count - 1 do
		writei32(rb, r * 4, reg_body[r + 1])
		writei32(rt, r * 4, reg_tile[r + 1])
		writef32(rx, r * 4, reg_x[r + 1])
		writef32(ry, r * 4, reg_y[r + 1])
		writeu8(rf, r, reg_full[r + 1])
	end
	reg_body, reg_tile, reg_x, reg_y, reg_full = nil :: any, nil :: any, nil :: any, nil :: any, nil :: any
	self.reg_body = rb
	self.reg_tile = rt
	self.reg_x = rx
	self.reg_y = ry
	self.reg_full = rf
	Coop.check()
	-- 2. Edges between regions, with every boundary pair collected per region pair (keys kept in
	-- first-seen order).
	local pairs_: { [number]: { number } } = {}
	local keys: { number } = {}
	local function add_pair(r: number, r2: number, t: number, t2: number)
		local k
		if r < r2 then
			k = r * PAIR_K + r2
		else
			k = r2 * PAIR_K + r
			t, t2 = t2, t
		end
		local list = pairs_[k]
		if list == nil then
			list = {}
			pairs_[k] = list
			keys[#keys + 1] = k
		end
		list[#list + 1] = t
		list[#list + 1] = t2
	end
	for t = 0, N - 1 do
		if t % 16384 == 0 then
			Coop.check()
		end
		local r = readi32(region, t * 4)
		if r < 0 then
			continue
		end
		local x = t % W
		local y = t // W
		local has_e = x < W - 1
		local e = t + 1
		local r2
		if has_e then
			r2 = readi32(region, e * 4)
			if r2 >= 0 and r2 ~= r then
				add_pair(r, r2, t, e)
			end
		end
		if y < H - 1 then
			local s = t + W
			r2 = readi32(region, s * 4)
			if r2 >= 0 and r2 ~= r then
				add_pair(r, r2, t, s)
			end
			-- Diagonal links through one-tile straits (both orthogonal tiles are land).
			if has_e then
				local se = s + 1
				r2 = readi32(region, se * 4)
				if r2 >= 0 and r2 ~= r and readi32(region, e * 4) < 0 and readi32(region, s * 4) < 0 then
					add_pair(r, r2, t, se)
				end
			end
			if x > 0 then
				local sw = s - 1
				r2 = readi32(region, sw * 4)
				local wv = t - 1
				if r2 >= 0 and r2 ~= r and readi32(region, wv * 4) < 0 and readi32(region, s * 4) < 0 then
					add_pair(r, r2, t, sw)
				end
			end
		end
	end
	-- 3. CSR adjacency (both directions), portal = middle boundary pair.
	local deg = buffer.create((reg_count + 1) * 4)
	for _, k in keys do
		local a = k // PAIR_K
		local b = k % PAIR_K
		writei32(deg, a * 4, readi32(deg, a * 4) + 1)
		writei32(deg, b * 4, readi32(deg, b * 4) + 1)
	end
	local adj_off = buffer.create((reg_count + 1) * 4)
	local acc = 0
	for r = 0, reg_count - 1 do
		writei32(adj_off, r * 4, acc)
		acc += readi32(deg, r * 4)
	end
	writei32(adj_off, reg_count * 4, acc)
	local na = math.max(acc, 1)
	local adj_to = buffer.create(na * 4)
	local adj_cost = buffer.create(na * 4)
	local adj_pa = buffer.create(na * 4)
	local adj_pb = buffer.create(na * 4)
	local fill = buffer.create((reg_count + 1) * 4)
	for _, k in keys do
		local a = k // PAIR_K
		local b = k % PAIR_K
		local list = pairs_[k]
		local mid = (#list // 4) * 2
		local ta = list[mid + 1]
		local tb = list[mid + 2]
		local cost = _dist(readf32(rx, a * 4), readf32(ry, a * 4), readf32(rx, b * 4), readf32(ry, b * 4))
		local fa = readi32(fill, a * 4)
		local ia = readi32(adj_off, a * 4) + fa
		writei32(fill, a * 4, fa + 1)
		writei32(adj_to, ia * 4, b)
		writef32(adj_cost, ia * 4, cost)
		writei32(adj_pa, ia * 4, ta)
		writei32(adj_pb, ia * 4, tb)
		local fb = readi32(fill, b * 4)
		local ib = readi32(adj_off, b * 4) + fb
		writei32(fill, b * 4, fb + 1)
		writei32(adj_to, ib * 4, a)
		writef32(adj_cost, ib * 4, cost)
		writei32(adj_pa, ib * 4, tb)
		writei32(adj_pb, ib * 4, ta)
	end
	Coop.check()
	self.adj_off = adj_off
	self.adj_to = adj_to
	self.adj_cost = adj_cost
	self.adj_pa = adj_pa
	self.adj_pb = adj_pb
	self:_alloc_scratch()
end

function SimNav.is_water(self: any, t: number): boolean
	return readu16(self.body, t * 2) ~= 0
end

--- Water body of tile `t` (0 on land).
function SimNav.body_of(self: any, t: number): number
	return readu16(self.body, t * 2)
end

--- Region of water tile `t` (-1 on land).
function SimNav.region_of(self: any, t: number): number
	return readi32(self.region, t * 4)
end

--- Water body of region `r`.
function SimNav.region_body(self: any, r: number): number
	return readi32(self.reg_body, r * 4)
end

--- A water tile of `water_body` 4/8-adjacent to land tile `t` (-1 if none). Order: west, east,
--- north, north-west, north-east, south, south-west, south-east.
function SimNav.water_next_to(self: any, t: number, water_body: number): number
	local body = self.body
	local region = self.region
	local W = self.W
	local x = t % W
	local has_w = x > 0
	local has_e = x < W - 1
	local function ok(c: number): boolean
		return readu16(body, c * 2) == water_body and readi32(region, c * 4) >= 0
	end
	if has_w and ok(t - 1) then
		return t - 1
	end
	if has_e and ok(t + 1) then
		return t + 1
	end
	if t >= W then
		local up = t - W
		if ok(up) then
			return up
		end
		if has_w and ok(up - 1) then
			return up - 1
		end
		if has_e and ok(up + 1) then
			return up + 1
		end
	end
	if t < self.N - W then
		local dn = t + W
		if ok(dn) then
			return dn
		end
		if has_w and ok(dn - 1) then
			return dn - 1
		end
		if has_e and ok(dn + 1) then
			return dn + 1
		end
	end
	return -1
end

-- =============================================================================================
-- Search
-- =============================================================================================

--- Dense water tile path from water tile `src` to water tile `dst` (same body), or {}.
function SimNav.find_path(self: any, src: number, dst: number): { number }
	local t0 = clock_us()
	local p = self:_find_path(src, dst)
	local dt = clock_us() - t0
	self.usec += dt
	if dt > self.usec_max then
		self.usec_max = dt
	end
	if #p == 0 then
		self.fails += 1
	end
	return p
end

--- Like find_path, but tries a straight line first (cheap for short warship hops).
function SimNav.short_path(self: any, src: number, dst: number): { number }
	local body = self.body
	if src >= 0 and dst >= 0 then
		local b = readu16(body, src * 2)
		if b ~= 0 and b == readu16(body, dst * 2) and self:los(src, dst, b) then
			local out = { src }
			self:_raster(src, dst, out)
			return out
		end
	end
	return self:find_path(src, dst)
end

function SimNav._find_path(self: any, src: number, dst: number): { number }
	if src < 0 or dst < 0 or src >= self.N or dst >= self.N then
		return {}
	end
	local region = self.region
	local ra = readi32(region, src * 4)
	local rb = readi32(region, dst * 4)
	local reg_body = self.reg_body
	if ra < 0 or rb < 0 or readi32(reg_body, ra * 4) ~= readi32(reg_body, rb * 4) then
		return {}
	end
	local ta = clock_us()
	local regs = self:_region_path(ra, rb)
	self.usec_astar += clock_us() - ta
	if #regs == 0 then
		return {}
	end
	local raw = { src }
	local cur = src
	local adj_off = self.adj_off
	local adj_to = self.adj_to
	local adj_pa = self.adj_pa
	local adj_pb = self.adj_pb
	for i = 1, #regs - 1 do
		local r = regs[i]
		local r2 = regs[i + 1]
		local k = readi32(adj_off, r * 4)
		local pa = -1
		local pb = -1
		local kend = readi32(adj_off, (r + 1) * 4)
		while k < kend do
			if readi32(adj_to, k * 4) == r2 then
				pa = readi32(adj_pa, k * 4)
				pb = readi32(adj_pb, k * 4)
				break
			end
			k += 1
		end
		if pa < 0 then
			return {}
		end
		if not self:_bfs_append(cur, pa, r, raw) then
			return {}
		end
		raw[#raw + 1] = pb
		cur = pb
	end
	if not self:_bfs_append(cur, dst, rb, raw) then
		return {}
	end
	local ts = clock_us()
	local sm = self:_smooth(raw, readi32(reg_body, ra * 4))
	self.usec_smooth += clock_us() - ts
	return sm
end

function SimNav._region_path(self: any, ra: number, rb: number): { number }
	self.searches += 1
	self._stamp += 1
	local st = self._stamp
	self._heap_size = 0
	local g = self._g
	local came = self._came
	local seen = self._seen
	local closed = self._closed
	local reg_x = self.reg_x
	local reg_y = self.reg_y
	local adj_off = self.adj_off
	local adj_to = self.adj_to
	local adj_cost = self.adj_cost
	writef64(g, ra * 8, 0.0)
	writei32(came, ra * 4, -1)
	writei32(seen, ra * 4, st)
	local gx = readf32(reg_x, rb * 4)
	local gy = readf32(reg_y, rb * 4)
	self:_heap_push(ra, _dist(readf32(reg_x, ra * 4), readf32(reg_y, ra * 4), gx, gy) * HEURISTIC_W)
	local found = false
	local expanded = 0
	while self._heap_size > 0 do
		local r = self:_heap_pop()
		if readi32(closed, r * 4) == st then
			continue
		end
		writei32(closed, r * 4, st)
		expanded += 1
		if r == rb then
			found = true
			break
		end
		local gr = readf64(g, r * 8)
		for k = readi32(adj_off, r * 4), readi32(adj_off, (r + 1) * 4) - 1 do
			local n = readi32(adj_to, k * 4)
			if readi32(closed, n * 4) == st then
				continue
			end
			-- g values are kept rounded to float32 (as the original's PackedFloat32Array).
			local ng = gr + readf32(adj_cost, k * 4)
			if readi32(seen, n * 4) ~= st or ng < readf64(g, n * 8) then
				writei32(seen, n * 4, st)
				writef64(g, n * 8, f32b(ng))
				writei32(came, n * 4, r)
				self:_heap_push(n, ng + _dist(readf32(reg_x, n * 4), readf32(reg_y, n * 4), gx, gy) * HEURISTIC_W)
			end
		end
	end
	self.expanded += expanded
	local out = {}
	if not found then
		return out
	end
	local c = rb
	while c ~= -1 do
		out[#out + 1] = c
		c = readi32(came, c * 4)
	end
	-- reverse
	local n = #out
	for i = 1, n // 2 do
		out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
	end
	return out
end

function SimNav._heap_push(self: any, n: number, f: number)
	local hn = self._heap_n
	local hf = self._heap_f
	local i = self._heap_size
	self._heap_size = i + 1
	while i > 0 do
		local p = (i - 1) // 2
		if hf[p] <= f then
			break
		end
		hn[i] = hn[p]
		hf[i] = hf[p]
		i = p
	end
	hn[i] = n
	hf[i] = f32b(f)
end

function SimNav._heap_pop(self: any): number
	local hn = self._heap_n
	local hf = self._heap_f
	local top = hn[0]
	local size = self._heap_size - 1
	self._heap_size = size
	if size == 0 then
		return top
	end
	local ln = hn[size]
	local lf = hf[size]
	local i = 0
	while true do
		local c = i * 2 + 1
		if c >= size then
			break
		end
		if c + 1 < size and hf[c + 1] < hf[c] then
			c += 1
		end
		if hf[c] >= lf then
			break
		end
		hn[i] = hn[c]
		hf[i] = hf[c]
		i = c
	end
	hn[i] = ln
	hf[i] = lf
	return top
end

--- BFS inside region `r` from `a` to `b`; appends the tiles after `a` up to and including `b`.
function SimNav._bfs_append(self: any, a: number, b: number, r: number, out: { number }): boolean
	if a == b then
		return true
	end
	if readu8(self.reg_full, r) == 1 then
		self:_raster(a, b, out)
		return true
	end
	local region = self.region
	local t_seen = self._t_seen
	local t_par = self._t_par
	table.clear(t_seen)
	table.clear(t_par)
	local q = self._q
	table.clear(q)
	q[1] = a
	local qn = 1
	t_seen[a] = true
	t_par[a] = -1
	local head = 1
	local found = false
	local W = self.W
	local NW = self.N - W
	while head <= qn do
		local t = q[head]
		head += 1
		if t == b then
			found = true
			break
		end
		local x = t % W
		for k = 1, 4 do
			local n
			if k == 1 then
				if x == 0 then
					continue
				end
				n = t - 1
			elseif k == 2 then
				if x == W - 1 then
					continue
				end
				n = t + 1
			elseif k == 3 then
				if t < W then
					continue
				end
				n = t - W
			else
				if t >= NW then
					continue
				end
				n = t + W
			end
			if readi32(region, n * 4) == r and not t_seen[n] then
				t_seen[n] = true
				t_par[n] = t
				qn += 1
				q[qn] = n
			end
		end
	end
	if not found then
		-- a and b might be diagonal neighbours across a one-tile strait: accept the jump.
		out[#out + 1] = b
		return readi32(region, b * 4) == r or readi32(region, a * 4) == r
	end
	local seg = {}
	local c = b
	while c ~= a do
		seg[#seg + 1] = c
		c = t_par[c]
	end
	for i = #seg, 1, -1 do
		out[#out + 1] = seg[i]
	end
	return true
end

-- =============================================================================================
-- Smoothing
-- =============================================================================================

function SimNav._smooth(self: any, raw: { number }, b: number): { number }
	local n = #raw
	if n <= 2 then
		return raw
	end
	local out = { raw[1] }
	-- 0-based indices into raw (raw[i + 1])
	local i = 0
	while i < n - 1 do
		-- Exponential probe then binary search for the farthest visible raw point.
		local good = i + 1
		local stride = 2
		local bad = -1
		while true do
			local j = i + stride
			if j >= n - 1 then
				j = n - 1
			end
			if self:los(raw[i + 1], raw[j + 1], b) then
				good = j
				if j == n - 1 or stride >= 256 then
					break
				end
				stride *= 2
			else
				bad = j
				break
			end
		end
		if bad > 0 then
			local lo = good
			local hi = bad
			while hi - lo > 1 do
				local mid = (lo + hi) // 2
				if self:los(raw[i + 1], raw[mid + 1], b) then
					lo = mid
				else
					hi = mid
				end
			end
			good = lo
		end
		if good == i + 1 then
			out[#out + 1] = raw[good + 1]
		else
			self:_raster(raw[i + 1], raw[good + 1], out)
		end
		i = good
	end
	return out
end

--- True when the straight tile line a→bt stays on water of body `b` without cutting land corners.
function SimNav.los(self: any, a: number, bt: number, b: number): boolean
	local body = self.body
	local W = self.W
	local x0 = a % W
	local y0 = a // W
	local x1 = bt % W
	local y1 = bt // W
	local dx = x1 - x0
	local dy = y1 - y0
	local sx = if dx > 0 then 1 else -1
	local sy = if dy > 0 then 1 else -1
	local ax = math.abs(dx)
	local ay = math.abs(dy)
	local err = ax - ay
	local x = x0
	local y = y0
	local steps = ax + ay
	local k = 0
	while k < steps do
		local e2 = err * 2
		local nx = x
		local ny = y
		if e2 > -ay then
			err -= ay
			nx = x + sx
		end
		if e2 < ax then
			err += ax
			ny = y + sy
		end
		if nx ~= x and ny ~= y then
			-- Diagonal: one orthogonal corner must be water too.
			if readu16(body, (y * W + nx) * 2) ~= b and readu16(body, (ny * W + x) * 2) ~= b then
				return false
			end
			k += 1
		end
		x = nx
		y = ny
		if readu16(body, (y * W + x) * 2) ~= b then
			return false
		end
		k += 1
	end
	return true
end

--- Tiles of the straight line a→bt (excluding a) on a grid `W` tiles wide, appended to the
--- 1-based array `out`.
local function line_tiles(W: number, a: number, bt: number, out: { number })
	local x0 = a % W
	local y0 = a // W
	local x1 = bt % W
	local y1 = bt // W
	local dx = x1 - x0
	local dy = y1 - y0
	local sx = if dx > 0 then 1 else -1
	local sy = if dy > 0 then 1 else -1
	local ax = math.abs(dx)
	local ay = math.abs(dy)
	local err = ax - ay
	local x = x0
	local y = y0
	local n = #out
	while x ~= x1 or y ~= y1 do
		local e2 = err * 2
		if e2 > -ay then
			err -= ay
			x += sx
		end
		if e2 < ax then
			err += ax
			y += sy
		end
		n += 1
		out[n] = y * W + x
	end
end

--- Appends the tiles of the line a→bt (excluding a) to out.
function SimNav._raster(self: any, a: number, bt: number, out: { number })
	line_tiles(self.W, a, bt, out)
end

--- line_tiles(W, a, bt, out): tiles of the straight line a→bt (excluding a) on any terrain — used
--- for roads and trucks.
SimNav.line_tiles = line_tiles

--- Random water tile of the same body within `radius` of `center` that is reachable by a short
--- search (used for warship patrols). Returns -1 when none found.
function SimNav.random_water_near(self: any, center: number, radius: number, rng: any): number
	local body = self.body
	local b = readu16(body, center * 2)
	if b == 0 then
		return -1
	end
	local W = self.W
	local cx = center % W
	local cy = center // W
	local rx = math.min(math.ceil(radius), W - 1)
	local r2 = radius * radius
	for _ = 1, 12 do
		local x = math.clamp(cx + rng:randi_range(-rx, rx), 0, W - 1)
		local y = math.clamp(cy + rng:randi_range(-radius, radius), 1, self.H - 2)
		local t = y * W + x
		local ddx = x - cx
		local ddy = y - cy
		if readu16(body, t * 2) == b and ddx * ddx + ddy * ddy <= r2 then
			return t
		end
	end
	return -1
end

return SimNav
