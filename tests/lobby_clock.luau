-- Lobby times across servers whose clocks disagree: SharedClock measures a server's offset from the
-- backend (a DataStore write's UpdatedTime); hubs ignore lobbies written with a clock far ahead (they
-- were listed as "starts in 17:29"), a lock written by such a clock doesn't block everyone, and a
-- match server never waits past the longest a lobby can be scheduled ahead.
require("./prelude")
local SharedClock = require("../src/server/Lobbies/SharedClock")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local MatchHost = require("../src/server/Lobbies/MatchHost")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- SharedClock: this server's clock is 900 s behind the backend's
do
	local local_ms = 1000000000
	local keys = {}
	local ds = {
		UpdateAsync = function(_self, key, fn)
			keys[key] = true
			local v = fn(nil)
			-- the backend stamps the write 120 ms into a 240 ms call, 900 s ahead of the local clock
			return v, { UpdatedTime = local_ms + 120 + 900000 }
		end,
	}
	local calls = 0
	local ok = SharedClock.measure({
		datastore = ds,
		millis = function()
			calls += 1
			return if calls == 1 then local_ms else local_ms + 240
		end,
	})
	expect(ok and math.abs(SharedClock.offset - 900) < 0.01, "offset from the backend stamp: " .. SharedClock.offset)
	-- (the writes are spread over SharedClock.KEYS keys: one key takes a write every few seconds)
	for _ = 1, 40 do
		calls = 0
		SharedClock.measure({
			datastore = ds,
			millis = function()
				calls += 1
				return if calls == 1 then local_ms else local_ms + 240
			end,
		})
	end
	local n = 0
	for k in keys do
		n += 1
		expect(
			string.match(k, "^probe(%d+)$") ~= nil and tonumber(string.sub(k, 6)) <= SharedClock.KEYS,
			"a probe key: " .. k
		)
	end
	expect(n >= 20, "40 measurements wrote " .. n .. " different keys")
	expect(math.abs(SharedClock.now() - (os.time() + 900)) < 1, "now() = os.time() + offset")
	local slow = SharedClock.measure({
		datastore = ds,
		millis = (function()
			local n = 0
			return function()
				n += 1
				return if n == 1 then 0 else 10000
			end
		end)(),
	})
	expect(not slow, "a measurement with a 10 s round trip is not trusted")
	SharedClock.offset = 0
end

-- hubs: a lobby written 17 min ahead is ignored and a real one is scheduled
do
	local now = 50000
	local store = LobbyStore.localstore(function()
		return now
	end)
	store.put(
		{
			id = "BOGUS",
			map = "world",
			map_name = "World",
			max = 50,
			starts = now + 1049,
			created = now + 929,
			players = 3,
			status = "open",
			code = "c",
			psid = "p",
		},
		2000
	)
	local dir = LobbyDirectory.new({
		store = store,
		teleport = {
			reserve = function()
				return "code", "psid"
			end,
			send = function()
				return true
			end,
		},
		maps = function()
			-- (World is its own lobby's: the free-for-alls need another map, 2026-10-19)
			return {
				{ id = "world", name = "World", weight = 1, land = 651569, k_lin = 1 },
				{ id = "europe", name = "Europe", weight = 1, land = 400000, k_lin = 1 },
			}
		end,
		now = function()
			return now
		end,
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
	local view = dir:view()
	local worst = 0
	for _, v in view do
		expect(v.id ~= "BOGUS", "the far-future lobby is not listed")
		worst = math.max(worst, v.starts_in)
	end
	expect(
		-- (the free-for-alls and World's own lobby)
		#view == LobbyRules.TARGET_OPEN + LobbyRules.TARGETS_WITH_TEAMS.world and worst <= LobbyRules.MAX_AHEAD_S,
		"real lobbies scheduled, soonest first (" .. worst .. " s)"
	)
end

-- locks: one written by a clock 15 min fast doesn't block the others
do
	local now = 70000
	local store = LobbyStore.localstore(function()
		return now
	end)
	expect(store.lock("scheduler", 10, "a-hub"), "a hub takes the lock")
	expect(not store.lock("scheduler", 10, "other"), "a normal lease blocks the others")
end

-- the memory store's lock logic, driven with a fake sorted map
do
	local rows = {}
	local fake_map = {
		UpdateAsync = function(_self, key, fn)
			local new = fn(rows[key])
			if new ~= nil then
				rows[key] = new
			end
			return new
		end,
	}
	local real_now = 90000
	-- build two memory stores over the same fake map (the MemoryStoreService stub)
	local function mk(job: string, clock_ahead: number)
		local store = LobbyStore.memory_with(fake_map, fake_map, fake_map, job, function()
			return real_now + clock_ahead
		end)
		return store
	end
	local fast = mk("fast", 900)
	local normal = mk("normal", 0)
	expect(fast.lock("scheduler", 10), "the fast server takes the lock")
	expect(normal.lock("scheduler", 10), "a lock that claims to last 15 min is not honoured")
	expect(not mk("third", 0).lock("scheduler", 10), "a normal lease still blocks the others")
end

-- a match server never waits past MAX_AHEAD_S from when it found its lobby
do
	local now = 120000
	local store = LobbyStore.localstore(function()
		return now
	end)
	store.put(
		{
			id = "B2",
			map = "world",
			map_name = "World",
			max = 50,
			starts = now + 1049,
			created = now,
			players = 1,
			status = "open",
			code = "c",
			psid = "PS",
		},
		3000
	)
	store.bind_psid("PS", "B2", 3000)
	local host = MatchHost.new({
		store = store,
		psid = "PS",
		now = function()
			return now
		end,
		to_hub = function()
			return true
		end,
	})
	host:lookup()
	local wait = host:starts_in()
	expect(
		wait ~= nil and wait <= LobbyRules.MAX_AHEAD_S,
		"a far-future lobby starts within MAX_AHEAD_S (" .. tostring(wait) .. " s)"
	)
end

print(if fails == 0 then "lobby_clock: all passed" else string.format("lobby_clock: %d FAILED", fails))
if fails > 0 then
	error("lobby_clock failed")
end
