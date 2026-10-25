-- Bot players (public-match fill): AI commanders that look exactly like human players. They take a
-- random start at a random moment of the spawn phase, are HUMAN-kind owners everywhere a client
-- can see (snapshot / mirror), grow and build like AI nations, and the match stays deterministic.
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local serde = require("@lune/serde")
local Defs = require("../src/shared/Core/Defs")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local BotNames = require("../src/shared/Data/BotNames")
local Protocol = require("../src/shared/Net/Protocol")

Protocol.set_codec({
	compress = function(b: buffer): buffer
		return buffer.fromstring(serde.compress("zstd", buffer.tostring(b)))
	end,
	decompress = function(b: buffer, _n: number): buffer
		return buffer.fromstring(serde.decompress("zstd", buffer.tostring(b)))
	end,
})

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
local function run(seed: number, ticks: number)
	local sim = Sim.new(map, { seed = seed, difficulty = 1, tribes = 40, max_humans = 12, spawn_ticks = 100 })
	local human = sim:add_human("u1", "RealPerson")
	local r = seed
	local function rand()
		r = (r * 1103515245 + 12345) % 2147483648
		return r / 2147483648
	end
	local bots = sim:add_bot_players(8, BotNames.many(8, rand))
	local gs = GameState.new(map)
	gs:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(sim:snapshot())))
	-- the human picks early; bots pick during the phase
	local spawned_at = {}
	for t = 1, ticks do
		if t == 5 then
			sim:submit(human, { type = "spawn", tile = map:land_tile(math.floor(map.land_count / 2)) })
		end
		local d = sim:step()
		gs:apply_delta(Protocol.decode_delta(Protocol.encode_delta(d)))
		for _, b in bots do
			if spawned_at[b] == nil and sim.o_spawned[b] == 1 then
				spawned_at[b] = t
			end
		end
	end
	return sim, gs, human, bots, spawned_at
end

local sim, gs, human, bots, spawned_at = run(7, 700)
expect(#bots == 8, "8 bot players added")
local all_spawned, spread = true, {}
for _, b in bots do
	if spawned_at[b] == nil then
		all_spawned = false
	else
		spread[spawned_at[b]] = true
	end
end
local distinct = 0
for _ in spread do
	distinct += 1
end
expect(all_spawned, "every bot took a start during the spawn phase")
expect(distinct >= 4, "bots pick at different moments (" .. distinct .. " distinct ticks)")
local look_human = true
for _, b in bots do
	local o = gs:get_owner(b)
	if o == nil or o.kind ~= Defs.KIND_HUMAN or string.find(o.name, "bot") then
		look_human = false
	end
end
expect(look_human, "the client mirror sees bots as human players with player names")
expect(gs:get_owner(human).kind == Defs.KIND_HUMAN, "the real human too")
local grew, built = 0, 0
for _, b in bots do
	if sim.o_tiles[b] > 60 then
		grew += 1
	end
	for k = 0, Defs.STRUCT_KIND_COUNT - 1 do
		if sim.o_built[b * 16 + k] > 0 then
			built += 1
			break
		end
	end
end
expect(grew >= 6, "bots expand like AI nations (" .. grew .. "/8 past 60 tiles)")
print("  info bots with structures after 700 ticks: " .. built)
-- the snapshot never tells clients who is a bot
local snap = sim:snapshot()
local leaks = false
for k in snap do
	if string.find(string.lower(tostring(k)), "bot") then
		leaks = true
	end
end
expect(not leaks, "snapshots carry no bot flag")
-- determinism
local sim2 = run(7, 700)
local same = true
for id = 1, sim.owner_total do
	if sim.o_tiles[id] ~= sim2.o_tiles[id] or math.floor(sim.o_troops[id]) ~= math.floor(sim2.o_troops[id]) then
		same = false
	end
end
expect(same, "same seed -> same match")

print(if fails == 0 then "sim_bots: all passed" else string.format("sim_bots: %d FAILED", fails))
if fails > 0 then
	error("sim_bots failed")
end
