--!nocheck
-- Growth rules: how fast a player grows and expands (troops, gold, spawn, attacks, time).
-- The rules are written out below independently of src/shared/Core (one formula per function,
-- and a step model of a lone player further down), and the Sim is checked
-- against them:
--   1. Formulas: maxTroops (+ cities), troopIncreaseRate, startManpower, goldAdditionRate.
--   2. A player's tick on a live Sim (World): troops and gold every tick, nothing in the spawn phase.
--   3. Spawning: the spawn disk around the start tile.
--   4. An attack one tick at a time on uniform synthetic maps (plains / highland / mountain):
--      tiles taken per tick, attacker and defender losses — unclaimed land and players (incl. bot
--      defenders and traitors).
--   5. Scenario: a lone human on World expanding for 60 s, clicking every 5 s with the default 20 %
--      ratio, against an independent step model of the player (income every tick, then the attack,
--      a binary heap of tile priorities, its own RNG).
-- Run: .bin/lune run tests/growth_rules.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local Rng = require("../src/shared/Core/Rng")
local WorldMap = require("../src/shared/Core/WorldMap")
local SimState = require("../src/shared/Core/SimState")
local SimAttacks = require("../src/shared/Core/SimAttacks")
local Sim = require("../src/shared/Core/Sim")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end
local readi32 = buffer.readi32
local readu8 = buffer.readu8

-- =============================================================================================
-- The growth rules, written out
-- =============================================================================================
local Formula = {}
local function within(v: number, lo: number, hi: number): number -- clamp to [lo, hi]
	return math.min(math.max(v, lo), hi)
end
local TYPE = { [Defs.KIND_HUMAN] = "Human", [Defs.KIND_NATION] = "Nation", [Defs.KIND_TRIBE] = "Bot" }

-- maxTroops: 2 * (tiles^0.6 * 1000 + 50000) + sum of finished city levels *
-- cityTroopIncrease (250k); Bot / 3; Nation x {0.5, 0.75, 1, 1.25} by difficulty.
function Formula.maxTroops(ptype: string, tiles: number, city_levels: number, difficulty: number): number
	local m = 2 * (tiles ^ 0.6 * 1000 + 50000) + city_levels * 250000
	if ptype == "Bot" then
		return m / 3
	elseif ptype == "Human" then
		return m
	end
	return m * ({ 0.5, 0.75, 1, 1.25 })[difficulty + 1]
end
-- troopIncreaseRate.
function Formula.troopIncreaseRate(ptype: string, troops: number, max: number, difficulty: number): number
	local toAdd = 10 + troops ^ 0.73 / 4
	toAdd *= 1 - troops / max
	if ptype == "Bot" then
		toAdd *= 0.5
	end
	if ptype == "Nation" then
		toAdd *= ({ 0.9, 0.95, 1, 1.05 })[difficulty + 1]
	end
	return math.min(troops + toAdd, max) - troops
end
-- addTroops / removeTroops on whole-number troops (floored).
function Formula.addTroops(troops: number, x: number): number
	if x < 0 then
		return troops - math.min(troops, math.floor(-x))
	end
	return troops + math.floor(x)
end
-- startManpower.
function Formula.startManpower(ptype: string, difficulty: number): number
	if ptype == "Bot" then
		return 10000
	elseif ptype == "Nation" then
		return ({ 12500, 18750, 25000, 31250 })[difficulty + 1]
	end
	return 25000
end
-- goldAdditionRate (gold multiplier 1).
function Formula.goldAdditionRate(ptype: string): number
	return if ptype == "Bot" then 50 else 100
end
-- largeTerritoryBonus = 1 - depth * sigmoid(log(tiles), 2.5, log(300000)).
function Formula.largeTerritoryBonus(tiles: number, depth: number): number
	return 1 - depth * (1 / (1 + math.exp(-2.5 * (math.log(tiles) - math.log(300000)))))
end
-- terrainAttackBase.
Formula.TERRAIN = {
	P = { mag = 80, tileCost = 16.5, prio = 1 },
	H = { mag = 100, tileCost = 20, prio = 1.5 },
	M = { mag = 120, tileCost = 25, prio = 2 }, -- prio: the magnitude in a tile's attack priority
}
-- attackLogic. `def` = nil for terra nullius.
function Formula.attackLogic(terrain: string, attackTroops: number, att: any, def: any?, borderSize: number)
	local base = Formula.TERRAIN[terrain]
	local mag, tileCost = base.mag, base.tileCost
	if def == nil then
		local tickBudget = borderSize * 2
		return mag / (if att.type == "Bot" then 10 else 5),
			0,
			within(2000 * tileCost / attackTroops, 5, 100) / tickBudget
	end
	if (att.type == "Human" or att.type == "Nation") and def.type == "Bot" then
		mag *= 0.7
	end
	local lab = Formula.largeTerritoryBonus(att.numTiles, 0.7)
	local ldb = Formula.largeTerritoryBonus(def.numTiles, 0.3)
	local traitorLoss = if def.isTraitor then 0.5 else 1 -- traitorDefenseDebuff
	local traitorCost = if def.isTraitor then 0.8 else 1 -- traitorSpeedDebuff
	local defenderTroopLoss = def.troops / def.numTiles
	local ratio = def.troops / attackTroops
	local attackerTroopLoss = mag
		* traitorLoss
		* within(ratio, 0.6, 2)
		* (0.463 * lab * ldb + 0.0039 * defenderTroopLoss)
	local speedCost = within(ratio, 0.82, 7.5) * within(ratio / 20, 1, 50) / 8.55
	local lasb = Formula.largeTerritoryBonus(att.numTiles, 0.73)
	return attackerTroopLoss, defenderTroopLoss, speedCost * tileCost * lasb * ldb * traitorCost / borderSize
end

-- =============================================================================================
-- 1. Formulas
-- =============================================================================================
do
	local worst_cap, worst_rate = 0.0, 0.0
	for _, kind in { Defs.KIND_HUMAN, Defs.KIND_NATION, Defs.KIND_TRIBE } do
		for d = 0, 2 do
			for _, tiles in { 0, 1, 52, 1000, 25000, 651569 } do
				for _, cities in { 0, 1, 4 } do
					local want = Formula.maxTroops(TYPE[kind], tiles, cities, d)
					local got = Rules.max_troops(kind, tiles, cities, d)
					worst_cap = math.max(worst_cap, math.abs(got - want) / want)
					for k = 0, 24 do
						local troops = math.floor(want * k / 20) -- (whole troops) includes troops above the cap
						local r = Formula.troopIncreaseRate(TYPE[kind], troops, want, d)
						local g = Rules.troop_growth(kind, troops, want, d)
						worst_rate = math.max(worst_rate, math.abs(g - r) / math.max(1, math.abs(r)))
						if Rules.troop_growth_applied(kind, troops, want, d) ~= Formula.addTroops(troops, r) - troops then
							worst_rate = math.huge
						end
					end
				end
			end
		end
		for d = 0, 2 do
			expect(
				Rules.start_troops(kind, d) == Formula.startManpower(TYPE[kind], d),
				string.format("startManpower %s difficulty %d = %d", TYPE[kind], d, Formula.startManpower(TYPE[kind], d))
			)
		end
		expect(Rules.gold_per_tick(kind) == Formula.goldAdditionRate(TYPE[kind]), "goldAdditionRate " .. TYPE[kind])
	end
	expect(worst_cap < 1e-9, string.format("maxTroops (+ city levels) = the formula (worst rel %.1e)", worst_cap))
	expect(
		worst_rate < 1e-9,
		string.format("troopIncreaseRate = the formula, applied as whole troops (worst rel %.1e)", worst_rate)
	)
	expect(Rules.TICK_RATE == 10 and Sim.TICK_RATE == 10, "10 ticks per second (100 ms a tick)")
	expect(Rules.DEFAULT_ATTACK_RATIO == 0.2, "default attack ratio 20 %")

	-- Growth per second on World (k_lin 1) for the report: internal troops and as displayed
	-- (troops / 10).
	print("  troop growth per second, human on World (internal / as displayed):")
	for _, tiles in { 52, 1000, 10000, 100000 } do
		local cap = Formula.maxTroops("Human", tiles, 0, 1)
		local cells = {}
		for _, f in { 0.1, 0.25, 0.5, 0.9 } do
			local troops = math.floor(cap * f)
			local per_s = Formula.troopIncreaseRate("Human", troops, cap, 1) * 10
			table.insert(cells, string.format("%3d%% %7d: +%5.0f/s (+%4.0f)", f * 100, troops, per_s, per_s / 10))
		end
		print(string.format("    %6d tiles cap %8.0f | %s", tiles, cap, table.concat(cells, " | ")))
	end
end

-- =============================================================================================
-- 2 + 3. A player's tick and spawning on a live Sim (World, one human, nothing else)
-- =============================================================================================
local world = WorldMap.get("world")
expect(world.k_lin == 1 and world.W == 2000 and world.H == 1000, "World is unscaled (k_lin 1, 2000 x 1000)")

--- A land tile whose surrounding (2r+1)^2 box is at least `share` contestable land.
local function open_land(map: any, r: number, share: number): number
	local W, H = map.W, map.H
	for y = r, H - 1 - r, 7 do
		for x = r, W - 1 - r, 7 do
			local c = y * W + x
			if readu8(map.land, c) == 0 then
				continue
			end
			local n = 0
			for dy = -r, r, 4 do
				for dx = -r, r, 4 do
					n += readu8(map.land, (y + dy) * W + x + dx)
				end
			end
			local total = (2 * (r // 4) + 1) ^ 2
			if n >= share * total then
				return c
			end
		end
	end
	return -1
end

--- Independent spawn disk (Euclidean distance with a half-tile offset, radius 4):
--- free land, not impassable, within 4 of the corner of the start tile.
local function model_spawn_tiles(map: any, owner: buffer?, center: number): { [number]: boolean }
	local W, H = map.W, map.H
	local cx, cy = center % W, center // W
	local out = {}
	for y = cy - 6, cy + 6 do
		for x = cx - 6, cx + 6 do
			if x < 0 or y < 0 or x >= W or y >= H then
				continue
			end
			local dx, dy = x - (cx - 0.5), y - (cy - 0.5)
			local t = y * W + x
			local b = readu8(map.tile_bytes, t)
			local free = owner == nil or readi32(owner :: buffer, t * 4) == 0
			if dx * dx + dy * dy <= 16 and b >= 128 and bit32.band(b, 0x1F) ~= 31 and free then
				out[t] = true
			end
		end
	end
	return out
end

local START = open_land(world, 80, 0.97)
expect(START >= 0, "found open land on World for the lone player")

local function lone_sim(seed: number): (any, number)
	local sim = Sim.new(world, { seed = seed, difficulty = 1, tribes = 0, max_humans = 1, nations = false })
	local h = sim:add_human("me", "Me")
	assert(sim:human_start(h, START), "spawn accepted")
	return sim, h
end

do
	local sim, h = lone_sim(3)
	local spawn_ticks = 0
	local frozen = true
	while sim.phase ~= Defs.PHASE_PLAYING and spawn_ticks < 500 do
		sim:step()
		spawn_ticks += 1
		frozen = frozen and sim.o_troops[h] == 25000 and sim.o_gold[h] == 0
	end
	expect(sim.phase == Defs.PHASE_PLAYING, "solo match starts after the pick")
	expect(frozen, "no troop or gold income during the spawn phase")
	-- spawn disk
	local want = model_spawn_tiles(world, nil, START)
	local n_want, same = 0, true
	for t in want do
		n_want += 1
		same = same and readi32(sim.owner, t * 4) == h
	end
	expect(same and sim.o_tiles[h] == n_want, string.format("spawn disk = the written-out disk (%d tiles)", n_want))
	-- a player's tick: troops += troopIncreaseRate (floored), gold += goldAdditionRate.
	local troops, gold = sim.o_troops[h], sim.o_gold[h]
	local exact = true
	for _ = 1, 600 do
		local cap = Formula.maxTroops("Human", sim.o_tiles[h], 0, 1)
		troops = Formula.addTroops(troops, Formula.troopIncreaseRate("Human", troops, cap, 1))
		gold += Formula.goldAdditionRate("Human")
		sim:step()
		exact = exact and sim.o_troops[h] == troops and sim.o_gold[h] == gold
	end
	expect(exact, string.format("60 s of player income tick for tick (troops %d, gold %d)", troops, gold))
	-- cities: the cap counts the levels of finished cities
	sim.o_alevel[h * SimState.STRUCT_KINDS + Defs.S_CITY] = 3
	sim:step()
	expect(math.abs(sim.o_cap[h] - Formula.maxTroops("Human", sim.o_tiles[h], 3, 1)) < 1e-6, "maxTroops with 3 city levels")
end

-- =============================================================================================
-- 4. An attack one tick at a time on uniform maps
-- =============================================================================================
local UNIFORM = { P = 0x85, H = 0x8F, M = 0x99 } -- land + magnitude 5 / 15 / 25
local maps = {}
local function uniform_map(terrain: string): any
	if maps[terrain] == nil then
		local W, H = 64, 32
		local b = buffer.create(W * H)
		buffer.fill(b, 0, UNIFORM[terrain])
		maps[terrain] =
			WorldMap.from_terrain({ id = "flat_" .. terrain, name = terrain, width = W, height = H, terrain = b })
	end
	return maps[terrain]
end

local Bare = {}
Bare.__index = Bare
SimState.install(Bare)
SimAttacks.install(Bare)
local function bare(map: any, seed: number): any
	local s = setmetatable({}, Bare)
	s.rng = Rng.new(seed)
	s:_init_state(map)
	s:_init_attacks()
	return s
end

--- One attack tick into terra nullius on uniform terrain with an endless frontier:
--- tiles taken and troops left.
local function model_tn_tick(troops: number, border: number, terrain: string, ptype: string): (number, number)
	local budget, n = 1, 0
	while budget > 0 do
		if troops < 1 then
			return n, 0
		end
		local loss, _, tf = Formula.attackLogic(terrain, troops, { type = ptype }, nil, border)
		budget -= tf
		troops -= loss
		n += 1
	end
	return n, troops
end

for _, terrain in { "P", "H", "M" } do
	for _, case in
		{ { Defs.KIND_HUMAN, 3000 }, { Defs.KIND_HUMAN, 200000 }, { Defs.KIND_HUMAN, 400 }, { Defs.KIND_TRIBE, 3000 } }
	do
		local kind, troops0 = case[1], case[2]
		local map = uniform_map(terrain)
		local s = bare(map, 11 + troops0)
		local A = s:add_owner("A", 0xffffffff, kind)
		local W = map.W
		for y = 12, 20 do
			for x = 28, 36 do
				s:set_owner(y * W + x, A)
			end
		end
		s.o_troops[A] = 0
		s.tick = 100
		local a = s:start_attack(A, 0, troops0, -1)
		local border_ok = a ~= nil and a.front == 36
		s.tick = 101
		s:attacks_tick()
		local gained = s.o_tiles[A] - 81
		local left = if a.dead then 0 else a.troops
		local match = -1
		for j = 0, 4 do
			local n, rest = model_tn_tick(troops0, 36 + j, terrain, TYPE[kind])
			if n == gained and math.abs(rest - left) < 1e-6 then
				match = j
			end
		end
		expect(
			border_ok and match >= 0,
			string.format(
				"unclaimed %s, %s with %d troops: %d tiles in one tick, %.1f troops lost (borderSize 36 + %d)",
				terrain,
				TYPE[kind],
				troops0,
				gained,
				troops0 - left,
				match
			)
		)
	end
end

--- One attack tick against a player on uniform terrain (endless frontier): tiles
--- taken, attack troops left, defender troops left (whole troops: floor per tile).
local function model_player_tick(
	T: number,
	D: number,
	tilesA: number,
	tilesB: number,
	border: number,
	terrain: string,
	att_type: string,
	def_type: string,
	traitor: boolean
): (number, number, number)
	local budget, n = 1, 0
	while budget > 0 do
		if T < 1 then
			break
		end
		local aloss, dloss, tf = Formula.attackLogic(
			terrain,
			T,
			{ type = att_type, numTiles = tilesA },
			{ type = def_type, numTiles = tilesB, troops = D, isTraitor = traitor },
			border
		)
		budget -= tf
		T -= aloss
		D -= math.min(D, math.floor(dloss))
		tilesA += 1
		tilesB -= 1
		n += 1
	end
	return n, T, D
end

for _, terrain in { "P", "H", "M" } do
	for _, case in
		{
			{ 30000, 20000, Defs.KIND_NATION, false },
			{ 10000, 40000, Defs.KIND_NATION, false },
			{ 30000, 20000, Defs.KIND_TRIBE, false },
			{ 30000, 20000, Defs.KIND_NATION, true },
		}
	do
		local T0, D0, def_kind, traitor = case[1], case[2], case[3], case[4]
		local map = uniform_map(terrain)
		local s = bare(map, 5 + T0 + D0)
		local A = s:add_owner("A", 0xffffffff, Defs.KIND_HUMAN)
		local B = s:add_owner("B", 0xffffffff, def_kind)
		local W, H = map.W, map.H
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				s:set_owner(y * W + x, if x < 32 then A else B)
			end
		end
		s.o_troops[A] = 0
		s.o_troops[B] = D0
		s.tick = 200
		if traitor then
			s.o_traitor_until[B] = 1000
		end
		local a = s:start_attack(A, B, T0, -1)
		local border_ok = a ~= nil and a.front == H
		s.tick = 201
		s:attacks_tick()
		local gained = s.o_tiles[A] - 32 * H
		local match = -1
		for j = 0, 4 do
			local n, T, D = model_player_tick(T0, D0, 32 * H, 32 * H, H + j, terrain, "Human", TYPE[def_kind], traitor)
			if n == gained and math.abs(T - a.troops) < 1e-6 * T0 and D == s.o_troops[B] then
				match = j
			end
		end
		expect(
			border_ok and match >= 0,
			string.format(
				"%s vs %s%s on %s, %d vs %d troops: %d tiles, attacker -%.1f, defender -%d (borderSize %d + %d)",
				"Human",
				TYPE[def_kind],
				if traitor then " (traitor)" else "",
				terrain,
				T0,
				D0,
				gained,
				T0 - a.troops,
				D0 - s.o_troops[B],
				H,
				match
			)
		)
	end
end

-- =============================================================================================
-- 5. Scenario: a lone human expanding on World for 60 s
-- =============================================================================================
--- A step model of a lone player on the raw tile bytes of `map` (independent of the Sim):
--- income every tick (troopIncreaseRate, whole troops) and an attack into
--- terra nullius with a binary heap of tile priorities and its own RNG.
local Model = {}
Model.__index = Model
function Model.new(map: any, spawn: { number }, seed: number): any
	local self = setmetatable({}, Model)
	self.W, self.H, self.N = map.W, map.H, map.N
	self.bytes = map.tile_bytes
	self.owner = buffer.create(map.N) -- 1 = the player
	self.owned = {}
	self.troops = 25000
	self.gold = 0
	self.tick = 0
	self.seed = seed
	self.attack = nil
	for _, t in spawn do
		self:conquer(t)
	end
	return self
end
function Model:next(): number -- LCG in [0, 1)
	self.seed = (self.seed * 1103515245 + 12345) % 2147483648
	return self.seed / 2147483648
end
function Model:nextInt(lo: number, hi: number): number -- lo inclusive, hi exclusive
	return math.floor(self:next() * (hi - lo)) + lo
end
function Model:conquer(t: number)
	buffer.writeu8(self.owner, t, 1)
	table.insert(self.owned, t)
end
function Model:mine(t: number): boolean
	return readu8(self.owner, t) == 1
end
function Model:land(t: number): boolean -- land and not impassable (magnitude 31)
	local b = readu8(self.bytes, t)
	return b >= 128 and bit32.band(b, 0x1F) ~= 31
end
function Model:terrain(t: number): string -- plains < 10 <= highland < 20 <= mountain
	local m = bit32.band(readu8(self.bytes, t), 0x1F)
	return if m < 10 then "P" elseif m < 20 then "H" else "M"
end
function Model:neighbors(t: number): { number } -- the 4 neighbours
	local W = self.W
	local out = {}
	if t >= W then
		table.insert(out, t - W)
	end
	if t < (self.H - 1) * W then
		table.insert(out, t + W)
	end
	if t % W ~= 0 then
		table.insert(out, t - 1)
	end
	if t % W ~= W - 1 then
		table.insert(out, t + 1)
	end
	return out
end
local function heap_push(h: any, t: number, p: number)
	local i = h.n + 1
	h.n = i
	while i > 1 do
		local parent = i // 2
		if h.pri[parent] <= p then
			break
		end
		h.pri[i], h.til[i] = h.pri[parent], h.til[parent]
		i = parent
	end
	h.pri[i], h.til[i] = p, t
end
local function heap_pop(h: any): number
	local top = h.til[1]
	local p, t = h.pri[h.n], h.til[h.n]
	h.pri[h.n], h.til[h.n] = nil, nil
	h.n -= 1
	local n = h.n
	if n > 0 then
		local i = 1
		while true do
			local c = i * 2
			if c > n then
				break
			end
			if c < n and h.pri[c + 1] < h.pri[c] then
				c += 1
			end
			if h.pri[c] >= p then
				break
			end
			h.pri[i], h.til[i] = h.pri[c], h.til[c]
			i = c
		end
		h.pri[i], h.til[i] = p, t
	end
	return top
end
-- addNeighbors: the free land around a taken tile joins the border with a jittered priority
function Model:addNeighbors(a: any, tile: number)
	for _, nb in self:neighbors(tile) do
		if not self:land(nb) or self:mine(nb) then
			continue
		end
		if not a.border[nb] then
			a.border[nb] = true
			a.bsize += 1
		end
		local mine = 0
		for _, x in self:neighbors(nb) do
			if self:mine(x) then
				mine += 1
			end
		end
		local mag = Formula.TERRAIN[self:terrain(nb)].prio
		heap_push(a.heap, nb, (self:nextInt(0, 7) + 10) * (1 - mine * 0.5 + mag / 2) + self.tick)
	end
end
function Model:refresh(a: any) -- the border and its heap rebuilt from every owned tile
	a.heap = { pri = {}, til = {}, n = 0 }
	a.border = {}
	a.bsize = 0
	for _, t in self.owned do
		self:addNeighbors(a, t)
	end
end
-- a new order (no opposing attacks; absorbs the running one)
function Model:order(amount: number)
	local removed = math.min(self.troops, math.floor(math.min(self.troops, amount)))
	self.troops -= removed
	local a = { troops = removed }
	self:refresh(a)
	if self.attack ~= nil then
		a.troops += self.attack.troops
	end
	self.attack = a
end
-- one attack tick
function Model:attackTick()
	local a = self.attack
	if a == nil then
		return
	end
	local borderSize = a.bsize + self:nextInt(0, 5)
	local budget = 1
	local troops = a.troops
	while budget > 0 do
		if troops < 1 then
			self.attack = nil
			return
		end
		if a.heap.n == 0 then
			self.troops = Formula.addTroops(self.troops, a.troops) -- nothing left to take: survivors come home
			self.attack = nil
			return
		end
		local tile = heap_pop(a.heap)
		if a.border[tile] then
			a.border[tile] = nil
			a.bsize -= 1
		end
		local onBorder = false
		for _, x in self:neighbors(tile) do
			if self:mine(x) then
				onBorder = true
			end
		end
		if self:mine(tile) or not onBorder or not self:land(tile) then
			continue
		end
		self:addNeighbors(a, tile)
		local loss, _, tf = Formula.attackLogic(self:terrain(tile), troops, { type = "Human" }, nil, borderSize)
		budget -= tf
		troops -= loss
		a.troops = math.max(0, troops)
		self:conquer(tile)
	end
end
--- One tick: income, then the attack; an order made this tick starts at the end of it
--- (after the attack has moved). The order's troops are ratio x troops after this tick's income (the Sim
--- applies the ratio when it processes the intent).
function Model:step(ratio: number?)
	self.tick += 1
	local cap = Formula.maxTroops("Human", #self.owned, 0, 1)
	self.troops = Formula.addTroops(self.troops, Formula.troopIncreaseRate("Human", self.troops, cap, 1))
	self.gold += 100
	local amount = if ratio ~= nil then ratio * self.troops else nil
	self:attackTick()
	if amount ~= nil then
		self:order(amount)
	end
end
function Model:total_troops(): number
	return self.troops + (if self.attack ~= nil then self.attack.troops else 0)
end

do
	local CLICK_EVERY = 50
	local RATIO = Rules.DEFAULT_ATTACK_RATIO
	local SECONDS = 60
	local sim, h = lone_sim(21)
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	local spawn = {}
	for t in model_spawn_tiles(world, nil, START) do
		table.insert(spawn, t)
	end
	table.sort(spawn)
	-- an unclaimed tile to click on (the order targets terra nullius; the model's order carries no tile)
	local far = world:land_tile(world.land_count - 1)
	local ours = {}
	for p = 1, SECONDS * 10 do
		if p % CLICK_EVERY == 1 then
			sim:submit(h, { type = "attack", tile = far, ratio = RATIO })
		end
		sim:step()
		if p % 100 == 0 then
			table.insert(ours, { sim.o_tiles[h], sim.o_troops[h] + sim:troops_in_attacks(h) })
		end
	end
	local runs = {}
	for seed = 1, 6 do
		local model = Model.new(world, spawn, seed * 7919)
		local rows = {}
		for p = 1, SECONDS * 10 do
			model:step(if p % CLICK_EVERY == 1 then RATIO else nil)
			if p % 100 == 0 then
				table.insert(rows, { #model.owned, model:total_troops() })
			end
		end
		table.insert(runs, rows)
	end
	print("  lone human on World, 20 % every 5 s: tiles / troops (ours vs the step model, 6 seeds)")
	local all_ok = true
	for i, row in ours do
		local lo_t, hi_t, sum_t, lo_r, hi_r, sum_r = math.huge, -math.huge, 0, math.huge, -math.huge, 0
		for _, rows in runs do
			local r = rows[i]
			lo_t, hi_t, sum_t = math.min(lo_t, r[1]), math.max(hi_t, r[1]), sum_t + r[1]
			lo_r, hi_r, sum_r = math.min(lo_r, r[2]), math.max(hi_r, r[2]), sum_r + r[2]
		end
		local mean_t, mean_r = sum_t / #runs, sum_r / #runs
		-- RNG streams differ (priorities, border jitter), so the fronts differ tile by tile: ours must
		-- sit inside the model's seed spread widened by 2 % (1 % for troops).
		local ok_t = row[1] >= lo_t * 0.98 and row[1] <= hi_t * 1.02
		local ok_r = row[2] >= lo_r * 0.99 and row[2] <= hi_r * 1.01
		all_ok = all_ok and ok_t and ok_r
		print(
			string.format(
				"    t=%2ds  ours %6d tiles %7d troops | model %6.0f tiles [%d..%d] %7.0f troops [%d..%d]%s",
				i * 10,
				row[1],
				row[2],
				mean_t,
				lo_t,
				hi_t,
				mean_r,
				lo_r,
				hi_r,
				if ok_t and ok_r then "" else "  <-- off"
			)
		)
	end
	expect(all_ok, "60 s expansion trajectory matches the model (within its seed spread)")
end

print(if fails == 0 then "growth_rules: all passed" else string.format("growth_rules: %d FAILED", fails))
if fails > 0 then
	error("growth_rules failed")
end
