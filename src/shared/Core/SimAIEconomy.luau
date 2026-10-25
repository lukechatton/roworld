--!native
-- Port of scripts/core/sim_ai_economy.gd (SimAIEconomy).
-- Base of SimAI: the AI's economy (what to build and where), defense-post policy, warship
-- behaviour and the neighbour-colour upkeep. Strategy
-- (expansion, war, boats, nukes, diplomacy) lives in SimAI.
--
-- Luau: GDScript `SimAI extends SimAIEconomy` is flattened: SimAI's class table gets these
-- methods through SimAIEconomy.install(C) (one-level method lookup), and SimAI.new() calls
-- `_init_economy()` for the member initialisers. The Sim is always passed in as `sim` (no stored
-- back-reference), exactly as in GDScript.

local Defs = require("./Defs")
local Rules = require("./Rules")
local SimColors = require("./SimColors")

local readu8 = buffer.readu8
local readi32 = buffer.readi32

local f32 = Defs.f32

local STRUCT_KINDS = 16
local S_CITY = Defs.S_CITY
local S_PORT = Defs.S_PORT
local S_FACTORY = Defs.S_FACTORY
local S_DEFENSE = Defs.S_DEFENSE
local S_SAM = Defs.S_SAM
local S_SILO = Defs.S_SILO
local T_LAKE = Defs.T_LAKE

local SimAIEconomy = {}

-- 0-based table from a list (enum / difficulty keyed constants, sim-core convention).
local function zt(values: { any }): { [number]: any }
	local out = {}
	for i, v in values do
		out[i - 1] = v
	end
	return out
end
SimAIEconomy.zt = zt

-- Ticks after the start before AI nations fire nukes (also when they start saving for them).
SimAIEconomy.NUKE_AGE = zt({ 4800, 3600, 2700 })
-- No wars on nations until the land grab is over.
SimAIEconomy.NATION_WAR_AGE = 1200
-- Only the largest nations build missile silos.
SimAIEconomy.SILO_TOP_RANK = 12
-- Structures per city (ports 0.75, factories 0.75 — x0.33 when
-- the nation has a coast — SAMs 0.15 / 0.2 / 0.25 by difficulty, silos 0.4 for the first then
-- 0.2, at most 3), cities otherwise; each owned structure raises its perceived cost by
-- PERCEIVED_COST_STEP x its price until the nation has saved up for a MIRV plus a hydrogen bomb.
--
-- Reworked on 2026-10-07 so that the AI builds more
-- ports. A 20-minute match of 70 nations had 23 of
-- its 42 coastal nations without a port at minute 6. What changed:
--   * the build step walks its build order (port, factory, SAM, silo, then a city) and takes
--     the first that can be afforded AND placed. Before, it picked one kind and waited for it, so a
--     nation saving for its next port built nothing else, and one with no site for it nothing ever;
--   * CROWDED_FULL_TILES_PER_NATION: with more than a nation per 7,500 land tiles a nation's very
--     first structure is a port (a factory without a coast), for income early. On top, a nation with
--     a coast builds its port first on every map (PORT_FIRST). The density threshold is met on the
--     World map with bot players (a nation per 5,900 tiles) but on few others (Africa: one per
--     23,000), and there the change above alone left half the coastal nations without a port at
--     minute 6. Measured on World, Easy, 40 bot players: 77 ports at minute 2 (was 3), 108 at
--     minute 4 (was 49). The nations are richer for it: 2.5M gold each at minute 6, was 1.25M
--     (docs/ai.md has the tables);
--   * CITIES_BEFORE_SAVING: nothing is hoarded for nukes before the third city (the second city
--     cost 500K to an AI, so the first port, due with it, came minutes late). Easy nations
--     wait too, since public matches run Easy nations;
--   * port sites only prefer the site farthest from the nation's other ports. Before, it refused any
--     site within PORT_MIN_GAP of one, so a short coast held one port;
--   * PORT_WATER_FULL_TILES: no port on a pond (water under 3,000 tiles that is not the
--     ocean), where no trade ship could ever call, at any difficulty.
SimAIEconomy.PORT_PER_CITY = 0.75
SimAIEconomy.FACTORY_PER_CITY = 0.75
SimAIEconomy.FACTORY_COASTAL_MULT = 0.33
SimAIEconomy.SAM_PER_CITY = zt({ f32(0.15), f32(0.2), f32(0.25) }) -- PackedFloat32Array
SimAIEconomy.SILO_PER_CITY = 0.2
SimAIEconomy.FIRST_SILO_PER_CITY = 0.4
SimAIEconomy.MAX_SILOS = 3
-- Perceived cost increase per owned structure of the kind: city/port/factory/silo 1, SAM 0.3.
SimAIEconomy.PERCEIVED_COST_STEP = zt({ 1.0, 1.0, 1.0, 0.0, f32(0.3), 1.0 }) -- PackedFloat32Array
-- Upgrade density: with more than one structure per 1500 full-size tiles a nation upgrades an
-- existing structure of the chosen kind instead of placing a new one.
SimAIEconomy.UPGRADE_DENSITY_FULL_TILES = 1500.0
-- Build order after defense posts; a city when none of these is due or possible.
SimAIEconomy.BUILD_ORDER = { S_PORT, S_FACTORY, S_SAM, S_SILO }
-- Crowded map: more nations than one per this many full-size land tiles.
SimAIEconomy.CROWDED_FULL_TILES_PER_NATION = 7500.0
-- A coastal nation's first structure is a port whatever the map's density.
SimAIEconomy.PORT_FIRST = true
-- CITIES_BEFORE_SAVING: cities owned before saving up for nukes inflates structure costs.
SimAIEconomy.CITIES_BEFORE_SAVING = 3
-- Full-size tiles of water (the ocean always counts) a port needs.
SimAIEconomy.PORT_WATER_FULL_TILES = 3000.0
-- A nation that found no site for a port looks again after this many ticks (the search walks the
-- map's coast list).
SimAIEconomy.PORT_RETRY_TICKS = 300
-- At most one defense post per this many border tiles (hard cap DEFENSE_CAP).
SimAIEconomy.DEFENSE_PER_BORDER = 250
SimAIEconomy.DEFENSE_CAP = 6
-- Minimum ticks between two defense posts built by the same AI.
SimAIEconomy.DEFENSE_GAP = 600
-- Colour upkeep: after the land grab, an AI owner whose colour is within RETINT_BELOW (OKLab ΔE)
-- of a bordering owner shifts it minimally — the smaller of the two changes (never a human).
SimAIEconomy.RETINT_FROM = 1200
SimAIEconomy.RETINT_BELOW = 0.06
SimAIEconomy.RETINT_OWNER_GAP = 1200
SimAIEconomy.RETINT_PER_MINUTE = 4
-- Chance that a nation answers a sunk transport / captured trade ship / incoming invasion with a
-- new warship (Easy never, Medium 15 %, Hard 50 %); with 10+ warships it re-tasks one.
SimAIEconomy.WARSHIP_RETALIATE_P = zt({ 0.0, f32(0.15), 0.5 }) -- PackedFloat32Array
SimAIEconomy.WARSHIP_FLEET_CAP = 10

local E = SimAIEconomy
local NUKE_AGE = E.NUKE_AGE
local NATION_WAR_AGE = E.NATION_WAR_AGE
local SAM_PER_CITY = E.SAM_PER_CITY
local PERCEIVED_COST_STEP = E.PERCEIVED_COST_STEP
local WARSHIP_RETALIATE_P = E.WARSHIP_RETALIATE_P
local WARSHIP_FLEET_CAP = E.WARSHIP_FLEET_CAP

-- Tiles of each water body of a map (body id -> tiles), counted once per map.
local BODY_TILES: { [any]: { [number]: number } } = setmetatable({}, { __mode = "k" }) :: any
local function body_tiles(map: any): { [number]: number }
	local sizes = BODY_TILES[map]
	if sizes == nil then
		sizes = {}
		local wb = map.water_body
		local readu16 = buffer.readu16
		for t = 0, map.N - 1 do
			local b = readu16(wb, t * 2)
			if b ~= 0 then
				sizes[b] = (sizes[b] or 0) + 1
			end
		end
		BODY_TILES[map] = sizes
	end
	return sizes
end
SimAIEconomy.body_tiles = body_tiles

local function filled(m: number, v: number): { [number]: number }
	local t = table.create(m)
	for i = 0, m - 1 do
		t[i] = v
	end
	return t
end
SimAIEconomy.filled = filled

function SimAIEconomy.install(C)
	-- Member initialisers of sim_ai_economy.gd.
	function C:_init_economy()
		self.last_build = {} :: { [number]: number }
		-- 1 once a nation's port-first structure stands (or can't)
		self.crowded_first = {} :: { [number]: number }
		-- crowded map or not, worked out once (nil until then)
		self._crowded = nil :: boolean?
		-- the tick a nation without a port site may look for one again
		self.port_wait = {} :: { [number]: number }
		self.last_defense = {} :: { [number]: number }
		-- Land rank per owner (1 = largest), refreshed every 50 ticks.
		self.rank = {} :: { [number]: number }
		self.nukes_in_play = false
		self.last_retint = {} :: { [number]: number }
		self.retints = 0
		self._retint_window = 0
		self._retint_count = 0
		-- OKLab ({x = L, y = a, z = b}) cache per owner, valid while _lab_col[id] == its colour.
		self._lab = {} :: { [number]: any }
		self._lab_col = {} :: { [number]: number }
	end

	function C:_setup_economy(m: number)
		self.last_build = filled(m, 0)
		self.crowded_first = filled(m, 0)
		self._crowded = nil
		self.port_wait = filled(m, 0)
		self.last_defense = filled(m, -100000)
		self.rank = filled(m, 999)
		self.last_retint = filled(m, -100000)
		self._lab = table.create(m)
		self._lab_col = filled(m, -1)
	end

	-- =========================================================================================
	-- Colour upkeep
	-- =========================================================================================

	function C:_lab_of(sim, id: number)
		local c = sim.o_color[id]
		if self._lab_col[id] ~= c then
			self._lab_col[id] = c
			self._lab[id] = SimColors.oklab(c)
		end
		return self._lab[id]
	end

	-- Called after scan_border(): re-tints this AI owner when it clashes with a neighbour it is
	-- smaller than (or with any human neighbour). Rate limited per owner and worldwide.
	function C:_consider_retint(sim, id: number, age: number)
		-- (a team game: every owner keeps its team's colour)
		if sim.team_mode then
			return
		end
		if age < E.RETINT_FROM or sim.tick - self.last_retint[id] < E.RETINT_OWNER_GAP or #sim.sc_list == 0 then
			return
		end
		if sim.tick - self._retint_window >= 600 then
			self._retint_window = sim.tick
			self._retint_count = 0
		end
		if self._retint_count >= E.RETINT_PER_MINUTE then
			return
		end
		local me = self:_lab_of(sim, id)
		local clash = false
		local refs = {}
		for _, p in sim.sc_list do
			local lab = self:_lab_of(sim, p)
			table.insert(refs, lab)
			if SimColors.dist(me, lab) < E.RETINT_BELOW and (sim.o_tiles[id] <= sim.o_tiles[p] or sim:is_human(p)) then
				clash = true
			end
		end
		if not clash then
			return
		end
		local col = SimColors.shift(sim.o_color[id], refs)
		if col == sim.o_color[id] then
			return
		end
		sim:set_owner_color(id, col)
		self.last_retint[id] = sim.tick
		self._retint_count += 1
		self.retints += 1
	end

	-- =========================================================================================
	-- Economy
	-- =========================================================================================

	-- Crowded map: nations (and bot players, who play as nations; never people or tribes)
	-- per full-size land tile.
	function C:_crowded_map(sim): boolean
		local c = self._crowded
		if c == nil then
			local nations = 0
			for id = 1, sim.owner_total do
				if sim.o_ai[id] == 1 and sim.o_kind[id] ~= Defs.KIND_TRIBE then
					nations += 1
				end
			end
			local land = sim.map.land_count * sim.R.K_AREA
			c = land > 0 and nations * E.CROWDED_FULL_TILES_PER_NATION > land
			self._crowded = c
		end
		return c
	end

	-- Due: fewer of `kind` than its share of the cities (levels counted).
	function C:_structure_due(sim, id: number, kind: number, cities: number, age: number): boolean
		local d = sim:ai_difficulty(id)
		if kind == S_PORT then
			return sim.o_coast[id] > 0 and sim:struct_levels(id, S_PORT) < Defs.trunc(cities * E.PORT_PER_CITY)
		elseif kind == S_FACTORY then
			local mult = if sim.o_coast[id] > 0 then E.FACTORY_COASTAL_MULT else 1.0
			return sim:struct_levels(id, S_FACTORY) < Defs.trunc(cities * E.FACTORY_PER_CITY * mult)
		elseif kind == S_SAM then
			return sim:struct_levels(id, S_SAM) < Defs.trunc(cities * SAM_PER_CITY[d]) and age > NATION_WAR_AGE
		elseif kind == S_SILO then
			local silos = sim:struct_count(id, S_SILO)
			return silos < E.MAX_SILOS
				and silos < Defs.trunc(cities * (if silos == 0 then E.FIRST_SILO_PER_CITY else E.SILO_PER_CITY))
				and age > NUKE_AGE[d] - 900
				and self.rank[id] <= E.SILO_TOP_RANK
		end
		return false
	end

	-- Build (or, on a crowded territory, upgrade) one `kind` when the nation
	-- has its perceived cost and a place for it. True when something was ordered.
	function C:_spawn_structure(sim, id: number, kind: number, cities: number, threat: number): boolean
		local gold = sim.o_gold[id]
		local cost = Rules.build_cost_kind(kind, sim:cost_count(id, kind))
		-- Perceived cost: inflate by owned count until the MIRV + hydrogen stockpile is reached
		-- (never before the third city).
		local perceived = cost
		if kind ~= S_DEFENSE and cities >= E.CITIES_BEFORE_SAVING then
			local save_up = Rules.nuke_cost("mirv", sim.mirvs_launched) + Rules.nuke_cost("hydrogen")
			if gold < save_up then
				perceived = cost * (1.0 + PERCEIVED_COST_STEP[kind] * sim:struct_levels(id, kind))
			end
		end
		if gold < perceived then
			return false
		end
		-- on a crowded territory upgrade instead (or leave it: a construction is under way)
		if Rules.is_upgradable(kind) and sim:struct_count(id, kind) > 0 then
			local total = 0
			for k = 0, Defs.STRUCT_KIND_COUNT - 1 do
				total += sim:struct_count(id, k)
			end
			if total * E.UPGRADE_DENSITY_FULL_TILES > sim.o_tiles[id] * sim.R.K_AREA then
				local ready = {}
				for _, s in sim:structs_of(id, kind) do
					if s.active then
						table.insert(ready, s)
					end
				end
				return #ready > 0
					and sim:try_build(id, Defs.STRUCT_NAMES[kind], ready[sim.rng:randi() % #ready + 1].tile) == true
			end
		end
		local site = self:_pick_site(sim, id, kind, threat)
		return site >= 0 and sim:try_build(id, Defs.STRUCT_NAMES[kind], site) == true
	end

	function C:_consider_build(sim, id: number, age: number)
		if sim.tick - self.last_build[id] < 20 then
			return
		end
		if sim.o_gold[id] < 100000.0 then
			return
		end
		-- Cities count by level.
		local cities = sim:struct_levels(id, S_CITY)
		local threat = self:_defense_threat(sim, id)
		-- A defense post against a threatening neighbour comes before the economy.
		if
			cities > 0
			and threat > 0
			and sim:struct_count(id, S_DEFENSE) < self:_defense_cap(sim, id)
			and sim.tick - self.last_defense[id] >= E.DEFENSE_GAP
			and sim.rng:randf() < 0.35
		then
			if self:_spawn_structure(sim, id, S_DEFENSE, cities, threat) then
				self.last_build[id] = sim.tick
				self.last_defense[id] = sim.tick
			end
			return
		end
		-- The very first structure is a port; without a coast a factory, on a crowded map only.
		if self.crowded_first[id] == 0 then
			local coastal = sim.o_coast[id] > 0
			if (coastal and E.PORT_FIRST) or self:_crowded_map(sim) then
				local first = if coastal then S_PORT else S_FACTORY
				if sim.o_gold[id] >= Rules.build_cost_kind(first, sim:cost_count(id, first)) then
					-- (with the gold and still nothing built: there is no place for it, cities then)
					self.crowded_first[id] = 1
					if self:_spawn_structure(sim, id, first, cities, threat) then
						self.last_build[id] = sim.tick
						return
					end
				end
			else
				self.crowded_first[id] = 1
			end
		end
		for _, kind in E.BUILD_ORDER do
			if self:_structure_due(sim, id, kind, cities, age) and self:_spawn_structure(sim, id, kind, cities, threat) then
				self.last_build[id] = sim.tick
				return
			end
		end
		if self:_spawn_structure(sim, id, S_CITY, cities, threat) then
			self.last_build[id] = sim.tick
		end
	end

	-- Defense posts are allowed on long borders only: 1 per DEFENSE_PER_BORDER border tiles
	-- (at least 1, at most DEFENSE_CAP).
	function C:_defense_cap(sim, id: number): number
		if sim.o_kind[id] == Defs.KIND_TRIBE then
			return 1
		end
		return math.clamp(sim.bcount[id] // (E.DEFENSE_PER_BORDER * sim.R.LEGACY_LIN), 1, E.DEFENSE_CAP)
	end

	-- The neighbour worth fortifying against, sharing a real border: one attacking us now, one
	-- that attacked us in the last minute and is not trivially weak, or (after the land grab) a
	-- nation much stronger than us along a long border. Tribes only fortify against live attacks.
	-- 0 when nobody threatens us.
	function C:_defense_threat(sim, id: number): number
		local mine = math.max(sim.o_troops[id], 1.0)
		local age = sim.tick - sim.playing_since
		local tribe = sim.o_kind[id] == Defs.KIND_TRIBE
		local best = 0
		local bs = 0.0
		local sc_count = sim.sc_count
		local L = sim.R.LEGACY_LIN
		for _, p in sim.sc_list do
			if sc_count[p] < 6 * L or sim:allied(id, p) then
				continue
			end
			local theirs = sim.o_troops[p]
			local attacking = sim:attack_between(p, id) ~= nil
			local ok = attacking
			if not ok and not tribe then
				-- (GDScript: if grudge… ok = true elif war-age… ok = true)
				if
					(sim:grudge_of(id, p) and theirs > 0.7 * mine)
					or (
						age > NATION_WAR_AGE
						and sim.o_kind[p] ~= Defs.KIND_TRIBE
						and theirs > 1.5 * mine
						and sc_count[p] >= 12 * L
					)
				then
					ok = true
				end
			end
			if not ok then
				continue
			end
			local s = theirs * (if attacking then 2.0 else 1.0)
			if s > bs then
				bs = s
				best = p
			end
		end
		if best < 0 then
			self.port_wait[id] = sim.tick + E.PORT_RETRY_TICKS
		end
		return best
	end

	function C:_pick_site(sim, id: number, kind: number, threat: number): number
		local tiles = sim.o_tiles[id]
		if kind == S_PORT then
			return self:_port_site(sim, id)
		elseif kind == S_FACTORY then
			return self:_factory_site(sim, id)
		elseif kind == S_DEFENSE then
			return self:_defense_site(sim, id, threat)
		elseif kind == S_SAM then
			local cities = sim:structs_of(id, S_CITY)
			if #cities > 0 then
				local s = sim:find_site(
					id,
					kind,
					cities[sim.rng:randi() % #cities + 1].tile,
					math.ceil(8 * sim.R.LEGACY_LIN),
					16
				)
				if s >= 0 then
					return s
				end
			end
		end
		-- Cities (and silos / fallback SAMs) sit around the centre of the territory.
		local L = sim.R.LEGACY_LIN
		local spread = math.clamp(Defs.trunc(math.sqrt(tiles) * 0.45), math.ceil(6 * L), math.ceil(45 * L))
		local site = sim:find_site(id, kind, sim:centre_tile(id), spread, 24)
		if site < 0 then
			site = sim:find_site(
				id,
				kind,
				if sim.o_spawn_tile[id] >= 0 then sim.o_spawn_tile[id] else sim.bhead[id],
				spread,
				12
			)
		end
		return site
	end

	-- Ports spread along the coast: the valid coastal site farthest from our other ports
	-- (structures keep STRUCT_MIN_DIST apart as everywhere), on the ocean or
	-- on water big enough for trade.
	function C:_port_site(sim, id: number): number
		if sim.tick < self.port_wait[id] then
			return -1
		end
		local sizes = body_tiles(sim.map)
		local need = E.PORT_WATER_FULL_TILES / sim.R.K_AREA
		local cb = sim.map.coast_body
		local readu16 = buffer.readu16
		local function water_ok(t: number): boolean
			local b = readu16(cb, t * 2)
			return b == 1 or (sizes[b] or 0) >= need
		end
		local anchor = sim:own_coast_tile(id)
		local best = -1
		local best_d = -1.0
		local ct = sim.map.coast_list
		local nct = sim.map.coast_count
		local owner = sim.owner
		local L = sim.R.LEGACY_LIN
		local far = math.ceil(60 * L)
		-- our coast tiles (big maps have tens of thousands of coast tiles, so a blind pick from the
		-- map's list is rarely ours): one pass, at most 4096 kept
		local mine = {}
		for k = 0, nct - 1 do
			local r = readi32(ct, k * 4)
			if readi32(owner, r * 4) == id and water_ok(r) then
				mine[#mine + 1] = r
				if #mine >= 4096 then
					break
				end
			end
		end
		for i = 0, 35 do
			local c = -1
			if i < 16 then
				c = sim:find_site(id, S_PORT, anchor, math.ceil(30 * L), 1)
			elseif #mine > 0 then
				local r = mine[sim.rng:randi() % #mine + 1]
				if sim:valid_site(id, S_PORT, r) then
					c = r
				end
			end
			if c < 0 or not water_ok(c) then
				continue
			end
			local dd = sim:own_struct_dist2(id, S_PORT, c, far)
			if dd < 0.0 then
				dd = far * far + 1.0
			end
			if dd > best_d then
				best_d = dd
				best = c
			end
		end
		if best < 0 then
			self.port_wait[id] = sim.tick + E.PORT_RETRY_TICKS
		end
		return best
	end

	-- Factories go next to an existing city or port that is already on the road network.
	function C:_factory_site(sim, id: number): number
		local hubs = {}
		local any = {}
		for _, k in { S_CITY, S_PORT } do
			for _, s in sim:structs_of(id, k) do
				table.insert(any, s)
				if s.station then
					table.insert(hubs, s)
				end
			end
		end
		if #hubs == 0 then
			hubs = any
		end
		for _ = 1, math.min(#hubs, 4) do
			local h = hubs[sim.rng:randi() % #hubs + 1]
			local site =
				sim:find_site(id, S_FACTORY, h.tile, sim.R.STRUCT_SPACING + math.ceil(3 * sim.R.LEGACY_LIN), 14)
			if site >= 0 then
				return site
			end
		end
		return -1
	end

	-- A defense post just behind the border facing `threat`, never inside the radius of another
	-- of our posts.
	function C:_defense_site(sim, id: number, threat: number): number
		if threat <= 0 or sim.sc_count[threat] <= 0 then
			return -1
		end
		local contact = sim.sc_tile[threat]
		local r = sim.R.DEFENSE_RADIUS
		local near = math.ceil(4 * sim.R.LEGACY_LIN)
		for _ = 1, 16 do
			local c = sim:find_site(id, S_DEFENSE, contact, near, 1)
			if c >= 0 and sim:own_struct_dist2(id, S_DEFENSE, c, r) < 0.0 then
				return c
			end
		end
		return -1
	end

	-- =========================================================================================
	-- Warships (the nations' warship behaviour)
	-- =========================================================================================

	function C:_warship_cost(sim, id: number): number
		return Rules.build_cost(
			Rules.WARSHIP_KIND_NAME,
			math.min(sim.o_warships[id], sim.o_built[id * STRUCT_KINDS + Rules.BUILT_WARSHIP])
		)
	end

	-- Each attack cycle, chance 1 in 50: the first warship, patrolling a random
	-- sea tile within 250 full-size tiles of one of the nation's ports.
	function C:_maybe_spawn_warship(sim, id: number)
		if sim.rng:randi() % 50 ~= 0 or sim.o_warships[id] > 0 or sim.o_gold[id] <= self:_warship_cost(sim, id) then
			return
		end
		local ports = {}
		for _, p in sim.port_list do
			if p.owner == id and p.water >= 0 then
				table.insert(ports, p)
			end
		end
		if #ports == 0 then
			return
		end
		local port = ports[sim.rng:randi() % #ports + 1]
		local t = self:_sea_tile_near(sim, port.tile, 250.0 / sim.R.K_LIN)
		if t >= 0 then
			sim:build_warship(id, t)
		end
	end

	-- A random water tile within `r` tiles (box) of `t`, or -1.
	function C:_sea_tile_near(sim, t: number, r: number): number
		local ri = Defs.trunc(r)
		local rx = sim.geo_span(t, r)
		local terrain = sim.map.terrain
		local region = sim.nav.region
		local rng = sim.rng
		local W = sim.W
		for _ = 1, 50 do
			local x = (t % W) + rng:randi_range(-rx, rx)
			local y = (t // W) + rng:randi_range(-ri, ri)
			if y < 1 or y >= sim.H - 1 or x < 0 or x >= W then
				continue
			end
			local c = y * W + x
			if readu8(terrain, c) <= T_LAKE and readi32(region, c * 4) >= 0 then
				return c
			end
		end
		return -1
	end

	function C:on_transport_sunk(sim, u, killer: number)
		if killer > 0 and self:_tracks_ships(sim, u.owner) then
			self:_retaliate(sim, u.owner, sim:unit_tile(u), killer)
		end
	end

	function C:on_trade_captured(sim, victim: number, captor: number, t: number)
		if self:_tracks_ships(sim, victim) then
			self:_retaliate(sim, victim, t, captor)
		end
	end

	-- Retaliation: an invasion heading for a nation with no warship within
	-- 90 full-size tiles of the landing (by position or patrol tile) makes it answer near the landing.
	function C:on_transport_launched(sim, u, tg: number)
		if not self:_tracks_ships(sim, tg) or sim:allied(u.owner, tg) or u.target_tile < 0 then
			return
		end
		local r = 90.0 / sim.R.K_LIN
		local range_d2 = sim.range_d2
		local geo_manhattan = sim.geo_manhattan
		for _, w in sim.warship_list do
			if w.dead or w.owner ~= tg then
				continue
			end
			if
				range_d2(sim:unit_tile(w), u.target_tile) <= r * r
				or (w.patrol >= 0 and geo_manhattan(u.target_tile, w.patrol) < r)
			then
				return
			end
		end
		local sea = self:_sea_tile_near(sim, u.target_tile, 30.0 / sim.R.K_LIN)
		if sea >= 0 then
			self:_retaliate(sim, tg, sea, u.owner)
		end
	end

	function C:_tracks_ships(sim, id: number): boolean
		return id > 0
			and sim.o_ai[id] == 1
			and (sim.o_kind[id] == Defs.KIND_NATION or sim.o_bot[id] == 1)
			and sim.o_alive[id] == 1
			and sim:ai_difficulty(id) > 0
			and sim.o_built[id * STRUCT_KINDS + S_PORT] > 0
	end

	function C:_retaliate(sim, id: number, t: number, enemy: number)
		if enemy == id or t < 0 then
			return
		end
		if sim.o_warships[id] >= WARSHIP_FLEET_CAP then
			self:_move_nearest_warship(sim, id, t)
			return
		end
		if sim.rng:randf() < WARSHIP_RETALIATE_P[sim:ai_difficulty(id)] then
			if
				readu8(sim.map.terrain, t) > T_LAKE
				or sim.o_gold[id] < self:_warship_cost(sim, id)
				or not sim:build_warship(id, t)
			then
				self:_move_nearest_warship(sim, id, t)
			end
		end
	end

	-- Re-tasking: the nearest warship still near its own patrol area takes `t` as patrol tile.
	function C:_move_nearest_warship(sim, id: number, t: number)
		if readu8(sim.map.terrain, t) > T_LAKE then
			return
		end
		local near = Rules.WARSHIP_RANGE_FULL / sim.R.K_LIN
		local geo_manhattan = sim.geo_manhattan
		local best = nil
		local bd = 0.0
		for _, w in sim.warship_list do
			if w.dead or w.owner ~= id or w.patrol < 0 then
				continue
			end
			local pos = sim:unit_tile(w)
			if geo_manhattan(pos, w.patrol) >= near then
				continue
			end
			local d = geo_manhattan(pos, t)
			if best == nil or d < bd then
				best = w
				bd = d
			end
		end
		if best ~= nil then
			sim:move_warship(id, best.uid, t)
		end
	end

	-- Warship swarms (Hard only): when 10+ warships sail and some enemy owns more than
	-- 10, one of the three richest AI owners builds a warship on top of one of them.
	function C:_counter_infestation(sim, id: number)
		if sim:ai_difficulty(id) < 2 or #sim.warship_list <= WARSHIP_FLEET_CAP or sim.o_warships[id] >= WARSHIP_FLEET_CAP then
			return
		end
		if sim.o_gold[id] < self:_warship_cost(sim, id) or sim.o_alevel[id * STRUCT_KINDS + S_PORT] <= 0 then
			return
		end
		local richer = 0
		local o_alive = sim.o_alive
		local o_gold = sim.o_gold
		for p = 1, sim.owner_total do
			if p ~= id and o_alive[p] == 1 and sim.o_kind[p] ~= Defs.KIND_HUMAN and o_gold[p] > o_gold[id] then
				richer += 1
				if richer >= 3 then
					return
				end
			end
		end
		for p = 1, sim.owner_total do
			if p == id or o_alive[p] == 0 or sim:allied(id, p) or sim.o_warships[p] <= WARSHIP_FLEET_CAP then
				continue
			end
			local theirs = {}
			for _, w in sim.warship_list do
				if not w.dead and w.owner == p then
					table.insert(theirs, w)
				end
			end
			if #theirs == 0 then
				continue
			end
			local target = theirs[sim.rng:randi() % #theirs + 1]
			local t = sim:unit_tile(target)
			if not sim:build_warship(id, t) then
				self:_move_nearest_warship(sim, id, t)
			end
			return
		end
	end
end

return SimAIEconomy
