-- sim-core: Sim.new / GameState:load_snapshot inside a Coop job yield in small slices and give the
-- same result as a direct call (on the default map, World 2000 x 1000).
-- Run: .bin/lune run tests/sim_coop.luau
local Coop = require("../src/shared/Net/Coop")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local fails = 0
local function expect(c, w)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end
local map = WorldMap.shared()
local direct = Sim.new(map, { seed = 3, tribes = 80, max_humans = 1 })
local job = Coop.job(function()
	local s = Sim.new(map, { seed = 3, tribes = 80, max_humans = 1 })
	local gs = GameState.new(map)
	gs:load_snapshot(s:snapshot())
	return { s, gs }
end)
local worst = 0
while not job.done do
	local t0 = os.clock()
	job:step(0.004)
	worst = math.max(worst, os.clock() - t0)
end
expect(job.ok, "job finished ok " .. tostring(job.err))
local s, gs = job.result[1], job.result[2]
expect(job.slices > 5, ("sliced into %d steps, worst slice %.1f ms"):format(job.slices, worst * 1000))
expect(
	buffer.tostring(s.owner) == buffer.tostring(direct.owner) and s.owner_total == direct.owner_total,
	"same match as a direct Sim.new"
)
expect(buffer.tostring(gs.owner) == buffer.tostring(s.owner), "snapshot loaded inside the job")
print(fails == 0 and "sim_coop ok" or ("sim_coop FAILED " .. fails))
if fails > 0 then
	error("failures")
end
