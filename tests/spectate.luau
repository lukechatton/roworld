-- Spectating public matches: the hubs list running matches (live, watchable while their server's
-- heartbeat is fresh) and teleport watchers with { spectate = true }; on the match server a
-- spectator is a participant without a nation (never counted as a player, no bot-fill slot, no
-- intents) that still gets the snapshot (owner 0) and every public delta.
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local MatchHost = require("../src/server/Lobbies/MatchHost")
local FakeSim = require("./net_fakesim")
U.use_zstd(Protocol)
local OP = Protocol.OP

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Match server
-- ---------------------------------------------------------------------------------------------
local clock_ms = 0
local started_with = -1
local removed = {}
local server = MatchServer.new({
	make_sim = function(cfg)
		local sim = FakeSim.new(cfg)
		local rm = sim.remove_human
		sim.remove_human = function(s, id)
			table.insert(removed, id)
			return rm(s, id)
		end
		return sim
	end,
	send = function(peer, op, ...)
		table.insert(peer.inbox, table.pack(op, ...))
	end,
	peers = function()
		return {}
	end,
	now_ms = function()
		return clock_ms
	end,
	seed = function()
		return 7
	end,
	lobby = {
		countdown = function()
			return math.max(0, 1.0 - clock_ms / 1000)
		end,
		info = function()
			return { map_id = "onion", max = 10 }
		end,
		on_start = function(humans)
			started_with = humans
			return 0
		end,
		bot_names = function()
			return {}
		end,
		on_over = function() end,
	},
})
local function peer(name)
	return { inbox = {}, name = name }
end
local function got(p, op)
	for _, m in p.inbox do
		if m[1] == op then
			return m
		end
	end
	return nil
end
local function run(seconds)
	local steps = math.floor(seconds * 20)
	for _ = 1, steps do
		clock_ms += 50
		server:process(0.05)
	end
end

local a, b = peer("A"), peer("B")
local early = peer("EarlyWatcher")
server:join(a, { uid = "a", name = "A" })
server:join(b, { uid = "b", name = "B" })
server:join(early, { uid = "w1", name = "EarlyWatcher", spectate = true })
run(3.0)
expect(server:stage() == "spawn" or server:stage() == "playing", "the match started: " .. server:stage())
expect(started_with == 2, "bot fill counts only the 2 players, not the watcher (" .. started_with .. ")")
local pa, pw = server:participant(a), server:participant(early)
expect(pa.owner ~= 0 and pw.owner == 0, "players get nations, the watcher none")
local snap = got(early, OP.SNAPSHOT)
expect(snap ~= nil and snap[2] == 0, "the early watcher gets the snapshot as owner 0")

local late = peer("LateWatcher")
server:join(late, { uid = "w2", name = "LateWatcher", spectate = true })
local snap2 = got(late, OP.SNAPSHOT)
expect(snap2 ~= nil and snap2[2] == 0, "a watcher arriving mid-match gets the snapshot as owner 0")
table.clear(late.inbox)
run(0.5)
expect(got(late, OP.DELTA) ~= nil, "watchers receive the deltas")
local info = server:lobby_info(late)
expect(info.spectating == true and info.watchers == 2, "lobby info: spectating, 2 watchers")
local listed = table.concat(info.players, ",")
expect(listed == "A,B", "the player list leaves watchers out: " .. listed)
expect(server:lobby_info(a).spectating == false, "players are not spectating")
local intent = Protocol.encode_intent({ type = "attack", tile = 5, ratio = 0.2 })
expect(server:intent(late, intent) == false, "a watcher's intents never reach the Sim")
server:leave(late)
expect(#removed == 0, "a watcher leaving removes no nation")
server:leave(a)
expect(#removed == 1, "a player leaving does")

-- ---------------------------------------------------------------------------------------------
-- Hubs: live list and Watch
-- ---------------------------------------------------------------------------------------------
local now = 10000
local function tnow()
	return now
end
local store = LobbyStore.localstore(tnow)
local sent = {}
local dir = LobbyDirectory.new({
	store = store,
	teleport = {
		reserve = function()
			return "code", "psid"
		end,
		send = function(players, code, data)
			table.insert(sent, { players = players, code = code, data = data })
			return true
		end,
	},
	maps = function()
		return { { id = "world", name = "World", weight = 1, land = 651569, k_lin = 1 } }
	end,
	now = tnow,
	rand = function()
		return 0.5
	end,
	new_id = (function()
		local n = 0
		return function()
			n += 1
			return "L" .. n
		end
	end)(),
})
dir:refresh()
local open_n = #dir:view()
local live = {
	id = "LIVE1",
	map = "world",
	map_name = "World",
	max = 50,
	starts = now - 300,
	created = now - 400,
	players = 4,
	status = "started",
	beat = now - 10,
	code = "livecode",
	psid = "livepsid",
}
store.put(live, 900)
dir:refresh()
local view = dir:view()
local lv = view[#view]
expect(#view == open_n + 1 and lv.live and lv.watchable and lv.elapsed == 300, "a running match is listed live")
expect(lv.code == nil and not lv.joinable, "the live entry hides the code and can't be joined")
local ok = dir:spectate({ Name = "viewer" }, "LIVE1")
expect(ok and #sent == 1 and sent[1].code == "livecode" and sent[1].data.spectate == true, "Watch teleports as a spectator")
store.update("LIVE1", function(v)
	v.beat = now - LobbyRules.LIVE_STALE_S - 1
	return v
end)
dir:refresh()
expect(#dir:view() == open_n, "a match whose server stopped beating drops off the list")
local ok2, why = dir:spectate({ Name = "viewer" }, "LIVE1")
expect(not ok2 and why ~= nil, "and can't be watched: " .. tostring(why))

-- MatchHost: heartbeat while running, record gone at the end
local rec = nil
for _, l in dir:lobbies() do
	if l.status == "open" then
		rec = store.get(l.id)
		break
	end
end
local host = MatchHost.new({
	store = store,
	psid = rec.psid,
	now = tnow,
	to_hub = function()
		return true
	end,
})
host:lookup()
local hid = host.lobby.id -- (the stub reserves one psid for every lobby: the last bound one)
host:set_present(3)
host:start(3)
expect(store.get(hid).status == "started" and store.get(hid).beat == now, "start marks the record live")
now += 40
host:tick(LobbyRules.LIVE_BEAT_S + 1)
expect(store.get(hid).beat == now, "the running match's heartbeat refreshes the record")
host:finish()
expect(store.get(hid) == nil, "the record goes when the match is over")

print(if fails == 0 then "spectate: all passed" else string.format("spectate: %d FAILED", fails))
if fails > 0 then
	error("spectate failed")
end
