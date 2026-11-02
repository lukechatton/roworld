--!nocheck
-- How a match server keeps up (2026-11-01: the dashboard's server frame rate P10 at 1-4 fps at
-- night). A server whose Sim steps take 100 ms or more never caught up: it stepped
-- MatchServer.MAX_CATCHUP_TICKS ticks in every frame. Now a frame stops stepping once it has spent
-- CATCHUP_BUDGET_S (one tick always runs), and ServerPerf sums up each window for the lobby service.
-- Run: .bin/lune run tests/server_perf.luau
require("./prelude")
local MatchServer = require("../src/server/MatchServer")
local ServerPerf = require("../src/server/ServerPerf")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

-- a playing match server whose steps cost `cost_s` each on a fake clock
local function playing(cost_s: number)
	local t = { now = 0.0, steps = 0 }
	local srv = MatchServer.new({
		make_sim = function()
			return {}
		end,
		send = function() end,
		peers = function()
			return {}
		end,
		now_ms = function()
			return 0
		end,
		seed = function()
			return 1
		end,
		clock = function()
			return t.now
		end,
	})
	srv._stage = "playing"
	srv._mp_sim = {}
	srv._server_step = function()
		t.now += cost_s
		t.steps += 1
	end
	return srv, t
end

do
	local srv, t = playing(0.008)
	srv:process(0.1)
	expect(t.steps == 1, "one tick a frame at 10 fps of game time")
	srv:process(0.35)
	expect(t.steps == 4, "a hitch of 0.35 s: three ticks at once, under the budget")
	srv:process(5.0)
	expect(t.steps == 4 + MatchServer.MAX_CATCHUP_TICKS, "a long hitch: at most MAX_CATCHUP_TICKS")
	local st = srv:take_stats()
	expect(st.catchup_frames == 2 and st.budget_stops == 0, "two catch-up frames, no budget stop")
end

do
	-- 150 ms a step: it used to run 6 a frame (0.9 s frames) and never catch up
	local srv, t = playing(0.15)
	local frames, longest = 0, 0.0
	for _ = 1, 20 do
		local before = t.now
		srv:process(math.max(t.now - before, 0.016) + 0.15)
		frames += 1
		longest = math.max(longest, t.now - before)
	end
	expect(longest < 0.2, ("a slow server's frame stays about one step long (%.2f s)"):format(longest))
	expect(t.steps == frames, "one tick a frame, every frame")
	local st = srv:take_stats()
	expect(st.budget_stops >= 15, ("frames left ticks for the next one (%d)"):format(st.budget_stops))
	expect(srv:take_stats().budget_stops == 0, "take_stats starts a fresh window")
end

do
	local perf = ServerPerf.new()
	for _ = 1, 50 do
		perf:frame(1 / 60)
	end
	perf:frame(0.5)
	perf:frame(0.25)
	local r = perf:take({ steps = 30, step_ms_avg = 12.345, step_ms_p99 = 80, budget_stops = 3 }, {
		role = "match",
		stage = "playing",
		humans = 48,
		map = "world",
		mem_mb = 612.37,
		bad = { 1 },
	})
	expect(r.slow_frames == 2 and r.worst_ms == 500, "two slow frames, the worst 500 ms")
	expect(math.abs(r.fps - 52 / (50 / 60 + 0.75)) < 0.1, ("frames over the window (%.1f fps)"):format(r.fps))
	expect(r.slow_share > 0.45 and r.slow_share < 0.48, "about half the window in slow frames")
	expect(r.step_ms_avg == 12.3 and r.budget_stops == 3 and r.catchup_frames == 0, "the match's numbers")
	expect(r.role == "match" and r.map == "world" and r.mem_mb == 612.4, "what it runs")
	expect(r.bad == nil, "only numbers and short strings go out")
	local again = perf:take({}, {})
	expect(again.slow_frames == 0 and again.steps == 0, "a fresh window")
end

if fails > 0 then
	error(fails .. " failure(s)")
end
print("server_perf: all ok")
