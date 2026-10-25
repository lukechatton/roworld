--!strict
-- Lobby storage for LobbyDirectory / MatchHost:
--   LobbyStore.memory()  the live game: MemoryStoreService (shared by every server of the
--                        experience) — a sorted map of lobby records (sort key = start time), a
--                        hash map PrivateServerId -> lobby id, and a sorted map of short locks;
--   LobbyStore.localstore() one process only (Lune tests, Studio when MemoryStore is unavailable).
-- Both expose: list(), get(id), put(lobby, ttl_s), update(id, fn), remove(id), lock(name, ttl_s),
-- bind_psid(psid, id, ttl_s), lobby_for_psid(psid), take(spec), release(id, uids). All MemoryStore
-- calls yield and may throw (callers pcall).
local LobbyRules = require("./LobbyRules")

local LobbyStore = {}

LobbyStore.NAMESPACE = "rofront_v1"
LobbyStore.LIST_LIMIT = 50

--- What a record is written as. A team game's record (and World's own kind's, 2026-10-19) keeps its
--- size as `slots`, not `max`: older servers decode only records with a numeric `max`, so while they
--- still run (a delayed restart) they leave those kinds alone (not listed, not counted, never
--- rewritten without their `mode`). LobbyRules.decode reads either.
function LobbyStore.encode(v: any): any
	if type(v) == "table" and (v.mode == "team" or v.mode == "world") and type(v.max) == "number" then
		local c = table.clone(v)
		c.slots = v.max
		c.max = nil
		return c
	end
	return v
end
local encode = LobbyStore.encode

--- `take` over `update` (stores that can't search: MemoryStore, the local store): the spec's
--- candidates in order (or its one `id`), the first that fits gets the seats. Returns the record.
local function take_via_update(store: any, spec: LobbyRules.TakeSpec): any
	local ids = if spec.id ~= nil then { spec.id } else (spec.candidates or {})
	for _, id in ids do
		local got: any = nil
		store.update(id, function(v: any): any?
			-- (UpdateAsync may run this again on a newer record: only the last run counts)
			got = nil
			local l = LobbyRules.decode(v)
			if l == nil or not LobbyRules.fits(l, spec) then
				return nil
			end
			got = LobbyRules.seated(l, spec)
			return got
		end)
		if got ~= nil then
			return got
		end
	end
	return nil
end

--- `release` over `update`: the record after, and how many seats went back.
local function release_via_update(store: any, id: string, uids: { string }): (any, number)
	local n = 0
	local after: any = nil
	store.update(id, function(v: any): any?
		n = 0
		local l = LobbyRules.decode(v)
		if l == nil then
			return nil
		end
		local c, k = LobbyRules.released(l, uids)
		after = c
		n = k
		return if k > 0 then c else nil
	end)
	return after, n
end

--- MemoryStoreService-backed store (live servers).
--- `now`: the shared clock (SharedClock.now) — lock expiry times are compared across servers.
function LobbyStore.memory(job_id: string, now: (() -> number)?)
	local MSS = game:GetService("MemoryStoreService")
	return LobbyStore.memory_with(
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_lobbies"),
		MSS:GetHashMap(LobbyStore.NAMESPACE .. "_psid"),
		MSS:GetSortedMap(LobbyStore.NAMESPACE .. "_locks"),
		job_id,
		now
	)
end

--- The memory store over given maps (tests pass fakes).
function LobbyStore.memory_with(lobbies: any, psids: any, locks: any, job_id: string, now: (() -> number)?)
	local clock = now or os.time
	local store = {}

	--- Both ends of the start-time order: the oldest records (running matches) and the newest (the
	--- open lobbies), so many live matches never push the open lobbies off the list.
	function store.list(): { any }
		local out = {}
		local seen = {}
		for _, dir in { Enum.SortDirection.Ascending, Enum.SortDirection.Descending } do
			local items = lobbies:GetRangeAsync(dir, LobbyStore.LIST_LIMIT)
			for _, it in items do
				if not seen[it.key] then
					seen[it.key] = true
					table.insert(out, it.value)
				end
			end
		end
		return out
	end

	function store.get(id: string): any
		return (lobbies:GetAsync(id))
	end

	function store.put(l: any, ttl_s: number)
		lobbies:SetAsync(l.id, encode(l), math.floor(ttl_s), l.starts)
	end

	--- Atomic read-modify-write; `fn` returns the new record or nil (leave unchanged).
	function store.update(id: string, fn: (any) -> any): any
		return lobbies:UpdateAsync(id, function(old: any, _sort: any): (any, any)
			local new = fn(old)
			if new == nil then
				return nil
			end
			return encode(new), new.starts
		end, 15 * 60)
	end

	function store.remove(id: string)
		lobbies:RemoveAsync(id)
	end

	--- A short lease: true when this server holds `name` now.
	function store.lock(name: string, ttl_s: number): boolean
		local got = false
		local now = clock()
		locks:UpdateAsync(name, function(old: any): any
			local exp = if type(old) == "table" then (tonumber(old.exp) or 0) else 0
			-- held, unless it claims to last far longer than any lease (a wrong clock wrote it)
			if type(old) == "table" and old.owner ~= job_id and exp > now and exp <= now + ttl_s + 60 then
				return nil
			end
			got = true
			return { owner = job_id, exp = now + ttl_s }
		end, ttl_s + 5)
		return got
	end

	function store.bind_psid(psid: string, id: string, ttl_s: number)
		psids:SetAsync(psid, id, math.floor(ttl_s))
	end

	function store.lobby_for_psid(psid: string): any
		local id = psids:GetAsync(psid)
		if type(id) ~= "string" then
			return nil
		end
		return (lobbies:GetAsync(id))
	end

	function store.take(spec: LobbyRules.TakeSpec): any
		return take_via_update(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return release_via_update(store, id, uids)
	end

	return store
end

--- update() tries at most this many compare-and-sets (each conflict reply carries the current row,
--- so a retry costs one round trip).
LobbyStore.CAS_TRIES = 12
--- An update keeps the record this long (as UpdateAsync's expiration did in the memory store).
LobbyStore.UPDATE_TTL_S = 15 * 60
--- Running matches a list from the service carries (the latest started), with every open lobby: a
--- hub shows a few running matches and needs the latest maps, not every match of the last 15
--- minutes (2026-10-11: 250 records to each of ~530 hubs every 3 s).
LobbyStore.LIST_LIVE = 64

--- The lobby service on easy-1 (LobbyHttp client; docs/lobby-service.md): the same API over signed
--- HTTP, so hundreds of servers reading the list every few seconds don't hit MemoryStore's
--- per-partition limits. `role` ("hub" | "match") only labels the caller in the service's health.
--- `store.enabled` is the service's LOBBIES switch from the last list.
--- `presence` (hubs): who on this server is doing what (Analytics.presence), sent with every list for
--- the service's live stats page.
function LobbyStore.http(client: any, role: string?, wait: ((number) -> ())?, presence: (() -> any)?)
	local store = {}
	store.enabled = true
	local tl = task :: any -- (nil under plain Luau)
	local pause = wait or (if tl ~= nil then tl.wait else nil)

	local function call(path: string, body: { [string]: any }): any
		body.role = role
		local r, err = client:post(path, body)
		if r == nil then
			error("lobby service: " .. tostring(err), 0)
		end
		if r.ok ~= true and r.err ~= "conflict" then
			error("lobby service: " .. tostring(r.err), 0)
		end
		return r
	end

	local function value(r: any): any
		return if type(r.value) == "table" then r.value else nil
	end

	function store.list(): { any }
		local body = {}
		if presence ~= nil then
			local ok, p = pcall(presence)
			if ok and type(p) == "table" then
				body.presence = p
			end
		end
		body.live = LobbyStore.LIST_LIVE
		local r = call("/v1/lobbies/list", body)
		store.enabled = r.enabled ~= false
		local out = {}
		for _, it in (if type(r.items) == "table" then r.items else {}) do
			if type(it) == "table" and type(it.value) == "table" then
				table.insert(out, it.value)
			end
		end
		return out
	end

	function store.get(id: string): any
		return value(call("/v1/lobbies/get", { id = id }))
	end

	function store.put(l: any, ttl_s: number)
		call("/v1/lobbies/put", { id = l.id, value = encode(l), sort = l.starts, ttl = math.floor(ttl_s) })
	end

	--- Read, apply `fn`, write if nobody wrote in between (else `fn` again on the row the conflict
	--- reply carries). `fn` returns the new record or nil (leave unchanged), as UpdateAsync's.
	function store.update(id: string, fn: (any) -> any): any
		local r = call("/v1/lobbies/get", { id = id })
		for attempt = 1, LobbyStore.CAS_TRIES do
			if attempt > 2 and pause ~= nil then
				-- many servers writing one lobby (a flood of joins): spread the retries out
				pause(math.random() * 0.03 * attempt)
			end
			local new = fn(value(r))
			if new == nil then
				return nil
			end
			local w = call("/v1/lobbies/cas", {
				id = id,
				expect = tonumber(r.version) or 0,
				value = encode(new),
				sort = new.starts,
				ttl = LobbyStore.UPDATE_TTL_S,
			})
			if w.ok == true then
				return new
			end
			r = w
		end
		error("lobby service: busy (" .. id .. ")", 0)
	end

	function store.remove(id: string)
		call("/v1/lobbies/remove", { id = id })
	end

	function store.lock(name: string, ttl_s: number): boolean
		return call("/v1/locks/acquire", { name = name, ttl = ttl_s }).got == true
	end

	function store.bind_psid(psid: string, id: string, ttl_s: number)
		call("/v1/psid/bind", { psid = psid, id = id, ttl = math.floor(ttl_s) })
	end

	function store.lobby_for_psid(psid: string): any
		return value(call("/v1/psid/lookup", { psid = psid }))
	end

	--- Seats in one step: the service picks the soonest lobby that fits (LobbyRules.TakeSpec) and
	--- writes the seats at once (no read, no conflicts). The record, or nil when none has room.
	function store.take(spec: LobbyRules.TakeSpec): any
		return value(call("/v1/lobbies/take", {
			mode = spec.mode,
			-- (the kinds it takes: a free-for-all join takes World's lobbies too; a service from before
			-- 2026-10-19 reads only `mode`)
			modes = spec.modes,
			n = spec.n,
			uids = spec.uids,
			at = spec.at,
			closeBefore = spec.close_before,
			startBefore = spec.start_before,
			id = spec.id,
		}))
	end

	function store.release(id: string, uids: { string }): (any, number)
		local r = call("/v1/lobbies/release", { id = id, uids = uids })
		return value(r), tonumber(r.released) or 0
	end

	return store
end

--- Two stores as one: `primary` (the lobby service) while it answers and is switched on, else
--- `fallback` (MemoryStore). A lobby stays in the store it was listed from or written to, so a
--- match server keeps updating the store its lobby lives in whichever one hubs use now.
--- A failed list while the service still counts as healthy (a blip) fails the refresh (the hub
--- keeps its cached list) instead of switching: only a down (or switched off) service moves hubs
--- to MemoryStore, and they try the service again every PROBE_S.
---   deps = { healthy = function() -> boolean, clock = function() -> number, log = function(text)? }
LobbyStore.PROBE_S = 15
function LobbyStore.failover(primary: any, fallback: any, deps: { [string]: any })
	local clock = deps.clock or os.clock
	local home: { [string]: any } = {}
	local on_primary = true
	local retry_at = 0.0
	local store = {}

	local function switch(to_primary: boolean, why: string)
		if on_primary ~= to_primary then
			on_primary = to_primary
			if deps.log then
				deps.log(
					if to_primary
						then "[Lobbies] using the lobby service"
						else "[Lobbies] using MemoryStore (" .. why .. ")"
				)
			end
		end
		if not to_primary then
			retry_at = clock() + LobbyStore.PROBE_S
		end
	end

	local function active(): any
		return if on_primary then primary else fallback
	end

	local function mark(list: { any }, s: any)
		for _, v in list do
			if type(v) == "table" and type(v.id) == "string" then
				home[v.id] = s
			end
		end
	end

	--- Which store is in use now ("service" | "memory"), for logs and diagnostics.
	function store.backend(): string
		return if on_primary then "service" else "memory"
	end

	--- On MemoryStore: is the service back? Checked in its own thread where there is one (Roblox), so a
	--- service that doesn't answer never holds up the refresh; inline otherwise (Lune tests).
	local probing = false
	local probe_ok = false
	local function probe()
		local ok, list = pcall(primary.list)
		probe_ok = ok and primary.enabled ~= false and type(list) == "table"
		probing = false
		if not probe_ok then
			retry_at = clock() + LobbyStore.PROBE_S
		end
	end

	function store.list(): { any }
		if not on_primary and not probing and clock() >= retry_at then
			probing = true
			local tl = task :: any -- (nil under plain Luau)
			if deps.spawn then
				deps.spawn(probe)
			elseif tl ~= nil then
				tl.spawn(probe)
			else
				probe()
			end
		end
		if on_primary or probe_ok then
			probe_ok = false
			local ok, list = pcall(primary.list)
			if ok then
				if primary.enabled == false then
					switch(false, "switched off on the service")
				else
					switch(true, "")
					mark(list, primary)
					return list
				end
			elseif on_primary and deps.healthy() then
				error(list, 0)
			else
				switch(false, tostring(list))
			end
		end
		local list = fallback.list()
		mark(list, fallback)
		return list
	end

	function store.get(id: string): any
		return (home[id] or active()).get(id)
	end

	function store.put(l: any, ttl_s: number)
		local s = active()
		s.put(l, ttl_s)
		home[l.id] = s
	end

	function store.update(id: string, fn: (any) -> any): any
		return (home[id] or active()).update(id, fn)
	end

	function store.remove(id: string)
		local s = home[id] or active()
		home[id] = nil
		s.remove(id)
	end

	function store.lock(name: string, ttl_s: number): boolean
		return active().lock(name, ttl_s)
	end

	function store.bind_psid(psid: string, id: string, ttl_s: number)
		local s = home[id] or active()
		s.bind_psid(psid, id, ttl_s)
	end

	--- Seats from the store in use (a lobby the service seats in lives there).
	function store.take(spec: LobbyRules.TakeSpec): any
		local s = if spec.id ~= nil then (home[spec.id] or active()) else active()
		local v = s.take(spec)
		if type(v) == "table" and type(v.id) == "string" then
			home[v.id] = s
		end
		return v
	end

	function store.release(id: string, uids: { string }): (any, number)
		return (home[id] or active()).release(id, uids)
	end

	--- A match server finds its lobby in whichever store the hub that made it used.
	function store.lobby_for_psid(psid: string): any
		local ok, v = pcall(primary.lobby_for_psid, psid)
		if ok and type(v) == "table" then
			home[v.id] = primary
			return v
		end
		local fv = fallback.lobby_for_psid(psid)
		if type(fv) == "table" and type(fv.id) == "string" then
			home[fv.id] = fallback
		end
		return fv
	end

	return store
end

--- In-process store with the same API (no expiry handling beyond the TTL timestamps).
function LobbyStore.localstore(now: (() -> number)?)
	local clock = now or os.time
	local rows: { [string]: { value: any, exp: number } } = {}
	local psid_rows: { [string]: string } = {}
	local lock_rows: { [string]: { owner: string, exp: number } } = {}
	local store = {}

	local function live(id: string): any
		local r = rows[id]
		if r == nil then
			return nil
		end
		if r.exp <= clock() then
			rows[id] = nil
			return nil
		end
		return table.clone(r.value)
	end

	function store.list(): { any }
		local out = {}
		for id in rows do
			local v = live(id)
			if v ~= nil then
				table.insert(out, v)
			end
		end
		table.sort(out, function(a, b)
			return a.starts < b.starts
		end)
		return out
	end

	function store.get(id: string): any
		return live(id)
	end

	function store.put(l: any, ttl_s: number)
		rows[l.id] = { value = table.clone(encode(l)), exp = clock() + ttl_s }
	end

	function store.update(id: string, fn: (any) -> any): any
		local new = fn(live(id))
		if new == nil then
			return nil
		end
		local exp = if rows[id] then rows[id].exp else clock() + 15 * 60
		rows[id] = { value = table.clone(encode(new)), exp = exp }
		return new
	end

	function store.remove(id: string)
		rows[id] = nil
	end

	function store.lock(name: string, ttl_s: number, owner: string?): boolean
		local who = owner or "local"
		local r = lock_rows[name]
		local t = clock()
		if r ~= nil and r.owner ~= who and r.exp > t and r.exp <= t + ttl_s + 60 then
			return false
		end
		lock_rows[name] = { owner = who, exp = clock() + ttl_s }
		return true
	end

	function store.bind_psid(psid: string, id: string, _ttl_s: number)
		psid_rows[psid] = id
	end

	function store.lobby_for_psid(psid: string): any
		local id = psid_rows[psid]
		return if id then live(id) else nil
	end

	function store.take(spec: LobbyRules.TakeSpec): any
		if spec.id == nil and spec.candidates == nil then
			-- (one process: the local store can search, as the service does)
			local ids = {}
			for _, v in store.list() do
				table.insert(ids, v.id)
			end
			spec = table.clone(spec)
			spec.candidates = ids
		end
		return take_via_update(store, spec)
	end

	function store.release(id: string, uids: { string }): (any, number)
		return release_via_update(store, id, uids)
	end

	return store
end

return LobbyStore
