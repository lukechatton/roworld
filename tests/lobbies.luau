--!nocheck
-- Public lobbies: LobbyRules (sizes, rotation, scheduling, bot fill), LobbyDirectory (two hubs
-- sharing one store: one creates, both list; joins reserve slots; failed teleports give slots back)
-- and MatchHost (lookup by reserved-server id, start time, started lobbies leave the lists).
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

-- ---------------------------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------------------------
-- (seats: the land-based count x 1.5, 10..50, at most a server's size; since 2026-10-19 up to 50 per
-- lobby where the map supports it. It was that times MAP_SCALE_PCT's area.)
local function r5(n)
	return math.floor(n / 5 + 0.5) * 5
end
local function full(land)
	return math.clamp(r5(land * 75 / 1e6), 10, 50)
end
expect(LobbyRules.max_players(651569, 1) == 50, "World hosts " .. LobbyRules.max_players(651569, 1))
expect(LobbyRules.max_players(5000000, 1) == 50, "the biggest maps host 50: " .. LobbyRules.max_players(5000000, 1))
expect(LobbyRules.max_players(100000, 1) == 10, "tiny maps get the minimum")
expect(LobbyRules.max_players(400000, 1) == full(400000), "the land-based count x 1.5, rounded: " .. LobbyRules.max_players(400000, 1))
expect(LobbyRules.max_players(651569, 1, 30) == 30, "never more seats than a server holds (Max Visitor Count 30)")
expect(LobbyRules.max_players(651569, 1, 55) == 50 and LobbyRules.max_players(400000, 1, 55) == 30, "a bigger server: the map's own count")
expect(LobbyRules.max_players(651569, 1, 5) == 50, "a server size under MIN_PLAYERS is no cap (Studio's)")
-- kinds: World's own free-for-all is always one of them (the free-for-all rotation still plays World)
do
	local k1, k2 = LobbyRules.kinds(true), LobbyRules.kinds(false)
	local modes1, modes2 = {}, {}
	for _, k in k1 do
		table.insert(modes1, k.mode)
	end
	for _, k in k2 do
		table.insert(modes2, k.mode)
	end
	expect(table.concat(modes1, ",") == "ffa,world,team", "kinds with team games: " .. table.concat(modes1, ","))
	expect(table.concat(modes2, ",") == "ffa,world", "kinds without: " .. table.concat(modes2, ","))
	expect(LobbyRules.is_mode("world") and LobbyRules.is_mode("ffa") and not LobbyRules.is_mode("solo"), "is_mode")
	local w = LobbyRules.public_weights({
		{ id = "world", weight = 10 },
		{ id = "bigmap", weight = 15 },
		{ id = "europe", weight = 5 },
	})
	local ids = {}
	for _, e in w do
		ids[e.id] = true
	end
	expect(not ids.world and ids.europe and ids.bigmap, "the free-for-all rotation: every map but World (its own lobby)")
	-- PUBLIC MATCH (a free-for-all join) takes World's seats too; World's and a team game's only their own
	local kinds_ffa = LobbyRules.takes_from("ffa")
	expect(table.find(kinds_ffa, "ffa") and table.find(kinds_ffa, "world") and #kinds_ffa == 2, "a free-for-all join takes ffa and world")
	expect(#LobbyRules.takes_from("world") == 1 and #LobbyRules.takes_from("team") == 1, "world and team joins: their own kind")
	local wl = { id = "w", status = "open", mode = "world", starts = 100, players = 0, max = 50 }
	local fl = { id = "f", status = "open", starts = 100, players = 0, max = 50 }
	local tl = { id = "t", status = "open", mode = "team", starts = 100, players = 0, max = 50 }
	local ffa_spec = LobbyRules.take_spec("ffa", 1, { "1" }, 0)
	local world_spec = LobbyRules.take_spec("world", 1, { "1" }, 0)
	expect(LobbyRules.fits(wl :: any, ffa_spec) and LobbyRules.fits(fl :: any, ffa_spec), "PUBLIC MATCH fits World's lobby and a free-for-all")
	expect(not LobbyRules.fits(tl :: any, ffa_spec), "... never a team game")
	expect(LobbyRules.fits(wl :: any, world_spec) and not LobbyRules.fits(fl :: any, world_spec), "WORLD fits only World's lobby")
	-- World's lobbies half an interval after the free-for-alls', so PUBLIC MATCH's soonest alternates
	local t0 = 5000
	local fs = LobbyRules.missing_starts({}, t0, "ffa", 1)
	local ws = LobbyRules.missing_starts({}, t0, "world", 1, nil, fs)
	expect(#fs == 1 and #ws == 1 and ws[1] - fs[1] == LobbyRules.WORLD_STAGGER_S, "World's first lobby starts WORLD_STAGGER_S after the free-for-all's")
	expect(ws[1] <= t0 + LobbyRules.LOBBY_OPEN_S, "... still within LOBBY_OPEN_S")
	expect(LobbyRules.missing_starts({}, t0, "world", 1)[1] == fs[1], "nothing to avoid: World's schedule as before")
	local busy = { rate = 3, size = 30 }
	expect(LobbyRules.missing_starts({}, t0, "world", 1, busy, fs)[1] == fs[1], "busy (a faster schedule): not moved")
	-- a level schedule (every lobby until 2026-10-19) comes apart: both kinds' lobbies on the same second
	local soonest_world, soonest_ffa = 0, 0
	local fl2 = { id = "f", status = "open", starts = t0 + 30, players = 0, max = 50, created = t0 }
	local wl2 = { id = "w", status = "open", mode = "world", starts = t0 + 30, players = 0, max = 50, created = t0 }
	local list = { fl2, wl2 }
	local gaps = {}
	for t = t0, t0 + 900 do
		-- (each kind's next lobby made as the scheduler would, World's clear of the free-for-alls')
		local ffa_starts = {}
		for _, l in list do
			if l.mode == nil and l.starts > t then
				table.insert(ffa_starts, l.starts)
			end
		end
		for _, k in { "ffa", "world" } do
			table.sort(ffa_starts)
			for _, st in LobbyRules.missing_starts(list, t, k, 1, nil, if k == "world" then ffa_starts else nil) do
				table.insert(list, { id = k .. st, status = "open", mode = if k == "world" then "world" else nil, starts = st, players = 0, max = 50, created = t })
				if k == "ffa" then
					table.insert(ffa_starts, st)
				else
					local near = math.huge
					for _, a in ffa_starts do
						near = math.min(near, math.abs(st - a))
					end
					table.insert(gaps, near)
				end
			end
		end
		local best = nil
		for _, l in list do
			if LobbyRules.fits(l :: any, LobbyRules.take_spec("ffa", 1, { "1" }, t)) and (best == nil or l.starts < best.starts) then
				best = l
			end
		end
		if best ~= nil then
			if best.mode == "world" then
				soonest_world += 1
			else
				soonest_ffa += 1
			end
		end
	end
	local share = soonest_world / math.max(1, soonest_world + soonest_ffa)
	expect(share > 0.3 and share < 0.7, string.format("PUBLIC MATCH's soonest is World's lobby %.0f%% of the time", share * 100))
	local late_ok = true
	for i = 2, #gaps do
		late_ok = late_ok and gaps[i] >= LobbyRules.WORLD_STAGGER_S
	end
	expect(#gaps > 10 and late_ok, "after the first, every World lobby is WORLD_STAGGER_S+ from a free-for-all's start")
	local g = LobbyRules.decode({ id = "g", map = "world", starts = 1, slots = 50, mode = "world" })
	expect(g ~= nil and g.mode == "world" and g.max == 50 and LobbyRules.mode_of(g) == "world", "a World-kind record decodes as its kind")
	expect(LobbyRules.public_view(g :: any, 0).mode == "world", "and clients see its kind")
	expect(LobbyRules.mode_of({ mode = "giant" } :: any) == "ffa", "the one-day giant kind reads as a free-for-all")
	expect(LobbyRules.mode_of({ mode = "x" } :: any) == "ffa", "an unknown mode is a free-for-all")
end
expect(LobbyRules.max_players(100000, 2) == LobbyRules.max_players(400000, 1), "our tiles count k_lin^2 full-size tiles")

local maps = { { id = "a", weight = 1 }, { id = "b", weight = 3 }, { id = "c", weight = 0 } }
expect(LobbyRules.pick_map(maps, {}, 0.0) == "a" and LobbyRules.pick_map(maps, {}, 0.5) == "b", "weighted pick")
expect(LobbyRules.pick_map(maps, { "b" }, 0.9) == "a", "recent maps are skipped")
expect(LobbyRules.pick_map(maps, { "a", "b" }, 0.3) ~= "c", "weight 0 never picked (falls back to recent)")

-- the free-for-all playlist on the real map list: never World (its own lobby takes PUBLIC MATCH's
-- seats); the odd maps (fictional, cosmic, arcade) far rarer than the maps' listed weights
do
	local MapList = require("../src/shared/Data/MapList")
	local maps = {}
	for _, m in MapList.maps do
		table.insert(maps, { id = m.id, weight = m.multiplayer_frequency or 1, categories = m.categories })
	end
	local function weird(id)
		for _, m in MapList.maps do
			if m.id == id then
				for _, c in m.categories or {} do
					if LobbyRules.WEIRD_CATEGORIES[c] then
						return true
					end
				end
			end
		end
		return false
	end
	local function simulate(entries, n)
		math.randomseed(11)
		local recent = {}
		local world, odd, twice = 0, 0, 0
		local last = nil
		for _ = 1, n do
			local id = LobbyRules.pick_map(entries, recent, math.random())
			if id == "world" then
				world += 1
				if last == "world" then
					twice += 1
				end
			end
			if weird(id) then
				odd += 1
			end
			last = id
			table.insert(recent, 1, id)
			while #recent > LobbyRules.RECENT_MAPS do
				table.remove(recent)
			end
		end
		return world / n, odd / n, twice
	end
	local n = 20000
	local w0, o0 = simulate(maps, n) -- the raw listed weights
	local w1, o1 = simulate(LobbyRules.public_weights(maps), n)
	expect(w1 == 0, string.format("World in none of the free-for-all rotation (was %.1f%%)", w0 * 100))
	expect(o1 == 0 and o0 == 0, string.format("no odd maps left to pick (%.1f%%, unweighted %.1f%%)", o1 * 100, o0 * 100))
end

local now = 1000
local open = {}
local starts = LobbyRules.missing_starts(open, now)
expect(#starts == LobbyRules.TARGET_OPEN and starts[1] == now + LobbyRules.MIN_LEAD_S, "empty list -> target lobbies")
expect(starts[2] - starts[1] == LobbyRules.LOBBY_INTERVAL_S, "starts are staggered")
expect(starts[#starts] <= now + LobbyRules.LOBBY_OPEN_S, "every listed match starts within LOBBY_OPEN_S")
-- steady state: when the soonest starts, its replacement still starts within LOBBY_OPEN_S
do
	local t = starts[1]
	local rest = { { id = "b", starts = starts[2], status = "open", players = 0, max = 10 } }
	local nxt = LobbyRules.missing_starts(rest, t)
	expect(#nxt == 1 and nxt[1] <= t + LobbyRules.LOBBY_OPEN_S, "a replacement starts within LOBBY_OPEN_S too")
end
-- lobbies leaving early (vote starts, fills) one after another never push the schedule past
-- LOBBY_OPEN_S, and there is always a joinable lobby
do
	local t = 7000
	local list = {}
	local worst, gaps = 0, 0
	local n = 0
	for step = 1, 200 do
		-- schedule what's missing
		for _, st in LobbyRules.missing_starts(list, t) do
			n += 1
			table.insert(list, { id = "v" .. n, starts = st, status = "open", players = 0, max = 30 })
			worst = math.max(worst, st - t)
		end
		local joinable = 0
		for _, lb in list do
			if LobbyRules.joinable(lb, t) then
				joinable += 1
			end
		end
		if joinable == 0 then
			gaps += 1
		end
		-- every 3rd step the soonest joinable lobby is vote-started (leaves at once)
		if step % 3 == 0 then
			local soonest = nil
			for _, lb in list do
				if LobbyRules.joinable(lb, t) and (soonest == nil or lb.starts < soonest.starts) then
					soonest = lb
				end
			end
			if soonest then
				soonest.status = "started"
			end
		end
		t += 3 -- a hub refresh
	end
	expect(worst <= LobbyRules.LOBBY_OPEN_S, "vote starts in a row: no lobby scheduled past " .. LobbyRules.LOBBY_OPEN_S .. " s (worst " .. worst .. " s)")
	expect(gaps == 0, "always a joinable lobby (" .. gaps .. " refreshes without)")
end
local l =
	{ id = "x", map = "a", map_name = "A", max = 10, starts = now + 30, created = now, players = 10, status = "open" }
expect(not LobbyRules.joinable(l, now), "a full lobby is not joinable")
l.players = 3
expect(
	LobbyRules.joinable(l, now) and not LobbyRules.joinable(l, now + 30 - LobbyRules.JOIN_CLOSE_S),
	"joins close before the start"
)
local view = LobbyRules.public_view(l, now)
expect(view.code == nil and view.starts_in == 30 and view.players == 3, "public view hides the access code")
expect(
	LobbyRules.decode({ id = 1 }) == nil
		and LobbyRules.decode({ id = "q", map = "m", starts = 5, max = 999 }).max == 200,
	"decode rejects / clamps"
)

-- ---------------------------------------------------------------------------------------------
-- Directory: two hubs, one store
-- ---------------------------------------------------------------------------------------------
local clock = 5000
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
			return {
				{ id = "world", name = "World", weight = 3, land = 651569, k_lin = 1 },
				{ id = "pangaea", name = "Pangaea", weight = 1, land = 150000, k_lin = 1 },
			}
		end,
		now = tnow,
		rand = function()
			return 0.1
		end,
		new_id = (function()
			local n = 0
			return function()
				n += 1
				return "L" .. n
			end
		end)(),
	})
end
local hub1, hub2 = make_hub("hub1"), make_hub("hub2")
hub1:refresh()
hub2:refresh()
-- (the free-for-alls; World's own lobby is one more)
local function ffa_of(list)
	local out = {}
	for _, v in list do
		if v.mode == nil then
			table.insert(out, v)
		end
	end
	return out
end
local function world_of(list)
	local out = {}
	for _, v in list do
		if v.mode == "world" then
			table.insert(out, v)
		end
	end
	return out
end
expect(
	#store.list() == LobbyRules.TARGET_OPEN + 1,
	"the first hub creates the lobbies (and World's own), the second (lock held) doesn't duplicate"
)
expect(#hub2:view() == LobbyRules.TARGET_OPEN + 1, "both hubs list the same lobbies")
local worlds = world_of(hub1:view())
expect(#worlds == 1 and worlds[1].map == "world", "World's own lobby is open, on World")
local first = ffa_of(hub1:view())[1]
expect(first.map ~= nil and first.max == LobbyRules.max_players(if first.map == "world" then 651569 else 150000, 1), "lobby sized for its map")

local ok, msg = hub2:join("player1", first.id)
expect(
	ok and #sent == 1 and sent[1].code ~= nil and sent[1].data.lobby == first.id,
	"join teleports to the lobby's reserved server"
)
expect(store.get(first.id).players == 1, "join reserves a slot")
teleport_ok = false
ok, msg = hub1:join("player2", first.id)
expect(not ok and store.get(first.id).players == 1, "a failed teleport gives the slot back: " .. tostring(msg))
teleport_ok = true

-- the store refusing the reservation (hundreds joining at once): a few tries, then the join goes
-- ahead from this hub's list; a lobby it can't see stays an error
do
	local target = hub1:view()[1]
	local real_update = store.update
	local calls = 0
	store.update = function(...)
		calls += 1
		error("MemoryStoreService: Request was throttled")
	end
	local before = #sent
	local ok1, msg1 = hub1:join("flood1", target.id)
	store.update = real_update
	expect(ok1 and #sent == before + 1 and calls == LobbyDirectory.JOIN_TRIES, "store busy: retried, then joined from the list: " .. tostring(msg1))
	store.update = function()
		error("throttled")
	end
	local ok2, msg2 = hub1:join("flood2", "no-such-lobby")
	store.update = real_update
	expect(not ok2 and msg2 ~= nil, "an unknown lobby still fails: " .. tostring(msg2))
end

-- the store re-runs the update on a newer record (UpdateAsync under contention): a seat from the
-- run that lost the race doesn't count when the newer record is full
do
	local target = hub1:view()[1]
	local real_update = store.update
	store.update = function(id, fn)
		local rec = store.get(id)
		fn(table.clone(rec)) -- lost the race: someone else took the last seat meanwhile
		local full = table.clone(rec)
		full.players = full.max
		return fn(full)
	end
	local before = #sent
	local okr, msgr = hub1:join("racer", target.id)
	store.update = real_update
	expect(not okr and #sent == before, "a re-run that finds the lobby full seats nobody: " .. tostring(msgr))
end

-- a lobby whose joins closed (the last JOIN_CLOSE_S before its start) leaves the list
do
	local v1 = hub1:view()[1]
	local rec = store.get(v1.id)
	local saved = clock
	clock = rec.starts - LobbyRules.JOIN_CLOSE_S + 1
	hub1:refresh()
	local listed = false
	for _, v in hub1:view() do
		if v.id == v1.id then
			listed = true
		end
	end
	expect(not listed and #hub1:view() >= 1, "a starting (no longer joinable) lobby is hidden; the next is listed")
	clock = saved
	hub1:refresh()
end

-- lobbies filling at once are replaced at once (not LOBBY_INTERVAL_S after the full ones)
do
	local t = 50000
	local full = {
		{ id = "f1", starts = t + 40, status = "open", players = 30, max = 30 },
		{ id = "f2", starts = t + 85, status = "open", players = 30, max = 30 },
	}
	local nxt = LobbyRules.missing_starts(full, t)
	expect(#nxt == LobbyRules.TARGET_OPEN and nxt[1] == t + LobbyRules.MIN_LEAD_S, "full lobbies: new ones start in MIN_LEAD_S")
end

-- a lobby that fills up leaves the list (players go for the next one), and another is scheduled
do
	local second = ffa_of(hub1:view())[2]
	local rec = store.get(second.id)
	local players = rec.players
	rec.players = rec.max
	store.put(rec, 900)
	hub1:refresh()
	local listed = false
	for _, v in hub1:view() do
		if v.id == second.id then
			listed = true
		end
	end
	local open = 0
	for _, v in ffa_of(hub1:view()) do
		if not v.live and v.joinable then
			open += 1
		end
	end
	expect(not listed and open == LobbyRules.TARGET_OPEN, "a full lobby is hidden; a new one takes its place")
	rec.players = players
	store.put(rec, 900)
	hub1:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- MatchHost on the reserved server
-- ---------------------------------------------------------------------------------------------
local rec = store.get(first.id)
local host = MatchHost.new({
	store = store,
	psid = rec.psid,
	now = tnow,
	to_hub = function()
		return true
	end,
})
expect(host:lookup() and host.lobby.id == first.id, "the match server finds its lobby by PrivateServerId")
host:set_present(1)
host:_sync()
expect(store.get(first.id).players >= 1, "presence keeps the count")
local wait = host:starts_in()
expect(wait ~= nil and wait > 0, "counts down to the start")
clock = rec.starts + 1
expect(host:starts_in() == 0, "start time reached")
local bots = host:start(1)
expect(bots == rec.max - 1, "bot players fill every empty slot")
hub1:refresh()
local joinable_listed, live_listed = false, false
for _, v in hub1:view() do
	if v.id == first.id then
		joinable_listed = joinable_listed or v.joinable
		live_listed = live_listed or v.live
	end
end
expect(not joinable_listed and live_listed, "a started lobby leaves the joinable list and shows live (Watch)")
expect(#hub1:view() >= 1, "the hub tops the list back up")

-- stale lobbies nobody joined are removed
clock += 10000
hub1:refresh()
for _, v in store.list() do
	if v.status == "open" and v.starts < clock - LobbyDirectory.STALE_AFTER_S then
		expect(false, "stale lobby removed: " .. v.id)
	end
end

-- a hub refused the scheduler lock asks again only after LOCK_RETRY_S (8-16 s), not every refresh;
-- the holder renews at every refresh; once free, it is taken at the next due ask
do
	local held_by_other = true
	local asks = 0
	local s2 = setmetatable({}, { __index = LobbyStore.localstore(tnow) })
	s2.list = function()
		return {} -- (nothing open: this hub always wants lobbies made)
	end
	s2.lock = function(_n, _ttl)
		asks += 1
		return not held_by_other
	end
	local hub3 = LobbyDirectory.new({
		store = s2,
		teleport = {
			reserve = function()
				reserved += 1
				return "code" .. reserved, "psid" .. reserved
			end,
			send = function()
				return true
			end,
		},
		maps = function()
			return { { id = "world", name = "World", weight = 1, land = 651569, k_lin = 1 } }
		end,
		now = tnow,
		rand = function()
			return 0.1
		end,
		new_id = (function()
			local n = 0
			return function()
				n += 1
				return "B" .. n
			end
		end)(),
	})
	local t0 = clock
	for _ = 1, 20 do -- 60 s of refreshes, every REFRESH_S (3 s)
		hub3:refresh()
		clock += LobbyDirectory.REFRESH_S
	end
	local lo, hi = LobbyDirectory.LOCK_RETRY_S[1], LobbyDirectory.LOCK_RETRY_S[2]
	expect(
		asks >= math.floor(60 / (hi + LobbyDirectory.REFRESH_S)) and asks <= math.ceil(60 / lo) + 1,
		string.format("refused, a hub asks %d times in 60 s (every 8-16 s), not 20", asks)
	)
	-- the lock frees up: taken at the next due ask, at most LOCK_RETRY_S later
	held_by_other = false
	local freed = clock
	local got_at = nil
	asks = 0
	for _ = 1, 8 do
		local before = asks
		hub3:refresh()
		if got_at == nil and asks > before then
			got_at = clock
		end
		clock += LobbyDirectory.REFRESH_S
	end
	expect(got_at ~= nil and got_at - freed <= hi, "the free lock is taken within LOCK_RETRY_S")
	-- holding it, the hub renews at every refresh
	local renew_from = asks
	for _ = 1, 4 do
		hub3:refresh()
		clock += LobbyDirectory.REFRESH_S
	end
	expect(asks - renew_from == 4, "the holder renews at every refresh")
	clock = t0
end

print(if fails == 0 then "lobbies: all passed" else string.format("lobbies: %d FAILED", fails))
if fails > 0 then
	error("lobbies failed")
end
