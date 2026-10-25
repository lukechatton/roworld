-- sim-systems: timing of the sim-systems subsystems inside a real late-game Sim.step (AI-only
-- match on an imported map, its nations + 80 tribes, Standard).
-- Run: .bin/lune run tests/simsys_perf.luau [-- --minutes=12 --seed=1 --map=world]
-- Prints ms/tick per subsystem (wrapped with os.clock, so a few µs of wrapper overhead each).
local process = require("@lune/process")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")

local minutes, seed, map_id = 12, 1, "world"
for _, a in process.args do
	local k, v = string.match(a, "^%-%-([%w_]+)=(.*)$")
	if k == "minutes" then
		minutes = tonumber(v) or minutes
	elseif k == "seed" then
		seed = tonumber(v) or seed
	elseif k == "map" then
		map_id = v
	end
end

local sim = Sim.new(WorldMap.get(map_id), { seed = seed, difficulty = 1, tribes = 80, max_humans = 0 })
local warm = (minutes - 3) * 600
for _ = 1, warm do
	sim:step()
end
local names = { "construction_tick", "units_tick", "warships_tick", "ports_tick", "factories_tick", "nukes_tick" }
local acc = {}
for _, name in names do
	local orig = sim[name]
	acc[name] = 0
	sim[name] = function(...)
		local t0 = os.clock()
		orig(...)
		acc[name] += os.clock() - t0
	end
end
local ai = sim.ai
local otick = ai.tick
local ai_t = 0
ai.tick = function(...)
	local t0 = os.clock()
	otick(...)
	ai_t += os.clock() - t0
end
local n = 1800
local t0 = os.clock()
for _ = 1, n do
	sim:step()
end
local total = (os.clock() - t0) / n * 1000
local mine = ai_t
print(string.format("minutes %d-%d, seed %d: Sim.step avg %.3f ms", minutes - 3, minutes, seed, total))
for _, name in names do
	print(string.format("  %-18s %.3f ms/tick", name, acc[name] / n * 1000))
	mine += acc[name]
end
print(string.format("  %-18s %.3f ms/tick", "ai.tick", ai_t / n * 1000))
print(
	string.format(
		"  sim-systems share %.3f ms/tick (%.0f %%) | warships %d units %d structs %d roads %d nukes launched %d",
		mine / n * 1000,
		mine / n * 1000 / total * 100,
		#sim.warship_list,
		#sim.unit_list,
		sim:struct_total(),
		sim:road_total(),
		sim.nukes_launched
	)
)
