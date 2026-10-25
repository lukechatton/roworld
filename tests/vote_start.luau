-- Vote to start: in a public match's waiting room, once two thirds of the players (watchers don't
-- count) voted, the match starts in MatchServer.VOTE_START_S; votes toggle, leavers can tip the
-- balance, the lobby hook moves the lobby's start up (MatchHost.start_early), and a passed vote is
-- locked in. A player alone for VOTE_SOLO_AFTER_S may vote it to start; in the last FILL_REVEAL_S
-- the bot players that fill the match show up in the waiting room.
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local MatchHost = require("../src/server/Lobbies/MatchHost")
local FakeSim = require("./net_fakesim")
U.use_zstd(Protocol)

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local function make(lobby_wait: number, opts: any?)
	local o = opts or {}
	local clock_ms = 0
	local early = {}
	local server = MatchServer.new({
		make_sim = function(cfg)
			local sim = FakeSim.new(cfg)
			sim.add_bot_players = function(_s, n, names)
				o.bots_added = { n = n, names = names }
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
			return 3
		end,
		lobby = {
			countdown = function()
				return math.max(0, lobby_wait - clock_ms / 1000)
			end,
			info = function()
				return { map_id = "onion", max = 10 }
			end,
			on_start = function(humans)
				return if o.fill then math.max(0, 10 - humans) else 0
			end,
			bot_names = function(n, taken)
				if not o.fill then
					return {}
				end
				local out = {}
				local i = 0
				while #out < n do
					i += 1
					local nm = "Bot" .. i
					if not taken[nm] then
						table.insert(out, nm)
					end
				end
				return out
			end,
			on_over = function() end,
			on_vote_start = function(sec)
				table.insert(early, sec)
			end,
		},
	})
	local function run(seconds)
		for _ = 1, math.floor(seconds * 20) do
			clock_ms += 50
			server:process(0.05)
		end
	end
	return server, run, early
end
local function peer(n)
	return { inbox = {}, name = n }
end

-- three players, a two-vote majority
do
	local server, run, early = make(300)
	local a, b, c, w = peer("A"), peer("B"), peer("C"), peer("Watcher")
	for _, p in { a, b, c } do
		server:join(p, { uid = p.name, name = p.name })
	end
	server:join(w, { uid = "w", name = "Watcher", spectate = true })
	run(1)
	expect(server:stage() == "lobby", "waiting in the lobby")
	server:on_client(w, { uid = "w", name = "Watcher" }, Protocol.OP.VOTE_START)
	local info = server:lobby_info(a)
	expect(info.votes == 0 and info.votes_needed == 2, "watchers can't vote; 2 of 3 players needed")
	server:on_client(b, { uid = "B", name = "B" }, Protocol.OP.VOTE_START)
	server:on_client(b, { uid = "B", name = "B" }, Protocol.OP.VOTE_START)
	server:on_client(a, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	info = server:lobby_info(b)
	expect(info.votes == 1 and info.voted == false and not info.vote_started, "a second press takes the vote back")
	expect(server:lobby_info(a).voted == true, "A's vote stands")
	server:on_client(c, { uid = "C", name = "C" }, Protocol.OP.VOTE_START)
	info = server:lobby_info(a)
	expect(info.vote_started and #early == 1 and early[1] == MatchServer.VOTE_START_S, "two votes start it early")
	run(0.5)
	expect(server:lobby_info(a).countdown_s <= MatchServer.VOTE_START_S, "the countdown drops to 10 s")
	server:on_client(c, { uid = "C", name = "C" }, Protocol.OP.VOTE_START)
	expect(server:lobby_info(a).vote_started, "a passed vote is locked in")
	run(MatchServer.VOTE_START_S + 1)
	expect(server:stage() == "spawn" or server:stage() == "playing", "the match starts: " .. server:stage())
	expect(server:lobby_info(a).votes == 0, "votes clear once it started")
end

-- a lone player can't vote-start (at least 2 players); leavers can tip the vote
do
	local server, run = make(300)
	local solo = peer("Solo")
	server:join(solo, { uid = "s", name = "Solo" })
	run(0.5)
	server:on_client(solo, { uid = "s", name = "Solo" }, Protocol.OP.VOTE_START)
	expect(not server:lobby_info(solo).vote_started, "one player alone can't start it")
	local friend = peer("Friend")
	server:join(friend, { uid = "f", name = "Friend" })
	run(0.5)
	expect(not server:lobby_info(solo).vote_started, "1 of 2 isn't enough")
	server:on_client(friend, { uid = "f", name = "Friend" }, Protocol.OP.VOTE_START)
	expect(server:lobby_info(solo).vote_started, "2 of 2 starts it")

	local server2, run2 = make(300)
	local a, b, c, d = peer("A"), peer("B"), peer("C"), peer("D")
	for _, p in { a, b, c, d } do
		server2:join(p, { uid = p.name, name = p.name })
	end
	run2(0.5)
	server2:on_client(a, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	server2:on_client(b, { uid = "B", name = "B" }, Protocol.OP.VOTE_START)
	expect(not server2:lobby_info(a).vote_started and server2:lobby_info(a).votes_needed == 3, "2 of 4 isn't two thirds (3 needed)")
	server2:leave(c)
	expect(server2:lobby_info(a).vote_started, "a non-voter leaving: 2 of 3 starts it")
	local server3, run3 = make(300)
	local e, f = peer("E"), peer("F")
	server3:join(e, { uid = "E", name = "E" })
	server3:join(f, { uid = "F", name = "F" })
	run3(0.5)
	server3:on_client(e, { uid = "E", name = "E" }, Protocol.OP.VOTE_START)
	server3:peer_disconnected(f)
	expect(not server3:lobby_info(e).vote_started, "left alone again: no vote start")
end

-- alone for VOTE_SOLO_AFTER_S: a lone vote starts the public match
do
	local server, run, early = make(300)
	local solo = peer("Solo")
	server:join(solo, { uid = "s", name = "Solo" })
	run(1)
	local info = server:lobby_info(solo)
	expect(info.vote_min_players == 2 and info.vote_solo_in ~= nil and info.vote_solo_in > 25, "alone: a lone vote unlocks in ~30 s")
	server:on_client(solo, { uid = "s", name = "Solo" }, Protocol.OP.VOTE_START)
	run(MatchServer.VOTE_SOLO_AFTER_S - 5)
	expect(not server:lobby_info(solo).vote_started, "not before 30 s alone")
	run(5)
	info = server:lobby_info(solo)
	expect(info.vote_min_players == 1 and info.vote_started and #early == 1, "after 30 s alone the standing vote starts it")

	local server2, run2 = make(300)
	local a, b = peer("A"), peer("B")
	server2:join(a, { uid = "A", name = "A" })
	run2(20)
	server2:join(b, { uid = "B", name = "B" })
	run2(0.5)
	server2:leave(b)
	run2(15)
	server2:on_client(a, { uid = "A", name = "A" }, Protocol.OP.VOTE_START)
	expect(not server2:lobby_info(a).vote_started, "the 30 s restart when someone else was here")
end

-- the last FILL_REVEAL_S: the bot players that fill the match show up in the waiting room one by one,
-- and the match starts with those names
do
	local opts = { fill = true }
	local server, run = make(30, opts)
	local a, w = peer("A"), peer("Watcher")
	server:join(a, { uid = "A", name = "A" })
	server:join(w, { uid = "w", name = "Watcher", spectate = true })
	run(30 - MatchServer.FILL_REVEAL_S - 1)
	expect(#server:lobby_info(a).players == 1, "before the last 10 s: just the real player")
	run(6)
	local mid = server:lobby_info(a)
	expect(#mid.players > 1 and #mid.players < 10, "a few seconds in, some have joined: " .. #mid.players)
	expect(mid.vote_players == 1, "bots don't count as voters")
	run(4.5) -- 0.5 s left (the last one shows up by 0.6 s)
	local full = server:lobby_info(a)
	expect(#full.players == 10, "just before the start the lobby is full: " .. #full.players)
	local shown = table.clone(full.players)
	run(1)
	expect(server:stage() == "spawn" or server:stage() == "playing", "the match starts")
	local added = opts.bots_added
	local same = added ~= nil and added.n == 9
	for i = 1, 9 do
		if not added or added.names[i] ~= shown[i + 1] then
			same = false
		end
	end
	expect(same, "the bots in the match are the ones shown joining")
end

-- the join times: in the window, ascending, thickening toward the start, some in quick succession,
-- and never on a one-second beat
do
	math.randomseed(7)
	local window = 9.4
	local early, late, quick, total = 0, 0, 0, 0
	local ok_range, frac = true, {}
	for _ = 1, 200 do
		local t = MatchServer.fill_schedule(25, window)
		for i, x in t do
			if x < 0 or x > window or (i > 1 and x < t[i - 1]) then
				ok_range = false
			end
			if x < window / 2 then
				early += 1
			else
				late += 1
			end
			if i > 1 and x - t[i - 1] < 0.5 then
				quick += 1
			end
			total += 1
			frac[math.floor((x % 1) * 10)] = true
		end
	end
	expect(ok_range, "within the window, in order")
	expect(late > early * 1.8, string.format("more join near the start (%d vs %d)", late, early))
	expect(quick > total * 0.3, "some join a moment after the one before")
	local tenths = 0
	for _ in frac do
		tenths += 1
	end
	expect(tenths == 10, "spread across each second, not on a beat")
end

-- joins are timed by the server clock, not the (whole-second) lobby countdown
do
	local clock_ms = 0
	local steps = {}
	local server = MatchServer.new({
		make_sim = function(cfg)
			return FakeSim.new(cfg)
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
			return 3
		end,
		lobby = {
			countdown = function()
				-- live: whole seconds (os.time)
				return math.max(0, math.ceil(30 - clock_ms / 1000))
			end,
			info = function()
				return { map_id = "onion", max = 30 }
			end,
			on_start = function()
				return 0
			end,
			bot_names = function(n)
				local out = {}
				for i = 1, n do
					out[i] = "Bot" .. i
				end
				return out
			end,
			on_over = function() end,
		},
	})
	local a = peer("A")
	server:join(a, { uid = "A", name = "A" })
	local last = 1
	for _ = 1, 29 * 20 do
		clock_ms += 50
		server:process(0.05)
		local n = #server:lobby_info(a).players
		if n ~= last then
			steps[(clock_ms % 1000) // 100] = true
			last = n
		end
	end
	local k = 0
	for _ in steps do
		k += 1
	end
	expect(last == 30 and k >= 6, string.format("joins land all through each second (%d of 10 tenths)", k))
end

-- two thirds: 6 players need 4 votes
do
	local server, run = make(300)
	local ps = {}
	for i = 1, 6 do
		ps[i] = peer("P" .. i)
		server:join(ps[i], { uid = "P" .. i, name = "P" .. i })
	end
	run(0.5)
	for i = 1, 3 do
		server:on_client(ps[i], { uid = "P" .. i, name = "P" .. i }, Protocol.OP.VOTE_START)
	end
	local info = server:lobby_info(ps[1])
	expect(info.votes_needed == 4 and not info.vote_started, "3 of 6 isn't enough (4 needed)")
	server:on_client(ps[4], { uid = "P4", name = "P4" }, Protocol.OP.VOTE_START)
	expect(server:lobby_info(ps[1]).vote_started, "4 of 6 starts it")
end

-- MatchHost.start_early moves the lobby's start up (hubs close joins before it)
do
	local now = 1000
	local store = LobbyStore.localstore(function()
		return now
	end)
	store.put({ id = "L", map = "world", map_name = "World", max = 50, starts = now + 90, created = now, players = 2, status = "open", code = "c", psid = "p" }, 900)
	store.bind_psid("p", "L", 900)
	local host = MatchHost.new({
		store = store,
		psid = "p",
		now = function()
			return now
		end,
		to_hub = function()
			return true
		end,
	})
	host:lookup()
	host:start_early(10)
	expect(store.get("L").starts == now + 10 and host.lobby.starts == now + 10, "the lobby record starts in 10 s")
	host:start_early(30)
	expect(store.get("L").starts == now + 10, "never later than it already was")
end

print(if fails == 0 then "vote_start: all passed" else string.format("vote_start: %d FAILED", fails))
if fails > 0 then
	error("vote_start failed")
end
