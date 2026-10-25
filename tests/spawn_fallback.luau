-- A public-match player who never picks a start during the spawn phase gets a random one when it
-- ends (Sim._spawn_phase_tick): placed on free land
-- away from the others, with the normal starting troops, told so, and playing from the first tick.
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
local sim = Sim.new(map, { seed = 11, difficulty = 1, tribes = 20, max_humans = 8, spawn_ticks = 60 })
local picker = sim:add_human("u1", "Picker")
local idle = sim:add_human("u2", "Idle")
-- the picker chooses a spot; the other one never does
local pick = -1
for k = 0, map.land_count - 1, 97 do
	local t = map:land_tile(k)
	if map:is_contestable(t) then
		pick = t
		break
	end
end
sim:submit(picker, { type = "spawn", tile = pick })
local msgs = {}
local guard = 0
while sim.phase ~= Defs.PHASE_PLAYING and guard < 500 do
	local d = sim:step()
	guard += 1
	for _, e in d.ev or {} do
		if e[1] == Ev.MSG and e[2] == idle then
			table.insert(msgs, e[4])
		end
	end
end
expect(sim.phase == Defs.PHASE_PLAYING, "the spawn phase ended")
expect(sim.o_spawned[idle] == 0, "the idle player had no start when it ended")
local d = sim:step()
for _, e in d.ev or {} do
	if e[1] == Ev.MSG and e[2] == idle then
		table.insert(msgs, e[4])
	end
end
expect(sim.o_spawned[idle] == 1 and sim.o_alive[idle] == 1 and sim.o_tiles[idle] > 0, "placed on the first tick of play: " .. sim.o_tiles[idle] .. " tiles")
expect(sim.o_troops[idle] >= Rules.START_TROOPS_HUMAN * 0.9, "with the normal starting troops")
local a, b = sim.o_spawn_tile[picker], sim.o_spawn_tile[idle]
expect(a >= 0 and b >= 0 and a ~= b and sim.geo_manhattan(a, b) >= 10, "away from the player who picked")
expect(#msgs > 0 and string.find(msgs[1], "placed", 1, true) ~= nil, "and told (\"" .. tostring(msgs[1]) .. "\")")
-- a player who left the match isn't placed
local sim2 = Sim.new(map, { seed = 12, difficulty = 1, tribes = 10, max_humans = 8, spawn_ticks = 40 })
local gone = sim2:add_human("u3", "Gone")
sim2.o_left[gone] = 1
while sim2.phase ~= Defs.PHASE_PLAYING do
	sim2:step()
end
sim2:step()
expect(sim2.o_spawned[gone] == 0, "a player who left is not placed")

print(if fails == 0 then "spawn_fallback: all passed" else string.format("spawn_fallback: %d FAILED", fails))
if fails > 0 then
	error("spawn_fallback failed")
end
