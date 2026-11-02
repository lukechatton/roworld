--!strict
-- How this server keeps up (2026-11-01). The Creator Dashboard's server frame rate P10 had fallen at
-- night (21:00-08:00 UTC) from ~56 fps to 1-4 fps since mid-October while the median stayed at 60,
-- and nothing of ours said which servers those were. Every live server now sends the lobby service a
-- summary of each window (ServerMain.STATS_EVERY_S): its frame rate and slow frames, the match's Sim
-- step times, and what it was running (POST /v1/perf: services/lobbies/src/perf.ts).
--
--   ServerPerf.new() -> perf
--   perf:frame(dt)                   every Heartbeat
--   perf:take(st, ctx) -> report     the window's report (and a fresh window); st = MatchServer
--                                    take_stats(), ctx = what the server runs (see `report`)
local ServerPerf = {}
ServerPerf.__index = ServerPerf

--- A frame this long or longer is slow (under 10 fps).
ServerPerf.SLOW_FRAME_S = 0.1

function ServerPerf.new()
	local self = setmetatable({}, ServerPerf)
	self.frames = 0
	self.time = 0.0
	self.slow = 0
	self.slow_time = 0.0
	self.worst = 0.0
	return self
end

function ServerPerf.frame(self: any, dt: number)
	self.frames += 1
	self.time += dt
	if dt >= ServerPerf.SLOW_FRAME_S then
		self.slow += 1
		self.slow_time += dt
	end
	if dt > self.worst then
		self.worst = dt
	end
end

local function r1(x: number): number
	return math.floor(x * 10 + 0.5) / 10
end

--- The window's report: every field a number or a short string (the service checks them).
---   ctx = { role = "hub" | "match", stage = string, humans = number, players = number,
---           map = string?, mode = string?, max = number?, minute = number?, nations = number?,
---           mem_mb = number, age_min = number, version = number }
function ServerPerf.take(self: any, st: { [string]: number }, ctx: { [string]: any }): { [string]: any }
	local t = math.max(self.time, 1e-6)
	local report: { [string]: any } = {
		fps = r1(self.frames / t),
		slow_frames = self.slow,
		-- the share of the window spent in slow frames: 1 = the server never kept up
		slow_share = math.floor(self.slow_time / t * 100 + 0.5) / 100,
		worst_ms = math.floor(self.worst * 1000 + 0.5),
		window_s = math.floor(t + 0.5),
		steps = st.steps or 0,
		step_ms_avg = r1(st.step_ms_avg or 0),
		step_ms_p99 = r1(st.step_ms_p99 or 0),
		step_ms_max = r1(st.step_ms_max or 0),
		encode_ms_avg = r1(st.encode_ms_avg or 0),
		catchup_frames = st.catchup_frames or 0,
		budget_stops = st.budget_stops or 0,
	}
	for k, v in ctx do
		if type(v) == "number" then
			report[k] = r1(v)
		elseif type(v) == "string" then
			report[k] = string.sub(v, 1, 32)
		end
	end
	self.frames, self.time, self.slow, self.slow_time, self.worst = 0, 0.0, 0, 0.0, 0.0
	return report
end

return ServerPerf
