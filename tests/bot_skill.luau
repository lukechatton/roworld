-- Bot players: only Sim.SMART_BOTS of them play at the match's difficulty with human troop numbers;
-- the rest are novices (Easy nation AI, Easy nation troops). Checks the split and the numbers, then
-- measures a new player's first minutes in a public-style match (World at 80 %, 29 bot players):
-- how often bot players attack them and how they fare, novices vs. the old all-smart bots.
require("./prelude")
local process = require("@lune/process")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local BotNames = require("../src/shared/Data/BotNames")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local map = WorldMap.get("world@80")
local BOTS = 29
local PLAY_TICKS = 3000 -- 5 minutes

local function run(seed: number, smart: number, difficulty: number)
	local keep = Sim.SMART_BOTS
	Sim.SMART_BOTS = smart
	local sim = Sim.new(map, { seed = seed, difficulty = difficulty, max_humans = 40, spawn_ticks = 200 })
	local h = sim:add_human("u1", "Newbie")
	local r = seed
	local bots = sim:add_bot_players(
		BOTS,
		BotNames.many(BOTS, function()
			r = (r * 1103515245 + 12345) % 2147483648
			return r / 2147483648
		end)
	)
	Sim.SMART_BOTS = keep
	-- the new player starts on open land in Africa's middle and expands every 5 s at 20 %
	local spawn = map:point_tile(math.floor(map.W * 0.53), math.floor(map.H * 0.55))
	for d = 0, 400 do
		local t = spawn + d
		if map:is_contestable(t) then
			spawn = t
			break
		end
	end
	sim:submit(h, { type = "spawn", tile = spawn })
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	local far = map:land_tile(map.land_count - 1)
	local bot_set = {}
	for _, b in bots do
		bot_set[b] = true
	end
	local attacks, attackers = 0, {}
	local seen = {}
	for p = 1, PLAY_TICKS do
		if p % 50 == 1 and sim.o_alive[h] == 1 then
			sim:submit(h, { type = "attack", tile = far, ratio = Rules.DEFAULT_ATTACK_RATIO })
		end
		local d = sim:step()
		for _, e in d.ev or {} do
			if e[1] == Ev.ATTACK and e[4] == h and bot_set[e[3]] and not seen[e[2]] then
				seen[e[2]] = true
				attacks += 1
				attackers[e[3]] = true
			end
		end
	end
	local n_att = 0
	for _ in attackers do
		n_att += 1
	end
	return {
		sim = sim,
		bots = bots,
		attacks = attacks,
		attackers = n_att,
		alive = sim.o_alive[h] == 1,
		tiles = sim.o_tiles[h],
	}
end

-- the split and the numbers
do
	local sim = Sim.new(WorldMap.get("pangaea"), { seed = 5, difficulty = 1, max_humans = 40, spawn_ticks = 50 })
	local bots = sim:add_bot_players(20, nil)
	local smart, novice = 0, 0
	for _, b in bots do
		if sim:is_novice_bot(b) then
			novice += 1
		else
			smart += 1
		end
	end
	expect(
		smart == Sim.SMART_BOTS and novice == 20 - Sim.SMART_BOTS,
		string.format("%d smart, %d novice bots", smart, novice)
	)
	local nb = nil
	for _, b in bots do
		if sim:is_novice_bot(b) then
			nb = b
			break
		end
	end
	expect(sim:ai_difficulty(nb) == Sim.NOVICE_SKILL, "novices play the Easy AI")
	expect(sim.o_troops[nb] == Rules.start_troops(Defs.KIND_NATION, 0), "novices start with the Easy nation's troops")
	-- towards players the smart ones are as patient as Easy AI (Rules.SMART_VS_PLAYERS)
	local sb = nil
	for _, b in bots do
		if not sim:is_novice_bot(b) then
			sb = b
			break
		end
	end
	expect(sim:ai_difficulty(sb) == Sim.SMART_SKILL and Sim.SMART_SKILL == 1, "smart bot players play the Medium AI")
	expect(
		Rules.SMART_VS_PLAYERS == 0 and sim:human_difficulty(sb) == 0,
		"but follow Easy's rules towards players (5 min of peace, 1 AI war on a player, 3 in 4 passed over)"
	)
	expect(sim:human_difficulty(nb) == 0, "novices: Easy towards players, as before")
	local nation = nil
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == Defs.KIND_NATION then
			nation = id
			break
		end
	end
	expect(
		nation ~= nil and sim:human_difficulty(nation) == sim.difficulty,
		"a nation keeps its match's rules (Medium here)"
	)
	local h = sim:add_human("u", "Real")
	expect(sim:ai_difficulty(h) == sim.difficulty and not sim:is_novice_bot(h), "real players are untouched")
	local a = Sim.new(WorldMap.get("pangaea"), { seed = 5, difficulty = 1, max_humans = 40, spawn_ticks = 50 })
	local b1 = a:add_bot_players(20, nil)
	local same = true
	for i, b in b1 do
		if a:is_novice_bot(b) ~= sim:is_novice_bot(bots[i]) then
			same = false
		end
	end
	expect(same, "which bots are smart is deterministic")
end

-- a new player's first five minutes in a public match (Easy nations, 2 smart + novice bots) vs. the
-- old setup (Medium nations, every bot smart). Slow (~30 s): AF_SLOW=1 .bin/lune run tests/bot_skill.luau
if process.env.AF_SLOW == "1" then
	local now_att, now_alive, now_tiles, old_att, old_alive, old_tiles = 0, 0, 0, 0, 0, 0
	local seeds = { 3, 11 }
	for _, seed in seeds do
		local new = run(seed, Sim.SMART_BOTS, 0)
		local old = run(seed, BOTS, 1)
		print(
			string.format(
				"  info seed %d: bot attacks on the new player %d (by %d bots) vs %d (by %d) before; alive %s / %s; tiles %d / %d",
				seed,
				new.attacks,
				new.attackers,
				old.attacks,
				old.attackers,
				tostring(new.alive),
				tostring(old.alive),
				new.tiles,
				old.tiles
			)
		)
		now_att += new.attacks
		old_att += old.attacks
		now_alive += if new.alive then 1 else 0
		old_alive += if old.alive then 1 else 0
		now_tiles += new.tiles
		old_tiles += old.tiles
	end
	expect(now_att < old_att, string.format("fewer bot attacks on a new player (%d vs %d)", now_att, old_att))
	expect(
		now_alive >= old_alive,
		string.format("the new player survives at least as often (%d vs %d of %d)", now_alive, old_alive, #seeds)
	)
end

print(if fails == 0 then "bot_skill: all passed" else string.format("bot_skill: %d FAILED", fails))
if fails > 0 then
	error("bot_skill failed")
end
