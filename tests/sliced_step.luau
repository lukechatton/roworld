--!nocheck
-- A local match's tick spread over frames (Session._local_process: the Sim's step as a Coop job,
-- docs/performance.md "Solo on phones"): stepped in slices of a fraction of a millisecond, a solo
-- World match is the same match, tile for tile, as stepped whole; a slice stays near its budget
-- (the Sim yields between attacks, AI turns, units and landings); and a Session finishes a tick in
-- flight before anything changes the Sim.
-- Run: .bin/lune run tests/sliced_step.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local Coop = require("../src/shared/Net/Coop")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local function solo_world(seed: number)
	local map = WorldMap.get("world")
	local sim = Sim.new(map, { seed = seed, difficulty = 0, max_humans = 1, time_limit_s = 0 })
	local h = sim:add_human("local", "Probe")
	local spawn = map:point_tile(math.floor(map.W * 0.53), math.floor(map.H * 0.55))
	for d = 0, 400 do
		if map:is_contestable(spawn + d) then
			spawn = spawn + d
			break
		end
	end
	sim:submit(h, { type = "spawn", tile = spawn })
	return sim, h
end

-- the same match, whole and in slices (spawn phase, then the first 30 s: 400 tribes expanding)
local TICKS = 400
local whole = solo_world(7)
local sliced = solo_world(7)
local slices, multi, budget_s = 0, 0, 0.0005
for i = 1, TICKS do
	local dw = whole:step()
	local job = Coop.job(sliced.step, sliced)
	while not job.done do
		job:step(budget_s)
	end
	assert(job.ok, job.err)
	slices += job.slices
	if job.slices > 1 then
		multi += 1
	end
	local ds = job.result
	if i % 50 == 0 or i == TICKS then
		-- deltas carry the same tiles
		local nw, ns = 0, 0
		for _ in dw.tiles do
			nw += 1
		end
		for _ in ds.tiles do
			ns += 1
		end
		if nw ~= ns then
			expect(false, ("tick %d: %d tiles changed whole, %d sliced"):format(i, nw, ns))
		end
	end
end
expect(whole.phase == Defs.PHASE_PLAYING, "the match is playing")
expect(buffer.tostring(whole.owner) == buffer.tostring(sliced.owner), ("after %d ticks every tile has the same owner"):format(TICKS))
local same_owners = true
for id = 1, whole.owner_total do
	if whole.o_alive[id] ~= sliced.o_alive[id] or whole.o_troops[id] ~= sliced.o_troops[id] or whole.o_tiles[id] ~= sliced.o_tiles[id] then
		same_owners = false
	end
end
expect(same_owners, "every owner's troops, tiles and life are the same")
expect(whole.rng:randi() == sliced.rng:randi(), "the random stream is in the same place")
expect(multi > 50, ("%d of %d ticks took more than one slice (%d slices)"):format(multi, TICKS, slices))

-- how long a slice runs past its budget: a fresh match on its own (a slice's time includes the
-- garbage collector's steps, so the share of long ones is what is checked, not the longest)
do
	local sim = solo_world(11)
	local times = {}
	local tick_worst = 0.0
	for _ = 1, TICKS do
		local t0 = os.clock()
		local job = Coop.job(sim.step, sim)
		while not job.done do
			local s0 = os.clock()
			job:step(budget_s)
			table.insert(times, (os.clock() - s0) * 1000)
		end
		tick_worst = math.max(tick_worst, (os.clock() - t0) * 1000)
	end
	table.sort(times)
	local p99 = times[math.ceil(#times * 0.99)]
	print(("    %d slices at a %.1f ms budget: median %.2f ms, 99th percentile %.2f, longest %.2f; longest tick %.1f ms in all (Lune, a Mac)"):format(#times, budget_s * 1000, times[math.ceil(#times / 2)], p99, times[#times], tick_worst))
	expect(p99 < 1.5, "a slice stays near its budget (the Sim yields between attacks, AI turns, units and landings)")
end

-- the Session: a tick in flight is finished before anything changes the Sim
do
	local Session = require("../src/client/Session")
	local CORE = {}
	for _, n in { "Defs", "Ev", "Rng", "Rules", "WorldMap", "SimNav", "GameState", "Sim" } do
		CORE[n] = require("../src/shared/Core/" .. n)
	end
	Session.TITLE_MAP_ID = "onion"
	local s = Session.new({
		now = os.clock,
		mobile = true,
		display_name = function()
			return "Tester"
		end,
		require_core = function(n)
			return CORE[n]
		end,
		defer = function(fn)
			fn()
		end,
		warn = print,
		net = nil,
	})
	s:start_solo(0, "world")
	local guard = 0
	while s:is_building() and guard < 20000 do
		s:process(1 / 60)
		guard += 1
	end
	expect(s.mode == Session.MODE_SOLO and s.state ~= nil, "a solo World match on a phone's budgets")
	-- spawn, then run the first seconds with a tiny frame budget so ticks span frames
	local map = s.state.map
	local tile = -1
	for k = 0, map.land_count - 1 do
		local t = map:land_tile(k)
		if map:is_contestable(t) and s.state:tile_owner(t) == 0 and not map:is_coastal(t) then
			tile = t
			break
		end
	end
	s:send_intent({ type = "spawn", tile = tile })
	s.step_budget_s = 0.0003
	s.step_budget_behind_s = 0.0003
	local spanned, frames = 0, 0
	local per_frame = {}
	while s.state.tick < 120 and frames < 20000 do
		local before_s = s.perf.step_s
		s:process(1 / 60)
		table.insert(per_frame, (s.perf.step_s - before_s) * 1000)
		frames += 1
		if s._step_job ~= nil then
			spanned += 1
		end
	end
	table.sort(per_frame)
	local p99 = per_frame[math.ceil(#per_frame * 0.99)]
	expect(spanned > 0, ("ticks span frames: %d of %d frames ended with a tick in flight"):format(spanned, frames))
	expect(p99 < 1.5, ("the Sim's time in a frame at a 0.3 ms budget: 99th percentile %.2f ms, longest %.2f"):format(p99, per_frame[#per_frame]))
	-- a tick in flight, then something changes the Sim: the tick finishes first
	local before = s.state.tick
	local guard2 = 0
	while s._step_job == nil and guard2 < 1000 do
		s:process(1 / 60)
		guard2 += 1
	end
	expect(s._step_job ~= nil, "a tick is in flight")
	local sim = s:local_sim()
	expect(s._step_job == nil and s.state.tick == sim.tick and s.state.tick >= before + 1, "local_sim() finishes the tick and applies it first")
	-- intents wait for the next tick
	s:send_intent({ type = "spawn", tile = tile })
	expect(#s._queued == 1, "an intent waits in the queue while no tick starts")
	-- leaving drops a tick in flight
	while s._step_job == nil do
		s:process(1 / 60)
	end
	s:leave_match()
	expect(s._step_job == nil, "leaving the match drops the tick in flight")
end

print(if fails == 0 then "sliced_step: all passed" else string.format("sliced_step: %d FAILED", fails))
if fails > 0 then
	error("sliced_step failed")
end
