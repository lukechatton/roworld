-- sim-core: quick smoke run (title mode) — .bin/lune run tests/sim_smoke.luau [ticks] [map=world]
local process = require("@lune/process")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local ticks = tonumber(process.args[1]) or 300
local map = WorldMap.get(process.args[2] or "world")
local t0 = os.clock()
local sim = Sim.new(map, { seed = 1, difficulty = 1, tribes = 80, max_humans = 0 })
print(("init %.0f ms owners %d"):format((os.clock() - t0) * 1000, sim:owner_count()))
local ts = os.clock()
for i = 1, ticks do
	local d = sim:step()
	if i % 100 == 0 then
		local claimed = 0
		for id = 1, sim.owner_total do
			if sim.o_alive[id] == 1 then
				claimed += sim.o_tiles[id]
			end
		end
		print(
			("tick %d claimed %.1f%% attacks %d ev %d"):format(
				sim.tick,
				100 * claimed / map.contestable_count,
				#sim.attacks,
				#d.ev
			)
		)
	end
end
print(("avg %.2f ms/tick"):format((os.clock() - ts) * 1000 / ticks))
