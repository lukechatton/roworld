-- The spawn shield (Rules.SPAWN_SHIELD_TICKS, 2026-10-30): a start is about 50 full-size tiles, under
-- the annexation threshold, so the first tile any attack took won the whole nation, whatever its
-- army (119 troops took 26,646 on the first tick of play). Now no one attacks a person for 30 s from
-- the nation's first tick in play (the start of play, or a late joiner's landing), attacking a person
-- or a nation ends one's own shield, and a person's small nation is annexed only by an attack that
-- outnumbers its army at home.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local map = WorldMap.get("pangaea")
local readi32 = buffer.readi32

local function neighbours(sim: any, t: number): { number }
	local out = {}
	local x = t % sim.W
	if x > 0 then
		table.insert(out, t - 1)
	end
	if x < sim.W - 1 then
		table.insert(out, t + 1)
	end
	if t >= sim.W then
		table.insert(out, t - sim.W)
	end
	if t < sim.N - sim.W then
		table.insert(out, t + sim.W)
	end
	return out
end

-- a tile of `b` next to land of `a` (-1 if they don't touch)
local function front(sim: any, a: number, b: number): number
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == b then
			for _, n in neighbours(sim, t) do
				if readi32(sim.owner, n * 4) == a then
					return t
				end
			end
		end
	end
	return -1
end

local function contestable_from(k0: number): number
	for k = k0, map.land_count - 1, 7 do
		local t = map:land_tile(k)
		if map:is_contestable(t) then
			return t
		end
	end
	return -1
end

-- the first contestable land tile `d` or more tiles from `t` along a row or column
local function away(sim: any, t: number, d: number): number
	for e = d, d + 40 do
		for _, c in { t + e, t - e, t + e * sim.W, t - e * sim.W } do
			if c >= 0 and c < sim.N and map:is_contestable(c) and readi32(sim.owner, c * 4) == 0 then
				return c
			end
		end
	end
	return -1
end

local function msgs_to(d: any, id: number, out: { string })
	for _, e in d.ev or {} do
		if e[1] == Ev.MSG and e[2] == id then
			table.insert(out, e[4])
		end
	end
end

-- Two players who start close; A expands (land only) until it touches B.
local function neighbours_match(seed: number): (any, number, number)
	local sim =
		Sim.new(map, { seed = seed, difficulty = 1, tribes = 0, nations = false, max_humans = 8, spawn_ticks = 20 })
	local a = sim:add_human("u1", "A")
	local b = sim:add_human("u2", "B")
	local ta = contestable_from(map.land_count // 2)
	sim:submit(a, { type = "spawn", tile = ta })
	sim:submit(b, { type = "spawn", tile = away(sim, ta, math.ceil(sim.R.SPAWN_RADIUS * 2.5)) })
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	sim:step()
	for _ = 1, 200 do
		if front(sim, a, b) >= 0 then
			break
		end
		if #sim.attacks == 0 then
			-- expand into every free tile next to A
			for t = 0, sim.N - 1 do
				if readi32(sim.owner, t * 4) == 0 and buffer.readu8(sim.land, t) == 1 then
					for _, n in neighbours(sim, t) do
						if readi32(sim.owner, n * 4) == a then
							sim:intent_attack(a, t, 0.3)
							break
						end
					end
				end
			end
		end
		sim:step()
	end
	return sim, a, b
end

-- the start of play: both shielded, and no attack gets through
do
	local sim, a, b = neighbours_match(21)
	local t = front(sim, a, b)
	expect(t >= 0, "the two starts touch")
	expect(sim:shielded(a) and sim:shielded(b), "both players are shielded from the start of play")
	expect(sim.o_shield_until[b] == sim.playing_since + Rules.SPAWN_SHIELD_TICKS, "for SPAWN_SHIELD_TICKS")
	local troops, tiles = sim.o_troops[a], sim.o_tiles[b]
	local ok = sim:intent_attack(a, t, 0.5)
	local msgs = {}
	msgs_to(sim:step(), a, msgs)
	expect(not ok and sim:attack_between(a, b) == nil, "an attack on a shielded player is refused")
	expect(sim.o_troops[a] >= troops and sim.o_tiles[b] == tiles, "and costs nothing: no troops sent, no land lost")
	expect(
		#msgs > 0 and string.find(msgs[1], "just spawned", 1, true) ~= nil,
		"the sender is told why: " .. tostring(msgs[1])
	)
	expect(not sim:_landing_allowed(a, b), "no transport lands on a shielded player")
	-- it runs out on its own
	while sim.tick < sim.o_shield_until[b] do
		sim:step()
	end
	expect(not sim:shielded(b), "the shield ends after " .. Rules.SPAWN_SHIELD_TICKS // Rules.TICK_RATE .. " s")
end

-- after the shield: a small nation's army has to be outnumbered before it falls whole
do
	local sim, a, b = neighbours_match(22)
	sim.o_shield_until[a] = 0
	sim.o_shield_until[b] = 0
	sim.o_troops[a] = 25000
	sim.o_troops[b] = 25000
	local tiles = sim.o_tiles[b]
	expect(tiles * sim.R.K_AREA < Rules.ANNEX_BELOW_FULL_TILES, "B is still under the annexation threshold")
	expect(sim:intent_attack(a, front(sim, a, b), 0.05), "a small attack goes out")
	for _ = 1, 50 do
		sim:step()
		if sim:attack_between(a, b) == nil then
			break
		end
	end
	expect(
		sim.o_alive[b] == 1 and sim.o_tiles[b] >= tiles * 0.7,
		"1,250 troops no longer take 25,000 (B kept " .. sim.o_tiles[b] .. " of " .. tiles .. " tiles)"
	)
	sim.o_troops[a] = 100000
	expect(sim:intent_attack(a, front(sim, a, b), 0.6), "an attack that outnumbers B's army goes out")
	for _ = 1, 50 do
		sim:step()
		if sim.o_alive[b] == 0 or sim:attack_between(a, b) == nil then
			break
		end
	end
	expect(sim.o_tiles[b] == 0, "and takes the whole nation")
end

-- attacking a person ends one's own shield (and the other may hit back)
do
	local sim, a, b = neighbours_match(23)
	sim.o_shield_until[b] = 0
	local msgs = {}
	expect(sim:intent_attack(a, front(sim, a, b), 0.2), "a shielded player may attack one who isn't")
	msgs_to(sim:step(), a, msgs)
	expect(not sim:shielded(a), "and loses their own shield")
	local said = false
	for _, m in msgs do
		said = said or string.find(m, "spawn shield is down", 1, true) ~= nil
	end
	expect(said, "and is told so")
	expect(sim:intent_attack(b, front(sim, b, a), 0.2), "so the other can hit back")
end

-- a late joiner: shielded from their landing, the AI included
do
	local sim =
		Sim.new(map, { seed = 24, difficulty = 1, tribes = 30, nations = false, max_humans = 8, spawn_ticks = 20 })
	local a = sim:add_human("u1", "A")
	sim:submit(a, { type = "spawn", tile = contestable_from(map.land_count // 2) })
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	for _ = 1, Rules.SPAWN_SHIELD_TICKS + 50 do
		sim:step()
	end
	expect(not sim:shielded(a), "the first player's shield is long over")
	local late = sim:add_human("u2", "Late")
	local spot = -1
	for k = 0, map.land_count - 1, 11 do
		local t = map:land_tile(k)
		if map:is_contestable(t) and readi32(sim.owner, t * 4) == 0 then
			spot = t
			break
		end
	end
	expect(sim:_intent_spawn(late, spot), "a late joiner may land on free land")
	local msgs = {}
	msgs_to(sim:step(), late, msgs)
	expect(sim.o_spawned[late] == 1 and sim:shielded(late), "and is shielded once landed")
	expect(sim.o_shield_until[late] == sim.tick + Rules.SPAWN_SHIELD_TICKS, "from the landing, not the start of play")
	expect(
		#msgs > 0 and string.find(msgs[1], "No one can attack you for 30 s", 1, true) ~= nil,
		"and told: " .. tostring(msgs[1])
	)
	local tribe = 0
	for id = 1, sim:owner_count() do
		if sim.o_kind[id] == Defs.KIND_TRIBE and sim.o_alive[id] == 1 then
			tribe = id
			break
		end
	end
	expect(tribe > 0 and not sim.ai:may_attack_human(sim, tribe, late), "tribes leave a shielded player be")
	expect(not sim.ai:_may_attack_human(sim, tribe, late, 100000), "the AI's human protection holds while shielded")
	expect(not sim:shielded(tribe), "AI nations and tribes have no shield")
end

-- solo: no one to be shielded from (and no "shield is down" in the tutorial)
do
	local sim = Sim.new(map, { seed = 25, difficulty = 1, tribes = 10, max_humans = 1 })
	local me = sim:add_human("u1", "Me")
	sim:human_start(me, contestable_from(map.land_count // 2))
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	sim:step()
	expect(not sim:shielded(me), "a solo match has no spawn shield")
end

if fails > 0 then
	error(fails .. " failure(s)")
end
print("spawn_shield: all ok")
