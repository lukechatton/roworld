--!native
-- Port of scripts/core/sim_structures.gd (SimStructures, mixin of the flattened Sim class).
-- Structures (city, port, factory, defense post, SAM, silo), the road network between economic
-- structures, trucks, and the registry shared by every moving unit (boats, ships, trucks).
-- Roads and trucks go by railroads, stations and trains in the names below (Rules too):
-- a factory becomes a station and turns every city, port and factory within
-- trainStationMaxRange into one; a new station snaps onto nearby railroads or links to stations it
-- isn't already within 4 hops of, over A*-routed tile paths; factories spawn trains with
-- trainSpawnRate odds towards a random city / port of their cluster, and every city / port stop
-- pays trainGold to the train's owner and the station's owner.
--
-- Luau notes: `structs` is a sid → Struct map; `struct_list` keeps them in sid (= GDScript
-- Dictionary insertion) order for every ordered iteration. `units` is uid → Unit, `unit_list` the
-- ordered list (as in GDScript). Paths are 1-based arrays of 0-based tile indices and are never
-- mutated after they were assigned to a unit (events share them).

local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local SimState = require("./SimState")

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local readi32 = buffer.readi32
local writei32 = buffer.writei32

local a_an = SimState.a_an

local MAXO = Defs.MAX_OWNERS
local STRUCT_KINDS = 16

local S_CITY = Defs.S_CITY
local S_PORT = Defs.S_PORT
local S_FACTORY = Defs.S_FACTORY
--- Order of kinds within a grid cell when a factory pulls in stations (city, port, factory)
local FACTORY_PULL_RANK = { [Defs.S_CITY] = 1, [Defs.S_PORT] = 2, [Defs.S_FACTORY] = 3 }
local S_DEFENSE = Defs.S_DEFENSE
local S_SAM = Defs.S_SAM
local S_SILO = Defs.S_SILO
local S_ARTILLERY = Defs.S_ARTILLERY
local U_TRANSPORT = Defs.U_TRANSPORT
local U_TRADE = Defs.U_TRADE
local U_WARSHIP = Defs.U_WARSHIP
local U_TRUCK = Defs.U_TRUCK

-- Spatial buckets of SCELL x SCELL tiles (self._scw x self._sch per map).
local SCELL = 32

local SimStructures = {}
SimStructures.SCELL = SCELL

-- Enum-keyed constant tables are 0-based (sim-core convention: Defs.STRUCT_TITLES[Defs.S_CITY]).
local function struct_title(kind: number): string
	return Defs.STRUCT_TITLES[kind]
end
local function build_ticks(kind: number): number
	return Rules.BUILD_TICKS[kind]
end
SimStructures.struct_title = struct_title

-- =============================================================================================
-- Struct / Unit records
-- =============================================================================================

export type Struct = {
	sid: number,
	kind: number,
	owner: number,
	tile: number,
	water: number,
	body: number,
	next_tick: number,
	rejections: number,
	level: number,
	active_tick: number,
	active: boolean,
	shots: { number },
	up_tick: number,
	last_spawn: number,
	trucks: number,
	roads: { number },
	station: boolean,
	cluster: number,
	partners: { number },
	partners_tick: number,
	owned_seq: number,
	delete_at: number,
	hp: number?,
	next_fire: number,
	dead: boolean,
}

local Struct = {}
SimStructures.Struct = Struct

function Struct.new(): Struct
	return {
		sid = 0,
		kind = 0,
		owner = 0,
		tile = 0,
		-- Ports: adjacent water tile and its body.
		water = -1,
		body = 0,
		-- Ports: tick offset of the 10-tick trade roll; pity-timer rejections.
		next_tick = 0,
		rejections = 0,
		-- Upgrade level (1 as built) and the tick construction completes (active from then on).
		level = 1,
		active_tick = 0,
		active = false,
		-- SAMs / silos: launch (or upgrade) ticks of missiles still reloading.
		shots = {},
		-- SAMs: tick of the last upgrade (range ramps up over Rules.SAM_UPGRADE_TICKS).
		up_tick = -100000,
		-- Factories: tick of the last truck (>= 10 ticks between trains).
		last_spawn = -100000,
		trucks = 0,
		-- Train station (cities, ports and factories on the rail network), its railroads and cluster.
		roads = {},
		station = false,
		cluster = 0,
		-- Ports: preferred trade partners (structure ids) and when they were chosen.
		partners = {},
		partners_tick = -100000,
		-- Order in which structures came to their current owner (built or
		-- captured), and the tick after which a structure marked for deletion goes (0: not marked;
		-- a tribe marks them, see SimAI).
		owned_seq = 0,
		delete_at = 0,
		-- Health, lowered only by a shell, an air strike or a slug (SimArsenal.damage_struct; nil =
		-- whole), and a battery's next shot.
		hp = nil,
		next_fire = 0,
		dead = false,
	}
end

export type Unit = { [string]: any }

local Unit = {}
SimStructures.Unit = Unit

function Unit.new(): Unit
	return {
		uid = 0,
		kind = 0,
		owner = 0,
		path = {},
		start_tick = 0,
		tpt = 100,
		troops = 0.0,
		end_tick = 0,
		-- Next tick at which this unit needs any processing (arrival, truck stop, warship turn).
		next_tick = 0,
		-- transports
		target_tile = -1,
		-- trade ships
		src_sid = 0,
		dst_sid = 0,
		-- trucks: stop structure ids, path index of each stop (0-based path index), tick each stop
		-- is reached; next_stop is a 1-based index into stops (GDScript 1 → Luau 2). Created in
		-- _spawn_truck only.
		stops = nil :: { number }?,
		stop_idx = nil :: { number }?,
		stop_ticks = nil :: { number }?,
		next_stop = 2,
		trade_stops = 0,
		factory_sid = 0,
		-- trade ships: full-size tiles sailed before a capture re-route; original owner (0 = never captured)
		traveled = 0,
		orig_owner = 0,
		-- warships (per-ship state, see SimWarships)
		hp = 0,
		max_hp = 0,
		vet = 0,
		vet_progress = 0,
		-- 0 patrolling, 1 retreating to a port, 2 docked (repairing).
		state = 0,
		patrol = -1,
		retreat_port = 0,
		last_shot = -100000,
		manual_tick = -100000,
		heal_rem = 0.0,
		target_uid = 0,
		hunt_uid = 0,
		hunt_path_tick = -100000,
		port_check_tick = -100000,
		-- uid → true of one-shot targets already shelled (warships only; see SimWarships).
		shelled = nil :: { [number]: boolean }?,
		shelled_n = 0,
		near_port = false,
		near_port_tick = -100000,
		body = 0,
		dead = false,
	}
end

-- =============================================================================================
-- Install
-- =============================================================================================

function SimStructures.install(C)
	-- Field initialisation (GDScript member initialisers + _init_structures()).
	function C:_init_structures()
		self.structs = {} :: { [number]: Struct }
		self.struct_list = {} :: { Struct }
		self._structs_dead = 0
		self.n_structs = 0
		self.next_sid = 1
		self._owned_seq = 0
		self.port_list = {} :: { Struct }
		self.factory_list = {} :: { Struct }
		-- Spatial buckets (32 x 32 tiles) of structure ids; cell c lives at scells[c + 1].
		local scw = (self.W + SCELL - 1) // SCELL
		local sch = (self.H + SCELL - 1) // SCELL
		self._scw = scw
		self._sch = sch
		local scells = table.create(scw * sch)
		for i = 1, scw * sch do
			scells[i] = {}
		end
		self.scells = scells
		-- rid → { sid_a, sid_b, tiles (a's end to b's end), grid cells }: the railroads
		self.roads = {} :: { [number]: { any } }
		self.n_roads = 0
		self.next_rid = 1
		-- Rail spatial grid: cell → { rid = true }
		self.rail_cells = {} :: { [number]: { [number]: boolean } }
		-- Clusters of connected stations (see _ensure_clusters)
		self._clusters_dirty = false
		self._cluster_trade = {} :: { [number]: { Struct } }
		-- Structures under construction, activated when their active_tick comes.
		self.building = {} :: { Struct }
		self.units = {} :: { [number]: Unit }
		self.n_units = 0
		self.unit_list = {} :: { Unit }
		self.next_uid = 1
		self._units_dead = 0
		-- Trade ships at sea and trucks on the roads, world-wide (they slow the spawn rates as they add up).
		self.n_trade = 0
		self.n_trucks = 0
	end

	-- Sizes of the GDScript dictionaries (Luau maps have no O(1) size).
	function C:struct_total(): number
		return self.n_structs
	end

	function C:unit_total(): number
		return self.n_units
	end

	function C:road_total(): number
		return self.n_roads
	end

	-- =========================================================================================
	-- Units registry
	-- =========================================================================================

	function C:add_unit(u: Unit)
		if u.next_tick == 0 then
			u.next_tick = if u.kind ~= U_WARSHIP then u.end_tick else 1073741824 -- 1 << 30
		end
		u.uid = self.next_uid
		self.next_uid += 1
		self.units[u.uid] = u
		self.n_units += 1
		table.insert(self.unit_list, u)
		if u.kind == U_TRADE then
			self.n_trade += 1
		elseif u.kind == U_TRUCK then
			self.n_trucks += 1
		end
		self:ev({ Ev.UNIT_ADD, u.uid, u.kind, u.owner, u.path, u.start_tick, u.tpt, Defs.trunc(u.troops) })
		self:_on_unit_added(u)
	end

	function C:remove_unit(u: Unit, reason: number)
		if u.dead then
			return
		end
		u.dead = true
		self._units_dead += 1
		self.units[u.uid] = nil
		self.n_units -= 1
		self:ev({ Ev.UNIT_DEL, u.uid, reason })
		local k = u.kind
		if k == U_TRANSPORT then
			self.o_boats[u.owner] -= 1
		elseif k == U_WARSHIP then
			self.o_warships[u.owner] -= 1
		elseif k == U_TRADE then
			self.n_trade -= 1
		elseif k == U_TRUCK then
			self.n_trucks -= 1
			local f = self.structs[u.factory_sid]
			if f ~= nil then
				f.trucks -= 1
			end
		end
	end

	-- Hook for SimWarships (warship registry).
	function C:_on_unit_added(_u: Unit) end

	-- Current tile of a unit (every unit follows its path at `tpt` ticks per tile x100).
	function C:unit_tile(u: Unit): number
		local path = u.path
		local n = #path
		if n == 0 then
			return -1
		end
		local tpt = u.tpt
		if tpt < 1 then
			tpt = 1
		end
		local idx = (self.tick - u.start_tick) * 100 // tpt
		if idx < 0 then
			idx = 0
		elseif idx > n - 1 then
			idx = n - 1
		end
		return path[idx + 1]
	end

	function C:compact_units()
		if self._units_dead == 0 then
			return
		end
		self._units_dead = 0
		local list = self.unit_list
		local w = 0
		local n = #list
		for i = 1, n do
			local u = list[i]
			if not u.dead then
				w += 1
				list[w] = u
			end
		end
		for i = n, w + 1, -1 do
			list[i] = nil
		end
	end

	function C:count_units_of(id: number, kind: number): number
		local n = 0
		for _, u in self.unit_list do
			if not u.dead and u.owner == id and u.kind == kind then
				n += 1
			end
		end
		return n
	end

	-- Drops destroyed structures from struct_list (kept in sid order).
	function C:_compact_structs()
		self._structs_dead = 0
		local list = self.struct_list
		local w = 0
		local n = #list
		for i = 1, n do
			local s = list[i]
			if not s.dead then
				w += 1
				list[w] = s
			end
		end
		for i = n, w + 1, -1 do
			list[i] = nil
		end
	end

	-- =========================================================================================
	-- Spatial index
	-- =========================================================================================

	function C:_cell_of(t: number): number
		local W = self.W
		return ((t // W) // SCELL) * self._scw + ((t % W) // SCELL)
	end

	function C:_cell_add(s: Struct)
		table.insert(self.scells[self:_cell_of(s.tile) + 1], s.sid)
	end

	function C:_cell_remove(s: Struct)
		local cell = self.scells[self:_cell_of(s.tile) + 1]
		local i = table.find(cell, s.sid)
		if i then
			local last = #cell
			cell[i] = cell[last]
			cell[last] = nil
		end
	end

	-- Structures whose tile lies within `rx` columns and `ry` rows of `center`.
	function C:structs_in_box(center: number, rx: number, ry: number, kind: number?): { Struct }
		local want = if kind == nil then -1 else kind
		local out = {}
		local W = self.W
		local scw = self._scw
		local cx = center % W
		local cy = center // W
		local y0 = math.max(cy - ry, 0) // SCELL
		local y1 = math.min(cy + ry, self.H - 1) // SCELL
		local g0 = math.max(cx - rx, 0) // SCELL
		local g1 = math.min(cx + rx, W - 1) // SCELL
		local scells = self.scells
		local structs = self.structs
		for gy = y0, y1 do
			for gx = g0, g1 do
				for _, sid in scells[gy * scw + gx + 1] do
					local s = structs[sid]
					if want >= 0 and s.kind ~= want then
						continue
					end
					local st = s.tile
					if math.abs((st % W) - cx) <= rx and math.abs((st // W) - cy) <= ry then
						table.insert(out, s)
					end
				end
			end
		end
		return out
	end

	-- =========================================================================================
	-- Placement
	-- =========================================================================================

	-- True when `id` may place a structure of `kind` exactly on `t` (own land, ports on the coast,
	-- no structure of anyone closer than Rules.STRUCT_MIN_DIST — place_site()'s per-tile test).
	function C:valid_site(id: number, kind: number, t: number): boolean
		if t < 0 or t >= self.N or readi32(self.owner, t * 4) ~= id or readu8(self.land, t) == 0 then
			return false
		end
		if kind == S_PORT and readu8(self.map.coastal, t) == 0 then
			return false
		end
		local range_d2 = self.range_d2
		local md = self.R.STRUCT_MIN_DIST
		local md2 = md * md
		for _, s in self:structs_in_box(t, self.geo_span(t, md), math.ceil(md)) do
			if range_d2(s.tile, t) < md2 then
				return false
			end
		end
		return true
	end

	-- Structure rows [sid, kind, owner, tile, level, active_tick] Rules.place_site() needs around
	-- `tile` (same reach as Rules.near_structures on a GameState), ordered by sid.
	function C:near_rows(tile: number): { { number } }
		local R = self.R
		local range_d2 = self.range_d2
		local reach = R.PLACE_SEARCH_R + R.STRUCT_MIN_DIST + 1.0
		local r2 = reach * reach
		local out = {}
		for _, s in self:structs_in_box(tile, self.geo_span(tile, reach), math.ceil(reach)) do
			if range_d2(tile, s.tile) <= r2 or range_d2(s.tile, tile) <= r2 then
				table.insert(out, { s.sid, s.kind, s.owner, s.tile, s.level, s.active_tick })
			end
		end
		table.sort(out, function(a, b)
			return a[1] < b[1]
		end)
		return out
	end

	-- Where a build click of `id` for `kind` at `t` goes: Rules.place_site() on the Sim's data.
	function C:place(id: number, kind: number, t: number)
		return self.R.place_site(self.map, self.owner, self.map.coastal, id, kind, t, self:near_rows(t), self.tick)
	end

	-- Random valid site for `kind` within `radius` of `anchor` (AI helper). -1 if none found.
	function C:find_site(id: number, kind: number, anchor: number, radius: number, tries: number): number
		if anchor < 0 then
			return -1
		end
		local W = self.W
		local cx = anchor % W
		local cy = anchor // W
		local rng = self.rng
		-- ports snap to own coast within 4 tiles of the original grid
		local coast_r = math.ceil(4 * self.R.LEGACY_LIN)
		for _ = 1, tries do
			local x = math.clamp(cx + rng:randi_range(-radius, radius), 0, W - 1)
			local y = math.clamp(cy + rng:randi_range(-radius, radius), 0, self.H - 1)
			local t = y * W + x
			if kind == S_PORT then
				t = self:_nearest_coast(id, t, coast_r)
				if t < 0 then
					continue
				end
			end
			if self:valid_site(id, kind, t) then
				return t
			end
		end
		return -1
	end

	-- Squared latitude-corrected distance from `t` to the nearest structure of `kind` owned by
	-- `id` within `r` tiles (-1 when there is none that close).
	function C:own_struct_dist2(id: number, kind: number, t: number, r: number): number
		local best = -1.0
		local rr = r * r
		local range_d2 = self.range_d2
		for _, s in self:structs_in_box(t, self.geo_span(t, r), r, kind) do
			if s.owner == id then
				local d = range_d2(s.tile, t)
				if d <= rr and (best < 0.0 or d < best) then
					best = d
				end
			end
		end
		return best
	end

	function C:_nearest_coast(id: number, t: number, r: number): number
		local W = self.W
		local H = self.H
		local cx = t % W
		local cy = t // W
		local owner = self.owner
		local coastal = self.map.coastal
		for dy = -r, r do
			local y = cy + dy
			if y < 0 or y >= H then
				continue
			end
			for dx = -r, r do
				local x = cx + dx
				if x < 0 or x >= W then
					continue
				end
				local c = y * W + x
				if readi32(owner, c * 4) == id and readu8(coastal, c) == 1 then
					return c
				end
			end
		end
		return -1
	end

	-- =========================================================================================
	-- Building / destroying
	-- =========================================================================================

	-- Build intent (also upgrades: see Rules.place_site). Returns true on success.
	--- Returns ok, and whether it was an upgrade (a level on an existing structure).
	function C:try_build(id: number, kind_name: string, t: number): (boolean, boolean?)
		if kind_name == Rules.WARSHIP_KIND_NAME then
			return self:build_warship(id, t)
		end
		local kind = Defs.struct_kind_from_name(kind_name)
		if kind < 0 or t < 0 or t >= self.N then
			return false
		end
		-- the Arsenal's structures need their unlock (SimArsenal)
		if not self:has_unlock(id, Defs.STRUCT_UNLOCK[kind] or 0) then
			self:msg(id, Defs.MSG_INFO, string.format("Unlock %s in the Arsenal first", struct_title(kind)))
			return false
		end
		local cost = Rules.build_cost_kind(kind, self:cost_count(id, kind))
		if self.o_gold[id] < cost then
			self:msg(id, Defs.MSG_INFO, string.format("Not enough gold for %s", a_an(struct_title(kind))))
			return false
		end
		local p = self:place(id, kind, t)
		local up = p.upgrade_sid
		if up ~= 0 then
			local s = self.structs[up]
			if s == nil then
				return false
			end
			self.o_gold[id] -= cost
			self:upgrade_struct(s)
			return true, true
		end
		local site = p.tile
		if site < 0 then
			local reason = p.reason
			if reason == "no_coast" then
				self:msg(id, Defs.MSG_INFO, "Ports must be built on your coast")
			elseif reason == "not_own" then
				self:msg(id, Defs.MSG_INFO, "You can only build on your own land")
			else
				self:msg(id, Defs.MSG_INFO, string.format("No room for %s there", a_an(struct_title(kind))))
			end
			return false
		end
		self.o_gold[id] -= cost
		self:add_struct(kind, id, site)
		return true
	end

	-- Count the price of `kind` grows with: per kind sharing the price, min(levels owned, levels built).
	function C:cost_count(id: number, kind: number): number
		local b = id * STRUCT_KINDS
		local o_slevel = self.o_slevel
		local o_built = self.o_built
		if kind == S_PORT or kind == S_FACTORY then
			return math.min(o_slevel[b + S_PORT], o_built[b + S_PORT])
				+ math.min(o_slevel[b + S_FACTORY], o_built[b + S_FACTORY])
		end
		return math.min(o_slevel[b + kind], o_built[b + kind])
	end

	-- Level sum of `id`'s structures of `kind` (construction counts 1).
	function C:struct_levels(id: number, kind: number): number
		return self.o_slevel[id * STRUCT_KINDS + kind]
	end

	-- An upgrade: +1 level at once; a SAM or silo gets one
	-- more missile slot, which starts reloading; a SAM's range grows over SAM_UPGRADE_TICKS.
	function C:upgrade_struct(s: Struct)
		s.level += 1
		local b = s.owner * STRUCT_KINDS + s.kind
		self.o_slevel[b] += 1
		self.o_built[b] += 1
		if s.active then
			self.o_alevel[b] += 1
		end
		if s.kind == S_SAM then
			s.up_tick = self.tick
		end
		self:ev({ Ev.STRUCT_LEVEL, s.sid, s.level, s.active_tick })
		if s.kind == S_SAM or s.kind == S_SILO then
			table.insert(s.shots, self.tick)
			self:ev({ Ev.STRUCT_SHOTS, s.sid, table.clone(s.shots) })
		end
	end

	-- Overridden by SimWarships.
	function C:build_warship(_id: number, _t: number): boolean
		return false
	end

	function C:add_struct(kind: number, id: number, t: number): Struct
		local tick = self.tick
		local s = Struct.new()
		s.sid = self.next_sid
		self.next_sid += 1
		s.kind = kind
		s.owner = id
		s.tile = t
		self._owned_seq += 1
		s.owned_seq = self._owned_seq
		s.active_tick = tick + build_ticks(kind)
		self.structs[s.sid] = s
		self.n_structs += 1
		table.insert(self.struct_list, s)
		writei32(self.struct_at, t * 4, s.sid)
		local b = id * STRUCT_KINDS + kind
		self.o_scount[b] += 1
		self.o_slevel[b] += 1
		self.o_built[b] += 1
		self:_cell_add(s)
		self:ev({ Ev.STRUCT_ADD, s.sid, kind, id, t })
		self:ev({ Ev.STRUCT_LEVEL, s.sid, 1, s.active_tick })
		if kind == S_PORT then
			s.body = readu16(self.map.coast_body, t * 2)
			s.water = self:_port_water(t, s.body)
			s.next_tick = tick % 10
		end
		if s.active_tick <= tick then
			self:_activate(s)
		else
			table.insert(self.building, s)
		end
		return s
	end

	-- Finishes construction of structures whose time has come.
	function C:construction_tick()
		-- struct_list compaction happens here, never while something iterates it.
		if self._structs_dead > 64 then
			self:_compact_structs()
		end
		local building = self.building
		if #building == 0 then
			return
		end
		local tick = self.tick
		local keep = {}
		for _, s in building do
			if s.dead then
				continue
			end
			if s.active_tick <= tick then
				self:_activate(s)
			else
				table.insert(keep, s)
			end
		end
		self.building = keep
	end

	-- A finished structure starts working: ports trade, factories dispatch trucks, posts defend,
	-- cities raise the troop cap, and stations join the road network.
	function C:_activate(s: Struct)
		s.active = true
		self.o_alevel[s.owner * STRUCT_KINDS + s.kind] += s.level
		local k = s.kind
		if k == S_PORT then
			table.insert(self.port_list, s)
		elseif k == S_FACTORY then
			table.insert(self.factory_list, s)
		elseif k == S_DEFENSE then
			self:_cover(s.tile, 1)
		elseif k == S_ARTILLERY then
			self:_battery_ready(s)
		end
		local t = s.tile
		if k == S_FACTORY then
			-- A new factory becomes a station (it runs the trains), then
			-- every city, port or factory (any owner) within trainStationMaxRange that has none.
			self:_make_station(s)
			for _, c in self:_factory_pull_order(self:_stations_near(t, true)) do
				self:_make_station(c)
			end
		elseif (k == S_CITY or k == S_PORT) and self:_factory_near(t) then
			-- A city or port: a station when a factory is in range
			self:_make_station(s)
		end
	end

	-- True when any factory stands within trainStationMaxRange of `t` (cities and
	-- ports only become stations near a factory).
	function C:_factory_near(t: number): boolean
		local range_d2 = self.range_d2
		local rmax = self.R.ROAD_MAX_TILES
		local r = math.ceil(rmax)
		for _, f in self:structs_in_box(t, self.geo_span(t, rmax), r, S_FACTORY) do
			if f.active and range_d2(f.tile, t) <= rmax * rmax then
				return true
			end
		end
		return false
	end

	-- Overridden by SimNaval (needs the nav grid).
	function C:_port_water(_t: number, _body: number): number
		return -1
	end

	function C:destroy_struct(s: Struct)
		if s.dead then
			return
		end
		s.dead = true
		self.structs[s.sid] = nil
		self.n_structs -= 1
		self._structs_dead += 1
		if readi32(self.struct_at, s.tile * 4) == s.sid then
			writei32(self.struct_at, s.tile * 4, 0)
		end
		local b = s.owner * STRUCT_KINDS + s.kind
		self.o_scount[b] -= 1
		self.o_slevel[b] -= s.level
		self:_cell_remove(s)
		self:ev({ Ev.STRUCT_DEL, s.sid })
		if s.active then
			self.o_alevel[b] -= s.level
			local k = s.kind
			if k == S_PORT then
				local i = table.find(self.port_list, s)
				if i then
					table.remove(self.port_list, i)
				end
			elseif k == S_FACTORY then
				local i = table.find(self.factory_list, s)
				if i then
					table.remove(self.factory_list, i)
				end
			elseif k == S_DEFENSE then
				self:_cover(s.tile, -1)
			end
		end
		-- A station removed: its railroads go (the network may split into clusters)
		for _, rid in table.clone(s.roads) do
			self:_remove_rail(rid)
		end
		table.clear(s.roads)
		if s.station then
			s.station = false
			self._clusters_dirty = true
		end
	end

	-- SimState hook: a structure's tile changed hands.
	function C:_struct_tile_changed(t: number, old: number, nw: number)
		local s = self.structs[readi32(self.struct_at, t * 4)]
		if s == nil then
			return
		end
		-- Captured structures change hands, except defense posts, which
		-- are destroyed. Tribes keep what they capture until they delete it (SimAI).
		-- (the Arsenal's structures too: they work only for an owner with their unlock)
		if nw == 0 or s.kind == S_DEFENSE or s.kind >= S_ARTILLERY then
			self:destroy_struct(s)
			if old > 0 and nw > 0 then
				self:msg(
					old,
					Defs.MSG_BAD,
					string.format("%s destroyed your %s", self.o_name[nw], struct_title(s.kind))
				)
			end
			return
		end
		local bo = old * STRUCT_KINDS + s.kind
		local bn = nw * STRUCT_KINDS + s.kind
		self.o_scount[bo] -= 1
		self.o_scount[bn] += 1
		self.o_slevel[bo] -= s.level
		self.o_slevel[bn] += s.level
		if s.active then
			self.o_alevel[bo] -= s.level
			self.o_alevel[bn] += s.level
		end
		s.owner = nw
		-- A capture clears a pending deletion.
		s.delete_at = 0
		self._owned_seq += 1
		s.owned_seq = self._owned_seq
		self:ev({ Ev.STRUCT_OWNER, s.sid, nw })
		if s.kind ~= S_FACTORY then
			self:msg(old, Defs.MSG_BAD, string.format("%s captured your %s", self.o_name[nw], struct_title(s.kind)))
			self:msg(
				nw,
				Defs.MSG_GOOD,
				string.format("You captured %s from %s", a_an(struct_title(s.kind)), self.o_name[old])
			)
		end
	end

	-- Marks the tiles a defense post at `t` covers (geo metric, like _defense_post_covers).
	function C:_cover(t: number, delta: number)
		local def_cover = self.def_cover
		for _, c in self:disk_tiles(t, self.R.defense_range(), false) do
			writeu8(def_cover, c, math.clamp(readu8(def_cover, c) + delta, 0, 255))
		end
	end

	-- True when a finished defense post of `id` stands within defensePostRange of `t`.
	function C:_defense_post_covers(t: number, id: number): boolean
		local R = self.R
		local range_d2 = self.range_d2
		local rf = R.defense_range()
		for _, s in self:structs_in_box(t, self.geo_span(t, rf), R.DEFENSE_RADIUS, S_DEFENSE) do
			if s.owner == id and s.active and range_d2(s.tile, t) <= rf * rf then
				return true
			end
		end
		return false
	end

	-- Structures of `id` of `kind` in sid order (linear scan; fine for AI decisions).
	function C:structs_of(id: number, kind: number): { Struct }
		local out = {}
		if self:struct_count(id, kind) <= 0 then
			return out
		end
		for _, s in self.struct_list do
			if not s.dead and s.owner == id and s.kind == kind then
				table.insert(out, s)
			end
		end
		return out
	end

	-- =========================================================================================
	-- Railroads (the roads between stations)
	-- =========================================================================================

	--- `s` becomes a train station; it snaps onto the railroads next to
	--- it, or else links to the stations in range.
	function C:_make_station(s: Struct)
		if s.station or s.dead then
			return
		end
		s.station = true
		self._clusters_dirty = true
		if not self:_snap_to_rails(s) then
			self:_link_nearby(s)
		end
	end

	--- Cities, ports and factories (any owner) within trainStationMaxRange of `t` as { d2, struct },
	--- nearest first (ties by sid); stations only unless `all`.
	function C:_stations_near(t: number, all: boolean?): { { any } }
		local range_d2 = self.range_d2
		local rmax = self.R.ROAD_MAX_TILES
		local out = {}
		for _, c in self:structs_in_box(t, self.geo_span(t, rmax), math.ceil(rmax)) do
			if c.kind > S_FACTORY or not c.active or c.dead or (not all and not c.station) then
				continue
			end
			local d2 = range_d2(t, c.tile)
			if d2 <= rmax * rmax then
				table.insert(out, { d2, c })
			end
		end
		table.sort(out, function(p, q)
			if p[1] ~= q[1] then
				return p[1] < q[1]
			end
			return p[2].sid < q[2].sid
		end)
		return out
	end

	--- The structures a new factory makes stations, in grid order
	--- (its 100-tile cells row by row, then city, port, factory, then build order), not nearest
	--- first: the order decides which cities snap onto the first long railroads (2026-10-12).
	function C:_factory_pull_order(near: { { any } }): { Struct }
		local K, W = self.R.K_LIN, self.W
		local keyed = {}
		for _, e in near do
			local c: Struct = e[2]
			local x, y = c.tile % W, c.tile // W
			table.insert(keyed, {
				c,
				math.floor((y + 0.5) * K) // 100,
				math.floor((x + 0.5) * K) // 100,
				FACTORY_PULL_RANK[c.kind] or 9,
			})
		end
		table.sort(keyed, function(p, q)
			if p[2] ~= q[2] then
				return p[2] < q[2]
			elseif p[3] ~= q[3] then
				return p[3] < q[3]
			elseif p[4] ~= q[4] then
				return p[4] < q[4]
			end
			return p[1].sid < q[1].sid
		end)
		local out = table.create(#keyed)
		for i, k in keyed do
			out[i] = k[1]
		end
		return out
	end

	--- Snapping: each railroad in the grid cells within RAIL_SNAP_FULL of `s` is split
	--- at its tile nearest `s` (unless that is an end), `s` joining both halves. True if any was.
	function C:_snap_to_rails(s: Struct): boolean
		local W = self.W
		local sx, sy = s.tile % W, s.tile // W
		local snapped = false
		for _, rid in self:_rails_near(s.tile) do
			local r = self.roads[rid]
			if r == nil then
				continue
			end
			local tiles = r[3]
			local n = #tiles
			local best, bd = 1, math.huge
			for i = 1, n do
				local t = tiles[i]
				local dx, dy = t % W - sx, t // W - sy
				local d = dx * dx + dy * dy
				if d < bd then
					bd = d
					best = i
				end
			end
			local idx = best - 1 -- 0-based index of the closest tile
			if idx == 0 or idx >= n then
				continue
			end
			local a, b = r[1], r[2]
			self:_remove_rail(rid)
			self:_add_rail(a, s.sid, table.move(tiles, 1, idx, 1, {}))
			self:_add_rail(s.sid, b, table.move(tiles, idx + 1, n, 1, {}))
			snapped = true
		end
		return snapped
	end

	--- Linking: a railroad to every station in range, nearest first, that is further
	--- than trainStationMinRange and not already within RAIL_LINK_HOPS hops of `s` (so networks stay
	--- sparse), when a short enough route exists.
	function C:_link_nearby(s: Struct)
		local rmin2 = self.R.ROAD_MIN_TILES * self.R.ROAD_MIN_TILES
		local max_path = self.R.RAIL_MAX_PATH
		for _, e in self:_stations_near(s.tile) do
			local n: Struct = e[2]
			if n == s or e[1] <= rmin2 or self:_hops(n, s, Rules.RAIL_LINK_HOPS) ~= -1 then
				continue
			end
			local path = self:rail_path(s.tile, n.tile)
			if #path > 0 and #path < max_path then
				self:_add_rail(s.sid, n.sid, path)
			end
		end
	end

	--- Hops from `from` to `to` over the railroads, -1 beyond `max_d`.
	function C:_hops(from: Struct, to: Struct, max_d: number): number
		if from == to then
			return 0
		end
		local structs = self.structs
		local seen = { [from.sid] = true }
		local frontier = { from.sid }
		for d = 1, max_d do
			local nxt = {}
			for _, sid in frontier do
				local st = structs[sid]
				if st == nil then
					continue
				end
				for _, rid in st.roads do
					local o = self:road_other(rid, sid)
					if o == to.sid then
						return d
					end
					if not seen[o] then
						seen[o] = true
						table.insert(nxt, o)
					end
				end
			end
			if #nxt == 0 then
				break
			end
			frontier = nxt
		end
		return -1
	end

	-- Rail spatial grid: railroads by the cells their tiles cross, RAIL_CELL_FULL full-size tiles square (a
	-- tile's cell is its centre's, in full-size tiles). Kept in full-size-tile units: rounding the cell and
	-- the snap radius to whole tiles of ours made the catchment 17% short on a K_LIN 1.25 map (2026-10-12).
	function C:_rail_cell(x: number, y: number): number
		local K, c = self.R.K_LIN, Rules.RAIL_CELL_FULL
		return (math.floor((y + 0.5) * K) // c) * (math.floor(self.W * K) // c + 2) + math.floor((x + 0.5) * K) // c
	end

	function C:_rail_register(rid: number, tiles: { number }): { number }
		local W = self.W
		local cells = self.rail_cells
		local mine = {}
		local seen = {}
		for _, t in tiles do
			local k = self:_rail_cell(t % W, t // W)
			if not seen[k] then
				seen[k] = true
				table.insert(mine, k)
				local set = cells[k]
				if set == nil then
					set = {}
					cells[k] = set
				end
				set[rid] = true
			end
		end
		return mine
	end

	function C:_rail_unregister(rid: number, mine: { number })
		local cells = self.rail_cells
		for _, k in mine do
			local set = cells[k]
			if set ~= nil then
				set[rid] = nil
				if next(set) == nil then
					cells[k] = nil
				end
			end
		end
	end

	--- The railroads in the cells overlapping the square of RAIL_SNAP_FULL
	--- full-size tiles around `t` (rid order).
	function C:_rails_near(t: number): { number }
		local W = self.W
		local K, c, r = self.R.K_LIN, Rules.RAIL_CELL_FULL, Rules.RAIL_SNAP_FULL
		local X, Y = math.floor((t % W + 0.5) * K), math.floor((t // W + 0.5) * K)
		local cols = math.floor(W * K) // c + 2
		local found = {}
		local out = {}
		for cy = math.max(Y - r, 0) // c, (Y + r) // c do
			for cx = math.max(X - r, 0) // c, (X + r) // c do
				local set = self.rail_cells[cy * cols + cx]
				if set ~= nil then
					for rid in set do
						if not found[rid] then
							found[rid] = true
							table.insert(out, rid)
						end
					end
				end
			end
		end
		table.sort(out)
		return out
	end

	function C:_add_rail(a: number, b: number, tiles: { number }): number
		local rid = self.next_rid
		self.next_rid += 1
		self.roads[rid] = { a, b, tiles, self:_rail_register(rid, tiles) }
		self.n_roads += 1
		table.insert(self.structs[a].roads, rid)
		table.insert(self.structs[b].roads, rid)
		self._clusters_dirty = true
		self:ev({ Ev.ROAD_ADD, rid, a, b, tiles })
		return rid
	end

	function C:_remove_rail(rid: number)
		local r = self.roads[rid]
		if r == nil then
			return
		end
		self.roads[rid] = nil
		self.n_roads -= 1
		self:_rail_unregister(rid, r[4])
		for k = 1, 2 do
			local st = self.structs[r[k]]
			if st ~= nil then
				local i = table.find(st.roads, rid)
				if i then
					table.remove(st.roads, i)
				end
			end
		end
		self._clusters_dirty = true
		self:ev({ Ev.ROAD_DEL, rid, r[1], r[2] })
	end

	function C:road_other(rid: number, sid: number): number
		local r = self.roads[rid]
		if r == nil then
			return 0
		end
		return if r[1] == sid then r[2] else r[1]
	end

	--- Cluster: connected stations share `cluster`; _cluster_trade[id] lists its cities and ports
	--- (the trains' destinations). Recomputed lazily after the network changed.
	function C:_ensure_clusters()
		if not self._clusters_dirty then
			return
		end
		self._clusters_dirty = false
		local trade = {}
		self._cluster_trade = trade
		local structs = self.structs
		for _, s in self.struct_list do
			s.cluster = 0
		end
		local next_id = 0
		for _, s in self.struct_list do
			if s.dead or not s.station or s.cluster ~= 0 then
				continue
			end
			next_id += 1
			local list = {}
			trade[next_id] = list
			s.cluster = next_id
			local queue = { s }
			local qi = 1
			while qi <= #queue do
				local cur = queue[qi]
				qi += 1
				if cur.kind ~= S_FACTORY then
					table.insert(list, cur)
				end
				for _, rid in cur.roads do
					local o = structs[self:road_other(rid, cur.sid)]
					if o ~= nil and o.station and o.cluster == 0 then
						o.cluster = next_id
						table.insert(queue, o)
					end
				end
			end
		end
	end

	--- Rail pathfinding (A* on the minimap, scaled back up): the railroad's tiles from
	--- `from` to `to`, or {} when no route is short enough. Nodes that can't lie on a path shorter
	--- than RAIL_MAX_PATH are never searched.
	function C:rail_path(from: number, to: number): { number }
		local R = self.R
		local f = R.RAIL_MINIMAP
		local W, H = self.W, self.H
		local mw = (W + f - 1) // f
		local mh = (H + f - 1) // f
		local terr = self.terr
		local ofb = self.map.tile_bytes
		local T_LAKE = Defs.T_LAKE
		local function full(m: number): number
			return (m // mw) * f * W + (m % mw) * f
		end
		local wet = {}
		local function water(m: number): boolean
			local v = wet[m]
			if v == nil then
				v = readu8(terr, full(m)) <= T_LAKE
				wet[m] = v
			end
			return v
		end
		local shores = {}
		local function shore(m: number): boolean
			local v = shores[m]
			if v == nil then
				local w = water(m)
				local x, y = m % mw, m // mw
				v = (x > 0 and water(m - 1) ~= w)
					or (x < mw - 1 and water(m + 1) ~= w)
					or (y > 0 and water(m - mw) ~= w)
					or (y < mh - 1 and water(m + mw) ~= w)
				shores[m] = v
			end
			return v
		end
		local start = ((from // W) // f) * mw + (from % W) // f
		local goal = ((to // W) // f) * mw + (to % W) // f
		local sx, sy = start % mw, start // mw
		local gx, gy = goal % mw, goal // mw
		local limit = math.ceil(R.RAIL_MAX_PATH / f) + 2
		if math.abs(sx - gx) + math.abs(sy - gy) > limit then
			return {}
		end
		local hw = Rules.RAIL_HEURISTIC_W
		local wpen = 1 + Rules.RAIL_WATER_PENALTY
		local tpen = Rules.RAIL_TURN_PENALTY
		-- binary heap of (priority, sequence, node); of equal priorities the newest comes out first (the
		-- last of its bucket). Oldest first, every L-shaped
		-- railroad was mirrored (down then along, not along then down), so later stations missed the
		-- rails they should have snapped onto (2026-10-12)
		local hp, hq, hn = {}, {}, {}
		local hsize = 0
		local seq = 0
		local function push(node: number, pri: number)
			seq += 1
			hsize += 1
			local i = hsize
			while i > 1 do
				local p = i // 2
				if hp[p] < pri or (hp[p] == pri and hq[p] > seq) then
					break
				end
				hp[i], hq[i], hn[i] = hp[p], hq[p], hn[p]
				i = p
			end
			hp[i], hq[i], hn[i] = pri, seq, node
		end
		local function pop(): number
			local top = hn[1]
			local lp, lq, ln = hp[hsize], hq[hsize], hn[hsize]
			hp[hsize], hq[hsize], hn[hsize] = nil, nil, nil
			hsize -= 1
			local i = 1
			while true do
				local c = i * 2
				if c > hsize then
					break
				end
				if c < hsize and (hp[c + 1] < hp[c] or (hp[c + 1] == hp[c] and hq[c + 1] > hq[c])) then
					c += 1
				end
				if lp < hp[c] or (lp == hp[c] and lq > hq[c]) then
					break
				end
				hp[i], hq[i], hn[i] = hp[c], hq[c], hn[c]
				i = c
			end
			if hsize > 0 then
				hp[i], hq[i], hn[i] = lp, lq, ln
			end
			return top
		end
		local g = { [start] = 0 }
		local parent = { [start] = -1 }
		local closed = {}
		push(start, hw * (math.abs(sx - gx) + math.abs(sy - gy)))
		local expanded = 0
		local found = false
		local nb = table.create(4, 0)
		while hsize > 0 do
			local node = pop()
			if closed[node] then
				continue
			end
			closed[node] = true
			if node == goal then
				found = true
				break
			end
			expanded += 1
			if expanded > 60000 or readu8(ofb, full(node)) == 0x9F then
				if expanded > 60000 then
					break
				end
				continue
			end
			local x, y = node % mw, node // mw
			local from_shore = shore(node)
			local prev = parent[node]
			local gn = g[node]
			local nn = 0
			if y > 0 then
				nn += 1
				nb[nn] = node - mw
			end
			if y < mh - 1 then
				nn += 1
				nb[nn] = node + mw
			end
			if x > 0 then
				nn += 1
				nb[nn] = node - 1
			end
			if x < mw - 1 then
				nn += 1
				nb[nn] = node + 1
			end
			for i = 1, nn do
				local m = nb[i]
				if closed[m] then
					continue
				end
				local m_water = water(m)
				if m_water and not (from_shore or shore(m)) then
					continue
				end
				local mx, my = m % mw, m // mw
				local hg = math.abs(mx - gx) + math.abs(my - gy)
				if math.abs(mx - sx) + math.abs(my - sy) + hg > limit then
					continue
				end
				local c = if m_water or shore(m) then wpen else 1
				if prev >= 0 and node - prev ~= m - node then
					c += tpen
				end
				local ng = gn + c
				local og = g[m]
				if og == nil or ng < og then
					g[m] = ng
					parent[m] = node
					push(m, ng + hw * hg)
				end
			end
		end
		if not found then
			return {}
		end
		local mini = {}
		local cur = goal
		while cur >= 0 do
			table.insert(mini, cur)
			cur = parent[cur]
		end
		-- (reversed: start first)
		local nmini = #mini
		for i = 1, nmini // 2 do
			mini[i], mini[nmini - i + 1] = mini[nmini - i + 1], mini[i]
		end
		local path = {}
		if f == 1 then
			for i = 1, nmini do
				path[i] = full(mini[i])
			end
		else
			-- Upscaling: minimap steps become f tiles, interpolated so the path stays connected
			for i = 1, nmini - 1 do
				local cx, cy = (mini[i] % mw) * f, (mini[i] // mw) * f
				local nx, ny = (mini[i + 1] % mw) * f, (mini[i + 1] // mw) * f
				table.insert(path, cy * W + cx)
				local dx, dy = nx - cx, ny - cy
				local steps = math.max(math.abs(dx), math.abs(dy))
				for step = 1, steps - 1 do
					local px = math.floor(cx + dx * step / steps + 0.5)
					local py = math.floor(cy + dy * step / steps + 0.5)
					table.insert(path, py * W + px)
				end
			end
			table.insert(path, full(mini[nmini]))
		end
		-- Ends: the path starts at `from` and ends at `to`
		local si = table.find(path, from)
		if si == nil then
			table.insert(path, 1, from)
		elseif si ~= 1 then
			path = table.move(path, si, #path, 1, {})
		end
		local di = table.find(path, to)
		if di == nil then
			table.insert(path, to)
		elseif di ~= #path then
			path = table.move(path, 1, di, 1, {})
		end
		return path
	end

	-- =========================================================================================
	-- Trains (the trucks on the roads)
	-- =========================================================================================

	--- A station trades with its owner and with anyone its owner holds
	--- no grudge against.
	function C:_trade_ok(st: Struct, player: number): boolean
		return st.owner == player or not self:hostile(st.owner, player)
	end

	--- Each finished factory station rolls `level` times per tick with odds 1 / trainSpawnRate(owner's
	--- factory levels, train units world-wide), at most one train per TRAIN_COOLDOWN_TICKS, and only
	--- when its cluster holds a city or port it may trade with; the train heads for a random one
	--- (reservoir sampling).
	function C:factories_tick()
		local list = self.factory_list
		if #list == 0 then
			return
		end
		self:_ensure_clusters()
		local units_w = self.n_trucks * Rules.TRAIN_UNITS
		local tick = self.tick
		local o_alive = self.o_alive
		local rng = self.rng
		for _, f in list do
			if not f.station or f.trucks >= Rules.TRUCKS_PER_FACTORY or o_alive[f.owner] == 0 then
				continue
			end
			if tick < f.last_spawn + Rules.TRAIN_COOLDOWN_TICKS then
				continue
			end
			local dests = self._cluster_trade[f.cluster]
			if dests == nil then
				continue
			end
			local any = false
			for _, d in dests do
				if not d.dead and self:_trade_ok(d, f.owner) then
					any = true
					break
				end
			end
			if not any then
				continue
			end
			local rate = Rules.train_spawn_rate(self:struct_levels(f.owner, S_FACTORY), units_w)
			local go = false
			for _ = 1, f.level do
				if rng:randi() % rate == 0 then
					go = true
					break
				end
			end
			if not go then
				continue
			end
			local pick = nil
			local seen = 0
			for _, d in dests do
				if not d.dead and self:_trade_ok(d, f.owner) then
					seen += 1
					if rng:randi() % seen == 0 then
						pick = d
					end
				end
			end
			if pick ~= nil and pick ~= f then
				self:_spawn_truck(f, pick)
				f.last_spawn = tick
			end
		end
	end

	--- A* over the station graph (1 per hop; the Manhattan tile heuristic makes it
	--- head straight for the destination). nil when not in the same cluster.
	function C:_station_path(a: Struct, b: Struct): { Struct }?
		self:_ensure_clusters()
		if a.cluster == 0 or a.cluster ~= b.cluster then
			return nil
		end
		local W = self.W
		local structs = self.structs
		local bx, by = b.tile % W, b.tile // W
		local function h(st: Struct): number
			return math.abs(st.tile % W - bx) + math.abs(st.tile // W - by)
		end
		local g = { [a.sid] = 0 }
		local parent = { [a.sid] = 0 }
		local open = { a }
		local closed = {}
		while #open > 0 do
			local bi, bf = 1, math.huge
			for i, st in open do
				local fv = g[st.sid] + h(st)
				if fv < bf or (fv == bf and st.sid < open[bi].sid) then
					bf = fv
					bi = i
				end
			end
			local cur = table.remove(open, bi)
			if closed[cur.sid] then
				continue
			end
			closed[cur.sid] = true
			if cur == b then
				local route = {}
				local sid = b.sid
				while sid ~= 0 do
					table.insert(route, 1, structs[sid])
					sid = parent[sid]
				end
				return route
			end
			for _, rid in cur.roads do
				local o = structs[self:road_other(rid, cur.sid)]
				if o ~= nil and o.station and not closed[o.sid] then
					local ng = g[cur.sid] + 1
					if g[o.sid] == nil or ng < g[o.sid] then
						g[o.sid] = ng
						parent[o.sid] = cur.sid
						table.insert(open, o)
					end
				end
			end
		end
		return nil
	end

	--- The factory's train runs the railroads of the station route to `dest`, stopping
	--- at every station on the way (a stop's tick: when the train, 2 full-size tiles a tick, reaches the end
	--- of the railroad leading there).
	function C:_spawn_truck(f: Struct, dest: Struct)
		local route = self:_station_path(f, dest)
		if route == nil or #route <= 1 then
			return
		end
		local path = {}
		local stop_idx = { 0 }
		for i = 1, #route - 1 do
			local a, b = route[i], route[i + 1]
			local seg = nil
			for _, rid in a.roads do
				if self:road_other(rid, a.sid) == b.sid then
					seg = self.roads[rid]
					break
				end
			end
			if seg == nil then
				return
			end
			local tiles = seg[3]
			if seg[1] == a.sid then
				for j = 1, #tiles do
					table.insert(path, tiles[j])
				end
			else
				for j = #tiles, 1, -1 do
					table.insert(path, tiles[j])
				end
			end
			table.insert(stop_idx, #path - 1)
		end
		if path[1] ~= f.tile then
			table.insert(path, 1, f.tile)
			for i = 2, #stop_idx do
				stop_idx[i] += 1
			end
		end
		local tick = self.tick
		local u = Unit.new()
		u.kind = U_TRUCK
		u.owner = f.owner
		u.factory_sid = f.sid
		u.start_tick = tick
		u.tpt = self.R.TRUCK_TPT_X100
		local stops = {}
		local stop_ticks = {}
		for i, st in route do
			stops[i] = st.sid
			stop_ticks[i] = tick + (stop_idx[i] * u.tpt + 99) // 100
		end
		u.stops = stops
		u.stop_idx = stop_idx
		u.stop_ticks = stop_ticks
		u.path = path
		u.end_tick = stop_ticks[#stop_ticks]
		u.next_stop = 2
		u.next_tick = stop_ticks[2]
		f.trucks += 1
		self:add_unit(u)
	end

	function C:_truck_tick(u: Unit)
		local tick = self.tick
		local stops = u.stops :: { number }
		local stop_ticks = u.stop_ticks :: { number }
		local nstops = #stops
		while u.next_stop <= nstops and tick >= stop_ticks[u.next_stop] do
			local s = self.structs[stops[u.next_stop]]
			-- A station that is gone or will not
			-- trade with the train's owner ends the trip there, unpaid.
			if s == nil or not s.station or self.o_alive[u.owner] == 0 or not self:_trade_ok(s, u.owner) then
				self:remove_unit(u, Defs.DEL_ARRIVED)
				return
			end
			-- City and port stops pay trainGold(relation, stops so far) to
			-- the train's owner and, when different, the same again to the station's owner.
			if s.kind ~= S_FACTORY then
				local rel = if s.owner == u.owner
					then "self"					-- (an ally; a teammate pays a stranger's rate: trainGold "team" = "other")

					elseif self:has_alliance(s.owner, u.owner) then "ally"
					else "other"
				local gold = Rules.train_gold(rel, u.trade_stops)
				-- (the earner sees "+ 25K" rise over the station)
				self:add_bonus_gold(u.owner, gold, s.tile)
				if s.owner ~= u.owner then
					self:add_bonus_gold(s.owner, gold, s.tile)
				end
				u.trade_stops += 1
			end
			u.next_stop += 1
		end
		if tick >= u.end_tick then
			self:remove_unit(u, Defs.DEL_ARRIVED)
		else
			u.next_tick = if u.next_stop <= #stop_ticks then stop_ticks[u.next_stop] else u.end_tick
		end
	end

	-- =========================================================================================
	-- Snapshot helpers
	-- =========================================================================================

	function C:struct_rows(): { { number } }
		local out = {}
		for _, s in self.struct_list do
			if not s.dead then
				-- (SAMs / silos with missiles reloading: + those launch ticks, Ev.STRUCT_SHOTS)
				table.insert(
					out,
					if #s.shots > 0
						then { s.sid, s.kind, s.owner, s.tile, s.level, s.active_tick, table.clone(s.shots) }
						else { s.sid, s.kind, s.owner, s.tile, s.level, s.active_tick }
				)
			end
		end
		return out
	end

	-- Snapshot rows [owner, built per slot...] for owners that built anything.
	function C:built_rows(): { { number } }
		local out = {}
		local o_built = self.o_built
		local slots = Rules.BUILT_SLOTS
		for id = 1, MAXO - 1 do
			local b = id * STRUCT_KINDS
			local any = false
			for k = 0, slots - 1 do
				if o_built[b + k] > 0 then
					any = true
					break
				end
			end
			if any then
				local row = { id }
				for k = 0, slots - 1 do
					table.insert(row, o_built[b + k])
				end
				table.insert(out, row)
			end
		end
		return out
	end

	function C:road_rows(): { { number } }
		local rids = {}
		for rid in self.roads do
			table.insert(rids, rid)
		end
		table.sort(rids)
		local out = {}
		for _, rid in rids do
			local r = self.roads[rid]
			table.insert(out, { rid, r[1], r[2], r[3] })
		end
		return out
	end

	function C:unit_rows(): { { any } }
		local out = {}
		for _, u in self.unit_list do
			if u.dead then
				continue
			end
			table.insert(out, {
				u.uid,
				u.kind,
				u.owner,
				u.path,
				u.start_tick,
				u.tpt,
				Defs.trunc(u.troops),
				u.hp,
				u.max_hp,
				u.vet,
				u.state,
				u.patrol,
			})
		end
		return out
	end
end

return SimStructures
