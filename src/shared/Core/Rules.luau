--!native
-- Port of scripts/core/rules.gd: every balance number and formula of the simulation. Numbers are
-- stated in full-size-tile units and scaled to the map's own tiles (see the map-scale conversion
-- below). The Sim charges exactly
-- what these functions return, so the UI and renderer may call them for costs, caps, incomes and
-- ranges.
--
-- Map-scale conversion: one of our tiles is K_LIN full-resolution full-size tiles across (per map:
-- map.k_lin, 1.0 unless the importer resampled the map to its tile budget, see WorldMap).
--   * a tile COUNT fed to a formula is multiplied by K_AREA (our tile is K_AREA full-size tiles);
--   * a full-size DISTANCE (ranges, radii, speeds in tiles/tick) is divided by K_LIN to get our tiles;
--   * an attack border length is multiplied by K_LIN;
--   * conquering one of our tiles costs K_AREA full-size tiles worth of troops and attack time, so the
--     same land AREA falls per second on every map. Time is never scaled (10 ticks/s).
-- Economy numbers are per player, not per tile, and are used unscaled. With K_LIN = 1 every number
-- is used as written.
--
-- Per-map rules: this module is the K_LIN = 1 table; Rules.for_map(map) / Rules.for_k(k_lin) return
-- the (cached) table built for another scale — same API, scaled constants. The Sim keeps its map's
-- table in `sim.R`; GameState in `state.rules`.
-- Geometry comes from the map (flat grid and its metrics): place_site takes the map,
-- near_structures / warship_port / placement read state.map.
-- Units: troops and gold are plain numbers (format with Defs.format_troops); time in ticks.
--
-- Luau conventions: tables indexed by an enum (BUILD_TICKS[Defs.S_CITY], ATTACK_MAG[terrain code],
-- NUKE_*[Defs.N_*], NATION_*[difficulty]) are keyed by the enum value (0-based). Functions that
-- returned a Vector2 return two numbers (nuke_radii → inner, outer). PackedFloat32Array constants
-- are rounded to float32 like the Godot version.
local Defs = require("./Defs")

local f32 = Defs.f32
local function f32t(values: { number }): { [number]: number }
	local out = {}
	for i, v in ipairs(values) do
		out[i - 1] = f32(v)
	end
	return out
end
local function zt(values: { any }): { [number]: any }
	local out = {}
	for i, v in ipairs(values) do
		out[i - 1] = v
	end
	return out
end

local function clampi(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local trunc = Defs.trunc

--- Builds the rules table for maps whose tiles are `K_LIN` full-size tiles across.
local function build(K_LIN: number): any
	local Rules: any = {}
	Rules.TICK_RATE = 10
	--- Full-size tiles per one of our tiles, linear and by area (the map's k_lin).
	Rules.K_LIN = K_LIN
	Rules.K_AREA = K_LIN * K_LIN
	local K_AREA = Rules.K_AREA
	--- Our tiles per tile of the original 1024 x 512 Earth grid (2000 / 1024 full-size tiles), where the
	--- AI heuristics were tuned: distances in those tiles scale by
	--- LEGACY_LIN, tile counts by LEGACY_AREA.
	Rules.LEGACY_LIN = (2000.0 / 1024.0) / K_LIN
	Rules.LEGACY_AREA = Rules.LEGACY_LIN * Rules.LEGACY_LIN

	-- ---------------------------------------------------------------------------------------------
	-- Spawning (startManpower, startingGold, minDistanceBetweenPlayers)
	-- ---------------------------------------------------------------------------------------------
	--- Spawn: a start claims the free land within euclidean distance 4 full-size tiles of the corner
	--- of the start tile (the disc is centred there) — nations, tribes and humans alike.
	Rules.SPAWN_RADIUS = 4.0 / K_LIN
	Rules.SPAWN_RADIUS_AI = Rules.SPAWN_RADIUS
	Rules.SPAWN_RADIUS_HUMAN = Rules.SPAWN_RADIUS
	--- Tribes spawn at least this far from any claimed tile: minDistanceBetweenPlayers 30 full-size tiles.
	Rules.TRIBE_SPAWN_MIN_DIST = 30.0 / K_LIN
	--- Nation spawn: a nation starts on free land within +-25 full-size tiles of its
	--- manifest coordinates (50 tries; mountains are skipped half the time).
	Rules.NATION_SPAWN_DELTA = 25.0 / K_LIN
	--- Default tribe count: 400 on every map (public lobbies, the
	--- singleplayer and private-lobby defaults; only half-size "compact" maps use 100).
	Rules.DEFAULT_TRIBES = 400
	--- Solo: countdown after the player's first pick.
	Rules.SOLO_COUNTDOWN_TICKS = 50
	--- Multiplayer default spawn phase length (config.spawn_ticks overrides).
	Rules.DEFAULT_SPAWN_TICKS = 200
	--- startManpower: humans 25k, tribes 10k, nations by difficulty (see NATION_START_TROOPS).
	Rules.START_TROOPS_HUMAN = 25000.0
	Rules.START_TROOPS_TRIBE = 10000.0
	--- startingGold: 0 by default.
	Rules.START_GOLD = 0.0
	--- Late joiners start with this fraction of the median nation's troops (never below START_TROOPS_HUMAN / 2).
	Rules.LATE_JOIN_TROOP_FRACTION = 0.4

	-- ---------------------------------------------------------------------------------------------
	-- Difficulty: Relaxed / Standard / Brutal (index = config.difficulty: 0 / 1 / 2)
	-- ---------------------------------------------------------------------------------------------
	--- maxTroops nation multiplier. Kept as doubles, not float32 (the
	--- Godot version's float32 packing made 0.9 x 10 = 8.99999 and truncated to 8).
	Rules.NATION_TROOP_MULT = zt({ 0.5, 0.75, 1.0 })
	--- troopIncreaseRate nation multiplier.
	Rules.NATION_GROWTH_MULT = zt({ 0.9, 0.95, 1.0 })
	--- startManpower for nations.
	Rules.NATION_START_TROOPS = zt({ 12500.0, 18750.0, 25000.0 })

	-- ---------------------------------------------------------------------------------------------
	-- Troops (maxTroops, troopIncreaseRate, cityTroopIncrease)
	-- ---------------------------------------------------------------------------------------------
	Rules.CITY_TROOPS = 250000.0
	--- Tribes: maxTroops / 3, growth x 0.5.
	Rules.TRIBE_CAP_DIV = 3.0
	Rules.TRIBE_GROWTH_MULT = 0.5

	local KIND_NATION = Defs.KIND_NATION
	local KIND_TRIBE = Defs.KIND_TRIBE
	local KIND_HUMAN = Defs.KIND_HUMAN

	function Rules.start_troops(kind: number, difficulty: number): number
		if kind == KIND_TRIBE then
			return Rules.START_TROOPS_TRIBE
		elseif kind == KIND_NATION then
			return Rules.NATION_START_TROOPS[clampi(difficulty, 0, 2)]
		end
		return Rules.START_TROOPS_HUMAN
	end

	--- maxTroops = 2 * (numTiles^0.6 * 1000 + 50000) + cities * 250k, numTiles in full-size tiles.
	function Rules.max_troops(kind: number, tiles: number, cities: number, difficulty: number): number
		local m = 2.0 * ((math.max(tiles, 0) * K_AREA) ^ 0.6 * 1000.0 + 50000.0) + cities * 250000.0
		if kind == KIND_TRIBE then
			return m / 3.0
		end
		if kind == KIND_NATION then
			return m * Rules.NATION_TROOP_MULT[clampi(difficulty, 0, 2)]
		end
		return m
	end

	--- troopIncreaseRate: toAdd = (10 + troops^0.73 / 4) *
	--- (1 - troops/max) [tribes x0.5, nations by difficulty]; the result is min(troops + toAdd, max) -
	--- troops, so troops above the cap snap to it. This is the float the UI shows; each tick adds it
	--- as whole troops, which truncates it (see troop_growth_applied).
	function Rules.troop_growth(kind: number, troops: number, cap: number, difficulty: number): number
		local add = (10.0 + math.max(troops, 0.0) ^ 0.73 / 4.0) * (1.0 - troops / math.max(cap, 1.0))
		if kind == KIND_TRIBE then
			add *= 0.5
		elseif kind == KIND_NATION then
			add *= Rules.NATION_GROWTH_MULT[clampi(difficulty, 0, 2)]
		end
		return math.min(troops + add, cap) - troops
	end

	--- What one tick really adds: troops grow in whole troops, a positive rate adds
	--- floor(x) and a negative rate removes floor(-x), i.e. the rate
	--- truncated toward zero.
	function Rules.troop_growth_applied(kind: number, troops: number, cap: number, difficulty: number): number
		return trunc(Rules.troop_growth(kind, troops, cap, difficulty))
	end

	-- ---------------------------------------------------------------------------------------------
	-- Gold (goldAdditionRate, conquerGoldAmount)
	-- ---------------------------------------------------------------------------------------------
	--- goldAdditionRate: 100 per tick for humans and nations, 50 for tribes.
	Rules.GOLD_PER_TICK = 100.0
	Rules.TRIBE_GOLD_PER_TICK = 50.0

	function Rules.gold_per_tick(kind: number): number
		return if kind == KIND_TRIBE then 50.0 else 100.0
	end

	--- Passive gold per second (goldAdditionRate x 10). Trade ships, trains and conquests come on top.
	--- (Signature kept for the UI; territory and factories don't change it.)
	function Rules.passive_income(kind: number, tiles: number, _factories: number?, _difficulty: number?): number
		if tiles > 0 then
			return Rules.gold_per_tick(kind) * 10.0
		end
		return 0.0
	end

	--- conquerGoldAmount: conquering a nation or tribe takes all its gold, a human half of it.
	function Rules.conquer_gold(victim_kind: number, victim_gold: number): number
		return victim_gold * (if victim_kind == KIND_HUMAN then 0.5 else 1.0)
	end

	-- ---------------------------------------------------------------------------------------------
	-- Structures (costs, structureMinDist, defensePost*, SAM*, Silo*)
	-- ---------------------------------------------------------------------------------------------
	--- structureMinDist 15 full-size tiles: a site is valid only when no structure lies closer than
	--- STRUCT_MIN_DIST tiles (euclidean, map.range_d2). STRUCT_SPACING is that distance rounded up.
	Rules.STRUCT_MIN_DIST = 15.0 / K_LIN
	Rules.STRUCT_SPACING = math.ceil(15.0 / K_LIN)
	Rules.WARSHIP_KIND_NAME = "warship"
	--- defensePostRange 30 full-size tiles; inside it a post multiplies mag x5 (defensePostDefenseBonus) and
	--- tileCost x3 (defensePostSpeedBonus).
	Rules.DEFENSE_RANGE_FULL = 30.0
	Rules.DEFENSE_POST_MAG = 5.0
	Rules.DEFENSE_POST_COST = 3.0
	--- Integer radius of the defense-post coverage map (ceil of defense_range()).
	Rules.DEFENSE_RADIUS = math.ceil(30.0 / K_LIN)
	--- SAMCooldown / SiloCooldown: 90 ticks per missile; a SAM or silo holds `level` missiles.
	Rules.SAM_COOLDOWN_TICKS = 90
	Rules.SILO_COOLDOWN_TICKS = 90
	--- samUpgradeDuration (SAMCooldown / 2): after an upgrade the SAM's range grows to the new level's
	--- over this many ticks.
	Rules.SAM_UPGRADE_TICKS = 45
	--- constructionDuration (ticks), index = Defs.S_*: city 2 s, port 5 s, factory 2 s,
	--- defense post 5 s, SAM 30 s, silo 10 s. A structure under construction blocks placement and
	--- counts for prices but does nothing and can't be upgraded.
	--- (Arsenal: artillery 8 s, airfield 10 s, railgun 15 s.)
	Rules.BUILD_TICKS = zt({ 20, 50, 20, 50, 300, 100, 80, 100, 150 })
	--- Upgradable: city, port, factory, SAM and silo gain levels; defense posts don't (nor
	--- the Arsenal's structures).
	Rules.UPGRADABLE = zt({ 1, 1, 1, 0, 1, 1, 0, 0, 0 })
	--- Build search radius (15 full-size tiles): a build click floods the builder's own
	--- connected land within this range and builds on the nearest tile with no structure closer than
	--- STRUCT_MIN_DIST. radiusPortSpawn (20 full-size tiles, manhattan) limits where a port may snap to the coast.
	Rules.PLACE_SEARCH_R = 15.0 / K_LIN
	Rules.PORT_SPAWN_MANHATTAN = 20.0 / K_LIN
	--- Per-owner "constructed" counters (units ever built): index Defs.S_* for structures,
	--- BUILT_WARSHIP for warships.
	Rules.BUILT_WARSHIP = 15
	Rules.BUILT_SLOTS = 16
	--- samRange(level) = 150 - 480 / (level + 5) full-size tiles (level 1 = 70).
	Rules.SAM_MAX_RANGE_FULL = 150.0
	--- Integer SAM range at level 1 (our tiles), for callers that want a constant.
	Rules.SAM_RADIUS = math.ceil(70.0 / K_LIN)

	--- Defense-post protection radius in OUR tiles (euclidean, map.range_d2).
	function Rules.defense_range(): number
		return 30.0 / K_LIN
	end

	--- SAM interception range in OUR tiles for a SAM of `level` (euclidean, map.range_d2).
	function Rules.sam_range(level: number?): number
		local l = level or 1
		return (150.0 - 480.0 / (math.max(l, 1) + 5)) / K_LIN
	end

	--- Gold cost of the next structure (or level) of `kind_name`. `owned_count` is the owner's
	--- cost count (see cost_count_kinds / cost_of). Upgrading costs the same as building.
	--- For "warship": min(warships owned, warships ever built). Returns -1 for unknown kinds.
	function Rules.build_cost(kind_name: string, owned_count: number): number
		local n = math.max(owned_count, 0)
		if kind_name == "city" or kind_name == "port" or kind_name == "factory" then
			return math.min(1000000, 125000 * 2 ^ math.min(n, 4))
		elseif kind_name == "defense" then
			return math.min(250000, 50000 * (n + 1))
		elseif kind_name == "sam" then
			return math.min(3000000, 1500000 * (n + 1))
		elseif kind_name == "silo" then
			return 1000000
		elseif kind_name == "warship" then
			return math.min(1000000, 250000 * (n + 1))
		elseif kind_name == "artillery" then
			return math.min(750000, 150000 * (n + 1))
		elseif kind_name == "airfield" then
			return math.min(1500000, 500000 * (n + 1))
		elseif kind_name == "railgun" then
			return math.min(7500000, 2500000 * (n + 1))
		end
		return -1
	end

	--- Structure kinds (Defs.S_*) whose owned counts add up to the count build_cost() expects (1-based list).
	function Rules.cost_count_kinds(kind_name: string): { number }
		if kind_name == "port" or kind_name == "factory" then
			return { Defs.S_PORT, Defs.S_FACTORY }
		end
		local k = Defs.struct_kind_from_name(kind_name)
		if k >= 0 then
			return { k }
		end
		return {}
	end

	function Rules.build_cost_kind(kind: number, owned_count: number): number
		if kind < 0 or kind >= Defs.STRUCT_KIND_COUNT then
			return -1
		end
		return Rules.build_cost(Defs.STRUCT_NAMES[kind], owned_count)
	end

	function Rules.is_upgradable(kind: number): boolean
		return kind >= 0 and kind < Defs.STRUCT_KIND_COUNT and Rules.UPGRADABLE[kind] == 1
	end

	--- SAM range (our tiles) `ticks_since_upgrade` after being raised to `level` (ramps over
	--- SAM_UPGRADE_TICKS from the previous level's range: a dynamic SAM range).
	function Rules.sam_range_at(level: number, ticks_since_upgrade: number): number
		local r = Rules.sam_range(level)
		if level <= 1 or ticks_since_upgrade >= Rules.SAM_UPGRADE_TICKS then
			return r
		end
		local r0 = Rules.sam_range(level - 1)
		return r0 + (r - r0) * math.max(ticks_since_upgrade, 0) / Rules.SAM_UPGRADE_TICKS
	end

	--- THE placement algorithm (upgrade a structure in reach, or else find a land or coastal site
	--- among the valid tiles near the click), shared by the Sim and by previews on a GameState.
	--- `map` gives the grid and metrics, `owner_grid` (i32 buffer) / `coastal` (u8 buffer) are the tile
	--- arrays, `now` the current tick,
	--- and `near` every structure (any owner) within PLACE_SEARCH_R + STRUCT_MIN_DIST of `tile` as
	--- 1-based rows {sid, kind, owner, tile, level, active_tick}, sorted by sid.
	--- Returns {tile = int, upgrade_sid = int, reason = string}:
	--- * the clicked tile must be `id`'s ("not_own");
	--- * upgradable kinds: if the nearest structure of that kind within STRUCT_MIN_DIST of the click is
	---   `id`'s and finished, the click upgrades it (upgrade_sid, tile = its tile);
	--- * otherwise flood `id`'s 4-connected land within PLACE_SEARCH_R of the click, keep tiles with no
	---   structure closer than STRUCT_MIN_DIST and take the one nearest the click (ports: coastal tiles
	---   within PORT_SPAWN_MANHATTAN, nearest by manhattan distance) — "no_room" / "no_coast" if none.
	function Rules.place_site(
		map: any,
		owner_grid: buffer,
		coastal: buffer,
		id: number,
		kind: number,
		tile: number,
		near: { { number } },
		now: number
	): { tile: number, upgrade_sid: number, reason: string }
		local out = { tile = -1, upgrade_sid = 0, reason = "" }
		local W = map.W
		local N = map.N
		local range_d2 = map.range_d2
		local geo_manhattan = map.geo_manhattan
		if tile < 0 or tile >= N or kind < 0 or kind >= Defs.STRUCT_KIND_COUNT then
			out.reason = "invalid"
			return out
		end
		if buffer.readi32(owner_grid, tile * 4) ~= id then
			out.reason = "not_own"
			return out
		end
		local md2 = Rules.STRUCT_MIN_DIST * Rules.STRUCT_MIN_DIST
		if Rules.is_upgradable(kind) then
			local best: { number }? = nil
			local bd = 0.0
			for _, row in near do
				if row[2] ~= kind then
					continue
				end
				local d = range_d2(row[4], tile)
				if d > md2 then
					continue
				end
				if best == nil or d < bd or (d == bd and row[1] < (best :: { number })[1]) then
					best = row
					bd = d
				end
			end
			if best ~= nil and best[3] == id and best[6] <= now then
				out.tile = best[4]
				out.upgrade_sid = best[1]
				return out
			end
		end
		local r2 = Rules.PLACE_SEARCH_R * Rules.PLACE_SEARCH_R
		local seen: { [number]: boolean } = { [tile] = true }
		local stack = { tile }
		local flood = { tile }
		while #stack > 0 do
			local t = stack[#stack]
			stack[#stack] = nil
			local x = t % W
			local n1 = if t >= W then t - W else -1
			local n2 = if t < N - W then t + W else -1
			local n3 = if x > 0 then t - 1 else -1
			local n4 = if x < W - 1 then t + 1 else -1
			for k = 1, 4 do
				local n = if k == 1 then n1 elseif k == 2 then n2 elseif k == 3 then n3 else n4
				if n < 0 or seen[n] or buffer.readi32(owner_grid, n * 4) ~= id or range_d2(tile, n) >= r2 then
					continue
				end
				seen[n] = true
				table.insert(flood, n)
				table.insert(stack, n)
			end
		end
		local port = kind == Defs.S_PORT
		local pick = -1
		local pd = 0.0
		for _, t in flood do
			if port and (buffer.readu8(coastal, t) == 0 or geo_manhattan(tile, t) > Rules.PORT_SPAWN_MANHATTAN) then
				continue
			end
			local blocked = false
			for _, row in near do
				if range_d2(row[4], t) < md2 then
					blocked = true
					break
				end
			end
			if blocked then
				continue
			end
			local d = if port then geo_manhattan(tile, t) else range_d2(tile, t)
			if pick < 0 or d < pd then
				pick = t
				pd = d
			end
		end
		if pick < 0 then
			out.reason = if port then "no_coast" else "no_room"
			return out
		end
		out.tile = pick
		return out
	end

	--- Structure rows {sid, kind, owner, tile, level, active_tick} of a GameState within the reach
	--- place_site() needs around `tile`, sorted by sid.
	function Rules.near_structures(state: any, tile: number): { { number } }
		local range_d2 = state.map.range_d2
		local reach = Rules.PLACE_SEARCH_R + Rules.STRUCT_MIN_DIST + 1.0
		local r2 = reach * reach
		local out = {}
		for _, s in state.structures do
			if range_d2(tile, s.tile) <= r2 or range_d2(s.tile, tile) <= r2 then
				table.insert(out, { s.sid, s.kind, s.owner, s.tile, s.level, s.active_tick })
			end
		end
		table.sort(out, function(a, b)
			return a[1] < b[1]
		end)
		return out
	end

	--- Cost count for `id` and `kind_name` from a GameState (see build_cost()).
	function Rules.cost_count_of(state: any, id: number, kind_name: string): number
		if kind_name == "warship" then
			return math.min(state:count_units(id, Defs.U_WARSHIP), state:built_count(id, Rules.BUILT_WARSHIP))
		end
		local n = 0
		for _, k in Rules.cost_count_kinds(kind_name) do
			n += math.min(state:struct_level_sum(id, k), state:built_count(id, k))
		end
		return n
	end

	--- Gold the next `kind_name` (structure, level or warship) costs `id` right now (nukes:
	--- nuke_cost with the match's MIRV count).
	function Rules.cost_of(state: any, id: number, kind_name: string): number
		if Defs.nuke_kind_from_name(kind_name) >= 0 then
			return Rules.nuke_cost(kind_name, state.mirvs_launched)
		end
		return Rules.build_cost(kind_name, Rules.cost_count_of(state, id, kind_name))
	end

	--- Build preview on client data, using exactly the Sim's algorithm (place_site). Returns
	--- {ok = bool, tile = snapped tile or -1, upgrade_sid = sid or 0, cost = gold, reason = ""} with
	--- reason one of "" / "not_own" / "no_room" / "no_coast" / "no_port" / "gold" / "invalid".
	--- Warships: tile is the port they launch from (nearest own finished port on the clicked water
	--- body, or nearest own finished port when a land tile is clicked).
	function Rules.placement(
		state: any,
		id: number,
		kind_name: string,
		tile: number
	): { ok: boolean, tile: number, upgrade_sid: number, cost: number, reason: string }
		local R = Rules.for_map(state.map)
		if R ~= Rules then
			return R.placement(state, id, kind_name, tile)
		end
		local out = { ok = false, tile = -1, upgrade_sid = 0, cost = Rules.cost_of(state, id, kind_name), reason = "" }
		if kind_name == "warship" then
			local p = Rules.warship_port(state, id, tile)
			out.tile = p
			out.reason = if p >= 0 then "" else "no_port"
		else
			local kind = Defs.struct_kind_from_name(kind_name)
			local r = Rules.place_site(
				state.map,
				state.owner,
				state.map.coastal,
				id,
				kind,
				tile,
				Rules.near_structures(state, tile),
				state.tick
			)
			out.tile = r.tile
			out.upgrade_sid = r.upgrade_sid
			out.reason = r.reason
		end
		local o = state.owners[id]
		if out.reason == "" and (o == nil or o.gold < out.cost) then
			out.reason = "gold"
		end
		out.ok = out.reason == ""
		return out
	end

	--- Port a warship ordered at `tile` launches from (GameState data; the Sim uses the same rule):
	--- the nearest (manhattan) finished own port on the clicked water body, or on any body when a land
	--- tile is clicked. -1 if none.
	function Rules.warship_port(state: any, id: number, tile: number): number
		local body = -1
		local map = state.map
		local geo_manhattan = map.geo_manhattan
		if tile >= 0 and tile < map.N and buffer.readu8(map.terrain, tile) <= Defs.T_LAKE then
			body = buffer.readu16(map.water_body, tile * 2)
		end
		local best = -1
		local bd = 0.0
		for _, s in state.structures do
			if s.owner ~= id or s.kind ~= Defs.S_PORT or s.active_tick > state.tick then
				continue
			end
			if body >= 0 and buffer.readu16(map.coast_body, s.tile * 2) ~= body then
				continue
			end
			local d = if tile >= 0 then geo_manhattan(tile, s.tile) else 0.0
			if best < 0 or d < bd or (d == bd and s.tile < best) then
				best = s.tile
				bd = d
			end
		end
		return best
	end

	-- ---------------------------------------------------------------------------------------------
	-- Roads & trains (trainStationMin/MaxRange, trainGold, trainSpawnRate, train speed 2)
	-- ---------------------------------------------------------------------------------------------
	--- trainStationMin/MaxRange: stations link to stations 15..110 full-size tiles away (our tiles below).
	Rules.ROAD_MIN_TILES = 15.0 / K_LIN
	Rules.ROAD_MAX_TILES = 110.0 / K_LIN
	--- Rail network: a new station first snaps onto any railroad in the 4-tile grid cells within
	--- stationRadius 3 of it (splitting the railroad there); otherwise it links to every station in
	--- range it isn't already within maxConnectionDistance (4) hops of. A railroad's tile path must be
	--- shorter than railroadMaxSize (trainStationMaxRange x 1.4142).
	--- (in full-size tiles: SimStructures keys its rail grid by full-size-tile cells)
	Rules.RAIL_SNAP_FULL = 3
	Rules.RAIL_CELL_FULL = 4
	Rules.RAIL_LINK_HOPS = 4
	Rules.RAIL_MAX_PATH = 110.0 * 1.4142 / K_LIN
	--- Rail paths: A* on the half-resolution minimap (maps coarser than full resolution use their
	--- own grid), 4-neighbour steps, water / shoreline steps cost 1 + 5, a turn +3, heuristic weight 2;
	--- water is entered only from or into shoreline (rails bridge narrow straits, never open sea).
	Rules.RAIL_MINIMAP = if K_LIN < 1.5 then 2 else 1
	Rules.RAIL_WATER_PENALTY = 5
	Rules.RAIL_TURN_PENALTY = 3
	Rules.RAIL_HEURISTIC_W = 2
	--- Trains move 2 full-size tiles per tick.
	Rules.TRUCK_TPT_X100 = trunc(100.0 * K_LIN / 2.0)
	--- Safety cap on trains in flight per factory (on top of the trainSpawnRate throttle).
	Rules.TRUCKS_PER_FACTORY = 6
	--- A train: an engine + 5 cars (units counted by trainSaturation), and at least 10
	--- ticks between two trains from one factory.
	Rules.TRAIN_UNITS = 6
	Rules.TRAIN_COOLDOWN_TICKS = 10

	--- trainGold(rel, citiesVisited): self 10k / ally 35k / other 25k, minus 5k per stop beyond the
	--- 9th, at least 5k. Paid to the train's owner and (if different) to the station's owner, at city
	--- and port stops only.
	function Rules.train_gold(rel: string, stops_visited: number): number
		local base = 25000.0
		if rel == "self" then
			base = 10000.0
		elseif rel == "ally" then
			base = 35000.0
		end
		return math.max(5000.0, base - 5000.0 * math.max(0, stops_visited - 9))
	end

	function Rules.sigmoid(value: number, decay_rate: number, midpoint: number): number
		return 1.0 / (1.0 + math.exp(-decay_rate * (value - midpoint)))
	end
	local sigmoid = Rules.sigmoid

	--- trainSaturation(units): world-wide spawn throttle by train units (TRAIN_UNITS per train).
	function Rules.train_saturation(units: number): number
		local boost = 1.0 + 0.5 * math.exp(-units / 30.0)
		local damping = 1.0 - sigmoid(units, math.log(2.0) / 100.0, 560.0)
		local plateau = 0.25 * (1.0 - sigmoid(units, math.log(2.0) / 150.0, 900.0))
		return boost * math.max(damping, plateau)
	end

	--- trainSpawnRate: each factory spawns a train with probability 1 / rate per tick.
	function Rules.train_spawn_rate(owner_factories: number, train_units: number): number
		local rate = (owner_factories + 10) * 15.0
		return math.max(1, math.floor(rate / Rules.train_saturation(train_units)))
	end

	-- ---------------------------------------------------------------------------------------------
	-- Attacks (attackLogic + tunables)
	-- ---------------------------------------------------------------------------------------------
	--- terrainAttackBase by our terrain code (ocean, lake, plains, highland, mountain, tundra, icecap):
	--- mag (bloodiness) and tileCost (slowness). Tundra uses the highland numbers.
	Rules.ATTACK_MAG = f32t({ 80.0, 80.0, 80.0, 100.0, 120.0, 100.0, 80.0 })
	Rules.ATTACK_TILE_COST = f32t({ 16.5, 16.5, 16.5, 20.0, 25.0, 20.0, 16.5 })
	--- Attack-front priority terrain magnitude (plains 1 / highland 1.5 / mountain 2).
	Rules.PRIORITY_MAG = f32t({ 1.0, 1.0, 1.0, 1.5, 2.0, 1.5, 1.0 })
	Rules.LARGE_TERRITORY_MIDPOINT = 300000.0
	Rules.LARGE_TERRITORY_STEEPNESS = 2.5
	Rules.LARGE_ATTACKER_DEPTH = 0.7
	Rules.LARGE_DEFENDER_DEPTH = 0.3
	Rules.LARGE_ATTACKER_SPEED_DEPTH = 0.73
	Rules.BOT_DEFENDER_LOSS_MULT = 0.7
	Rules.TERRA_NULLIUS_COST_SCALE = 2000.0
	Rules.TERRA_NULLIUS_MIN_COST = 5.0
	Rules.TERRA_NULLIUS_MAX_COST = 100.0
	Rules.ATTACKER_LOSS_BASE = 0.463
	Rules.ATTACKER_LOSS_PER_DENSITY = 0.0039
	Rules.SPEED_COST_DIVISOR = 8.55
	--- Each attack tick: borderSize = the attack's border length + a random jitter whose upper
	--- bound 5 is exclusive, so the jitter is 0..4 (rand % BORDER_JITTER).
	Rules.BORDER_JITTER = 5
	--- Queueing a front tile: priority = (random 0..6 + 10) * (1 - 0.5 n + mag / 2)
	--- + ticks, n = the attacker's 4-neighbours of the queued tile (before the tile being conquered
	--- changes hands), mag = PRIORITY_MAG. The random part is 10..16.
	Rules.PRIORITY_BASE = 10
	Rules.PRIORITY_RAND = 7
	--- malusForRetreat: retreating from a player attack loses 25 %.
	Rules.RETREAT_MALUS = 0.25
	Rules.RETREAT_KEEP = 1.0 - 0.25
	--- Retreat delay: a retreat order freezes the attack and brings the troops home
	--- 20 ticks later (the attack still advances on the tick after the order).
	Rules.RETREAT_DELAY_TICKS = 20
	--- Annexation: a player under 100 full-size tiles is annexed by the attacker.
	Rules.ANNEX_BELOW_FULL_TILES = 100.0
	--- Performance guard: at most ~572 full-size tiles (this many of our tiles) per
	--- attack per tick; see tests/growth_rules.luau for when it binds.
	Rules.MAX_TILES_PER_TICK = math.max(1, math.floor(572.0 / K_AREA))
	Rules.ATTACK_UPDATE_TICKS = 10
	--- attackRatio default (the troop slider starts at 20 %); the Sim's fallback when an
	--- attack / boat intent carries no ratio.
	Rules.DEFAULT_ATTACK_RATIO = 0.2

	local LOG_MID = math.log(300000.0)

	--- largeTerritoryBonus: logistic in log(full-size tiles), ~1 for small, 1 - depth for huge territories.
	function Rules.large_territory_bonus(src_tiles: number, depth: number): number
		return 1.0 - depth * sigmoid(math.log(math.max(src_tiles, 1.0)), 2.5, LOG_MID)
	end

	--- falloutDefenseModifier(ratio): 5 - 2 * ratio (ratio = fallout tiles / land tiles).
	function Rules.fallout_modifier(fallout_ratio: number): number
		return 5.0 - clampi(fallout_ratio, 0.0, 1.0) * 2.0
	end

	--- attackLogic against terra nullius: troops lost per full-size tile per unit of mag (tribes / 10, others / 5).
	function Rules.neutral_loss_per_mag(attacker_kind: number): number
		return 1.0 / (if attacker_kind == KIND_TRIBE then 10.0 else 5.0)
	end

	-- ---------------------------------------------------------------------------------------------
	-- Naval (boatMaxNumber, boatAttackAmount, transports / trade ships 1 tile/tick, tradeShipGold,
	-- tradeShipSpawnRate, warship*)
	-- ---------------------------------------------------------------------------------------------
	--- Transports and trade ships move 1 full-size tile per tick.
	Rules.TRANSPORT_TPT_X100 = trunc(100.0 * K_LIN)
	Rules.TRADE_TPT_X100 = trunc(100.0 * K_LIN)
	--- boatMaxNumber: 3 transports at sea per player. The AI (nations, tribes, bot players) keeps it.
	Rules.MAX_BOATS_PER_OWNER = 3
	--- A person's transports at sea (raised to 10 on 2026-10-10).
	Rules.MAX_BOATS_PLAYER = 10
	--- boatAttackAmount / AI boat attacks: troops / 5.
	Rules.BOAT_ATTACK_FRACTION = 0.2
	--- Boat orders that need a path search, per owner per second (extra orders are rejected).
	Rules.BOAT_SEARCHES_PER_S = 2
	--- Shore probes (boat reach and AI boat attacks on unclaimed land): every
	--- 10th shore tile of an owner (a count along its border, scaled like a border length) looks 5 full-size
	--- tiles across the water in each direction whose first step is water (rivers up to 4 wide).
	Rules.SHORE_PROBE_EVERY = math.max(1, math.floor(10.0 / K_LIN + 0.5))
	Rules.SHORE_PROBE_DIST = math.max(2, math.floor(5.0 / K_LIN + 0.5))
	--- tradeShipShortRangeDebuff 300 full-size tiles (manhattan) — closer ports get no bonus weight.
	Rules.TRADE_SHORT_RANGE_FULL = 300.0
	-- Warships (warship*, warship and shell stats) -------------------------------------------------
	--- maxHealth 1000; +20 % per veterancy level (max 3), which also scales shell damage +20 %.
	Rules.WARSHIP_HP = 1000
	Rules.WARSHIP_MAX_VET = 3
	Rules.WARSHIP_VET_HP_PCT = 20
	Rules.WARSHIP_VET_DMG_PCT = 20
	--- Veterancy: the final blow on an enemy warship is +1 level at once (partial progress wiped);
	--- otherwise 10 transports sunk OR 25 trade ships captured (or a mix) fill a level.
	Rules.WARSHIP_VET_TRANSPORTS = 10
	Rules.WARSHIP_VET_TRADES = 25
	--- Shell damage 250 x roll: multiplier 200 / 225 / 250 / 275 / 300 (%, /250).
	Rules.SHELL_DAMAGE = 250
	--- warshipShellAttackRate: a warship fires when more than 20 ticks passed since its last shell at a
	--- warship (it does not reload between transports).
	Rules.WARSHIP_FIRE_TICKS = 20
	--- warshipTargettingRange 130, warshipPatrolRange 100, warshipDockingRange 5 full-size tiles.
	Rules.WARSHIP_RANGE_FULL = 130.0
	Rules.WARSHIP_PATROL_FULL = 100.0
	Rules.WARSHIP_DOCK_FULL = 5.0
	Rules.WARSHIP_RANGE = trunc(130.0 / K_LIN)
	Rules.WARSHIP_PATROL_RADIUS = trunc(100.0 / K_LIN)
	--- Healing: +1 HP per tick within 150 full-size tiles of an own port (warshipPassiveHealing[Range]);
	--- docked: the port's level x 5 HP per tick shared by the ships docked there
	--- (warshipPortHealingBonusPerLevel); a port docks at most `level` ships.
	Rules.WARSHIP_PASSIVE_HEAL = 1
	Rules.WARSHIP_PASSIVE_HEAL_FULL = 150.0
	Rules.WARSHIP_PORT_HEAL_PER_LEVEL = 5
	--- Repair retreat below 75 % of (veterancy-adjusted) max health (warshipRetreatHealthPercent); a
	--- retreating ship switches port when another is within 0.75 x the squared distance
	--- (warshipPortSwitchThreshold); no retreat for 50 ticks after a manual move.
	Rules.WARSHIP_RETREAT_PCT = 75
	Rules.WARSHIP_RETREAT_FRAC = 0.75
	Rules.WARSHIP_PORT_SWITCH = 0.75
	Rules.WARSHIP_MANUAL_NO_RETREAT_TICKS = 50
	--- Speeds: 1 full-size tile per tick (2 while chasing a trade ship) — ticks per our tile x100.
	Rules.WARSHIP_TPT_X100 = trunc(100.0 * K_LIN)
	Rules.WARSHIP_HUNT_TPT_X100 = trunc(50.0 * K_LIN)
	--- Shells fly 3 full-size tiles per tick (air path) and fizzle if the target is gone or friendly.
	Rules.SHELL_SPEED_FULL = 3.0
	--- A trade ship sailing along a shore is safe from warships for 20 ticks
	--- (safeFromPiratesCooldownMax).
	Rules.SAFE_FROM_PIRATES_TICKS = 20
	--- Defense posts can shell transports / warships within 75 full-size tiles every 100 ticks;
	--- this targeting is off by default (Sim config
	--- "defense_posts_shoot" turns it on).
	Rules.DEFENSE_POST_SHOOTS = false
	Rules.DEFENSE_POST_SHELL_TICKS = 100
	Rules.DEFENSE_POST_TARGET_FULL = 75.0
	--- Build-click snap radius (the build search radius), for the UI.
	Rules.BUILD_SNAP_RADIUS = 15.0 / K_LIN

	--- Max health of a warship with `vet` veterancy (maxHealthWithVeterancy).
	function Rules.warship_max_hp(vet: number): number
		return 1000 * (100 + clampi(vet, 0, 3) * 20) // 100
	end

	--- Shell damage for a die `roll` in 1..5 and the shooter's veterancy.
	function Rules.shell_damage(roll: number, vet: number): number
		local mult = (clampi(roll, 1, 5) - 1) * 25 + 200
		if vet > 0 then
			mult = Defs.idiv(mult * (100 + vet * 20), 100)
		end
		return trunc(Defs.round(250 / 250.0 * mult))
	end

	--- Ticks a shell needs to cover `dist_tiles` of our tiles.
	function Rules.shell_flight_ticks(dist_tiles: number): number
		return math.max(1, trunc(math.ceil(dist_tiles * K_LIN / 3.0)))
	end

	--- Targeting range of warships in our tiles (euclidean, map.range_d2).
	function Rules.warship_range(): number
		return 130.0 / K_LIN
	end

	--- Transports an owner may have at sea at once (boatMaxNumber; a `player`: MAX_BOATS_PLAYER).
	function Rules.max_boats(_tiles: number?, player: boolean?): number
		return if player then Rules.MAX_BOATS_PLAYER else Rules.MAX_BOATS_PER_OWNER
	end

	--- tradeShipGold(dist): 75000 / (1 + e^(-0.03 (dist - 300))) + 50 dist, dist = full-size tiles sailed.
	function Rules.trade_gold(path_tiles: number): number
		local d = path_tiles * K_LIN
		return 75000.0 / (1.0 + math.exp(-0.03 * (d - 300.0))) + 50.0 * d
	end

	--- tradeShipSaturation(ships): world-wide spawn throttle.
	function Rules.trade_saturation(ships: number): number
		local boost = 1.0 + 0.45 * math.exp(-ships / 120.0)
		local damping = 1.0 - sigmoid(ships, math.log(2.0) / 50.0, 330.0)
		local plateau = 0.25 * (1.0 - sigmoid(ships, math.log(2.0) / 100.0, 800.0))
		return boost * math.max(damping, plateau)
	end

	--- tradeShipSpawnRate: every 10 ticks each port spawns with probability 1 / rate (pity timer).
	function Rules.trade_spawn_rate(rejections: number, ships: number): number
		return math.max(1, math.floor(100.0 / (rejections + 1) / Rules.trade_saturation(ships)))
	end

	-- ---------------------------------------------------------------------------------------------
	-- Nukes (index = Defs.N_*; nukeMagnitudes, nukeSpeed, nukeDeathFactor, costs,
	-- nukeAllianceBreakThreshold, MIRV warheads)
	-- ---------------------------------------------------------------------------------------------
	--- Atom 750k, hydrogen 5M, MIRV 25M (+15M per MIRV launched in the match; see nuke_cost()).
	--- (Arsenal: mega 2.5M, scattershot 3.75M; a shell, an air strike and a railgun slug are free —
	--- their battery, airfield or railgun is the price.)
	Rules.NUKE_COST = zt({ 750000, 5000000, 25000000, 0, 2500000, 3750000, 0, 0, 0 })
	Rules.MIRV_COST_STEP = 15000000
	--- nukeMagnitudes (full-size tiles): atom 12/30, hydrogen 80/100, warhead 12/18 (inner / outer).
	--- (Arsenal: mega = twice an atom bomb's radii, four times its ground; scattershot's own crater is
	--- an atom bomb's; a shell, an air strike and a slug have one blast disc and take no land.)
	Rules.NUKE_INNER_FULL = f32t({ 12.0, 80.0, 0.0, 12.0, 24.0, 12.0, 0.0, 0.0, 0.0 })
	Rules.NUKE_OUTER_FULL = f32t({ 30.0, 100.0, 0.0, 18.0, 60.0, 30.0, 1.5, 15.0, 5.0 })
	--- Outer blast radius in our tiles (UI displays trunc(NUKE_RADIUS[kind])).
	Rules.NUKE_RADIUS = f32t({
		30.0 / K_LIN,
		100.0 / K_LIN,
		0.0,
		18.0 / K_LIN,
		60.0 / K_LIN,
		30.0 / K_LIN,
		1.5 / K_LIN,
		15.0 / K_LIN,
		5.0 / K_LIN,
	})
	--- SAMs always hit what they can reach; the MIRV carrier itself can't be intercepted (nor can a
	--- shell, an air strike or a slug).
	Rules.NUKE_INTERCEPT_P = f32t({ 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0 })
	--- defaultSamMissileSpeed 12 full-size tiles/tick (manhattan time to reach); a bomb or warhead can be
	--- targeted only within defaultNukeTargetableRange (150 full-size tiles) of its target or of its launch point.
	Rules.SAM_MISSILE_SPEED_FULL = 12.0
	Rules.NUKE_TARGETABLE_FULL = 150.0
	--- nukeSpeed (full-size tiles per tick): atom / hydrogen 10, MIRV 15, warhead 22.
	--- (Arsenal: mega / scattershot 10 like the bombs; shell 6, air strike 8, slug 80.)
	Rules.NUKE_SPEED_FULL = f32t({ 10.0, 10.0, 15.0, 22.0, 10.0, 10.0, 6.0, 8.0, 80.0 })
	--- MIRV: 350 warheads within 1500 full-size tiles of the aim, on the target's land.
	Rules.MIRV_WARHEADS = 350
	Rules.MIRV_SPREAD = trunc(1500.0 / K_LIN)
	--- nukeAllianceBreakThreshold: 100 weighted full-size tiles (inner 1, outer 0.5) of an ally's land.
	Rules.NUKE_ALLIANCE_BREAK_FULL = 100.0

	--- (inner, outer) blast radii in OUR tiles for nuke kind `kind`; MIRV: (0, spread).
	--- (GDScript returned Vector2(inner, outer).)
	function Rules.nuke_radii(kind: number): (number, number)
		if kind == Defs.N_MIRV then
			return 0.0, Rules.MIRV_SPREAD
		end
		if kind < 0 or kind >= Defs.NUKE_KIND_COUNT then
			return 0.0, 0.0
		end
		return Rules.NUKE_INNER_FULL[kind] / K_LIN, Rules.NUKE_OUTER_FULL[kind] / K_LIN
	end

	--- Gold cost of a nuke; the MIRV grows by 15M for every MIRV already launched in the match.
	function Rules.nuke_cost(kind_name: string, mirvs_launched: number?): number
		local k = Defs.nuke_kind_from_name(kind_name)
		if k < 0 or k == Defs.N_WARHEAD or k == Defs.N_SHELL then
			return -1
		end
		if k == Defs.N_MIRV then
			return Rules.NUKE_COST[k] + Rules.MIRV_COST_STEP * math.max(mirvs_launched or 0, 0)
		end
		return Rules.NUKE_COST[k]
	end

	--- Flight time in ticks over `dist_tiles` of OUR tiles at nukeSpeed.
	function Rules.nuke_flight_ticks(dist_tiles: number, kind: number?): number
		local speed = Rules.NUKE_SPEED_FULL[clampi(kind or Defs.N_ATOM, 0, Defs.NUKE_KIND_COUNT - 1)]
		return math.max(1, trunc(math.ceil(dist_tiles * K_LIN / speed)))
	end

	--- The nuke flight path, a parabola-like arc:
	--- a cubic Bezier from the silo's tile centre to the target's, its control
	--- points a quarter and three quarters along, raised by max(dist / 3, 50 full-size tiles) toward the top of
	--- the map (clamped to it), flown at constant speed along the curve. The Sim's trajectory (what SAMs
	--- intercept) and the renderer's nuke both come from this arc, so a nuke seen crossing a SAM is one
	--- the SAM can reach (2026-09-29: a SAM shoots down the nukes that pass over it; the Sim
	--- flew a straight line under the drawn arc).
	--- nuke_arc builds its arc-length table (NUKE_ARC_SAMPLES segments); nuke_arc_at the point at
	--- arc-length fraction s in [0, 1] (tile units, map space); nuke_arc_ticks the flight time.
	Rules.NUKE_ARC_MIN_HEIGHT_FULL = 50.0
	Rules.NUKE_ARC_SAMPLES = 96
	function Rules.nuke_arc(W: number, H: number, from_tile: number, to_tile: number): any
		local sx, sy = from_tile % W + 0.5, from_tile // W + 0.5
		local dx, dy = to_tile % W + 0.5, to_tile // W + 0.5
		local ddx, ddy = dx - sx, dy - sy
		local dist = math.sqrt(ddx * ddx + ddy * ddy)
		local hmax = math.max(dist / 3, Rules.NUKE_ARC_MIN_HEIGHT_FULL / K_LIN)
		local p1x, p1y = sx + ddx / 4, math.clamp(sy + ddy / 4 - hmax, 0, H - 1)
		local p2x, p2y = sx + ddx * 3 / 4, math.clamp(sy + ddy * 3 / 4 - hmax, 0, H - 1)
		local n = Rules.NUKE_ARC_SAMPLES
		local xs, ys, lens = table.create(n + 1), table.create(n + 1), table.create(n + 1)
		local total = 0.0
		local px, py = sx, sy
		for i = 0, n do
			local t = i / n
			local u = 1 - t
			local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
			local x = a * sx + b * p1x + c * p2x + d * dx
			local y = a * sy + b * p1y + c * p2y + d * dy
			if i > 0 then
				total += math.sqrt((x - px) * (x - px) + (y - py) * (y - py))
			end
			xs[i + 1], ys[i + 1], lens[i + 1] = x, y, total
			px, py = x, y
		end
		return { xs = xs, ys = ys, lens = lens, length = total }
	end

	function Rules.nuke_arc_at(arc: any, s: number): (number, number)
		local xs, ys, lens = arc.xs, arc.ys, arc.lens
		local total = arc.length
		if total <= 0 then
			return xs[1], ys[1]
		end
		local want = math.clamp(s, 0, 1) * total
		local lo, hi = 1, #lens
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if lens[mid] < want then
				lo = mid
			else
				hi = mid
			end
		end
		local seg = lens[hi] - lens[lo]
		local f = if seg > 0 then (want - lens[lo]) / seg else 0
		return xs[lo] + (xs[hi] - xs[lo]) * f, ys[lo] + (ys[hi] - ys[lo]) * f
	end

	--- Ticks to fly `arc`: a nuke moves nukeSpeed full-size tiles along the curve per tick.
	function Rules.nuke_arc_ticks(arc: any, kind: number?): number
		local speed = Rules.NUKE_SPEED_FULL[clampi(kind or Defs.N_ATOM, 0, Defs.NUKE_KIND_COUNT - 1)]
		return math.max(1, trunc(math.ceil(arc.length * K_LIN / speed)))
	end

	-- ---------------------------------------------------------------------------------------------
	-- The Arsenal (2026-10-04: units unlocked with Stars or Robux, Data/Arsenal). Numbers
	-- are in full-size tiles like everything above.
	-- ---------------------------------------------------------------------------------------------
	--- Munitions that fly a straight line (a shell, a bomber's run, a railgun slug); the others fly
	--- the nuke arc (nuke_arc).
	Rules.NUKE_FLAT = zt({ false, false, false, false, false, false, true, true, true })
	--- The structure a munition leaves from (Defs.S_*): bombs a silo, an air strike an airfield, a slug
	--- a railgun. (Shells are fired by the battery itself; warheads come off a MIRV or a scattershot.)
	Rules.NUKE_LAUNCHER = zt({
		Defs.S_SILO,
		Defs.S_SILO,
		Defs.S_SILO,
		-1,
		Defs.S_SILO,
		Defs.S_SILO,
		Defs.S_ARTILLERY,
		Defs.S_AIRFIELD,
		Defs.S_RAILGUN,
	})
	--- A structure that fires reloads for this long per shot (index Defs.S_*; 0: it doesn't fire).
	--- SAMCooldown / SiloCooldown 90; an airfield rearms for 30 s, a railgun reloads for 25 s. A battery
	--- rolls its own gap per shot (ARTILLERY_GAP_*).
	Rules.RELOAD_TICKS = zt({ 0, 0, 0, 0, 90, 90, 0, 300, 250 })
	--- What the Rapid Reload unlock makes of every reload of its owner's.
	Rules.RAPID_RELOAD_MULT = 0.5
	--- Artillery: a battery shells whatever isn't its owner's or an ally's within 45 tiles, every 4 to
	--- 7 s (a new battery waits one gap first; with nothing in range it looks again every 2 s).
	Rules.ARTILLERY_RANGE_FULL = 45.0
	Rules.ARTILLERY_GAP_MIN = 40
	Rules.ARTILLERY_GAP_MAX = 70
	Rules.ARTILLERY_IDLE_TICKS = 20
	Rules.ARTILLERY_SAMPLES = 24
	--- A shell kills 2.88 % of the army whose land it hits (at least 1,440, at most 19,200) and does
	--- 150 damage to the structures within 1.5 tiles.
	Rules.SHELL_KILL_FRAC = 0.0288
	Rules.SHELL_KILL_MIN = 1440.0
	Rules.SHELL_KILL_MAX = 19200.0
	--- Air strike: an airfield reaches 156 tiles; the bombs fall on a 15-tile disc and kill, per army
	--- with land under it, 60 troops per tile hit up to 6 % of that army; structures take 600.
	Rules.AIRFIELD_RANGE_FULL = 156.0
	Rules.AIRSTRIKE_KILL_PER_TILE = 60.0
	Rules.AIRSTRIKE_KILL_FRAC = 0.06
	--- Railgun: no range limit; a 5-tile disc, 150 troops per tile up to 4 % of the army; structures
	--- take 1000 (a level).
	Rules.SLUG_KILL_PER_TILE = 150.0
	Rules.SLUG_KILL_FRAC = 0.04
	--- Damage a munition does to each structure in its disc (index Defs.N_*).
	Rules.STRIKE_DAMAGE = zt({ 0, 0, 0, 0, 0, 0, 150, 600, 1000 })
	--- Health of a structure (index Defs.S_*), only ever lowered by a shell, an air strike or a slug:
	--- at 0 it loses a level and is whole again, or is destroyed at level 1.
	Rules.STRUCT_HP = zt({ 1000, 1000, 1000, 600, 1000, 1000, 600, 800, 1000 })
	--- Scattershot: 4 to 6 warheads come down 28 to 46 tiles around the aim point.
	Rules.SCATTER_MIN = 4
	Rules.SCATTER_MAX = 6
	Rules.SCATTER_NEAR_FULL = 28.0
	Rules.SCATTER_FAR_FULL = 46.0
	--- Reinforcements: 100,000 gold brings a fifth of the troop cap (never past the cap), every 30 s.
	Rules.REINFORCE_COST = 100000.0
	Rules.REINFORCE_FRACTION = 0.20
	Rules.REINFORCE_COOLDOWN_TICKS = 300

	function Rules.artillery_range(): number
		return 45.0 / K_LIN
	end

	--- Reach of the structure a munition leaves from, in OUR tiles (0: no limit).
	function Rules.launch_range(kind: number): number
		if kind == Defs.N_AIRSTRIKE then
			return 156.0 / K_LIN
		elseif kind == Defs.N_SHELL then
			return 45.0 / K_LIN
		end
		return 0.0
	end

	--- A munition's flight path: the nuke arc for the bombs, a straight line for a shell, an air
	--- strike and a slug (same table shape, so nuke_arc_at / nuke_arc_ticks work on both).
	function Rules.munition_arc(W: number, H: number, from_tile: number, to_tile: number, kind: number?): any
		if kind == nil or not Rules.NUKE_FLAT[kind] then
			return Rules.nuke_arc(W, H, from_tile, to_tile)
		end
		local sx, sy = from_tile % W + 0.5, from_tile // W + 0.5
		local dx, dy = to_tile % W + 0.5, to_tile // W + 0.5
		local len = math.sqrt((dx - sx) * (dx - sx) + (dy - sy) * (dy - sy))
		return { xs = { sx, dx }, ys = { sy, dy }, lens = { 0.0, len }, length = len }
	end

	--- Troops a strike (shell / air strike / slug) kills of an army of `troops` with `src_tiles`
	--- full-size tiles of land under the blast.
	function Rules.strike_kill(kind: number, troops: number, src_tiles: number): number
		local t = math.max(troops, 0.0)
		if kind == Defs.N_SHELL then
			return math.min(t, clampi(math.floor(t * 0.0288), 1440.0, 19200.0))
		elseif kind == Defs.N_AIRSTRIKE then
			return math.floor(math.min(t, src_tiles * 60.0, t * 0.06))
		elseif kind == Defs.N_SLUG then
			return math.floor(math.min(t, src_tiles * 150.0, t * 0.04))
		end
		return 0.0
	end

	--- Troops one Reinforcements call brings an army of `troops` under `cap`.
	function Rules.reinforce_troops(troops: number, cap: number): number
		return math.max(0, math.min(math.floor(cap * 0.20), math.floor(cap) - math.floor(troops)))
	end

	--- nukeDeathFactor for a warhead, per full-size tile: 500 * (1 - e^(-2 * excess / max)).
	function Rules.warhead_death(troops: number, max_troops: number): number
		local m = math.max(max_troops, 1.0)
		local excess = math.max(0.0, troops - 0.03 * m)
		return 500.0 * (1.0 - math.exp(-2.0 * excess / m))
	end

	-- ---------------------------------------------------------------------------------------------
	-- Diplomacy & victory (traitor*, win share)
	-- ---------------------------------------------------------------------------------------------
	--- allianceRequestDuration 20 s: a request is rejected once
	--- more than this many ticks passed since it was made.
	Rules.ALLY_REQUEST_TICKS = 200
	--- allianceRequestCooldown 30 s: a player can't send a new request to
	--- the same player until this many ticks after the previous (answered or expired) one was made.
	Rules.ALLY_REQUEST_COOLDOWN_TICKS = 300
	--- allianceDuration 5 min: an alliance expires this many ticks after it was formed
	--- or last renewed (expiresAt <= ticks: it ends, no traitor penalty).
	Rules.ALLIANCE_TICKS = 3000
	--- allianceExtensionPromptOffset 30 s: renewal can be asked in the last 300
	--- ticks; once both allies asked, the alliance is extended: expiresAt = now + ALLIANCE_TICKS.
	Rules.ALLIANCE_EXTEND_WINDOW_TICKS = 300
	--- traitorDuration 30 s; traitors take x0.5 attacker losses (traitorDefenseDebuff) and x0.8 attack
	--- time (traitorSpeedDebuff) when attacked.
	Rules.TRAITOR_TICKS = 300
	Rules.TRAITOR_DEFENSE_DEBUFF = 0.5
	Rules.TRAITOR_SPEED_DEBUFF = 0.8
	--- Owners are hostile for this long after one attacked the other.
	Rules.HOSTILE_TICKS = 600
	--- Nukes leave a much longer grudge.
	Rules.NUKE_GRUDGE_TICKS = 3000
	Rules.AI_MAX_ALLIES = 3
	--- Win share: 80 % of the land that is not fallout.
	Rules.WIN_SHARE = 0.8

	-- ---------------------------------------------------------------------------------------------
	-- Human protection (our AI behaviour layer; index = difficulty)
	-- ---------------------------------------------------------------------------------------------
	--- No AI attacks a human before this many ticks after PLAYING starts. Each AI adds its own
	--- random delay (0..HUMAN_GRACE_JITTER) plus HUMAN_GRACE_PER_TILE per tile of distance beyond
	--- HUMAN_GRACE_NEAR tiles, so wars trickle in instead of starting on one tick.
	Rules.HUMAN_GRACE_TICKS = zt({ 3000, 1800, 1200 })
	Rules.HUMAN_GRACE_JITTER = 900
	Rules.HUMAN_GRACE_NEAR = 40
	Rules.HUMAN_GRACE_PER_TILE = 3
	Rules.HUMAN_GRACE_MAX_EXTRA = 1200
	--- At most this many AI nations may be at war with one human at once (tribes don't count).
	Rules.MAX_AI_WARS_ON_HUMAN = zt({ 1, 2, 3 })
	--- The smart bot players of a public match (Sim.SMART_BOTS, playing at Sim.SMART_SKILL) are no
	--- harsher towards players than this difficulty's AI: its grace above, its limit on wars, how
	--- often it passes a player over as a target (SimAI.HUMAN_SKIP). They were the one AI of a public
	--- match that came for a player after 3 minutes instead of 5, passed one over 1 time in 4 instead
	--- of 3 in 4, and joined a war another AI already had on one (made a little easier for
	--- public matches on 2026-10-05). The rest of them stays as it was: their troops,
	--- their pace, their wars on the AI. Also the difficulty of a public match's "Protected" countdown.
	Rules.SMART_VS_PLAYERS = 0
	--- Endgame capitulation (AI nations only): after CAPITULATE_AGE ticks of play, a nation
	--- holding less than CAPITULATE_SHARE of the land that is attacked by an owner with
	--- CAPITULATE_RATIO times its troops surrenders all its land (and gold) to that attacker.
	Rules.CAPITULATE_AGE = 12000
	Rules.CAPITULATE_SHARE = 0.02
	Rules.CAPITULATE_RATIO = 8.0
	Rules.CAPITULATE_GAP = 300

	--- Earliest tick (counted from the start of PLAYING) at which any AI may attack a human —
	--- for a "protected" countdown in the UI. Counter-attacks against a human who attacks first are
	--- always allowed.
	function Rules.human_grace_ticks(difficulty: number): number
		return Rules.HUMAN_GRACE_TICKS[clampi(difficulty, 0, 2)]
	end

	return Rules
end

local cache: { [number]: any } = {}

--- Rules scaled for maps whose tiles are `k_lin` full-size tiles across (cached per value).
local function for_k(k_lin: number?): any
	local k = tonumber(k_lin) or 1.0
	if k <= 0 or k ~= k then
		k = 1.0
	end
	local r = cache[k]
	if r == nil then
		r = build(k)
		cache[k] = r
		r.for_k = for_k
		r.for_map = function(map: any): any
			return for_k(if map ~= nil then map.k_lin else nil)
		end
	end
	return r
end

return for_k(1.0)
