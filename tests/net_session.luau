-- Headless multiplayer lifecycle: the real MatchServer and real client Sessions (with the real Core
-- GameState) talking through an in-process transport that behaves like one ordered reliable
-- RemoteEvent per direction. The Sim is tests/net_fakesim.luau unless AF_REAL_SIM=1 and Core/Sim exists.
-- Run: .bin/lune run tests/net_session.luau
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
local REAL_SIM = process.env.AF_REAL_SIM == "1"
local RealSim = nil
if REAL_SIM then
	RealSim = require("../src/shared/Core/Sim")
	-- build the default map now: the server builds its Sim inside a Coop job, where Lune's
	-- require (of the map data module) must not yield
	CORE.WorldMap.shared()
end

local OVER_AT = 600 -- fake match ends at tick 600 (spawn phase is 200 ticks)
local clock_ms = 0
local hello: { any } = {}
local logs = {}

local function make_sim(cfg)
	if RealSim then
		return RealSim.new(CORE.WorldMap.shared(), cfg)
	end
	cfg.over_at = OVER_AT
	return FakeSim.new(cfg)
end

local server = MatchServer.new({
	make_sim = make_sim,
	send = function(peer, op, ...)
		table.insert(peer.inbox, table.pack(op, ...))
		peer.rx_bytes += 0
	end,
	peers = function()
		return hello
	end,
	now_ms = function()
		return clock_ms
	end,
	log = function(text)
		table.insert(logs, text)
	end,
	seed = function()
		return 42
	end,
})
server.lobby_countdown_sec = 2.0

local clients = {}
local function make_client(name, uid)
	local peer = { inbox = {}, name = name, uid = uid, handler = nil, rx_bytes = 0, messages = {}, notices = {} }
	local env = {
		now = function()
			return clock_ms / 1000
		end,
		mobile = false,
		warn = function(text)
			print("    [warn " .. name .. "] " .. text)
		end,
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
				if op == Protocol.OP.HELLO then
					if not table.find(hello, peer) then
						table.insert(hello, peer)
					end
					server:_send(peer, Protocol.OP.LOBBY, server:lobby_info(peer))
				else
					server:on_client(peer, { uid = uid, name = name }, op, ...)
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
	peer.session = s
	peer.joined = 0
	s.joined_owner:Connect(function(id)
		peer.joined = id
	end)
	s.state_ready:Connect(function(st)
		st.message:Connect(function(_to, _cat, text)
			table.insert(peer.messages, text)
		end)
	end)
	table.insert(clients, peer)
	return peer
end

local function pump(seconds)
	local steps = math.max(1, math.round(seconds / 0.1))
	for _ = 1, steps do
		clock_ms += 100
		server:process(0.1)
		for _, c in clients do
			local inbox = c.inbox
			c.inbox = {}
			for _, m in inbox do
				for i = 2, m.n do
					if type(m[i]) == "buffer" then
						c.rx_bytes += buffer.len(m[i])
					end
				end
				if c.handler then
					c.handler(table.unpack(m, 1, m.n))
				end
			end
			c.session:process(0.1)
		end
	end
end

local function grid_equal(a, b)
	return buffer.tostring(a) == buffer.tostring(b)
end

local check = U.check
print("hello / lobby")
local A = make_client("Alice", "u1")
local B = make_client("Bob", "u2")
check(not A.session:multiplayer_available(), "multiplayer unavailable before the server answers")
A.session.env.net.send(Protocol.OP.HELLO)
B.session.env.net.send(Protocol.OP.HELLO)
pump(0.1)
check(
	A.session:multiplayer_available() and A.session:multiplayer_status() == "connected",
	"HELLO → lobby info → multiplayer available"
)
check(A.session.lobby.stage == "idle", "server idle before anyone queues")

print("lobby countdown")
A.session:join_multiplayer()
check(A.session.mode == Session.MODE_MULTI, "join switches to MODE_MULTI (queued)")
pump(0.1)
check(server:stage() == "lobby", "first join starts the lobby countdown")
B.session:join_multiplayer()
pump(0.5)
check(#A.session.lobby.players == 2 and A.session.lobby.in_match, "lobby lists both commanders")
check(
	A.session.lobby.countdown_s > 0 and A.session.lobby.countdown_s < 2,
	("countdown running (%.1f s)"):format(A.session.lobby.countdown_s)
)

print("spawn phase")
pump(2.0)
check(server:stage() == "spawn", "countdown elapsed → spawn stage")
check(
	A.joined ~= 0 and B.joined ~= 0 and A.joined ~= B.joined,
	("both got owner ids (%d, %d)"):format(A.joined, B.joined)
)
check(
	A.session.state ~= nil and A.session.state.local_owner == A.joined,
	"snapshot loaded into GameState with local_owner"
)
local sim = server:sim()
local spawn_a = 250 * 512 + 300 -- the fake match plays on onion (512 x 512)
local spawn_b = 260 * 512 + 400
A.session:send_intent({ type = "spawn", tile = spawn_a })
B.session:send_intent({ type = "spawn", tile = spawn_b })
pump(0.3)
check(
	A.session.state:tile_owner(spawn_a) == A.joined and B.session.state:tile_owner(spawn_a) == A.joined,
	"spawn intent → server Sim → delta on both clients"
)
check(table.find(A.messages, "You have landed. Expand into free land!") ~= nil, "private spawn message reached Alice")
local b_saw_alice = false
for _, m in B.messages do
	if m == "You have landed. Expand into free land!" then
		b_saw_alice = true -- (Bob gets his own copy; count below)
	end
end
check(b_saw_alice, "Bob got his own landing message")

print("playing")
pump(23.5)
check(server:stage() == "playing", "spawn phase ended → playing")
check(A.session.state.phase == 1, "clients mirror PHASE_PLAYING")
check(grid_equal(A.session.state.owner, sim.owner), "Alice's owner grid == server Sim grid")
check(grid_equal(B.session.state.owner, sim.owner), "Bob's owner grid == server Sim grid")
print("    A messages:", table.concat(A.messages, " | "))
local a_priv, b_priv, a_leak = 0, 0, 0
for _, m in A.messages do
	if m == "Private note for Alice" then
		a_priv += 1
	elseif m == "Private note for Bob" then
		a_leak += 1
	end
end
for _, m in B.messages do
	if m == "Private note for Bob" then
		b_priv += 1
	end
end
check(
	a_priv > 0 and b_priv > 0 and a_leak == 0,
	("private MSGs only to their owner (%d, %d, leaks %d)"):format(a_priv, b_priv, a_leak)
)
check(table.find(A.messages, "Everyone hears this") ~= nil, "broadcast MSG reaches everyone")

print("intents: sanitising + rate limit")
local before = #sim.intents
server._intent_budget = {}
for k = 1, 40 do
	A.session:send_intent({ type = "attack", tile = spawn_a + k, ratio = 0.3 })
end
check(
	#sim.intents - before == 30,
	("40 intents in one second → %d accepted (limit 30)"):format(#sim.intents - before)
)
pump(1.1)
local ok_before = #sim.intents
server:on_client(A, { uid = "u1", name = "Alice" }, Protocol.OP.INTENT, "not a buffer")
server:on_client(A, { uid = "u1", name = "Alice" }, Protocol.OP.INTENT, buffer.create(500))
server:on_client(A, { uid = "u1", name = "Alice" }, Protocol.OP.INTENT, { type = "spawn", tile = 5 })
check(#sim.intents == ok_before, "malformed intents are dropped")

print("late join")
local C = make_client("Cara", "u3")
C.session.env.net.send(Protocol.OP.HELLO)
pump(0.1)
C.session:join_multiplayer()
pump(0.2)
check(C.joined ~= 0 and C.session.state ~= nil, "late joiner admitted with a snapshot")
check(C.session.state.tick == sim.tick, ("late joiner's state is current (tick %d)"):format(C.session.state.tick))
check(grid_equal(C.session.state.owner, sim.owner), "late joiner's grid == server grid")
pump(1.0)
check(grid_equal(C.session.state.owner, sim.owner), "late joiner keeps up via deltas")

print("leave / rejoin")
local b_owner = B.joined
B.session:leave_match()
pump(0.2)
check(server:participant(B) == nil, "leave removes the participant")
check(sim.left[b_owner] == true, "Sim.remove_human called (nation turns passive)")
check(B.session.mode == Session.MODE_TITLE, "Bob is back on the title")
pump(2.5)
B.joined = 0
B.session:join_multiplayer()
pump(0.2)
check(B.joined == b_owner, ("rejoin maps to the same owner by account key (%d)"):format(B.joined))

print("disconnect")
server:peer_disconnected(C)
pump(0.1)
check(server:participant(C) == nil and server:participant_count() == 2, "disconnect drops the participant")

print("match end → results → rematch")
local t_left = OVER_AT - sim.tick
pump(t_left / 10 + 0.3)
check(server:stage() == "over", "sim GAME_OVER → over stage")
check(A.session.state.phase == 2 and A.session.state.winner == 1, "clients mirror GAME_OVER")
-- Alice idles past IDLE_DROP between matches; Bob keeps playing
A.session.env.net.send(Protocol.OP.INTENT, Protocol.encode_intent({ type = "attack", tile = 1 }))
server:participant(A).active_msec = clock_ms - MatchServer.IDLE_DROP_MSEC - 1000
server:participant(B).active_msec = clock_ms
pump(MatchServer.RESULTS_SEC + 0.2)
check(server:stage() == "lobby", "results elapsed → rematch lobby")
check(server:participant(A) == nil, "idle Alice not carried into the next match")
check(
	A.session.mode == Session.MODE_TITLE
		and table.find(A.notices, "You were away, so you weren't entered in the next match.") ~= nil,
	"Alice told why and sent to the title"
)
check(math.abs(B.session.lobby.countdown_s - MatchServer.REMATCH_COUNTDOWN_SEC) < 0.5, "rematch countdown is 12 s")
local old_sim = sim
pump(MatchServer.REMATCH_COUNTDOWN_SEC + 0.2)
check(server:stage() == "spawn" and server:sim() ~= old_sim, "rematch starts a new match")
check(
	B.session.state.phase == 0 and B.session.state.tick == server:sim().tick,
	("Bob received the new match snapshot (phase %d, tick %d/%d)"):format(
		B.session.state.phase,
		B.session.state.tick,
		server:sim().tick
	)
)

print("everyone leaves → idle")
B.session:leave_match()
pump(0.2)
check(server:stage() == "idle" and server:sim() == nil, "last participant leaving closes the match")

print("shutdown")
A.session:join_multiplayer()
pump(0.2)
server:shutdown()
pump(0.2)
check(A.session.mode == Session.MODE_TITLE, "shutdown sends participants back to the title")
local shutdown_notices = 0
for _, n in A.notices do
	if
		n == "The game server is restarting. You're back at the title screen."
		or n == "Lost connection to the game server. You're back at the title screen."
	then
		shutdown_notices += 1
	end
end
check(shutdown_notices == 1, ("exactly one shutdown notice (%d)"):format(shutdown_notices))
check(
	not A.session:multiplayer_available() and A.session:multiplayer_status() == "offline",
	"multiplayer shows offline after shutdown"
)

print("names")
do
	local names = {}
	local ms = MatchServer.new({
		make_sim = make_sim,
		send = function() end,
		peers = function()
			return {}
		end,
		now_ms = function()
			return clock_ms
		end,
	})
	for i, raw in { "  Zoë Ünïcødé Ωmega Longname  ", "", string.rep("é", 30), "bad\255utf8" } do
		local p = {}
		ms:join(p, { uid = "n" .. i, name = raw })
		names[i] = ms:participant(p).name
	end
	check(
		names[1] == "Zoë Ünïcødé Ωmega Lo" and utf8.len(names[1]) == 20,
		"names trimmed to 20 UTF-8 characters: " .. names[1]
	)
	check(names[2] == "Commander" and names[4] == "Commander", "empty / invalid names become Commander")
	check(utf8.len(names[3]) == 20, "multi-byte names never split a character")
end

print(("server log lines: %d"):format(#logs))
if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("net_session ok")
