-- code-fixer: multiplayer lifecycle fixes (review_code.md #5, #6, #8, #11, #13), headless: the real
-- MatchServer and real client Sessions (real Core GameState) over an in-process ordered transport.
-- The Sim is tests/net_fakesim.luau unless AF_REAL_SIM=1.
-- Run: .bin/lune run tests/fix_server.luau
require("./prelude")
local process = require("@lune/process")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local Session = require("../src/client/Session")
local FakeSim = require("./net_fakesim")
U.use_zstd(Protocol)

local CORE = {
	GameState = require("../src/shared/Core/GameState"),
	WorldMap = require("../src/shared/Core/WorldMap"),
}
local RealSim = if process.env.AF_REAL_SIM == "1" then require("../src/shared/Core/Sim") else nil
if RealSim then
	CORE.WorldMap.shared() -- load the map outside the server's Coop job (Lune's require may yield)
end
local OP = Protocol.OP
local check = U.check

local function make_sim(cfg)
	if RealSim then
		return RealSim.new(CORE.WorldMap.shared(), cfg)
	end
	cfg.over_at = 600
	return FakeSim.new(cfg)
end

-- One world: a server, its clock, and clients. `drop(peer, op)` may swallow client → server messages.
local function world()
	local w = { clock_ms = 0, hello = {}, logs = {}, clients = {}, drop = nil :: any, sent_ops = {} }
	w.server = MatchServer.new({
		make_sim = make_sim,
		send = function(peer, op, ...)
			table.insert(peer.inbox, table.pack(op, ...))
		end,
		peers = function()
			return w.hello
		end,
		now_ms = function()
			return w.clock_ms
		end,
		log = function(text)
			table.insert(w.logs, text)
		end,
		seed = function()
			return 42
		end,
	})
	w.server.lobby_countdown_sec = 2.0
	function w.client(name: string)
		local peer = { inbox = {}, name = name, handler = nil, notices = {}, joined = 0, snapshots = 0, sent = {} }
		local env = {
			now = function()
				return w.clock_ms / 1000
			end,
			mobile = false,
			warn = function(_text) end,
			display_name = function()
				return name
			end,
			require_core = function(n)
				if n == "Sim" then
					return {
						new = function(_map, cfg)
							return make_sim(cfg)
						end,
					}
				end
				return CORE[n]
			end,
			net = {
				connected = true,
				send = function(op, ...)
					table.insert(peer.sent, op)
					if w.drop and w.drop(peer, op) then
						return
					end
					if op == OP.HELLO then
						if not table.find(w.hello, peer) then
							table.insert(w.hello, peer)
						end
						w.server:_send(peer, OP.LOBBY, w.server:lobby_info(peer))
					else
						w.server:on_client(peer, { uid = "u_" .. name, name = name }, op, ...)
					end
				end,
				listen = function(fn)
					peer.handler = fn
				end,
			},
		}
		local s = Session.new(env)
		s.threaded = false
		s.notice:Connect(function(text)
			table.insert(peer.notices, text)
		end)
		s.joined_owner:Connect(function(id)
			peer.joined = id
		end)
		peer.session = s
		table.insert(w.clients, peer)
		s:start_title()
		env.net.send(OP.HELLO)
		return peer
	end
	function w.pump(seconds: number)
		local steps = math.max(1, math.round(seconds / 0.1))
		for _ = 1, steps do
			w.clock_ms += 100
			w.server:process(0.1)
			for _, c in w.clients do
				local inbox = c.inbox
				c.inbox = {}
				for _, m in inbox do
					if m[1] == OP.SNAPSHOT then
						c.snapshots += 1
					end
					if m[1] == OP.DELTA and c.corrupt_next then
						-- the wire mangled this tick's delta: the client sees garbage instead
						c.corrupt_next = false
						m = table.pack(OP.DELTA, buffer.fromstring("\1\255\255\255"))
					end
					if c.handler then
						c.handler(table.unpack(m, 1, m.n))
					end
				end
				c.session:process(0.1)
			end
		end
	end
	return w
end

--- Runs one scenario; a crash counts as a failure and the next scenario still runs.
local function scenario(title: string, fn: () -> ())
	print(title)
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		check(false, "scenario crashed: " .. tostring(err))
	end
end

local function grid_equal(a, b)
	return buffer.tostring(a) == buffer.tostring(b)
end

local function count(list, v)
	local n = 0
	for _, x in list do
		if x == v then
			n += 1
		end
	end
	return n
end

scenario("#5 queue → leave queue → queue again inside the JOIN cooldown", function()
	local w = world()
	local a, b = w.client("Alice"), w.client("Bob")
	w.pump(0.3)
	b.session:join_multiplayer()
	w.pump(0.2)
	a.session:join_multiplayer()
	w.pump(0.5)
	a.session:leave_match()
	w.pump(0.5)
	a.session:join_multiplayer() -- 1.0 s after the first JOIN: inside the 2 s cooldown
	w.pump(0.3)
	check(w.server:participant(a) == nil, "the re-queue is held (cooldown), not admitted yet")
	w.pump(1.5)
	check(
		w.server:participant(a) ~= nil and a.session.lobby.in_match == true,
		"…and admitted once the cooldown passed"
	)
	w.pump(4)
	check(a.joined ~= 0 and a.session._mp_waiting == false, ("Alice plays in the match (owner %d)"):format(a.joined))
	-- leave mid-match and rejoin within 1 s
	local c = w.client("Cara")
	w.pump(0.2)
	c.session:join_multiplayer()
	w.pump(3)
	local owner = c.joined
	-- rejoin less than 2 s after the previous JOIN (inside the cooldown)
	c.session:leave_match()
	w.pump(0.5)
	c.session:join_multiplayer()
	w.pump(0.6)
	c.session:leave_match()
	w.pump(0.3)
	c.joined = 0
	c.session:join_multiplayer()
	w.pump(3)
	check(
		c.joined == owner and c.session.state ~= nil and c.session.mode == Session.MODE_MULTI,
		"leave + rejoin inside the cooldown mid-match lands back in the match"
	)
	-- leaving again while the re-queue is pending cancels it
	local d = w.client("Dan")
	w.pump(0.2)
	d.session:join_multiplayer()
	w.pump(0.3)
	d.session:leave_match()
	w.pump(0.2)
	d.session:join_multiplayer()
	w.pump(0.2)
	d.session:leave_match()
	w.pump(3)
	check(
		w.server:participant(d) == nil and d.session.mode == Session.MODE_TITLE,
		"a leave cancels the pending re-queue"
	)
end)

scenario("#5 client side: a lost JOIN is re-sent", function()
	local w = world()
	local a = w.client("Alice")
	w.pump(0.3)
	local dropped = 0
	w.drop = function(_peer, op)
		if op == OP.JOIN and dropped == 0 then
			dropped += 1
			return true
		end
		return false
	end
	a.session:join_multiplayer()
	w.pump(2.0)
	check(w.server:participant(a) == nil and a.session._mp_waiting, "first JOIN lost: still waiting")
	w.pump(1.5)
	check(w.server:participant(a) ~= nil, ("JOIN re-sent after %.0f s → queued"):format(Session.JOIN_RETRY_S or 0))
	check(count(a.sent, OP.JOIN) == 2, ("exactly one retry (%d JOINs)"):format(count(a.sent, OP.JOIN)))
	w.pump(4)
	check(a.joined ~= 0, "and plays")
	check(count(a.sent, OP.JOIN) == 2, "no further JOINs once in")
end)

scenario("#8 match start: every participant's snapshot has its own nation", function()
	local w = world()
	local peers = {}
	for k = 1, 4 do
		local c = w.client("P" .. k)
		c.session.joined_owner:Connect(function(id)
			c.own_row = c.session.state.owners[id] ~= nil
			c.local_info = c.session.state:local_info() ~= nil
		end)
		table.insert(peers, c)
	end
	w.pump(0.2)
	for _, c in peers do
		c.session:join_multiplayer()
	end
	w.pump(3)
	for _, c in peers do
		check(
			c.joined ~= 0 and c.own_row == true and c.local_info == true,
			("%s: own nation present at joined_owner"):format(c.name)
		)
	end
	check(w.server.stats.snapshots_sent >= 4, "one snapshot per participant")
end)

-- A running match with two players in PLAYING, for the step-guard / resync scenarios.
local function playing_world()
	local w = world()
	local a, b = w.client("Alice"), w.client("Bob")
	w.pump(0.2)
	a.session:join_multiplayer()
	b.session:join_multiplayer()
	w.pump(3)
	w.pump(21) -- spawn phase (200 ticks)
	return w, a, b
end

scenario("#6 a transient Sim error: logged, everyone resynced, the match goes on", function()
	local w, a, b = playing_world()
	local sim = w.server:sim()
	check(w.server:stage() == "playing", "match is playing")
	local snaps_a, snaps_b = a.snapshots, b.snapshots
	local real_step = sim.step
	local fail_once = true
	sim.step = function(self)
		if fail_once then
			fail_once = false
			error("simulated Sim bug")
		end
		return real_step(self)
	end
	w.pump(1.0)
	check(w.server:stage() == "playing", "still playing after one failed tick")
	check(a.snapshots == snaps_a + 1 and b.snapshots == snaps_b + 1, "every participant got a resync snapshot")
	check(
		grid_equal(a.session.state.owner, sim.owner) and grid_equal(b.session.state.owner, sim.owner),
		"mirrors equal the server"
	)
	local logged = 0
	for _, l in w.logs do
		if string.find(l, "match step failed", 1, true) then
			logged += 1
		end
	end
	check(logged == 1, "the error is logged once")
end)

scenario("#6 an encoder error: the lost tick is healed by a resync", function()
	local w, a = playing_world()
	local sim = w.server:sim()
	local real_encode = Protocol.encode_delta
	local fail_once = true
	Protocol.encode_delta = function(...)
		if fail_once then
			fail_once = false
			error("simulated encoder bug")
		end
		return real_encode(...)
	end
	w.pump(1.0)
	Protocol.encode_delta = real_encode
	check(w.server:stage() == "playing", "still playing")
	check(grid_equal(a.session.state.owner, sim.owner), "the tick whose delta was lost is in the mirror (resync)")
end)

scenario("#6 a persistent Sim error ends the match with a notice (no silent freeze)", function()
	local w, a, b = playing_world()
	local sim = w.server:sim()
	sim.step = function()
		error("corrupted state")
	end
	pcall(w.pump, 1.0)
	check(
		w.server:stage() == "idle" and w.server:sim() == nil and w.server:participant_count() == 0,
		"match aborted, server idle"
	)
	for _, c in { a, b } do
		check(
			c.session.mode == Session.MODE_TITLE
				and table.find(c.notices, (MatchServer.STEP_FAILED_NOTICE or "?")) ~= nil,
			c.name .. " is back on the title with the notice"
		)
	end
	local logged = 0
	for _, l in w.logs do
		if string.find(l, "match step failed", 1, true) then
			logged += 1
		end
	end
	check(logged == 1, ("one log line for a repeated error (%d)"):format(logged))
	-- the server recovers: a new queue starts a new match
	a.session:join_multiplayer()
	w.pump(3.0)
	check(w.server:stage() == "spawn" and a.joined ~= 0 and a.session.state ~= nil, "a new match starts afterwards")
end)

scenario("#11 a delta the client can't decode → RESYNC → fresh snapshot", function()
	local w, a, b = playing_world()
	local sim = w.server:sim()
	local snaps = a.snapshots
	-- one tick's delta arrives corrupted (that tick's changes never reach the mirror)
	a.corrupt_next = true
	w.pump(0.1)
	check(a.session._resync_pending == true and count(a.sent, OP.RESYNC) == 1, "client asked for a resync")
	w.pump(0.3)
	check(a.snapshots == snaps + 1 and a.session._resync_pending == false, "server answered with a snapshot")
	check(grid_equal(a.session.state.owner, sim.owner), "mirror equals the server again")
	check(a.session.mode == Session.MODE_MULTI and a.joined ~= 0, "still in the match")
	-- a second bad delta inside the gap: no second request (client) …
	a.handler(OP.DELTA, buffer.fromstring("\1\255\255\255"))
	check(count(a.sent, OP.RESYNC) == 1, "client rate-limits RESYNC")
	-- … and the server rate-limits too
	local before = b.snapshots
	w.server:on_client(b, { uid = "u_Bob", name = "Bob" }, OP.RESYNC)
	w.server:on_client(b, { uid = "u_Bob", name = "Bob" }, OP.RESYNC)
	w.pump(0.2)
	check(b.snapshots == before + 1, "server answers one RESYNC per 10 s")
	-- apply failure also triggers it: make apply_delta throw once
	w.pump(11)
	local st = a.session.state
	local real_apply = st.apply_delta
	st.apply_delta = function(self, d)
		st.apply_delta = real_apply
		real_apply(self, d)
		error("simulated mirror bug")
	end
	w.pump(0.4)
	check(count(a.sent, OP.RESYNC) == 2, "a failing apply_delta asks for a resync too")
	w.pump(0.3)
	check(grid_equal(a.session.state.owner, sim.owner), "mirror healed")
	-- non-participants and title players can't pull snapshots
	local z = w.client("Zed")
	w.pump(0.2)
	w.server:on_client(z, { uid = "u_Zed", name = "Zed" }, OP.RESYNC)
	w.pump(0.2)
	check(z.snapshots == 0, "RESYNC from a non-participant is ignored")
end)

scenario("#13 a watcher who is at the controls is not idle-dropped at the rematch", function()
	local w, a, b = playing_world()
	-- both have been 'idle' (no intents) for longer than IDLE_DROP; only Alice moves the camera
	w.server:participant(a).active_msec = w.clock_ms - MatchServer.IDLE_DROP_MSEC - 1000
	w.server:participant(b).active_msec = w.clock_ms - MatchServer.IDLE_DROP_MSEC - 1000
	a.session:note_activity()
	check(count(a.sent, OP.ACTIVE) == 1, "input reported as ACTIVE")
	a.session:note_activity()
	check(count(a.sent, OP.ACTIVE) == 1, "ACTIVE throttled")
	local sim = w.server:sim()
	sim.over_at = sim.tick + 5
	sim.phase = 1
	w.pump(1.0)
	check(w.server:stage() == "over", "match over")
	w.pump(MatchServer.RESULTS_SEC + 0.3)
	check(w.server:stage() == "lobby", "rematch lobby")
	check(w.server:participant(a) ~= nil, "Alice (watching, sent ACTIVE) stays in for the rematch")
	check(
		w.server:participant(b) == nil
			and table.find(b.notices, "You were away, so you weren't entered in the next match.") ~= nil,
		"Bob (really away) is dropped as before"
	)
	-- title players don't send ACTIVE
	local t = w.client("Tim")
	t.session:note_activity()
	check(count(t.sent, OP.ACTIVE) == 0, "no ACTIVE outside multiplayer")
end)

if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("fix_server ok")
