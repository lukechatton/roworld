--!nocheck
-- Quick Play (docs/lobby-service.md "Quick Play"): seats taken in one store step in the soonest
-- lobby of a kind with room (LobbyRules.fits / seated, LobbyStore.take), the line on a hub for a
-- player with no seat anywhere (LobbyDirectory.enqueue / serve_queue), seats given back (a failed
-- teleport, a player who left the waiting room or never came: LobbyRules.released / lapsed_seats,
-- MatchHost), and lobbies scaled to the demand (LobbyRules.demand / missing_starts).
require("./prelude")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local MatchHost = require("../src/server/Lobbies/MatchHost")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local function lobby(id: string, starts: number, extra: { [string]: any }?): any
	local l = { id = id, map = "world", map_name = "World", max = 4, starts = starts, created = starts - 45, players = 0, status = "open", code = "c-" .. id }
	for k, v in extra or {} do
		l[k] = v
	end
	return l
end

-- ---------------------------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------------------------
do
	local now = 1000
	local spec = LobbyRules.take_spec("ffa", 2, { "1", "2" }, now)
	expect(LobbyRules.fits(lobby("a", now + 30), spec), "an open free-for-all with room fits")
	expect(not LobbyRules.fits(lobby("a", now + 30, { players = 3 }), spec), "3 + 2 > 4: no room")
	expect(not LobbyRules.fits(lobby("a", now + 30, { mode = "team" }), spec), "a team game is not a free-for-all")
	expect(not LobbyRules.fits(lobby("a", now + LobbyRules.JOIN_CLOSE_S), spec), "joins closed before the start")
	expect(not LobbyRules.fits(lobby("a", now + LobbyRules.MAX_AHEAD_S + 1), spec), "a wrong clock's lobby is skipped")
	expect(not LobbyRules.fits(lobby("a", now + 30, { status = "started" }), spec), "a started match takes no seats")
	expect(not LobbyRules.fits(lobby("a", now + 30), LobbyRules.take_spec("ffa", 1, { "1" }, now, "b")), "only the lobby asked for")

	local l = lobby("a", now + 30)
	local s = LobbyRules.seated(l, spec)
	expect(s.players == 2 and s.seats["1"] == now and s.seats["2"] == now, "seated: the count and the ledger")
	expect(l.players == 0 and l.seats == nil, "seated leaves the record it was given alone")

	local r, n = LobbyRules.released(s, { "1", "9" })
	expect(n == 1 and r.players == 1 and r.seats["1"] == nil and r.seats["2"] ~= nil, "released: only seats in the ledger")
	local r2, n2 = LobbyRules.released(r, { "1" })
	expect(n2 == 0 and r2.players == 1, "a seat goes back once")
	local st = table.clone(s)
	st.status = "started"
	local _, n3 = LobbyRules.released(st, { "2" })
	expect(n3 == 0, "a started match keeps its count")

	-- the ledger on a waiting lobby: who to give back
	local w = lobby("w", now + 60, { players = 4, seats = { ["1"] = now - 5, ["2"] = now - 40, ["3"] = now - 40, ["4"] = now - 5 } })
	local lapsed = LobbyRules.lapsed_seats(w, { ["3"] = true }, { ["1"] = true, ["3"] = true }, now)
	expect(table.concat(lapsed, ",") == "1,2", "lapsed: left the waiting room (1), never came after ARRIVE_S (2); here (3) and on the way (4) keep theirs")

	-- decode keeps the ledger; an empty one written as [] is fine; junk is dropped
	local d = LobbyRules.decode({ id = "q", map = "m", starts = 5, max = 30, seats = { ["7"] = 3, bad = "x" } })
	expect(d.seats["7"] == 3 and d.seats.bad == nil, "decode keeps the seat ledger, drops junk")
	expect(next(LobbyRules.decode({ id = "q", map = "m", starts = 5, max = 30, seats = {} }).seats) == nil, "an empty ledger")
	expect(LobbyRules.decode({ id = "q", map = "m", starts = 5, max = 30 }).seats == nil, "no ledger (older servers)")
end

-- demand, and the lobbies kept open for it
do
	local now = 50000
	local list = {}
	-- 10 free-for-all lobbies made over the last 90 s, 30 seats taken in each: 300 seats / 120 s
	for i = 1, 10 do
		table.insert(list, lobby("s" .. i, now - 60 + i, { status = "started", max = 30, players = 30, created = now - 90 + i * 9 }))
	end
	table.insert(list, lobby("old", now - 600, { status = "started", max = 30, players = 30, created = now - 700 }))
	table.insert(list, lobby("t1", now + 40, { mode = "team", max = 24, players = 12, created = now - 5 }))
	local d = LobbyRules.demand(list, now, "ffa")
	expect(math.abs(d.rate - 300 / LobbyRules.DEMAND_WINDOW_S) < 1e-9 and d.size == 30, string.format("demand: %.2f seats/s over the window, lobbies of 30", d.rate))
	local dt = LobbyRules.demand(list, now, "team")
	expect(math.abs(dt.rate - 12 / LobbyRules.DEMAND_WINDOW_S) < 1e-9 and dt.size == 24, "per kind")
	local short = LobbyRules.demand(list, now, "ffa", 60)
	expect(short.rate > d.rate, "a list that covers less time: the rate over what it covers")

	-- 3.3 seats/s (10k players, 2026-10-11): one lobby with 5 seats free is not enough
	local busy = { rate = 3.3, size = 30 }
	local open = { lobby("o1", now + 50, { max = 30, players = 25 }) }
	local starts = LobbyRules.missing_starts(open, now, "ffa", 1, busy)
	expect(#starts == LobbyRules.MAX_OPEN_PER_KIND - 1, string.format("busy: %d more lobbies (up to %d open)", #starts, LobbyRules.MAX_OPEN_PER_KIND))
	local gap = starts[2] - starts[1]
	expect(math.abs(gap - 30 / 3.3) < 1e-6, string.format("each starts about as long after the last as it takes to fill (%.1f s)", gap))
	expect(starts[1] == math.max(now + LobbyRules.MIN_LEAD_S, now + 50 + gap), "after the latest lobby of the kind")
	local within = true
	for _, t in starts do
		within = within and t <= now + LobbyRules.LOBBY_OPEN_S
	end
	expect(within, "never more than LOBBY_OPEN_S out")
	-- enough free seats for FILL_AHEAD_S of joins: nothing more
	local roomy = { lobby("o1", now + 50, { max = 30 }), lobby("o2", now + 59, { max = 30 }), lobby("o3", now + 68, { max = 30 }) }
	expect(#LobbyRules.missing_starts(roomy, now, "ffa", 1, busy) == 0, "90 free seats cover 20 s of 3.3/s")
	-- quiet: as before (one per kind)
	local quiet = { rate = 0.02, size = 30 }
	expect(#LobbyRules.missing_starts({}, now, "ffa", 1, quiet) == 1, "quiet, none open: one")
	expect(#LobbyRules.missing_starts({ lobby("o1", now + 50, { max = 30 }) }, now, "ffa", 1, quiet) == 0, "quiet, one open: none more")
	-- no demand known (a fresh list): exactly the old schedule
	local a = LobbyRules.missing_starts({}, now, nil, nil, nil)
	expect(#a == LobbyRules.TARGET_OPEN and a[2] - a[1] == LobbyRules.LOBBY_INTERVAL_S, "no demand: TARGET_OPEN, LOBBY_INTERVAL_S apart")
end

-- ---------------------------------------------------------------------------------------------
-- Hubs: seats in one step, the line
-- ---------------------------------------------------------------------------------------------
local clock = 100000
local function tnow()
	return clock
end
local store = LobbyStore.localstore(tnow)
local reserved = 0
local sent = {}
local teleport_ok = true
local function make_hub(name)
	local s = setmetatable({}, { __index = store })
	s.lock = function(n, ttl)
		return store.lock(n, ttl, name)
	end
	return LobbyDirectory.new({
		store = s,
		teleport = {
			reserve = function()
				reserved += 1
				return "code" .. reserved, "psid" .. reserved
			end,
			send = function(players, code, data)
				if not teleport_ok then
					return false, "nope"
				end
				table.insert(sent, { players = players, code = code, data = data })
				return true
			end,
		},
		maps = function()
			-- a small map: 10 players at 80 % (LobbyRules.max_players)
			return { { id = "pangaea", name = "Pangaea", weight = 1, land = 150000, k_lin = 1 } }
		end,
		now = tnow,
		rand = function()
			return 0.1
		end,
		wait = function() end,
		new_id = (function()
			local n = 0
			return function()
				n += 1
				return name .. "-L" .. n
			end
		end)(),
		team_games = true,
	})
end
local hub1, hub2 = make_hub("hub1"), make_hub("hub2")
hub1:refresh()
hub2:refresh()
local first = hub1:view()[1]
local size = first.max
expect(size == 10, "lobbies of " .. size)

do
	local ok, why, l = hub2:join_public({ "p1" }, "ffa")
	expect(ok and l.id == first.id and sent[#sent].data.lobby == first.id, "Quick Play seats in the soonest free-for-all and sends the player there: " .. tostring(why))
	local rec = store.get(first.id)
	expect(rec.players == 1 and rec.seats.p1 == clock, "the seat is in the record's ledger")
	local okt, _, lt = hub2:join_public({ "p2" }, "team")
	expect(okt and lt.mode == "team", "a team game for a team ask")
	-- a party: all of it in one lobby, with the party in the teleport data
	local okp, _, lp = hub1:join_public({ "a", "b", "c" }, "ffa", { party = { key = "P", uids = { "a", "b", "c" }, leader = 1 } })
	expect(okp and lp.id == first.id and store.get(first.id).players == 4 and sent[#sent].data.party.key == "P", "a party sits together")
	-- a failed teleport gives the seats back
	teleport_ok = false
	local okf = hub1:join_public({ "f1", "f2" }, "ffa")
	teleport_ok = true
	local after = store.get(first.id)
	expect(not okf and after.players == 4 and after.seats.f1 == nil, "a failed teleport gives the seats back")
	-- cancelled while the store answered: seats back, no teleport
	local before = #sent
	local okc, whyc = hub1:join_public({ "c1" }, "ffa", {
		wanted = function()
			return false
		end,
	})
	expect(not okc and whyc == "cancelled" and #sent == before and store.get(first.id).players == 4, "a cancelled ask sends nobody and keeps no seat")
end

-- every free-for-all full: PUBLIC MATCH takes a seat in World's lobby (LobbyRules.takes_from); that
-- full too: no room, then the line
do
	local function fill(kind)
		for _, l in hub1:lobbies() do
			if l.status == "open" and LobbyRules.mode_of(l) == kind then
				store.update(l.id, function(v)
					local d = LobbyRules.decode(v)
					d.players = d.max
					return d
				end)
			end
		end
	end
	fill("ffa")
	local okw, _, lw = hub1:join_public({ "to_world" }, "ffa")
	expect(okw and lw ~= nil and lw.mode == "world", "free-for-alls full: PUBLIC MATCH seats in World's lobby")
	fill("world")
	local ok, why = hub1:join_public({ "late" }, "ffa")
	expect(not ok and why == LobbyDirectory.NO_ROOM, "all full: no room")
	local done = {}
	local function entry(key, players, mode)
		return {
			key = key,
			mode = mode or "ffa",
			since = clock,
			members = function()
				return players, nil
			end,
			done = function(okd, reason, l, who)
				table.insert(done, { key = key, ok = okd, reason = reason, lobby = l, who = who })
			end,
		}
	end
	hub1:enqueue(entry("party4", { "q1", "q2", "q3", "q4" }))
	hub1:enqueue(entry("solo", { "q5" }))
	hub1:enqueue(entry("solo", { "q5" })) -- (asking twice: one place in line)
	expect(hub1:queue_size() == 2, "one place per key")
	hub1:serve_queue()
	expect(#done == 0 and hub1:queue_size() == 2, "still no room: both wait")
	-- a lobby with 2 seats free: the party of 4 can't go, the single behind it can
	local spare
	for _, l in hub1:lobbies() do
		if l.status == "open" and LobbyRules.mode_of(l) == "ffa" then
			spare = l.id
		end
	end
	store.update(spare, function(v)
		local d = LobbyRules.decode(v)
		d.players = d.max - 2
		return d
	end)
	hub1:serve_queue()
	expect(#done == 1 and done[1].key == "solo" and done[1].ok and done[1].who[1] == "q5", "a single behind a party that doesn't fit is seated")
	expect(hub1:queued("party4") ~= nil, "the party keeps its place")
	-- the scheduler makes room (demand: many seats taken lately) and the party goes
	clock += 3
	hub1:refresh()
	hub1:serve_queue()
	expect(#done == 2 and done[2].key == "party4" and done[2].ok and #done[2].who == 4, "a new lobby: the party is seated together")
	expect(hub1:queue_size() == 0, "the line is empty")
	-- gone (left / started a solo match) and timed out
	hub1:enqueue({
		key = "gone",
		mode = "team",
		since = clock,
		members = function()
			return nil
		end,
		done = function(okd, reason)
			table.insert(done, { key = "gone", ok = okd, reason = reason })
		end,
	})
	local slow = entry("slow", { "z" }, "team")
	slow.since = clock - LobbyDirectory.QUEUE_MAX_S - 1
	hub1:enqueue(slow)
	hub1:serve_queue()
	expect(done[3].key == "gone" and done[3].reason == "gone" and done[4].key == "slow" and done[4].reason == "timeout", "out of the line: gone, timed out")
	-- leaving the line
	hub1:enqueue(entry("bye", { "y" }))
	expect(hub1:dequeue("bye") and hub1:queue_size() == 0 and not hub1:dequeue("bye"), "dequeue")
end

-- the store unreachable: a few tries, then the soonest lobby with room in the hub's list
do
	hub1:refresh()
	local real_take = store.take
	local calls = 0
	store.take = function()
		calls += 1
		error("lobby service: timeout")
	end
	local before = #sent
	local ok, why = hub1:join_public({ "offline" }, "team")
	store.take = real_take
	expect(ok and calls == LobbyDirectory.JOIN_TRIES and #sent == before + 1, "store unreachable: retried, then joined from the hub's list: " .. tostring(why))
end

-- MemoryStore can't search: take tries the hub's candidates in turn
do
	local rows = {}
	local fake = {
		UpdateAsync = function(_self, key, fn)
			local new = fn(rows[key])
			if new ~= nil then
				rows[key] = new
			end
			return new
		end,
		GetAsync = function(_self, key)
			return rows[key]
		end,
	}
	local ms = LobbyStore.memory_with(fake, fake, fake, "job", function()
		return 0
	end)
	rows.full = lobby("full", 30, { players = 4 })
	rows.free = lobby("free", 40)
	local spec = LobbyRules.take_spec("ffa", 1, { "u1" }, 0)
	spec.candidates = { "full", "free" }
	local got = ms.take(spec)
	expect(got ~= nil and got.id == "free" and rows.free.players == 1 and rows.free.seats.u1 == 0, "MemoryStore: the first candidate with room")
	local after, n = ms.release("free", { "u1" })
	expect(n == 1 and rows.free.players == 0 and after.players == 0, "MemoryStore: release")
end

-- ---------------------------------------------------------------------------------------------
-- The match server gives back seats of players who left or never came
-- ---------------------------------------------------------------------------------------------
do
	local target = hub1:create(clock + 60, "ffa")
	hub1:refresh()
	expect(target ~= nil and target.psid ~= nil, "an empty lobby to fill")
	for _, p in { "m1", "m2", "m3" } do
		hub1:join_public({ p }, "ffa", { id = target.id })
	end
	expect(store.get(target.id).players == 3, "three seats taken")
	local host = MatchHost.new({ store = store, psid = target.psid, now = tnow, to_hub = function()
		return true
	end })
	expect(host:lookup(), "the match server finds its lobby")
	-- m1 arrives and leaves, m2 arrives and stays, m3 never comes
	host:set_present(1)
	host:set_roster({ "m1" })
	host:set_roster({ "m2" })
	host:set_present(1)
	host:_sync()
	local rec = store.get(target.id)
	expect(rec.players == 2 and rec.seats.m1 == nil and rec.seats.m2 ~= nil and rec.seats.m3 ~= nil, "a player who left the waiting room gives the seat back; one on the way keeps it")
	clock += LobbyRules.ARRIVE_S
	host:_sync()
	rec = store.get(target.id)
	expect(rec.players == 1 and rec.seats.m3 == nil and host.released == 2, "one who never came, ARRIVE_S later, too")
	-- the seats are taken again
	local ok = hub2:join_public({ "m4" }, "ffa", { id = target.id })
	expect(ok and store.get(target.id).players == 2, "and someone else gets one")
end

print(if fails == 0 then "quick_play: all passed" else string.format("quick_play: %d FAILED", fails))
if fails > 0 then
	error("quick_play failed")
end
