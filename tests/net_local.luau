-- Local (title / solo) Session path with the REAL Sim and GameState, frames simulated with dt = 1/60 and
-- the real clock (so the per-frame step budget is exercised):
--   title: build in Coop slices → state_ready; warm-up 22x → 1.35x at tick 900; budget caps ticks/frame;
--          a conquered world restarts itself (fresh state_ready, still MODE_TITLE)
--   solo:  building_started → mode_changed(SOLO) → state_ready → joined_owner; spawn intent claims land;
--          pause freezes ticks; queued intents only reach the Sim when a tick is due
-- The title and solo worlds play on a small map (onion, 512 x 512: fast to conquer).
-- Run: .bin/lune run tests/net_local.luau
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local U = require("./net_util")
local Session = require("../src/client/Session")
Session.TITLE_MAP_ID = "onion"
local MAP = "onion"
local CORE = {}
for _, n in { "Defs", "Ev", "Rng", "Rules", "WorldMap", "SimNav", "GameState", "Sim" } do
	CORE[n] = require("../src/shared/Core/" .. n)
end

local deferred = {}
local s = Session.new({
	now = os.clock,
	mobile = false,
	display_name = function()
		return "Tester"
	end,
	require_core = function(n)
		return CORE[n]
	end,
	defer = function(fn)
		table.insert(deferred, fn)
	end,
	warn = print,
	net = nil,
})
local log = {}
s.state_ready:Connect(function(st)
	table.insert(log, "ready:" .. s.mode .. ":" .. st.tick)
end)
s.mode_changed:Connect(function(m)
	table.insert(log, "mode:" .. m)
end)
s.joined_owner:Connect(function(id)
	table.insert(log, "joined:" .. id)
end)
s.building_started:Connect(function(m)
	table.insert(log, "building:" .. m)
end)

local frame_worst = 0
local function frame(dt)
	local t0 = os.clock()
	s:process(dt or 1 / 60)
	frame_worst = math.max(frame_worst, os.clock() - t0)
	local d = deferred
	deferred = {}
	for _, fn in d do
		fn()
	end
end

local check = U.check
print("title")
check(s:multiplayer_status() == "offline" and not s:multiplayer_available(), "no network → multiplayer offline")
s:start_title()
check(s:is_building(), "title build is asynchronous")
local frames = 0
while s:is_building() and frames < 5000 do
	frame()
	frames += 1
end
check(s.state ~= nil and s.mode == Session.MODE_TITLE, ("title world live after %d frames"):format(frames))
check(s.local_speed == Session.TITLE_WARMUP_SPEED, "warm-up time-lapse at 22x")
local lb = s.perf.last_build
print(
	("    build %.0f ms over %d frames, longest slice %.1f ms (Lune, no --!native)"):format(
		lb.ms,
		lb.frames,
		lb.slice_max_ms
	)
)
frame_worst = 0
local n = 0
local max_per_frame = 0
while s.state.tick < Session.TITLE_WARMUP_TICKS and n < 20000 do
	local before = s.state.tick
	frame()
	max_per_frame = math.max(max_per_frame, s.state.tick - before)
	n += 1
end
frame()
check(
	s.local_speed == Session.TITLE_SPEED,
	("warm-up ends at tick 900 → %.2fx (%d frames, ≤ %d ticks/frame)"):format(s.local_speed, n, max_per_frame)
)
check(max_per_frame <= Session.MAX_STEPS_PER_TASK, "never more than MAX_STEPS_PER_TASK ticks in a frame")
print(
	("    worst frame during warm-up %.1f ms (budget %.0f ms + one tick)"):format(
		frame_worst * 1000,
		s.step_budget_s * 1000
	)
)

-- render_tick follows tick smoothly
local st = s.state
check(
	st.render_tick <= st.tick + 1.25 + 1e-6 and st.render_tick >= st.tick - 5,
	("render_tick %.2f tracks tick %d"):format(st.render_tick, st.tick)
)

-- race to the end of the title world: it must restart itself
local first_state = s.state
s.local_speed = 400
local guard = 0
while s.state == first_state and guard < 200000 do
	frame()
	if s.state == first_state and first_state.phase ~= 2 then
		s.local_speed = 400
	end
	guard += 1
end
check(first_state.phase == 2, ("title world ended (tick %d, winner %d)"):format(first_state.tick, first_state.winner))
while s:is_building() do
	frame()
end
check(
	s.state ~= first_state and s.mode == Session.MODE_TITLE and s.local_speed == Session.TITLE_WARMUP_SPEED,
	"a fresh title world started by itself (warm-up again)"
)

print("solo")
table.clear(log)
s:start_solo(2, MAP)
while s:is_building() do
	frame()
end
check(
	table.concat(log, ",") == ("building:1,mode:1,ready:1:0,joined:%d"):format(s.state.local_owner),
	"signals: " .. table.concat(log, ",")
)
check(s.difficulty == 2 and s.local_speed == 1.0, "difficulty 2 at 1x")
local me = s.state.local_owner
local map = s.state.map
check(map.id == MAP and s.map_id == MAP, "solo on the chosen map")
local tile = -1
for k = 0, map.land_count - 1 do
	local t = map:land_tile(k)
	if map:is_contestable(t) and s.state:tile_owner(t) == 0 and not map:is_coastal(t) then
		tile = t
		break
	end
end
s:send_intent({ type = "spawn", tile = tile })
for _ = 1, 30 do
	frame()
end
check(s.state:get_owner(me).tiles > 0, ("spawn claimed %d tiles"):format(s.state:get_owner(me).tiles))
s:set_paused(true)
local t0 = s.state.tick
for _ = 1, 120 do
	frame()
end
check(s.state.tick == t0, "paused solo does not advance")
s:set_paused(false)
for _ = 1, 30 do
	frame()
end
check(s.state.tick > t0, "unpaused solo advances again")
s:join_multiplayer()
check(s.mode == Session.MODE_SOLO, "join_multiplayer without a server keeps the match (notice only)")
s:leave_match()
while s:is_building() do
	frame()
end
check(s.mode == Session.MODE_TITLE and s.state.local_owner == 0, "leave_match → title world")

print("handler errors")
do
	-- Core/Signal isolates handler errors (reported, then the next handler runs); Session:_emit
	-- additionally guards its own flow. A view bug in state_ready must not stop the match.
	local bad = s.state_ready:Connect(function()
		error("view bug (expected in this test)")
	end)
	local after = false
	local ac = s.state_ready:Connect(function()
		after = true
	end)
	local joined = 0
	local jc = s.joined_owner:Connect(function(id)
		joined = id
	end)
	s:start_solo(1, MAP)
	while s:is_building() do
		frame()
	end
	check(
		joined ~= 0 and s.mode == Session.MODE_SOLO,
		"a failing state_ready handler does not stop joined_owner / the match"
	)
	check(after, "later state_ready handlers still run")
	bad:Disconnect()
	ac:Disconnect()
	jc:Disconnect()
end

if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("net_local ok")
