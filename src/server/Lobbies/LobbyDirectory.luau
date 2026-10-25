--!strict
-- The public-lobby directory on a hub server (a public server of the place): keeps the game-wide
-- list of open lobbies fresh, creates new ones when too few are open (one hub at a time, elected by
-- a short store lock), shows them to its players and sends joiners to the lobby's reserved server.
-- Every hub reads the same store, so all players across the game see the same lobbies.
--
--   deps = {
--     store = {                                -- LobbyStore (the lobby service / MemoryStore live)
--       list = function() -> { any },          -- lobby records, earliest start first
--       put = function(lobby, ttl_s),
--       update = function(id, fn(any?) -> any?) -> any?,   -- atomic; fn returns nil to abort
--       remove = function(id),
--       lock = function(name, ttl_s) -> boolean,
--       bind_psid = function(psid, id, ttl_s),
--       take = function(LobbyRules.TakeSpec) -> any?,     -- seats in the soonest lobby that fits
--       release = function(id, uids) -> (any?, number),   -- seats given back
--     },
--     teleport = {
--       reserve = function() -> (code, psid),  -- a new reserved server
--       send = function(players, code, data) -> (ok, err?),
--     },
--     maps = function() -> { { id, name, weight, land, k_lin } },
--     now = function() -> number,              -- os.time() seconds (shared by all servers)
--     rand = function() -> number,             -- [0, 1)
--     new_id = function() -> string,
--     log = function(text)?,
--     team_games = boolean?,                   -- also keep a team game open (staging only for now)
--     server_size = function() -> number?,     -- most players a server holds (Players.MaxPlayers; seats cap)
--     uid_of = function(player) -> string?,    -- a player's user id (default: tostring(player.UserId))
--   }
local LobbyRules = require("./LobbyRules")

local LobbyDirectory = {}
LobbyDirectory.__index = LobbyDirectory

LobbyDirectory.REFRESH_S = 3.0
LobbyDirectory.LOCK_TTL_S = 10
--- A hub refused the "scheduler" lock asks again only after a random wait in this range (seconds),
--- not at every refresh. With ~700 hubs at 23,000 players they asked ~150 times a second, a third of
--- the lobby service's requests (2026-10-21; its one core at 54%). The holder renews at every refresh
--- as before, and the service hands the lock on after 20 s (LOCK_MAX_HOLD_S), so with hundreds of hubs
--- asking every 8-16 s the next one takes it within a fraction of a second.
LobbyDirectory.LOCK_RETRY_S = { 8.0, 16.0 }
--- Open lobbies whose start passed this long ago without a match server marking them started had
--- nobody join: they are removed.
LobbyDirectory.STALE_AFTER_S = 30
--- Tries at reserving a slot before joining without one (join).
LobbyDirectory.JOIN_TRIES = 3
--- join_public's reason when no lobby of the kind has room now (the caller puts the player in line).
LobbyDirectory.NO_ROOM = "no room"
--- join_public's reason when the store can't be reached and the hub's list has no room either.
LobbyDirectory.UNREACHABLE = "Couldn't reach the lobby list. Try again in a moment."
--- Players in line (Quick Play) are tried again this often...
LobbyDirectory.QUEUE_RETRY_S = 1.0
--- ...this many at most each time (store calls: a server may make 500 HTTP requests a minute)...
LobbyDirectory.QUEUE_BATCH = 4
--- ...and wait this long at most.
LobbyDirectory.QUEUE_MAX_S = 120

--- Someone waiting in line for a seat: `key` (one per player or party leader), `mode`, `since`;
--- `members()` -> (the players to seat, the party data for join) or nil when they no longer can go
--- (left, started a solo match); `done(ok, reason, lobby, players)` once they are seated (the players
--- sent) or out of the line.
export type QueueEntry = {
	key: string,
	mode: string,
	since: number,
	members: () -> ({ any }?, { [string]: any }?),
	done: (boolean, string?, LobbyRules.Lobby?, { any }?) -> (),
}

function LobbyDirectory.new(deps: { [string]: any })
	local self = setmetatable({}, LobbyDirectory)
	self.deps = deps
	self._lobbies = {} :: { LobbyRules.Lobby }
	self._refresh_in = 0.0
	self._recent = {} :: { string }
	self._busy = false
	self._queue = {} :: { QueueEntry }
	self._queue_in = 0.0
	self._queue_busy = false
	--- deps.now() before which this hub doesn't ask for the scheduler lock again (it was refused)
	self._lock_retry_at = -math.huge
	--- the demand per kind at the last refresh (LobbyRules.demand), for diagnostics
	self.demand = {} :: { [string]: LobbyRules.Demand }
	return self
end

function LobbyDirectory._log(self: any, text: string)
	local log = self.deps.log
	if log then
		log("[Lobbies] " .. text)
	end
end

--- The cached lobbies (refreshed every REFRESH_S by tick).
function LobbyDirectory.lobbies(self: any): { LobbyRules.Lobby }
	return self._lobbies
end

--- What clients see: open lobbies that can still be joined (earliest first; a full one, or one whose
--- joins closed JOIN_CLOSE_S before its start, is hidden so players go for the next — missing_starts
--- has already scheduled one; since 2026-09-28 a match in its starting phase isn't listed, as it can't
--- be joined), then up to MAX_LIVE_LISTED running matches to watch (most players first).
function LobbyDirectory.view(self: any): { any }
	local now = self.deps.now()
	local out = {}
	local live = {}
	for _, l in self._lobbies do
		if l.status == "open" and l.starts > now then
			if LobbyRules.joinable(l, now) then
				table.insert(out, LobbyRules.public_view(l, now))
			end
		elseif LobbyRules.watchable(l, now) then
			table.insert(live, l)
		end
	end
	table.sort(live, function(a, b)
		if a.players ~= b.players then
			return a.players > b.players
		end
		return a.starts > b.starts
	end)
	for i = 1, math.min(#live, LobbyRules.MAX_LIVE_LISTED) do
		table.insert(out, LobbyRules.public_view(live[i], now))
	end
	return out
end

--- Teleport `player` to a running match as a spectator (no slot is taken).
function LobbyDirectory.spectate(self: any, player: any, id: string): (boolean, string?)
	local deps = self.deps
	local ok, v = pcall(deps.store.get, id)
	local l = if ok then LobbyRules.decode(v) else nil
	if l == nil or not LobbyRules.watchable(l, deps.now()) then
		return false, "That match has ended."
	end
	local sent, terr = deps.teleport.send({ player }, l.code, { lobby = l.id, map = l.map, spectate = true })
	if not sent then
		return false, terr or "The teleport failed. Try again."
	end
	return true, nil
end

--- Per-frame: refresh the list and top it up now and then. Store calls yield, so the refresh runs in
--- its own thread; `spawn` (task.spawn on Roblox) is injectable for tests.
function LobbyDirectory.tick(self: any, dt: number, spawn: ((() -> ()) -> ())?)
	self._refresh_in -= dt
	if self._refresh_in > 0 or self._busy then
		return
	end
	self._refresh_in = LobbyDirectory.REFRESH_S
	self._busy = true
	local run = function()
		local ok, err = pcall(self.refresh, self)
		if not ok then
			self:_log("refresh failed: " .. tostring(err))
		end
		self._busy = false
	end
	if spawn then
		spawn(run)
	else
		run()
	end
end

--- Read the store, drop stale lobbies, create missing ones (when this hub holds the lock).
function LobbyDirectory.refresh(self: any)
	local deps = self.deps
	local now = deps.now()
	local list: { LobbyRules.Lobby } = {}
	for _, v in deps.store.list() do
		local l = LobbyRules.decode(v)
		if l == nil then
			continue
		end
		if l.status == "open" and l.starts < now - LobbyDirectory.STALE_AFTER_S then
			-- nobody joined before the start: gone
			pcall(deps.store.remove, l.id)
			continue
		end
		if l.status == "open" and not LobbyRules.plausible(l, now) then
			-- written with a wrong clock (a server whose clock ran fast): not listed, not counted
			continue
		end
		table.insert(list, l)
	end
	table.sort(list, function(a, b)
		return a.starts < b.starts
	end)
	self._lobbies = list
	-- the demand per kind: the seats of the lobbies made lately (the list from the service holds only
	-- the latest running matches, so it covers since the oldest record in it at most)
	local oldest = now
	for _, l in list do
		oldest = math.min(oldest, l.created)
	end
	local window = math.min(LobbyRules.DEMAND_WINDOW_S, now - oldest)
	local kinds = LobbyRules.kinds(deps.team_games)
	for _, k in kinds do
		self.demand[k.mode] = LobbyRules.demand(list, now, k.mode, window)
	end
	local want = {}
	-- the free-for-alls' starts, made and about to be: World's keep clear of them (WORLD_STAGGER_S), so
	-- PUBLIC MATCH, which takes World's seats too, finds World's lobby the soonest about half the time
	local ffa_starts = {}
	for _, l in list do
		if LobbyRules.mode_of(l) == LobbyRules.MODE_FFA and l.status == "open" and l.starts > now then
			table.insert(ffa_starts, l.starts)
		end
	end
	for _, k in kinds do
		-- (without team games the free-for-all keeps its old schedule: no `mode`, TARGET_OPEN)
		local plain = k.mode == LobbyRules.MODE_FFA and not deps.team_games
		local mode = if plain then nil else k.mode
		local avoid = nil
		if k.mode == LobbyRules.MODE_WORLD then
			table.sort(ffa_starts)
			avoid = ffa_starts
		end
		for _, starts in
			LobbyRules.missing_starts(list, now, mode, if plain then nil else k.target, self.demand[k.mode], avoid)
		do
			table.insert(want, { starts, k.mode })
			if k.mode == LobbyRules.MODE_FFA then
				table.insert(ffa_starts, starts)
			end
		end
	end
	if #want > 0 and now >= self._lock_retry_at then
		if deps.store.lock("scheduler", LobbyDirectory.LOCK_TTL_S) then
			self._lock_retry_at = -math.huge
			for _, w in want do
				local ok, l = pcall(self.create, self, w[1], w[2])
				if ok and l ~= nil then
					table.insert(self._lobbies, l)
				elseif not ok then
					self:_log("create failed: " .. tostring(l))
				end
			end
		else
			-- another hub has it (or this one's turn just ended): it makes the lobbies meanwhile
			local r = LobbyDirectory.LOCK_RETRY_S
			self._lock_retry_at = now + r[1] + math.random() * (r[2] - r[1])
		end
	end
end

--- Create one lobby starting at `starts` (a reserved server + a store record); `mode`:
--- LobbyRules.MODE_TEAM for a team game (team playlist and team sizes), MODE_WORLD for
--- World's own free-for-all (that map only).
function LobbyDirectory.create(self: any, starts: number, mode: string?): LobbyRules.Lobby?
	local deps = self.deps
	local maps = deps.maps()
	local team = mode == LobbyRules.MODE_TEAM
	local world = mode == LobbyRules.MODE_WORLD
	local weights = if world
		then { { id = LobbyRules.WORLD_ID, weight = 1 } }
		elseif team then LobbyRules.team_weights(maps)
		else LobbyRules.public_weights(maps)
	-- the maps of the latest lobbies of this kind game-wide (every hub reads the same list; this
	-- hub's own memory only while the list is empty), newest first
	local latest = {}
	for _, l in self._lobbies do
		if LobbyRules.mode_of(l) == (mode or LobbyRules.MODE_FFA) then
			table.insert(latest, l)
		end
	end
	table.sort(latest, function(a, b)
		return a.starts > b.starts
	end)
	local recent = {}
	for _, l in latest do
		if #recent >= LobbyRules.RECENT_MAPS then
			break
		end
		table.insert(recent, l.map)
	end
	if #recent == 0 and not team and not world then
		recent = self._recent
	end
	local map_id = if world then LobbyRules.WORLD_ID else LobbyRules.pick_map(weights, recent, deps.rand())
	if map_id == nil then
		return nil
	end
	local info
	for _, m in maps do
		if m.id == map_id then
			info = m
			break
		end
	end
	if not world then
		table.insert(self._recent, 1, map_id)
		while #self._recent > LobbyRules.RECENT_MAPS do
			table.remove(self._recent)
		end
	end
	-- (never more seats than a server of the place holds: deps.server_size, Players.MaxPlayers)
	local max = LobbyRules.max_players(
		if info then info.land else nil,
		if info then info.k_lin else nil,
		if type(deps.server_size) == "function" then deps.server_size() else nil
	)
	local teams = nil
	if team then
		max, teams = LobbyRules.team_slots(max, LobbyRules.team_config(map_id, deps.rand(), deps.rand()))
	end
	local code, psid = deps.teleport.reserve()
	local now = deps.now()
	local l: LobbyRules.Lobby = {
		id = deps.new_id(),
		map = map_id,
		map_name = if info then info.name else map_id,
		max = max,
		starts = starts,
		created = now,
		players = 0,
		status = "open",
		code = code,
		psid = psid,
		mode = if team then LobbyRules.MODE_TEAM elseif world then LobbyRules.MODE_WORLD else nil,
		teams = teams,
	}
	local ttl = math.max(60, starts - now + LobbyRules.RECORD_TTL_AFTER_START_S)
	deps.store.put(l, ttl)
	if psid ~= nil then
		deps.store.bind_psid(psid, l.id, ttl)
	end
	self:_log(
		string.format(
			"created %s on %s (%d players%s) starting in %ds",
			l.id,
			l.map,
			l.max,
			if team then ", " .. tostring(teams) .. " teams" else "",
			starts - now
		)
	)
	return l
end

--- Send `player` to lobby `id`: reserve a slot (atomic), then teleport. Returns ok, message.
--- Yields (store + teleport).
function LobbyDirectory.join(self: any, player: any, id: string, party: { [string]: any }?): (boolean, string?)
	local deps = self.deps
	local reserved: LobbyRules.Lobby? = nil
	-- a party (Party.luau): `party.players` go together, a seat each, in one teleport; the match
	-- server reads `party` from the teleport data (who came together: one team in a team game)
	local players = if party ~= nil and type(party.players) == "table" then party.players else { player }
	local n = math.max(1, #players)
	-- a slot is reserved in the lobby's record; with hundreds joining one lobby from many hubs the
	-- store refuses some updates, so: a few tries with a random pause, then (the store still busy)
	-- go anyway when this hub's copy of the list has room — the match server seats up to
	-- MatchServer.MP_MAX_HUMANS and its presence count corrects the record
	local ok, err = false, nil
	for attempt = 1, LobbyDirectory.JOIN_TRIES do
		reserved = nil
		ok, err = pcall(function()
			deps.store.update(id, function(v: any): any?
				-- the store may run this again on a newer record (a write in between: UpdateAsync
				-- and the lobby service both retry), so only the last run's seat counts — a seat from
				-- a run that lost the race and then found the lobby full is no seat
				reserved = nil
				local l = LobbyRules.decode(v)
				if l == nil or not LobbyRules.joinable(l, deps.now()) or l.players + n > l.max then
					return nil
				end
				l.players += n
				reserved = l
				return l
			end)
		end)
		if ok then
			break
		end
		if attempt < LobbyDirectory.JOIN_TRIES then
			local tl = task :: any -- (nil under Lune)
			local wait = deps.wait or (if tl ~= nil then tl.wait else nil)
			if wait then
				wait(0.15 + (deps.rand and deps.rand() or math.random()) * 0.4 * attempt)
			end
		end
	end
	if not ok then
		local mine = nil
		for _, c in self._lobbies do
			if c.id == id then
				mine = c
			end
		end
		if mine == nil or mine.code == nil or not LobbyRules.joinable(mine, deps.now()) or mine.players + n > mine.max then
			self:_log("join failed: " .. tostring(err))
			return false, "Couldn't reach the lobby list. Try again in a moment."
		end
		self:_log("join without a reservation (store busy): " .. tostring(err))
		mine.players += n
		reserved = table.clone(mine)
	end
	local l = reserved
	if l == nil or l.code == nil then
		return false, if n > 1 then "That match has no room for your whole party." else "That match is full or already starting."
	end
	local data: { [string]: any } = { lobby = l.id, map = l.map }
	if n > 1 and party ~= nil then
		data.party = { key = party.key, uids = party.uids, leader = party.leader }
	end
	local sent, terr = deps.teleport.send(players, l.code, data)
	if not sent then
		-- give the slot back (the one reserved in the store; a join without one only counted it here)
		if not ok then
			return false, terr or "The teleport failed. Try again."
		end
		pcall(deps.store.update, id, function(v: any): any?
			local lb = LobbyRules.decode(v)
			if lb == nil then
				return nil
			end
			lb.players = math.max(0, lb.players - n)
			return lb
		end)
		return false, terr or "The teleport failed. Try again."
	end
	-- mirror the reservation locally so the list shows it at once
	for _, c in self._lobbies do
		if c.id == l.id then
			c.players = l.players
		end
	end
	return true, nil
end

-- ---------------------------------------------------------------------------------------------
-- Quick Play (2026-10-11): a seat in the soonest public match of a kind, or a place in line
-- ---------------------------------------------------------------------------------------------

function LobbyDirectory._uid(self: any, p: any): string
	local f = self.deps.uid_of
	if f ~= nil then
		local u = f(p)
		if u ~= nil then
			return u
		end
	end
	local ok, u = pcall(function()
		return p.UserId
	end)
	return if ok and u ~= nil then tostring(u) else tostring(p)
end

--- This hub's open lobbies a join of `mode` may take (LobbyRules.takes_from: a free-for-all join takes
--- World's too) that still take joins, soonest first (what a store that can't search tries in turn,
--- and where to go while the store is unreachable).
function LobbyDirectory._open_of(self: any, mode: string, now: number): { LobbyRules.Lobby }
	local out = {}
	local kinds = LobbyRules.takes_from(mode)
	for _, l in self._lobbies do
		if
			l.status == "open"
			and table.find(kinds, LobbyRules.mode_of(l)) ~= nil
			and l.starts > now + LobbyRules.JOIN_CLOSE_S
			and LobbyRules.plausible(l, now)
		then
			table.insert(out, l)
		end
	end
	-- (a tie: its own kind first, so PUBLIC MATCH plays World only when World's lobby is sooner)
	table.sort(out, function(a, b)
		if a.starts ~= b.starts then
			return a.starts < b.starts
		end
		return LobbyRules.mode_of(a) == mode and LobbyRules.mode_of(b) ~= mode
	end)
	return out
end

--- Seats `players` (one player, or a party: `opts.party` = { key, uids, leader } as in join) in the
--- soonest public match of `mode` (or one it takes from: LobbyRules.takes_from) with room for all of them, in one store step, and sends them
--- there (yields). `opts.id`: only that lobby; `opts.wanted()`: checked before the teleport (false:
--- the seats go back). Returns ok, reason, lobby: reason NO_ROOM when no lobby has room now.
function LobbyDirectory.join_public(self: any, players: { any }, mode: string, opts: { [string]: any }?): (boolean, string?, LobbyRules.Lobby?)
	local deps = self.deps
	local o: { [string]: any } = opts or {}
	local n = math.max(1, #players)
	local uids = {}
	for _, p in players do
		table.insert(uids, self:_uid(p))
	end
	local now = deps.now()
	local spec = LobbyRules.take_spec(mode, n, uids, now, o.id)
	local open = self:_open_of(mode, now)
	local ids = {}
	for _, l in open do
		table.insert(ids, l.id)
	end
	spec.candidates = ids
	local ok, v = false, nil
	for attempt = 1, LobbyDirectory.JOIN_TRIES do
		ok, v = pcall(deps.store.take, spec)
		if ok then
			break
		end
		if attempt < LobbyDirectory.JOIN_TRIES then
			local tl = task :: any -- (nil under Lune)
			local wait = deps.wait or (if tl ~= nil then tl.wait else nil)
			if wait then
				wait(0.15 + (deps.rand and deps.rand() or math.random()) * 0.4 * attempt)
			end
		end
	end
	local l: LobbyRules.Lobby? = nil
	if ok then
		l = LobbyRules.decode(v)
		if l == nil then
			return false, LobbyDirectory.NO_ROOM, nil
		end
	else
		-- the store unreachable: the soonest lobby with room in this hub's copy of the list (the match
		-- server seats up to MatchServer.MP_MAX_HUMANS, and its presence count corrects the record)
		for _, c in open do
			if LobbyRules.fits(c, spec) and c.code ~= nil then
				c.players += n
				l = table.clone(c)
				break
			end
		end
		if l == nil then
			self:_log("join failed: " .. tostring(v))
			return false, LobbyDirectory.UNREACHABLE, nil
		end
		self:_log("join without a reservation (store busy): " .. tostring(v))
	end
	local lobby = l :: LobbyRules.Lobby
	local function give_back()
		if ok then
			pcall(deps.store.release, lobby.id, uids)
		end
	end
	if lobby.code == nil then
		give_back()
		return false, "That match is gone.", nil
	end
	if o.wanted ~= nil and not o.wanted() then
		give_back()
		return false, "cancelled", lobby
	end
	local data: { [string]: any } = { lobby = lobby.id, map = lobby.map }
	if n > 1 and o.party ~= nil then
		data.party = { key = o.party.key, uids = o.party.uids, leader = o.party.leader }
	end
	local sent, terr = deps.teleport.send(players, lobby.code, data)
	if not sent then
		give_back()
		return false, terr or "The teleport failed. Try again.", lobby
	end
	-- mirror the seats locally so the list shows them at once
	for _, c in self._lobbies do
		if c.id == lobby.id then
			c.players = lobby.players
		end
	end
	return true, nil, lobby
end

--- Gives back the seats of `uids` in lobby `id` (a teleport that failed after it began). Yields.
function LobbyDirectory.release(self: any, id: string, uids: { string }): number
	local ok, res, n = pcall(self.deps.store.release, id, uids)
	if not ok then
		self:_log("release failed: " .. tostring(res))
		return 0
	end
	return tonumber(n) or 0
end

--- Puts someone in line for a seat (QueueEntry); one entry per key (a new one replaces it).
function LobbyDirectory.enqueue(self: any, e: QueueEntry)
	self:dequeue(e.key)
	table.insert(self._queue, e)
end

--- Takes `key` out of the line (true if it was in it). Its `done` is not called.
function LobbyDirectory.dequeue(self: any, key: string): boolean
	for i, e in self._queue do
		if e.key == key then
			table.remove(self._queue, i)
			return true
		end
	end
	return false
end

function LobbyDirectory.queued(self: any, key: string): QueueEntry?
	for _, e in self._queue do
		if e.key == key then
			return e
		end
	end
	return nil
end

function LobbyDirectory.queue_size(self: any): number
	return #self._queue
end

--- One pass over the line: oldest first, up to QUEUE_BATCH store calls; per kind, once n seats were
--- missing, nobody needing n or more is tried this pass (someone smaller still may fit). Yields.
function LobbyDirectory.serve_queue(self: any)
	local now = self.deps.now()
	local calls = 0
	local blocked: { [string]: number } = {}
	for _, e in table.clone(self._queue) do
		if calls >= LobbyDirectory.QUEUE_BATCH then
			break
		end
		if self:queued(e.key) ~= e then
			continue -- (left the line meanwhile)
		end
		if now - e.since > LobbyDirectory.QUEUE_MAX_S then
			self:dequeue(e.key)
			e.done(false, "timeout", nil)
			continue
		end
		local players, party = e.members()
		if players == nil or #players == 0 then
			self:dequeue(e.key)
			e.done(false, "gone", nil)
			continue
		end
		local n = #players
		if blocked[e.mode] ~= nil and n >= blocked[e.mode] then
			continue
		end
		calls += 1
		local ok, reason, l = self:join_public(players, e.mode, {
			party = party,
			wanted = function(): boolean
				return self:queued(e.key) == e
			end,
		})
		if ok then
			self:dequeue(e.key)
			e.done(true, nil, l, players)
		elseif reason == LobbyDirectory.NO_ROOM then
			blocked[e.mode] = math.min(blocked[e.mode] or math.huge, n)
		elseif reason ~= "cancelled" then
			self:dequeue(e.key)
			e.done(false, reason, l, players)
		end
	end
end

--- Per-frame: serve the line every QUEUE_RETRY_S (in its own thread; `spawn` as in tick).
function LobbyDirectory.tick_queue(self: any, dt: number, spawn: ((() -> ()) -> ())?)
	self._queue_in -= dt
	if self._queue_in > 0 or self._queue_busy or #self._queue == 0 then
		return
	end
	self._queue_in = LobbyDirectory.QUEUE_RETRY_S
	self._queue_busy = true
	local run = function()
		local ok, err = pcall(self.serve_queue, self)
		if not ok then
			self:_log("queue failed: " .. tostring(err))
		end
		self._queue_busy = false
	end
	if spawn then
		spawn(run)
	else
		run()
	end
end

return LobbyDirectory
