-- sim-core dev harness (server): times Sim.step (+ GameState:apply_delta) in Roblox.
-- Enable in your own place: workspace:SetAttribute("AF_DEV", "SimBench"), then Play.
-- Optional attributes: SimBenchMinutes (15), SimBenchSeed (1), SimBenchHuman (0), SimBenchTribes (80),
-- SimBenchSide ("server" default | "client": the client harness src/client/Dev/SimBench.luau runs it).
-- Prints a line per minute plus a final summary; the summary is also stored in
-- workspace:GetAttribute("SimBenchResult") so tools/studio.py can read it.
local RS = game:GetService("ReplicatedStorage")
local Core = RS:WaitForChild("Airfront"):WaitForChild("Core")

local Defs = require(Core:WaitForChild("Defs"))
local WorldMap = require(Core:WaitForChild("WorldMap"))
local GameState = require(Core:WaitForChild("GameState"))
local Sim = require(Core:WaitForChild("Sim"))

local minutes = workspace:GetAttribute("SimBenchMinutes") or 15
local seed = workspace:GetAttribute("SimBenchSeed") or 1
local human = (workspace:GetAttribute("SimBenchHuman") or 0) ~= 0
local tribes = workspace:GetAttribute("SimBenchTribes") or 80

local function stats(times: { number }): (number, number, number, number)
	if #times == 0 then
		return 0, 0, 0, 0
	end
	local s = table.clone(times)
	table.sort(s)
	local sum = 0
	for _, v in s do
		sum += v
	end
	local n = #s
	return sum / n, s[math.min(n, math.floor(n * 0.95) + 1)], s[math.min(n, math.floor(n * 0.99) + 1)], s[n]
end

local SIDE = "server"
if (workspace:GetAttribute("SimBenchSide") or "server") ~= SIDE then
	print("[SimBench] idle on the " .. SIDE)
	return nil
end

task.spawn(function()
	workspace:SetAttribute("SimBenchResult", "running")
	local t0 = os.clock()
	local map = WorldMap.shared()
	local t1 = os.clock()
	local sim = Sim.new(map, { seed = seed, difficulty = 1, tribes = tribes, max_humans = if human then 1 else 0 })
	local t2 = os.clock()
	local gs = GameState.new(map)
	gs:load_snapshot(sim:snapshot())
	local t3 = os.clock()
	print(
		string.format(
			"[SimBench] map %.0f ms, Sim.new %.0f ms (incl. nav %s), snapshot+load %.0f ms, owners %d",
			(t1 - t0) * 1000,
			(t2 - t1) * 1000,
			tostring(sim.nav.reg_count),
			(t3 - t2) * 1000,
			sim:owner_count()
		)
	)
	if human then
		local hid = sim:add_human("bench", "Bench Commander")
		for _, t in map.land_tiles do
			if buffer.readi32(sim.owner, t * 4) == 0 and sim:_area_free(t, 8) then
				sim:human_start(hid, t)
				break
			end
		end
		for _ = 1, 51 do
			gs:apply_delta(sim:step())
		end
	end
	local all, late, apply_all, minute_t = {}, {}, {}, {}
	local total = minutes * 600
	local budget_start = os.clock()
	for i = 1, total do
		local s0 = os.clock()
		local d = sim:step()
		local s1 = os.clock()
		gs:apply_delta(d)
		local s2 = os.clock()
		local ms = (s1 - s0) * 1000
		table.insert(all, ms)
		table.insert(minute_t, ms)
		table.insert(apply_all, (s2 - s1) * 1000)
		if i > total - 3000 then
			table.insert(late, ms)
		end
		if i % 600 == 0 then
			local avg, p95, p99, mx = stats(minute_t)
			local claimed, alive = 0, 0
			for id = 1, sim.owner_total do
				if sim.o_alive[id] == 1 then
					claimed += sim.o_tiles[id]
					alive += 1
				end
			end
			print(
				string.format(
					"[SimBench] minute %d: step avg %.2f p95 %.2f p99 %.2f max %.2f ms | alive %d claimed %.1f%% structs %d units %d",
					i // 600,
					avg,
					p95,
					p99,
					mx,
					alive,
					100 * claimed / map.contestable_count,
					sim:struct_total(),
					sim:unit_total()
				)
			)
			table.clear(minute_t)
		end
		if sim.phase == Defs.PHASE_OVER then
			break
		end
		-- yield regularly (script timeout) — ~20 ms of work per frame
		if os.clock() - budget_start > 0.02 then
			task.wait()
			budget_start = os.clock()
		end
	end
	local avg, p95, p99, mx = stats(all)
	local lavg, lp95, lp99, lmx = stats(late)
	local aavg, ap95, ap99, amx = stats(apply_all)
	local res = string.format(
		"ticks %d | step avg %.2f p95 %.2f p99 %.2f max %.2f ms | late (last 5 min) avg %.2f p95 %.2f p99 %.2f max %.2f ms | apply_delta avg %.3f p99 %.2f max %.2f ms",
		#all,
		avg,
		p95,
		p99,
		mx,
		lavg,
		lp95,
		lp99,
		lmx,
		aavg,
		ap99,
		amx
	)
	print("[SimBench] DONE " .. res)
	local _ = ap95
	workspace:SetAttribute("SimBenchResult", res)
	pcall(function()
		workspace:SetAttribute("SimBenchResult_" .. SIDE, res)
	end)
end)

return nil
