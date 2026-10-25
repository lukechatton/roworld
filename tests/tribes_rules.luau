--!nocheck
-- Tribe rules (the "Bot" player type): how many there are, when they act,
-- what they attack and with how many troops, their alliances and the structures they capture.
-- The tribe rules are written out below (one function or table per rule),
-- independently of src/shared/Core, and the Sim is checked against them:
--   1. Setup: 400 tribes on every map; per-tribe attackRate / attackTick / ratios drawn at
--      a tribe's setup (nextInt excludes its upper bound).
--   2. A World match (400 tribes + nations, 60 s): every tribe acts exactly when tick % attackRate ==
--      attackTick, its first act sends everything above expandRatio x maxTroops into terra nullius,
--      and every attack a tribe orders has the rules' size; tribe land over time is printed next to
--      the previous tribe AI's.
--   3. maybeAttack / attackRandomTarget in lock-step: random neighbourhoods (tribes, nations, humans;
--      allies, traitors, incoming attacks, tribes holding structures, free land, the
--      neighborsTerraNullius latch, troop levels) decided by the Sim and by the written-out rules, both
--      reading the same random numbers.
--   4. Alliances: requests and renewals accepted on the tribe's next attack tick after its first.
--   5. No human grace and no stand-alone counter-attack: a tribe attacks a human neighbour as soon
--      as its rules say so, retaliates only at triggerRatio, on its attack tick.
--   6. Rivers: free land and players seen across a river (reachable from a shore) get transports.
--   7. Captured structures: kept, marked for deletion on an attack tick once the 30 s cooldown
--      allows, deleted 30 s later unless recaptured.
--   8. A lone tribe on World for 60 s against an independent step model of a tribe
--      (income every tick, its attack ticks, an attack into terra nullius).
-- Run: .bin/lune run tests/tribes_rules.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local SimState = require("../src/shared/Core/SimState")
local SimAI = require("../src/shared/Core/SimAI")
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
local KIND_TRIBE, KIND_NATION, KIND_HUMAN = Defs.KIND_TRIBE, Defs.KIND_NATION, Defs.KIND_HUMAN
local TYPE = { [KIND_HUMAN] = "Human", [KIND_NATION] = "Nation", [KIND_TRIBE] = "Bot" }

-- =============================================================================================
-- The tribe rules, written out
-- =============================================================================================
local Formula = {}
local function within(v: number, lo: number, hi: number): number -- clamp to [lo, hi]
	return math.min(math.max(v, lo), hi)
end
-- Tribes per match (public lobbies and single player alike): 400 (100 on
-- the half-size "compact" maps).
Formula.BOTS = 400
-- A tribe's setup: attackRate = nextInt(40, 80), attackTick = nextInt(0, attackRate),
-- triggerRatio = nextInt(50, 60) / 100, reserveRatio = nextInt(30, 40) / 100, expandRatio =
-- nextInt(10, 20) / 100; nextInt: min inclusive, max exclusive.
Formula.ATTACK_RATE = { 40, 80 }
Formula.TRIGGER = { 50, 60 }
Formula.RESERVE = { 30, 40 }
Formula.EXPAND = { 10, 20 }
-- deletionMarkDuration / deleteUnitCooldown: 30 s; a player's
-- lastDeleteUnitTick starts at -1; canDeleteUnit: ticks - last >= cooldown;
-- a marked structure's deletionAt = ticks + duration, overdue once ticks - deletionAt > 0.
Formula.DELETE_COOLDOWN = 300
Formula.DELETION_MARK = 300
-- maxTroops: 2 * (tiles^0.6 * 1000 + 50000) + city levels * 250k; Bot / 3.
function Formula.maxTroopsBot(tiles: number, city_levels: number?): number
	return (2 * (tiles ^ 0.6 * 1000 + 50000) + (city_levels or 0) * 250000) / 3
end
-- troopIncreaseRate for a bot (x 0.5).
function Formula.troopIncreaseRateBot(troops: number, max: number): number
	local toAdd = (10 + troops ^ 0.73 / 4) * (1 - troops / max) * 0.5
	return math.min(troops + toAdd, max) - troops
end
-- addTroops / removeTroops on whole-number troops (floored).
function Formula.addTroops(troops: number, x: number): number
	if x < 0 then
		return troops - math.min(troops, math.floor(-x))
	end
	return troops + math.floor(x)
end
-- terrainAttackBase; prio is the magnitude in a tile's attack priority.
Formula.TERRAIN = {
	P = { mag = 80, tileCost = 16.5, prio = 1 },
	H = { mag = 100, tileCost = 20, prio = 1.5 },
	M = { mag = 120, tileCost = 25, prio = 2 },
}
-- attackLogic into terra nullius (TERRA_NULLIUS_COST_SCALE 2000, min 5, max 100):
-- attacker loss mag / (Bot ? 10 : 5), tick fraction within(2000 * tileCost /
-- troops, 5, 100) / (borderSize * 2).
function Formula.tnAttackLogic(terrain: string, attackTroops: number, ptype: string, borderSize: number): (number, number)
	local base = Formula.TERRAIN[terrain]
	return base.mag / (if ptype == "Bot" then 10 else 5),
		within(2000 * base.tileCost / attackTroops, 5, 100) / (borderSize * 2)
end

--- The match's random numbers driven by a script of integers r (both sides read the same ones):
--- nextInt(lo, hi) = lo + r % (hi - lo), chance(odds) = nextInt(0, odds) == 0, randElement,
--- shuffleArray (Fisher-Yates from the end).
local Script = {}
Script.__index = Script
function Script.new(values: { number }): any
	return setmetatable({ v = values, used = 0 }, Script)
end
function Script:next(): number
	self.used += 1
	return self.v[(self.used - 1) % #self.v + 1]
end
function Script:nextInt(lo: number, hi: number): number
	return lo + self:next() % (hi - lo)
end
function Script:chance(odds: number): boolean
	return self:nextInt(0, odds) == 0
end
function Script:randElement(arr: { any }): any
	return arr[self:nextInt(0, #arr) + 1]
end
function Script:shuffleArray(arr: { any }): { any }
	local r = table.clone(arr)
	for i = #r - 1, 1, -1 do -- 0-based i
		local j = self:nextInt(0, i + 1)
		r[i + 1], r[j + 1] = r[j + 1], r[i + 1]
	end
	return r
end

--- A tribe's attack choice on its attack tick: a neighbouring traitor first (1 in 3), then free
--- land while the latch holds, then, from triggerRatio up, a random target: the largest incoming
--- attacker, a traitor (1 in 3), or a shuffled neighbour (a nation or human skipped 1 in 2). A bot
--- always attacks with troops - maxTroops x ratio (no send cap), by land, else by boat;
--- the attack removes floor(min(troops, amount)).
--- `st`: near (the nearby owners in the Sim's order, 0 = terra nullius), p[id] = {kind, friendly, traitor,
--- border, structures}, incoming = {{attacker, troops}} (creation order), troops, max, trigger,
--- reserve, expand, latch (still next to free land), landTN (a land border with terra nullius).
--- Returns the attack sent ({target, troops} or nil) and the latch.
function Formula.maybeAttack(st: any, rnd: any): (any, boolean)
	local function sendAttack(target: number): any
		local ratio
		if target == 0 then
			if not st.landTN then
				return nil -- (a boat to free land nearby: no shore in these scenarios)
			end
			ratio = st.expand
		else
			local p = st.p[target]
			if not p.border then
				return { target = target, boat = true }
			end
			-- the reserve ratio against a player, the expand ratio against a tribe holding structures
			ratio = if p.kind == "Bot" and p.structures then st.expand else st.reserve
		end
		local troops = st.troops - st.max * ratio
		if troops < 1 then
			return nil
		end
		return { target = target, troops = math.floor(math.min(st.troops, troops)) }
	end
	local function neighborTraitor(): number?
		local traitors = {}
		for _, n in st.near do
			if n ~= 0 and not st.p[n].friendly and st.p[n].traitor then
				table.insert(traitors, n)
			end
		end
		if #traitors == 0 then
			return nil
		end
		return rnd:randElement(traitors)
	end
	local latch = st.latch
	local toAttack = neighborTraitor()
	if toAttack ~= nil then
		local odds = if st.p[toAttack].friendly then 6 else 3
		if rnd:chance(odds) then
			local a = sendAttack(toAttack)
			if a then
				return a, latch
			end
		end
	end
	if latch then
		if table.find(st.near, 0) ~= nil then
			local a = sendAttack(0)
			if a then
				return a, latch
			end
		else
			latch = false
		end
	end
	-- a random target, from triggerRatio up
	if st.troops / st.max < st.trigger then
		return nil, latch
	end
	local largest, attacker = 0, nil
	for _, a in st.incoming do
		if st.p[a.attacker].friendly or a.troops <= largest then
			continue
		end
		largest = a.troops
		attacker = a.attacker
	end
	if attacker ~= nil then
		local a = sendAttack(attacker)
		if a then
			return a, latch
		end
	end
	local traitor = neighborTraitor()
	if traitor ~= nil and rnd:chance(3) then
		local a = sendAttack(traitor)
		if a then
			return a, latch
		end
	end
	for _, n in rnd:shuffleArray(st.near) do
		if n == 0 then
			continue
		end
		local p = st.p[n]
		if p.friendly then
			continue
		end
		if (p.kind == "Nation" or p.kind == "Human") and rnd:chance(2) then
			continue
		end
		local a = sendAttack(n)
		if a then
			return a, latch
		end
	end
	return nil, latch
end

--- closestTwoTiles: both lists sorted by x, a sweep keeping the closest (manhattan) pair.
function Formula.closestTwoTiles(W: number, xs: { number }, ys: { number }): number
	local function by_x(a: number, b: number): boolean
		if a % W ~= b % W then
			return a % W < b % W
		end
		return a < b
	end
	xs = table.clone(xs)
	ys = table.clone(ys)
	table.sort(xs, by_x)
	table.sort(ys, by_x)
	local i, j, best, result = 1, 1, math.huge, ys[1]
	while i <= #xs and j <= #ys do
		local cx, cy = xs[i], ys[j]
		local d = math.abs(cx % W - cy % W) + math.abs(cx // W - cy // W)
		if d < best then
			best = d
			result = cy
		end
		if i == #xs then
			j += 1
		elseif j == #ys then
			i += 1
		elseif cx % W < cy % W then
			i += 1
		else
			j += 1
		end
	end
	return result
end

-- =============================================================================================
-- Helpers
-- =============================================================================================
local PLAINS, WATER = 0x85, 0x20 -- full-size tile bytes: land + magnitude 5; ocean

--- A W x H plains map; `water` = {x0, x1} makes those columns a river.
local function synth_map(id: string, W: number, H: number, water: { number }?): any
	local b = buffer.create(W * H)
	buffer.fill(b, 0, PLAINS)
	if water ~= nil then
		for y = 0, H - 1 do
			for x = water[1], water[2] do
				buffer.writeu8(b, y * W + x, WATER)
			end
		end
	end
	return WorldMap.from_terrain({ id = id, name = id, width = W, height = H, terrain = b })
end

--- A playing match with nobody in it (owners are placed by hand; nobody may hold 80 % of the land,
--- or the match ends by domination).
local function empty_sim(map: any, seed: number): any
	return Sim.new(map, { seed = seed, difficulty = 1, tribes = 0, nations = false, max_humans = 0 })
end

local function add(sim: any, name: string, kind: number, troops: number?): number
	local id = sim:add_owner(name, 0xffffffff, kind)
	sim.o_spawned[id] = 1
	sim.o_troops[id] = troops or 10000
	return id
end

local function own(sim: any, id: number, x0: number, y0: number, x1: number, y1: number)
	local W = sim.W
	for y = y0, y1 do
		for x = x0, x1 do
			local t = y * W + x
			if readu8(sim.land, t) == 1 then
				sim:set_owner(t, id)
			end
		end
	end
end

--- Fixes a tribe's attack ticks (its attackRate / attackTick).
local function cadence(sim: any, id: number, rate: number, at: number)
	sim.ai.attack_rate[id] = rate
	sim.ai.attack_tick[id] = at
end

--- Records the attacks and transports ordered through the Sim's entry points (and still runs them).
local function record(sim: any): { any }
	local log = {}
	local ia = sim.intent_attack_troops
	sim.intent_attack_troops = function(self, id, t, amount)
		local home, tiles = self.o_troops[id], self.o_tiles[id]
		local ok = ia(self, id, t, amount)
		table.insert(log, {
			tick = self.tick,
			id = id,
			target = readi32(self.owner, t * 4),
			troops = math.floor(math.min(amount, home)),
			home = home,
			tiles = tiles,
			ok = ok,
		})
		return ok
	end
	local lb = sim.launch_boat
	sim.launch_boat = function(self, id, t, ratio)
		local home = self.o_troops[id]
		local ok = lb(self, id, t, ratio)
		table.insert(log, {
			tick = self.tick,
			id = id,
			target = readi32(self.owner, t * 4),
			tile = t,
			boat = true,
			ratio = ratio,
			home = home,
			ok = ok,
		})
		return ok
	end
	return log
end

local function step_to(sim: any, tick: number)
	while sim.tick < tick do
		sim:step()
	end
end

-- =============================================================================================
-- 1. Setup
-- =============================================================================================
print("1. setup")
do
	local ok = true
	for _, id in { "world", "pangaea" } do
		ok = ok and Sim.default_tribes(WorldMap.get(id)) == Formula.BOTS
	end
	expect(ok, "400 tribes by default on every map (World, Pangaea)")
end

-- =============================================================================================
-- 2. World match
-- =============================================================================================
print("2. World: 400 tribes + nations, 60 s")
local world = WorldMap.get("world")
do
	local sim = Sim.new(world, { seed = 1, difficulty = 1, max_humans = 0 })
	local ai = sim.ai
	local tribes = {}
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == KIND_TRIBE then
			table.insert(tribes, id)
		end
	end
	local alive0 = 0
	for _, id in tribes do
		alive0 += sim.o_alive[id]
	end
	expect(#tribes == Formula.BOTS and alive0 == Formula.BOTS, string.format("%d tribes spawned, %d alive", #tribes, alive0))

	-- setup draws
	local draws_ok = true
	local lo = { rate = math.huge, tr = math.huge, rr = math.huge, er = math.huge }
	local hi = { rate = -1, tr = -1, rr = -1, er = -1 }
	for _, id in tribes do
		local rate, at = ai.attack_rate[id], ai.attack_tick[id]
		local v = { rate = rate, tr = ai.trigger_r[id] * 100, rr = ai.reserve_r[id] * 100, er = ai.expand_r[id] * 100 }
		for k, x in v do
			lo[k] = math.min(lo[k], x)
			hi[k] = math.max(hi[k], x)
			if math.abs(x - math.floor(x + 0.5)) > 1e-9 then
				draws_ok = false
			end
		end
		if at < 0 or at >= rate or at ~= math.floor(at) then
			draws_ok = false
		end
	end
	local function in_of(k: string, range: { number }): boolean
		return lo[k] >= range[1] - 1e-9 and hi[k] <= range[2] - 1 + 1e-9
	end
	expect(
		draws_ok
			and in_of("rate", Formula.ATTACK_RATE)
			and in_of("tr", Formula.TRIGGER)
			and in_of("rr", Formula.RESERVE)
			and in_of("er", Formula.EXPAND),
		string.format(
			"attackRate %d-%d, attackTick < attackRate, trigger %.2f-%.2f, reserve %.2f-%.2f, expand %.2f-%.2f",
			lo.rate,
			hi.rate,
			lo.tr / 100,
			hi.tr / 100,
			lo.rr / 100,
			hi.rr / 100,
			lo.er / 100,
			hi.er / 100
		)
	)

	-- every tribe decision: when, and what it ordered
	local log = record(sim)
	local acts = {} -- id -> {ticks}
	local decisions = {}
	local function wrap(name: string, first: boolean)
		local f = ai[name]
		ai[name] = function(self, s, id)
			local d = {
				id = id,
				tick = s.tick,
				first = first,
				troops = s.o_troops[id],
				cap = s.o_cap[id],
				tiles = s.o_tiles[id],
				cities = s.o_alevel[id * SimState.STRUCT_KINDS + Defs.S_CITY],
				from = #log + 1,
			}
			local l = acts[id]
			if l == nil then
				l = {}
				acts[id] = l
			end
			table.insert(l, s.tick)
			f(self, s, id)
			d.to = #log
			table.insert(decisions, d)
		end
	end
	wrap("_tribe_first", true)
	wrap("_think_tribe", false)

	local BEFORE = { -- the previous tribe AI (commit 67ac2b2), seed 1, same setup
		[5] = { 400, 295351 },
		[10] = { 400, 367196 },
		[20] = { 400, 394584 },
		[30] = { 396, 479345 },
		[60] = { 261, 351046 },
	}
	print("    tribe land (now | previous tribe AI):")
	for tick = 1, 600 do
		sim:step()
		local s = tick // 10
		if tick % 10 == 0 and BEFORE[s] ~= nil then
			local n, tiles = 0, 0
			for _, id in tribes do
				if sim.o_alive[id] == 1 then
					n += 1
					tiles += sim.o_tiles[id]
				end
			end
			print(
				string.format(
					"      t=%2ds  %3d tribes %6d tiles (%4.1f%% of the land) | %3d tribes %6d tiles (%4.1f%%)",
					s,
					n,
					tiles,
					100 * tiles / world.land_count,
					BEFORE[s][1],
					BEFORE[s][2],
					100 * BEFORE[s][2] / world.land_count
				)
			)
		end
	end

	-- cadence
	local cad_ok, n_acts = true, 0
	for id, l in acts do
		local rate, at = ai.attack_rate[id], ai.attack_tick[id]
		for i, t in l do
			n_acts += 1
			if t % rate ~= at or (i > 1 and t - l[i - 1] ~= rate) or (i == 1 and t > rate) then
				cad_ok = false
			end
		end
	end
	expect(cad_ok and n_acts > 3000, string.format("%d tribe acts, each on tick %% attackRate == attackTick", n_acts))

	-- sizes
	local first_ok, sizes_ok, caps_ok, one_ok = true, true, true, true
	local n_first, n_tn, n_pl, n_boat = 0, 0, 0, 0
	for _, d in decisions do
		if math.abs(d.cap - Formula.maxTroopsBot(d.tiles, d.cities)) > 1e-6 * d.cap then
			caps_ok = false
		end
		local sent = 0
		for i = d.from, d.to do
			local e = log[i]
			if e.id ~= d.id then
				continue
			end
			if e.ok then
				sent += 1
			end
			if e.boat then
				n_boat += 1
				if e.ratio ~= 0.2 then
					sizes_ok = false
				end
				continue
			end
			local ratio
			if e.target == 0 then
				ratio = sim.ai.expand_r[d.id]
				n_tn += 1
			else
				n_pl += 1
				local holds = false
				for _, k in { Defs.S_CITY, Defs.S_PORT, Defs.S_FACTORY, Defs.S_SAM, Defs.S_SILO } do
					holds = holds or sim.o_scount[e.target * SimState.STRUCT_KINDS + k] > 0
				end
				ratio = if sim.o_kind[e.target] == KIND_TRIBE and holds then sim.ai.expand_r[d.id] else sim.ai.reserve_r[d.id]
			end
			-- attack troops: troops - maxTroops * ratio (the attack floors it)
			local want = math.floor(d.troops - Formula.maxTroopsBot(d.tiles, d.cities) * ratio)
			if e.troops ~= want or e.home ~= d.troops then
				sizes_ok = false
			end
			if d.first then
				n_first += 1
				if e.target ~= 0 then
					first_ok = false
				end
			end
		end
		if sent > 1 then
			one_ok = false
		end
	end
	expect(caps_ok, "maxTroops = the formula's bot maxTroops at every decision")
	expect(
		first_ok and n_first >= 390,
		string.format("first act: everything above expandRatio x maxTroops into terra nullius (%d tribes)", n_first)
	)
	expect(
		sizes_ok and n_tn > 1000 and n_pl > 100,
		string.format(
			"every tribe attack has the formula's size (%d on free land, %d on players, %d transports)",
			n_tn,
			n_pl,
			n_boat
		)
	)
	expect(one_ok, "at most one attack per tribe act")
end

-- =============================================================================================
-- 3. The attack choice in lock-step
-- =============================================================================================
print("3. maybeAttack / attackRandomTarget in lock-step with the step model")
do
	local fmap = synth_map("tribes_fuzz", 48, 48)
	-- the tribe's 16 x 16 block and eight 3-wide strips around it (two per side)
	local BLOCK = { 16, 16, 31, 31 }
	local SEGS = {
		{ 16, 13, 23, 15 },
		{ 24, 13, 31, 15 },
		{ 16, 32, 23, 34 },
		{ 24, 32, 31, 34 },
		{ 13, 16, 15, 23 },
		{ 13, 24, 15, 31 },
		{ 32, 16, 34, 23 },
		{ 32, 24, 34, 31 },
	}
	local seed = 12345
	local function rnd(n: number): number -- LCG (its high bits), [0, n)
		seed = (seed * 1103515245 + 12345) % 2147483648
		return (seed // 65536) % n
	end
	local KINDS = { KIND_TRIBE, KIND_NATION, KIND_HUMAN }
	local CASES = 600
	local agree, same_draws, same_near, latch_ok = 0, 0, 0, 0
	local by_outcome = {}
	local first_bad = nil
	for case = 1, CASES do
		local sim = empty_sim(fmap, case)
		local ai = sim.ai
		local T = add(sim, "T", KIND_TRIBE)
		own(sim, T, BLOCK[1], BLOCK[2], BLOCK[3], BLOCK[4])
		-- neighbours: 1-6 players over the strips, the rest free land (sometimes none)
		local np = 1 + rnd(6)
		local tn_share = if rnd(3) == 0 then 0 else 1 + rnd(3)
		local slot_owner = {}
		for i = 1, #SEGS do
			slot_owner[i] = if rnd(8) < tn_share then 0 else 1 + rnd(np)
		end
		local p_ids = {}
		local info = {}
		for i = 1, #SEGS do
			local k = slot_owner[i]
			if k > 0 and p_ids[k] == nil then
				local kind = KINDS[1 + rnd(3)]
				local id = add(sim, "P" .. k, kind, 1000 + rnd(80000))
				p_ids[k] = id
				info[id] = { kind = TYPE[kind], friendly = false, traitor = false, border = true, structures = false }
			end
			local s = SEGS[i]
			own(sim, if k > 0 then p_ids[k] else 0, s[1], s[2], s[3], s[4])
		end
		local land_tn = false
		for i = 1, #SEGS do
			land_tn = land_tn or slot_owner[i] == 0
		end
		-- the tribe
		local cap = sim.R.max_troops(KIND_TRIBE, sim.o_tiles[T], 0, sim.difficulty)
		sim.o_cap[T] = cap
		local troops = math.floor(cap * rnd(1100) / 1000)
		sim.o_troops[T] = troops
		ai.trigger_r[T] = (Formula.TRIGGER[1] + rnd(10)) / 100
		ai.reserve_r[T] = (Formula.RESERVE[1] + rnd(10)) / 100
		ai.expand_r[T] = (Formula.EXPAND[1] + rnd(10)) / 100
		ai.started[T] = 1
		local latch = rnd(4) ~= 0
		ai.tribe_tn[T] = if latch then 1 else 0
		-- relations
		local incoming = {}
		for _, id in p_ids do
			local p = info[id]
			if rnd(5) == 0 then
				sim:form_alliance(T, id)
				p.friendly = true
			end
			if rnd(4) == 0 then
				sim.o_traitor_until[id] = sim.tick + 100
				p.traitor = true
			end
			if p.kind == "Bot" and rnd(3) == 0 then
				for t = 0, sim.N - 1 do
					if readi32(sim.owner, t * 4) == id then
						sim:add_struct(Defs.S_CITY, id, t)
						break
					end
				end
				p.structures = true
			end
		end
		for _, id in p_ids do
			if not info[id].friendly and rnd(5) < 2 then
				local amount = 100 + rnd(50000)
				local a = sim:start_attack(id, T, amount, -1)
				if a ~= nil then
					table.insert(incoming, { attacker = id, troops = amount })
				end
			end
		end
		-- the nearby owners: the owners of the land next to the tribe's block (and free land), by hand
		local want_near = {}
		local W = sim.W
		for y = BLOCK[2], BLOCK[4] do
			for x = BLOCK[1], BLOCK[3] do
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local o = readi32(sim.owner, ((y + d[2]) * W + x + d[1]) * 4)
					if o ~= T then
						want_near[o] = true
					end
				end
			end
		end
		ai:_tribe_nearby(sim, T)
		local near = table.clone(ai._near)
		ai:_tribe_nearby(sim, T)
		local set_ok = #near == #ai._near
		for i, o in near do
			set_ok = set_ok and want_near[o] == true and ai._near[i] == o
		end
		for o in want_near do
			set_ok = set_ok and table.find(near, o) ~= nil
		end
		if set_ok then
			same_near += 1
		end

		-- the same random numbers for both
		local values = {}
		for i = 1, 24 do
			values[i] = rnd(1048576)
		end
		local stub = Script.new(values)
		local real_rng = sim.rng
		sim.rng = {
			randi = function(_)
				return 0 -- border-scan tie breaks, not decisions
			end,
			randi_range = function(_, a, b)
				return a + stub:next() % (b - a + 1)
			end,
			randf = function(_)
				return 0
			end,
		}
		local got = nil
		sim.intent_attack_troops = function(self, id, t, amount)
			got = got or { target = readi32(self.owner, t * 4), troops = math.floor(math.min(amount, self.o_troops[id])) }
			return true
		end
		sim.launch_boat = function(self, _id, t, _ratio)
			got = got or { target = readi32(self.owner, t * 4), boat = true }
			return true
		end
		ai:_think_tribe(sim, T)
		sim.rng = real_rng

		local model = Script.new(values)
		local st = {
			near = near,
			p = info,
			incoming = incoming,
			troops = troops,
			max = Formula.maxTroopsBot(sim.o_tiles[T]),
			trigger = ai.trigger_r[T],
			reserve = ai.reserve_r[T],
			expand = ai.expand_r[T],
			latch = latch,
			landTN = land_tn,
		}
		local want, want_latch = Formula.maybeAttack(st, model)
		local same = (want == nil and got == nil)
			or (
				want ~= nil
				and got ~= nil
				and want.target == got.target
				and (want.boat == true) == (got.boat == true)
				and want.troops == got.troops
			)
		if same then
			agree += 1
		elseif first_bad == nil then
			first_bad = string.format(
				"case %d: Sim %s, model %s",
				case,
				if got then string.format("-> %d (%s)", got.target, tostring(got.troops)) else "nothing",
				if want then string.format("-> %d (%s)", want.target, tostring(want.troops)) else "nothing"
			)
		end
		if stub.used == model.used then
			same_draws += 1
		end
		if (ai.tribe_tn[T] == 1) == want_latch then
			latch_ok += 1
		end
		local key = if want == nil
			then "nothing"
			elseif want.target == 0 then "free land"
			else TYPE[sim.o_kind[want.target]]:lower()
		by_outcome[key] = (by_outcome[key] or 0) + 1
	end
	local parts = {}
	for k, v in by_outcome do
		table.insert(parts, k .. " " .. v)
	end
	table.sort(parts)
	expect(same_near == CASES, string.format("nearby() = the owners next to the border, free land as 0 (%d/%d)", same_near, CASES))
	expect(
		agree == CASES,
		string.format("same attack, target and troops (%d/%d: %s)", agree, CASES, table.concat(parts, ", "))
			.. (if first_bad then " — " .. first_bad else "")
	)
	expect(same_draws == CASES, string.format("same random draws, in the same order (%d/%d)", same_draws, CASES))
	expect(latch_ok == CASES, string.format("same neighborsTerraNullius latch (%d/%d)", latch_ok, CASES))
end

-- =============================================================================================
-- 4. Alliances
-- =============================================================================================
print("4. alliances")
do
	local fmap = synth_map("tribes_ally", 48, 48)
	local sim = empty_sim(fmap, 3)
	local T = add(sim, "T", KIND_TRIBE, 20000)
	local H = add(sim, "H", KIND_HUMAN, 20000)
	local H2 = add(sim, "H2", KIND_HUMAN, 20000)
	own(sim, T, 16, 16, 31, 31)
	own(sim, H, 32, 16, 40, 31)
	own(sim, H2, 16, 32, 31, 40)
	cadence(sim, T, 50, 7)
	-- a request before the tribe's first act waits for its second attack tick
	sim:ally_request(H2, T)
	step_to(sim, 7)
	expect(sim.ai.started[T] == 1 and not sim:allied(T, H2), "not answered on the first attack tick (tick 7)")
	-- mid-war: the tribe attacks H, then H asks
	step_to(sim, 20)
	sim:start_attack(T, H, 3000, -1)
	sim:ally_request(H, T)
	step_to(sim, 56)
	expect(not sim:allied(T, H) and not sim:allied(T, H2), "not answered off the attack ticks (to tick 56)")
	sim:step()
	expect(
		sim.tick == 57 and sim:allied(T, H) and sim:allied(T, H2),
		"both accepted on the next attack tick (tick 57), one of them mid-war"
	)
	-- renewal: H asks inside the window; the tribe agrees on its next attack tick
	local k = SimState.pair_key(T, H)
	sim.ally_expires[k] = sim.tick + 250
	step_to(sim, 60)
	expect(sim:ally_extend(H, T), "H asks to renew")
	step_to(sim, 106)
	expect(not sim:asked_to_extend(T, H) and sim:alliance_expires(T, H) == 57 + 250, "not renewed before tick 107")
	sim:step()
	expect(sim:alliance_expires(T, H) == 107 + Rules.ALLIANCE_TICKS, "renewed on the attack tick 107")
end

-- =============================================================================================
-- 5. No human grace, no stand-alone counter-attack
-- =============================================================================================
print("5. humans")
do
	local fmap = synth_map("tribes_human", 48, 48)
	-- a tribe enclosed by a human: at triggerRatio it goes for the human (1 time in 2 per attack tick)
	local sim = empty_sim(fmap, 5)
	local H = add(sim, "H", KIND_HUMAN, 200000)
	local T = add(sim, "T", KIND_TRIBE, 1000)
	own(sim, H, 8, 8, 39, 39)
	own(sim, T, 18, 18, 29, 29)
	cadence(sim, T, 40, 3)
	expect(sim:_landing_allowed(T, H), "a tribe's transports may land on a human at once")
	local log = record(sim)
	step_to(sim, 3) -- first act (no free land: nothing)
	sim.o_troops[T] = math.floor(sim.o_cap[T] * 0.9)
	local hit = nil
	for _ = 1, 12 do
		local before = sim.o_troops[T]
		step_to(sim, sim.tick + 40)
		for _, e in log do
			if e.id == T and e.target == H and hit == nil then
				hit = e
				hit.cap = sim.R.max_troops(KIND_TRIBE, sim.o_tiles[T], 0, 1)
				hit.before = before
			end
		end
		if hit then
			break
		end
		sim.o_troops[T] = math.floor(sim.o_cap[T] * 0.9)
	end
	expect(
		hit ~= nil and hit.tick < Rules.human_grace_ticks(1),
		string.format(
			"the tribe attacks its human neighbour at tick %s (the old human grace was %d+ ticks)",
			if hit then tostring(hit.tick) else "never",
			Rules.human_grace_ticks(1)
		)
	)

	-- attacked below triggerRatio: no answer; at triggerRatio: the attacker, on the attack tick
	local sim2 = empty_sim(fmap, 6)
	local H2 = add(sim2, "H", KIND_HUMAN, 500000)
	local T2 = add(sim2, "T", KIND_TRIBE, 1000)
	own(sim2, H2, 8, 8, 39, 39)
	own(sim2, T2, 18, 18, 29, 29)
	cadence(sim2, T2, 40, 3)
	sim2.ai.trigger_r[T2] = 0.55
	local log2 = record(sim2)
	-- attack ticks 3, 43, 83, 123, 163: H is attacking the tribe at each of them
	for _, d in { 43, 83, 123 } do
		step_to(sim2, d - 1)
		sim2:start_attack(H2, T2, 60, -1)
		sim2.o_troops[T2] = math.floor(sim2.o_cap[T2] * 0.3)
		sim2:step()
	end
	local answered = false
	for _, e in log2 do
		answered = answered or e.id == T2
	end
	expect(
		not answered and sim2:attack_between(H2, T2) ~= nil,
		"under attack below triggerRatio: no counter-attack (3 attack ticks)"
	)
	step_to(sim2, 162)
	sim2:start_attack(H2, T2, 60, -1)
	sim2.o_troops[T2] = math.floor(sim2.o_cap[T2] * 0.6)
	sim2:step()
	local e = log2[#log2]
	local want = if e then math.floor(e.home - Formula.maxTroopsBot(e.tiles) * sim2.ai.reserve_r[T2]) else -1
	expect(
		e ~= nil and e.id == T2 and e.tick == 163 and e.target == H2 and e.troops == want,
		string.format(
			"at triggerRatio it answers the attacker on its attack tick with troops - reserveRatio x max (%s)",
			if e then tostring(e.troops) else "-"
		)
	)
end

-- =============================================================================================
-- 6. Rivers
-- =============================================================================================
print("6. rivers")
do
	-- a 3-wide river at x = 28..30; the tribe's land (x 20..27) touches it, a human walls it in on
	-- the land side, the far bank is free land
	local rmap = synth_map("tribes_river", 60, 40, { 28, 30 })
	local sim = empty_sim(rmap, 7)
	local X = add(sim, "X", KIND_HUMAN, 10000)
	local T = add(sim, "T", KIND_TRIBE, 20000)
	own(sim, X, 0, 0, 27, 39)
	own(sim, T, 20, 10, 27, 29)
	cadence(sim, T, 40, 4)
	local log = record(sim)
	step_to(sim, 4)
	local e = log[#log]
	expect(
		e ~= nil and e.boat and e.ok and e.target == 0 and e.tile % 60 == 31 and sim.o_boats[T] == 1,
		"first act, no free land next to it: a transport to the free far bank (sendBoatAttackToNearbyTerraNullius)"
	)
	local boat = nil
	for _, u in sim.unit_list do
		if not u.dead and u.owner == T and u.kind == Defs.U_TRANSPORT then
			boat = u
		end
	end
	expect(
		boat ~= nil and e ~= nil and boat.troops == math.floor(e.home / 5),
		string.format("with troops / 5 (%s)", if boat then tostring(boat.troops) else "-")
	)
	sim.ai:_tribe_nearby(sim, T)
	expect(table.find(sim.ai._near, 0) ~= nil, "free land across the river is nearby (shoreReachableNeighbors)")

	-- a tribe on the far bank: seen across the river, attacked by transport at the closest shore
	local sim2 = empty_sim(rmap, 8)
	local X2 = add(sim2, "X", KIND_HUMAN, 10000)
	local T2 = add(sim2, "T", KIND_TRIBE, 20000)
	local P = add(sim2, "P", KIND_TRIBE, 10000)
	own(sim2, X2, 0, 0, 27, 39)
	own(sim2, T2, 20, 10, 27, 29)
	own(sim2, P, 31, 0, 59, 39)
	cadence(sim2, T2, 40, 4)
	cadence(sim2, P, 1000000, -1) -- P never acts
	sim2.ai.tribe_tn[T2] = 0
	local log2 = record(sim2)
	step_to(sim2, 4)
	local got = nil
	for _ = 1, 10 do
		sim2.o_troops[T2] = math.floor(sim2.o_cap[T2] * 0.9)
		step_to(sim2, sim2.tick + 40)
		for _, x in log2 do
			if x.id == T2 and x.target == P then
				got = got or x
			end
		end
		if got then
			break
		end
	end
	local want = Formula.closestTwoTiles(60, sim2:coast_tiles(T2), sim2:coast_tiles(P))
	expect(
		got ~= nil and got.boat and got.ok and got.tile == want and got.ratio == 0.2,
		string.format(
			"a player across the river gets a transport (troops / 5) at closestTwoTiles' shore (tile %s, want %d)",
			if got then tostring(got.tile) else "-",
			want
		)
	)
	-- the coast lists stay exact
	local exact = true
	for _, id in { X2, T2, P } do
		local n = 0
		for _, c in sim2:coast_tiles(id) do
			n += 1
			exact = exact and readi32(sim2.owner, c * 4) == id and readu8(rmap.coastal, c) == 1
		end
		exact = exact and n == sim2.o_coast[id]
	end
	expect(exact, "every owner's coast list = its coastal tiles")
end

-- =============================================================================================
-- 7. Captured structures
-- =============================================================================================
print("7. captured structures")
do
	local fmap = synth_map("tribes_structs", 48, 48)
	local sim = empty_sim(fmap, 9)
	local H = add(sim, "H", KIND_HUMAN, 100000)
	local T = add(sim, "T", KIND_TRIBE, 5000)
	own(sim, H, 0, 0, 40, 40)
	own(sim, T, 10, 10, 30, 30)
	cadence(sim, T, 40, 5)
	sim.ai.trigger_r[T] = 2 -- never attacks: only the deletions matter here
	local W = sim.W
	local c1 = sim:add_struct(Defs.S_CITY, H, 33 * W + 20)
	local c2 = sim:add_struct(Defs.S_CITY, H, 33 * W + 26)
	step_to(sim, 200) -- both cities built
	sim:set_owner(c1.tile, T)
	sim:step()
	sim:set_owner(c2.tile, T)
	sim:step()
	expect(
		c1.owner == T and c2.owner == T and not c1.dead and not c2.dead,
		"the tribe keeps what it captures"
	)
	expect(
		math.abs(sim.o_cap[T] - Formula.maxTroopsBot(sim.o_tiles[T], 2)) < 1e-6,
		"its cities count for its maxTroops meanwhile"
	)
	-- attack ticks 205, 245, 285, 325...: the first with tick - (-1) >= 300 is 325
	step_to(sim, 324)
	expect(c1.delete_at == 0 and c2.delete_at == 0, "nothing marked before the delete cooldown (tick 324)")
	sim:step()
	expect(
		c1.delete_at == 325 + Formula.DELETION_MARK and c2.delete_at == 0,
		"tick 325: the first captured city is marked (deleteNextStructure)"
	)
	step_to(sim, 625)
	expect(not c1.dead and c2.delete_at == 0, "still there at tick 625")
	sim:step()
	expect(c1.dead, "gone at tick 626 (isOverdueDeletion)")
	-- the next mark: attack tick with tick - 325 >= 300, i.e. 645
	step_to(sim, 644)
	expect(c2.delete_at == 0, "the second waits for the cooldown (tick 644)")
	sim:step()
	expect(c2.delete_at == 645 + Formula.DELETION_MARK, "tick 645: the second city is marked")
	step_to(sim, 700)
	sim:set_owner(c2.tile, H) -- recaptured
	step_to(sim, 1000)
	expect(not c2.dead and c2.owner == H and c2.delete_at == 0, "recaptured before it went: kept (setOwner clears the mark)")
end

-- =============================================================================================
-- 8. A lone tribe on World for 60 s
-- =============================================================================================
print("8. a lone tribe on World, 60 s: ours vs the step model")
--- A step model of one tribe on the raw tile bytes of `map` (independent of the Sim):
--- income every tick (troopIncreaseRate, whole troops), an order into terra nullius
--- with troops - maxTroops x expandRatio on its attack ticks, and the attack taking terra
--- nullius tile by tile (a binary heap of priorities, border jitter) with its own RNG.
local Model = {}
Model.__index = Model
function Model.new(map: any, spawn: { number }, seed: number, rate: number, at: number, expand: number): any
	local self = setmetatable({}, Model)
	self.W, self.H, self.N = map.W, map.H, map.N
	self.bytes = map.tile_bytes
	self.owner = buffer.create(map.N)
	self.owned = {}
	self.troops = 10000 -- startManpower of a tribe
	self.tick = 0
	self.seed = seed
	self.rate, self.at, self.expand = rate, at, expand
	self.attack = nil
	for _, t in spawn do
		self:conquer(t)
	end
	return self
end
function Model:next(): number
	self.seed = (self.seed * 1103515245 + 12345) % 2147483648
	return self.seed / 2147483648
end
function Model:nextInt(lo: number, hi: number): number
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
function Model:neighbors(t: number): { number }
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
function Model:addNeighbors(a: any, tile: number) -- the free land around a taken tile joins the border
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
function Model:order(amount: number) -- a new order: the border rebuilt, absorbs the running one
	local removed = math.min(self.troops, math.floor(math.min(self.troops, amount)))
	self.troops -= removed
	local a = { troops = removed, heap = { pri = {}, til = {}, n = 0 }, border = {}, bsize = 0 }
	for _, t in self.owned do
		self:addNeighbors(a, t)
	end
	if self.attack ~= nil then
		a.troops += self.attack.troops
	end
	self.attack = a
end
function Model:attackTick() -- one attack tick
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
			self.troops = Formula.addTroops(self.troops, a.troops)
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
		local loss, tf = Formula.tnAttackLogic(self:terrain(tile), troops, "Bot", borderSize)
		budget -= tf
		troops -= loss
		a.troops = math.max(0, troops)
		self:conquer(tile)
	end
end
--- One tick: income, the tribe's own turn (its attack reaches the running one at the end of the
--- tick), then the running attack.
function Model:step()
	self.tick += 1
	local max = Formula.maxTroopsBot(#self.owned)
	self.troops = Formula.addTroops(self.troops, Formula.troopIncreaseRateBot(self.troops, max))
	local amount = nil
	if self.tick % self.rate == self.at then
		local troops = self.troops - max * self.expand
		if troops >= 1 then
			amount = troops
		end
	end
	self:attackTick()
	if amount ~= nil then
		self:order(amount)
	end
end
function Model:total_troops(): number
	return self.troops + (if self.attack ~= nil then self.attack.troops else 0)
end

do
	local SECONDS = 60
	local sim = Sim.new(world, { seed = 4, difficulty = 1, tribes = 1, nations = false, max_humans = 0 })
	local T = 1
	expect(sim.o_kind[T] == KIND_TRIBE and sim.o_alive[T] == 1, "one tribe")
	local spawn = {}
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == T then
			table.insert(spawn, t)
		end
	end
	local ai = sim.ai
	local rate, at, expand = ai.attack_rate[T], ai.attack_tick[T], ai.expand_r[T]
	local ours = {}
	for p = 1, SECONDS * 10 do
		sim:step()
		if p % 100 == 0 then
			table.insert(ours, { sim.o_tiles[T], sim.o_troops[T] + sim:troops_in_attacks(T) })
		end
	end
	local runs = {}
	for seed = 1, 6 do
		local model = Model.new(world, spawn, seed * 7919, rate, at, expand)
		local rows = {}
		for p = 1, SECONDS * 10 do
			model:step()
			if p % 100 == 0 then
				table.insert(rows, { #model.owned, model:total_troops() })
			end
		end
		table.insert(runs, rows)
	end
	print(string.format("    attackRate %d, attackTick %d, expandRatio %.2f, %d start tiles", rate, at, expand, #spawn))
	local all_ok = true
	for i, row in ours do
		local lo_t, hi_t, sum_t, lo_r, hi_r, sum_r = math.huge, -math.huge, 0, math.huge, -math.huge, 0
		for _, rows in runs do
			local r = rows[i]
			lo_t, hi_t, sum_t = math.min(lo_t, r[1]), math.max(hi_t, r[1]), sum_t + r[1]
			lo_r, hi_r, sum_r = math.min(lo_r, r[2]), math.max(hi_r, r[2]), sum_r + r[2]
		end
		-- the RNG streams differ (tile priorities, border jitter): ours must sit inside the model's
		-- seed spread widened by 2 % (1 % for troops)
		local ok_t = row[1] >= lo_t * 0.98 and row[1] <= hi_t * 1.02
		local ok_r = row[2] >= lo_r * 0.99 and row[2] <= hi_r * 1.01
		all_ok = all_ok and ok_t and ok_r
		print(
			string.format(
				"    t=%2ds  ours %6d tiles %6d troops | model %6.0f tiles [%d..%d] %6.0f troops [%d..%d]%s",
				i * 10,
				row[1],
				row[2],
				sum_t / #runs,
				lo_t,
				hi_t,
				sum_r / #runs,
				lo_r,
				hi_r,
				if ok_t and ok_r then "" else "  <-- off"
			)
		)
	end
	expect(all_ok, "60 s of tribe expansion matches the model (within its seed spread)")
end

print(if fails == 0 then "tribes_rules: all passed" else string.format("tribes_rules: %d FAILED", fails))
if fails > 0 then
	error("tribes_rules failed")
end
